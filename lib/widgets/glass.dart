import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// Re-export the package's key types so call-sites can import them from a
// single place instead of importing both libraries.
// Note: GlassAppBar, GlassCard, GlassScaffold are intentionally excluded here
// because this file defines its own drop-in-compatible versions with extended
// APIs (e.g. GlassAppBar supports a `bottom` TabBar slot; GlassScaffold keeps
// the MediaQuery-inflation architecture for the call/location overlays).
export 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show
        GlassContainer,
        GlassPanel,
        GlassButton,
        GlassSwitch,
        GlassSlider,
        GlassSheet,
        GlassDialog,
        GlassDialogAction,
        GlassModalSheet,
        GlassBottomBar,
        GlassBottomBarTab,
        GlassQuality,
        LiquidGlassSettings,
        LiquidShape,
        LiquidOval,
        LiquidRoundedSuperellipse,
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
            color: scheme.surface.withValues(alpha: isDark ? 0.97 : 0.99),
            borderRadius: borderRadius,
            border: border,
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
                padding: iconPadding ?? const EdgeInsets.fromLTRB(0, 24, 0, 0),
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
                  ),
                  textAlign: TextAlign.center,
                  child: title!,
                ),
              ),
            if (content != null)
              Padding(
                padding:
                    contentPadding ?? const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: DefaultTextStyle(
                  style: textTheme.bodyMedium!.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.80),
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
                    letterSpacing: 0.4,
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
    );
  }
}

// ── LiquidMeshBackground ─────────────────────────────────────────────────────

/// A rich gradient background used behind glass surfaces on auth and lock
/// screens. Simulates the "dynamic wallpaper" aesthetic of iOS 26: deep
/// midnight layers with soft radial light pools in indigo, blue and teal.
class LiquidMeshBackground extends StatelessWidget {
  final Widget child;
  final List<Color>? colors;

  const LiquidMeshBackground({super.key, required this.child, this.colors});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final seed = Theme.of(context).colorScheme.primary;

    final defaultDark = [
      const Color(0xFF060D1C),
      const Color(0xFF0B1527),
      const Color(0xFF0F1A32),
    ];
    final defaultLight = [
      const Color(0xFFE8F0FE),
      const Color(0xFFF0F4FF),
      const Color(0xFFFAFBFF),
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
        // Radial accent pools
        Positioned(
          top: -120,
          left: -80,
          width: 420,
          height: 420,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  seed.withValues(alpha: isDark ? 0.28 : 0.14),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        Positioned(
          bottom: -100,
          right: -60,
          width: 380,
          height: 380,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  const Color(
                    0xFF00B4D8,
                  ).withValues(alpha: isDark ? 0.22 : 0.10),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: 220,
          right: -40,
          width: 260,
          height: 260,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  const Color(
                    0xFF7B2FFF,
                  ).withValues(alpha: isDark ? 0.16 : 0.08),
                  Colors.transparent,
                ],
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
            letterSpacing: -0.2,
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
    final content = scrollable ? SingleChildScrollView(child: child) : child;

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

// Keep old name as alias for backwards compat
typedef OldGlassButton = GlassButtonWidget;
