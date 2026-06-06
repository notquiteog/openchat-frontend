import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    hide GlassContainer, GlassDialog, GlassDialogAction;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lg;

// Re-export the package's key types so call-sites can import them from a
// single place instead of importing both libraries.
// Note: GlassAppBar, GlassCard, GlassScaffold are intentionally excluded here
// because this file defines its own drop-in-compatible versions with extended
// APIs (e.g. GlassAppBar supports a `bottom` TabBar slot; GlassScaffold keeps
// the MediaQuery-inflation architecture for the call/location overlays).
export 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show
        // Containers
        GlassListTile,
        GlassGroupedSection,
        GlassDivider,
        // Interactive
        GlassButton,
        GlassButtonStyle,
        GlassSwitch,
        GlassSlider,
        GlassIconButton,
        GlassChip,
        GlassBadge,
        GlassSegmentedControl,
        GlassPicker,
        GlassPageControl,
        // Input
        GlassTextField,
        GlassPasswordField,
        GlassSearchBar,
        // Feedback
        GlassProgressIndicator,
        GlassToast,
        // Overlays
        GlassSheet,
        GlassModalSheet,
        showGlassActionSheet,
        GlassActionSheetAction,
        GlassActionSheetStyle,
        GlassPopover,
        // Surfaces
        GlassBottomBar,
        GlassBottomBarTab,
        GlassPage,
        GlassStatusBarStyle,
        GlassScrollEdgeEffect,
        // Config & types
        GlassQuality,
        LiquidGlassSettings,
        LiquidShape,
        LiquidOval,
        LiquidRoundedSuperellipse,
        GlassTheme,
        GlassThemeData,
        GlassThemeVariant,
        GlassThemeSettings,
        GlassAccessibilityScope,
        GlassAccessibilityData;

/// Whether the user or the platform has requested reduced transparency.
///
/// Checks (in priority order):
///  1. An explicit [GlassAccessibilityScope] in the widget tree — this is how
///     the app's in-app "Reduce transparency" setting propagates down.
///  2. The system `MediaQuery.highContrastOf` flag (iOS/Android accessibility).
bool glassReduceTransparency(BuildContext context) =>
    GlassAccessibilityData.of(context).reduceTransparency;

Color reducedGlassSurfaceColor(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final isDark = theme.brightness == Brightness.dark;
  final base = isDark
      ? scheme.surfaceContainerHigh
      : scheme.surfaceContainerLow;
  final tint = scheme.primary.withValues(alpha: isDark ? 0.08 : 0.025);
  return Color.alphaBlend(tint, base).withValues(alpha: 1);
}

Color _reducedGlassOutlineColor(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final isDark = theme.brightness == Brightness.dark;
  return isDark
      ? Colors.white.withValues(alpha: 0.14)
      : scheme.outlineVariant.withValues(alpha: 0.62);
}

ShapeBorder _shapeWithFallbackSide(BuildContext context, LiquidShape shape) {
  if (shape.side != BorderSide.none) return shape;
  return shape.copyWith(
    side: BorderSide(color: _reducedGlassOutlineColor(context), width: 0.7),
  );
}

class GlassContainer extends StatelessWidget {
  final Widget? child;
  final AlignmentGeometry? alignment;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final LiquidShape shape;
  final LiquidGlassSettings? settings;
  final bool useOwnLayer;
  final GlassQuality? quality;
  final Clip clipBehavior;
  final bool allowElevation;
  final double glowIntensity;

  const GlassContainer({
    super.key,
    this.child,
    this.width,
    this.height,
    this.padding,
    this.margin,
    this.shape = const LiquidRoundedSuperellipse(borderRadius: 16),
    this.settings,
    this.useOwnLayer = false,
    this.quality,
    this.clipBehavior = Clip.none,
    this.alignment,
    this.allowElevation = false,
    this.glowIntensity = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    if (!glassReduceTransparency(context)) {
      return lg.GlassContainer(
        width: width,
        height: height,
        padding: padding,
        margin: margin,
        shape: shape,
        settings: settings,
        useOwnLayer: useOwnLayer,
        quality: quality,
        clipBehavior: clipBehavior,
        alignment: alignment,
        allowElevation: allowElevation,
        glowIntensity: glowIntensity,
        child: child,
      );
    }

    Widget content = child ?? const SizedBox.shrink();
    if (padding != null) {
      content = Padding(padding: padding!, child: content);
    }
    if (alignment != null) {
      content = Align(alignment: alignment!, child: content);
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final effectiveShape = _shapeWithFallbackSide(context, shape);
    Widget surface = DecoratedBox(
      decoration: ShapeDecoration(
        color: reducedGlassSurfaceColor(context),
        shape: effectiveShape,
        shadows: allowElevation
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.34 : 0.10),
                  blurRadius: 24,
                  spreadRadius: -10,
                  offset: const Offset(0, 12),
                ),
              ]
            : null,
      ),
      child: content,
    );

    if (clipBehavior != Clip.none) {
      surface = ClipPath(
        clipper: ShapeBorderClipper(shape: effectiveShape),
        clipBehavior: clipBehavior,
        child: surface,
      );
    }
    if (width != null || height != null) {
      surface = SizedBox(width: width, height: height, child: surface);
    }
    if (margin != null) {
      surface = Padding(padding: margin!, child: surface);
    }
    return surface;
  }
}

// ── LiquidGlass ─────────────────────────────────────────────────────────────

/// The primary iOS 26 Liquid Glass surface backed by the liquid_glass_widgets
/// shader pipeline. On Impeller (iOS/Android) this renders real refraction
/// distortion and chromatic aberration; on Skia/desktop it uses a lightweight
/// fragment shader with BackdropFilter fallback.
///
/// Use this for any chrome that *floats* over the canvas: nav pills, the
/// message composer, floating action controls. Edge-to-edge chrome (app bars,
/// full-screen backgrounds) should use [GlassSurface] instead.
class LiquidGlass extends StatelessWidget {
  final Widget child;
  final double blur;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final List<BoxShadow>? boxShadow;
  final Color? tint;
  final double stroke;

  const LiquidGlass({
    super.key,
    required this.child,
    this.blur = 64,
    this.borderRadius = const BorderRadius.all(Radius.circular(28)),
    this.padding,
    this.boxShadow,
    this.tint,
    this.stroke = 0.7,
  });

  /// Full capsule (pill) geometry — the default for floating bars.
  const LiquidGlass.capsule({
    super.key,
    required this.child,
    this.blur = 64,
    this.padding,
    this.boxShadow,
    this.tint,
    this.stroke = 0.7,
  }) : borderRadius = const BorderRadius.all(Radius.circular(999));

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isCapsule =
        borderRadius == const BorderRadius.all(Radius.circular(999));
    final cornerR = borderRadius.topLeft.x.clamp(0.0, 200.0);

    // Map our borderRadius to the package's LiquidShape:
    // – 999 → LiquidRoundedSuperellipse(999) (iOS squircle-capsule)
    // – anything else → LiquidRoundedSuperellipse (Apple squircle)
    // Note: LiquidOval maps to OvalBorder (a geometric ellipse) which looks
    // wrong on non-square or wide widgets — use LiquidRoundedSuperellipse(999)
    // for all capsule/pill shapes instead.
    final shape = isCapsule
        ? const LiquidRoundedSuperellipse(borderRadius: 999)
        : LiquidRoundedSuperellipse(borderRadius: cornerR);

    final shadow =
        boxShadow ??
        [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.42 : 0.10),
            blurRadius: 32,
            spreadRadius: -6,
            offset: const Offset(0, 14),
          ),
        ];

    Widget container = GlassContainer(
      shape: shape,
      padding: padding,
      allowElevation: true,
      glowIntensity: isDark ? 0.06 : 0.04,
      child: child,
    );

    // Apply tint overlay when explicitly set (e.g. primary-coloured FAB).
    if (tint != null) {
      container = ColorFiltered(
        colorFilter: ColorFilter.mode(
          tint!.withValues(alpha: isDark ? 0.16 : 0.10),
          BlendMode.srcATop,
        ),
        child: container,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: shadow,
        borderRadius: isCapsule ? null : borderRadius,
        shape: isCapsule ? BoxShape.rectangle : BoxShape.rectangle,
      ),
      child: container,
    );
  }
}

// ── GlassSurface ─────────────────────────────────────────────────────────────

/// Edge-to-edge frosted glass for chrome that fills its slot: app bars,
/// the incoming call overlay, the voice recorder tray. Uses BackdropFilter
/// since GlassContainer needs a bounded context that edge-to-edge surfaces
/// can't always provide.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final double blur;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final Border? border;
  final List<BoxShadow>? boxShadow;

  const GlassSurface({
    super.key,
    required this.child,
    this.blur = 60,
    this.borderRadius = BorderRadius.zero,
    this.padding,
    this.border,
    this.boxShadow,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (glassReduceTransparency(context)) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: reducedGlassSurfaceColor(context),
            borderRadius: borderRadius,
            border:
                border ??
                Border.all(
                  color: _reducedGlassOutlineColor(context),
                  width: 0.7,
                ),
            boxShadow: boxShadow,
          ),
          child: child,
        ),
      );
    }

    final effectiveBorder =
        border ??
        Border.all(
          color: Colors.white.withValues(alpha: isDark ? 0.10 : 0.24),
          width: 0.5,
        );

    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: boxShadow,
        ),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: Container(
              padding: padding,
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                border: effectiveBorder,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    scheme.surface.withValues(alpha: isDark ? 0.20 : 0.26),
                    scheme.surface.withValues(alpha: isDark ? 0.14 : 0.18),
                  ],
                ),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

// ── GlassAppBar ───────────────────────────────────────────────────────────────

/// Frosted AppBar for screens with [Scaffold.extendBodyBehindAppBar].
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool centerTitle;
  final PreferredSizeWidget? bottom;
  final double? titleSpacing;

  const GlassAppBar({
    super.key,
    required this.title,
    this.actions,
    this.leading,
    this.centerTitle = false,
    this.bottom,
    this.titleSpacing,
  });

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      blur: 60,
      child: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: title,
        actions: actions,
        leading: leading,
        centerTitle: centerTitle,
        bottom: bottom,
        titleSpacing: titleSpacing,
      ),
    );
  }
}

// ── GlassCard ────────────────────────────────────────────────────────────────

/// A raised glass-backed panel for grouping content — uses the package's
/// GlassContainer for real shader-backed glass rendering.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final BorderRadius borderRadius;
  final double blur;
  final Color? tint;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.margin,
    this.borderRadius = const BorderRadius.all(Radius.circular(22)),
    this.blur = 50,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final r = borderRadius.topLeft.x.clamp(0.0, 200.0);

    Widget glass = GlassContainer(
      shape: LiquidRoundedSuperellipse(borderRadius: r),
      padding: padding,
      allowElevation: true,
      glowIntensity: isDark ? 0.04 : 0.02,
      child: child,
    );

    if (margin != null) {
      glass = Padding(padding: margin!, child: glass);
    }
    return glass;
  }
}

TextStyle _glassOverlayTextStyle(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return (Theme.of(context).textTheme.bodyMedium ??
          TextStyle(color: scheme.onSurface, fontSize: 14))
      .copyWith(
        color: scheme.onSurface,
        decoration: TextDecoration.none,
        letterSpacing: 0,
      );
}

class _GlassOverlayTextScope extends StatelessWidget {
  final Widget child;

  const _GlassOverlayTextScope({required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DefaultTextStyle(
      style: _glassOverlayTextStyle(context),
      child: IconTheme(
        data: IconThemeData(
          color: scheme.onSurface.withValues(alpha: 0.86),
          size: 21,
        ),
        child: child,
      ),
    );
  }
}

class GlassDialogAction {
  final String label;
  final VoidCallback onPressed;
  final bool isPrimary;
  final bool isDestructive;

  const GlassDialogAction({
    required this.label,
    required this.onPressed,
    this.isPrimary = false,
    this.isDestructive = false,
  });
}

class GlassDialog {
  const GlassDialog._();

  static Future<T?> show<T>({
    required BuildContext context,
    required List<GlassDialogAction> actions,
    String? title,
    String? message,
    Widget? content,
    LiquidGlassSettings? settings,
    GlassQuality quality = GlassQuality.standard,
    bool barrierDismissible = false,
    Color? barrierColor,
    double maxWidth = 280,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor ?? Colors.black.withValues(alpha: 0.35),
      builder: (dialogContext) => GlassAlertDialog(
        title: title == null ? null : Text(title),
        content: SizedBox(
          width: maxWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message != null)
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(
                      dialogContext,
                    ).colorScheme.onSurface.withValues(alpha: 0.72),
                    height: 1.4,
                  ),
                ),
              if (message != null && content != null)
                const SizedBox(height: 12),
              ?content,
            ],
          ),
        ),
        actions: [
          for (final action in actions)
            if (action.isPrimary || action.isDestructive)
              FilledButton(
                style: action.isDestructive
                    ? FilledButton.styleFrom(
                        backgroundColor: Theme.of(
                          dialogContext,
                        ).colorScheme.error,
                        foregroundColor: Theme.of(
                          dialogContext,
                        ).colorScheme.onError,
                      )
                    : null,
                onPressed: action.onPressed,
                child: Text(action.label),
              )
            else
              TextButton(
                onPressed: action.onPressed,
                child: Text(action.label),
              ),
        ],
      ),
    );
  }
}

// ── GlassAlertDialog ─────────────────────────────────────────────────────────

/// iOS 26 glass alert dialog — drop-in replacement for [AlertDialog].
/// Renders as a transparent [Dialog] backed by [GlassContainer] so the
/// shader pipeline renders true refraction through the modal barrier.
class GlassAlertDialog extends StatelessWidget {
  final Widget? icon;
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? iconPadding;
  final EdgeInsetsGeometry? titlePadding;
  final EdgeInsetsGeometry? contentPadding;
  final EdgeInsetsGeometry? actionsPadding;
  final MainAxisAlignment actionsAlignment;

  const GlassAlertDialog({
    super.key,
    this.icon,
    this.title,
    this.content,
    this.actions,
    this.iconPadding,
    this.titlePadding,
    this.contentPadding,
    this.actionsPadding,
    this.actionsAlignment = MainAxisAlignment.end,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: _GlassOverlayTextScope(
        child: GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 28),
          allowElevation: true,
          glowIntensity: 0.05,
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (icon != null)
                Padding(
                  padding:
                      iconPadding ?? const EdgeInsets.fromLTRB(0, 24, 0, 0),
                  child: IconTheme(
                    data: IconThemeData(color: scheme.primary, size: 32),
                    child: Align(alignment: Alignment.center, child: icon!),
                  ),
                ),
              if (title != null)
                Padding(
                  padding:
                      titlePadding ??
                      EdgeInsets.fromLTRB(24, icon != null ? 12 : 24, 24, 0),
                  child: DefaultTextStyle(
                    style: textTheme.headlineSmall!.copyWith(
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.none,
                      letterSpacing: 0,
                    ),
                    textAlign: TextAlign.center,
                    child: title!,
                  ),
                ),
              if (content != null)
                Padding(
                  padding:
                      contentPadding ??
                      const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  child: DefaultTextStyle(
                    style: textTheme.bodyMedium!.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.80),
                      decoration: TextDecoration.none,
                      letterSpacing: 0,
                    ),
                    child: content!,
                  ),
                ),
              if (actions != null && actions!.isNotEmpty) ...[
                Divider(
                  height: 1,
                  thickness: 0.5,
                  color: scheme.outlineVariant.withValues(alpha: 0.40),
                ),
                Padding(
                  padding:
                      actionsPadding ??
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    mainAxisAlignment: actionsAlignment,
                    children: actions!,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── GlassSimpleDialog ─────────────────────────────────────────────────────────

/// iOS 26 glass simple dialog — drop-in replacement for [SimpleDialog].
class GlassSimpleDialog extends StatelessWidget {
  final Widget? title;
  final List<Widget>? children;
  final EdgeInsetsGeometry? titlePadding;
  final EdgeInsetsGeometry? contentPadding;

  const GlassSimpleDialog({
    super.key,
    this.title,
    this.children,
    this.titlePadding,
    this.contentPadding,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: _GlassOverlayTextScope(
        child: GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 28),
          allowElevation: true,
          glowIntensity: 0.05,
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                Padding(
                  padding:
                      titlePadding ?? const EdgeInsets.fromLTRB(24, 20, 24, 8),
                  child: DefaultTextStyle(
                    style: textTheme.titleMedium!.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.55),
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                      letterSpacing: 0,
                    ),
                    child: title!,
                  ),
                ),
              if (children != null)
                Padding(
                  padding:
                      contentPadding ?? const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children!,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── LiquidMeshBackground ─────────────────────────────────────────────────────

/// A rich gradient background used behind glass surfaces on auth and lock
/// screens. Simulates the "dynamic wallpaper" aesthetic of iOS 26 with layered
/// color fields that keep the chrome readable without obvious decorative blobs.
class LiquidMeshBackground extends StatelessWidget {
  final Widget child;
  final List<Color>? colors;

  const LiquidMeshBackground({super.key, required this.child, this.colors});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final seed = Theme.of(context).colorScheme.primary;

    final defaultDark = [
      const Color(0xFF07080B),
      const Color(0xFF10161A),
      const Color(0xFF17121A),
    ];
    final defaultLight = [
      const Color(0xFFF8FAFC),
      const Color(0xFFEFF7F2),
      const Color(0xFFF7F2FA),
    ];

    final bg = colors ?? (isDark ? defaultDark : defaultLight);

    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: bg,
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [
                  seed.withValues(alpha: isDark ? 0.20 : 0.08),
                  Colors.transparent,
                  const Color(
                    0xFF0FAF8F,
                  ).withValues(alpha: isDark ? 0.14 : 0.07),
                ],
                stops: const [0, 0.44, 1],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomRight,
                end: Alignment.topLeft,
                colors: [
                  const Color(
                    0xFF9B5DE5,
                  ).withValues(alpha: isDark ? 0.10 : 0.05),
                  Colors.transparent,
                  Colors.white.withValues(alpha: isDark ? 0.02 : 0.36),
                ],
                stops: const [0, 0.52, 1],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

// ── GlassButtonWidget ─────────────────────────────────────────────────────────

/// iOS 26 glass capsule button with physics-driven jelly animations.
///
/// Wraps the package's [GlassButton.custom] so callers get real Impeller
/// shader-backed glass + squish/stretch on tap, while keeping the same
/// constructor API as the old BackdropFilter-based button.
class GlassButtonWidget extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget child;
  final Color? color;
  final Color? foregroundColor;
  final EdgeInsetsGeometry padding;
  final double blur;

  const GlassButtonWidget({
    super.key,
    required this.onPressed,
    required this.child,
    this.color,
    this.foregroundColor,
    this.padding = const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
    this.blur = 24,
  });

  factory GlassButtonWidget.icon({
    Key? key,
    required VoidCallback? onPressed,
    required Widget icon,
    required Widget label,
    Color? color,
    Color? foregroundColor,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
      horizontal: 20,
      vertical: 14,
    ),
    double blur = 24,
  }) {
    return GlassButtonWidget(
      key: key,
      onPressed: onPressed,
      color: color,
      foregroundColor: foregroundColor,
      padding: padding,
      blur: blur,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [icon, const SizedBox(width: 8), label],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Glass surface tracks the ambient theme — use white text in dark mode
    // and near-black text in light mode. If a tint color is given, honour it.
    final fg =
        foregroundColor ??
        (color != null
            ? (ThemeData.estimateBrightnessForColor(color!) == Brightness.dark
                  ? Colors.white
                  : Colors.black87)
            : (isDark ? Colors.white : Colors.black87));

    return GlassButton.custom(
      onTap: onPressed ?? () {},
      enabled: onPressed != null,
      shape: const LiquidRoundedSuperellipse(borderRadius: 999),
      child: Padding(
        padding: padding,
        child: DefaultTextStyle(
          style: TextStyle(
            color: fg,
            fontWeight: FontWeight.w700,
            fontSize: 15,
            letterSpacing: 0,
          ),
          child: IconTheme(
            data: IconThemeData(color: fg, size: 18),
            child: child,
          ),
        ),
      ),
    );
  }
}

class GlassCircleIconButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget icon;
  final String tooltip;
  final double size;
  final double glowIntensity;

  const GlassCircleIconButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.tooltip,
    this.size = 42,
    this.glowIntensity = 0.08,
  });

  @override
  Widget build(BuildContext context) {
    final surface = Opacity(
      opacity: onPressed == null ? 0.45 : 1,
      child: SizedBox.square(
        dimension: size,
        child: GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 999),
          allowElevation: true,
          glowIntensity: glowIntensity,
          padding: EdgeInsets.zero,
          child: Center(child: icon),
        ),
      ),
    );

    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: tooltip,
        child: MouseRegion(
          cursor: onPressed == null
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
            child: surface,
          ),
        ),
      ),
    );
  }
}

class GlassBottomSheetFrame extends StatelessWidget {
  final Widget child;
  final EdgeInsets margin;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final double glowIntensity;
  final bool allowElevation;
  final bool includeKeyboardInset;
  final bool scrollable;
  final double maxHeightFactor;

  const GlassBottomSheetFrame({
    super.key,
    required this.child,
    this.margin = const EdgeInsets.fromLTRB(14, 0, 14, 14),
    this.padding = EdgeInsets.zero,
    this.borderRadius = 28,
    this.glowIntensity = 0.06,
    this.allowElevation = true,
    this.includeKeyboardInset = true,
    this.scrollable = true,
    this.maxHeightFactor = 0.92,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scheme = Theme.of(context).colorScheme;
    final keyboardInset = includeKeyboardInset ? media.viewInsets.bottom : 0.0;
    final reservedHeight =
        media.padding.top +
        media.padding.bottom +
        keyboardInset +
        margin.top +
        margin.bottom +
        8;
    final maxHeight = math.max(
      0.0,
      (media.size.height - reservedHeight) * maxHeightFactor,
    );
    final sheetBodyStyle =
        Theme.of(context).textTheme.bodyMedium ??
        TextStyle(color: scheme.onSurface, fontSize: 14);
    final content = DefaultTextStyle(
      style: sheetBodyStyle.copyWith(
        color: scheme.onSurface,
        decoration: TextDecoration.none,
        letterSpacing: 0,
      ),
      child: IconTheme(
        data: IconThemeData(
          color: scheme.onSurface.withValues(alpha: 0.86),
          size: 21,
        ),
        child: scrollable ? SingleChildScrollView(child: child) : child,
      ),
    );

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          margin.left,
          margin.top,
          margin.right,
          margin.bottom + keyboardInset,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: GlassContainer(
            shape: LiquidRoundedSuperellipse(borderRadius: borderRadius),
            allowElevation: allowElevation,
            glowIntensity: glowIntensity,
            padding: padding,
            child: content,
          ),
        ),
      ),
    );
  }
}

class GlassSheetGrabber extends StatelessWidget {
  const GlassSheetGrabber({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 38,
        height: 4,
        margin: const EdgeInsets.only(top: 12, bottom: 8),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}

class GlassSheetHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final VoidCallback? onClose;

  const GlassSheetHeader({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 12, 10),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: 0.13),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.16),
                width: 0.5,
              ),
            ),
            child: Icon(icon, color: scheme.primary, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.56),
                      height: 1.25,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ],
            ),
          ),
          for (final action in actions) action,
          if (onClose != null) ...[
            const SizedBox(width: 4),
            GlassCircleIconButton(
              tooltip: 'Close',
              size: 36,
              glowIntensity: 0.04,
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ],
      ),
    );
  }
}

class GlassActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;
  final Color? color;
  final Widget? trailing;
  final bool selected;
  final bool dividerBefore;

  const GlassActionTile({
    super.key,
    required this.icon,
    required this.label,
    this.subtitle,
    this.onTap,
    this.color,
    this.trailing,
    this.selected = false,
    this.dividerBefore = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? (selected ? scheme.primary : scheme.primary);
    final textColor = color ?? scheme.onSurface;
    final radius = BorderRadius.circular(18);
    final tile = ClipRRect(
      borderRadius: radius,
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tint.withValues(alpha: selected ? 0.18 : 0.12),
                    border: Border.all(
                      color: tint.withValues(alpha: selected ? 0.28 : 0.10),
                      width: 0.5,
                    ),
                  ),
                  child: Icon(icon, size: 19, color: tint),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: textColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          letterSpacing: 0,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurface.withValues(alpha: 0.52),
                            fontSize: 12.5,
                            height: 1.25,
                            letterSpacing: 0,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 10), trailing!],
                if (selected && trailing == null)
                  Icon(Icons.check_circle_rounded, color: scheme.primary),
              ],
            ),
          ),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dividerBefore)
          Divider(
            height: 1,
            indent: 68,
            endIndent: 16,
            color: scheme.outlineVariant.withValues(alpha: 0.22),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: tile,
        ),
      ],
    );
  }
}
