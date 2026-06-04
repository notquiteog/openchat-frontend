import 'dart:ui';
import 'package:flutter/material.dart';

/// Whether the platform/user has asked for reduced transparency.
bool glassReduceTransparency(BuildContext context) =>
    MediaQuery.highContrastOf(context);

// ── Gradient border painter ─────────────────────────────────────────────────

/// Paints the iOS 26-style prismatic specular rim: bright white at the top
/// edge fading to a near-invisible accent at the bottom. The topmost arc
/// acts as a "dew-drop" highlight that makes the surface look truly liquid.
class _SpecularBorderPainter extends CustomPainter {
  final BorderRadius borderRadius;
  final double strokeWidth;
  final bool isDark;

  const _SpecularBorderPainter({
    required this.borderRadius,
    required this.strokeWidth,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final hw = strokeWidth / 2;
    final rrect = RRect.fromRectAndCorners(
      Rect.fromLTWH(
        hw,
        hw,
        size.width - strokeWidth,
        size.height - strokeWidth,
      ),
      topLeft: borderRadius.topLeft,
      topRight: borderRadius.topRight,
      bottomLeft: borderRadius.bottomLeft,
      bottomRight: borderRadius.bottomRight,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: const [0.0, 0.15, 0.5, 1.0],
        colors: [
          Colors.white.withValues(alpha: isDark ? 0.48 : 0.58),
          Colors.white.withValues(alpha: isDark ? 0.24 : 0.34),
          Colors.white.withValues(alpha: isDark ? 0.07 : 0.11),
          Colors.white.withValues(alpha: isDark ? 0.03 : 0.05),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_SpecularBorderPainter old) =>
      old.isDark != isDark ||
      old.strokeWidth != strokeWidth ||
      old.borderRadius != borderRadius;
}

// ── LiquidGlass ─────────────────────────────────────────────────────────────

/// The primary iOS 26 Liquid Glass surface: free-floating chrome that hovers
/// above content with a heavy backdrop blur (30–36 sigma), a prismatic top-rim
/// highlight, a soft inner glow and a generous ambient shadow.
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

  /// Fill tint. Defaults to the theme surface so the canvas colour bleeds
  /// through. Pass a brand colour for accented controls (e.g. a send button).
  final Color? tint;

  /// Specular stroke width (Apple spec ≈ 0.5–0.8 dp).
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
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = tint ?? scheme.surface;

    final shadow =
        boxShadow ??
        [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.42 : 0.10),
            blurRadius: 32,
            spreadRadius: -6,
            offset: const Offset(0, 14),
          ),
          BoxShadow(
            color: base.withValues(alpha: isDark ? 0.04 : 0.05),
            blurRadius: 8,
            spreadRadius: 0,
            offset: const Offset(0, 1),
          ),
        ];

    // Reduced transparency fallback: flat, opaque, legible.
    if (glassReduceTransparency(context)) {
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: shadow,
        ),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: base.withValues(alpha: isDark ? 0.97 : 0.99),
              borderRadius: borderRadius,
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
            child: child,
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: shadow,
        ),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: Stack(
              children: [
                // Main glass fill: highly transparent, gradient from
                // slightly more opaque at top to very clear at bottom.
                Container(
                  padding: padding,
                  decoration: BoxDecoration(
                    borderRadius: borderRadius,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.0, 0.6, 1.0],
                      colors: [
                        base.withValues(alpha: isDark ? 0.50 : 0.56),
                        base.withValues(alpha: isDark ? 0.40 : 0.48),
                        base.withValues(alpha: isDark ? 0.32 : 0.40),
                      ],
                    ),
                  ),
                  child: child,
                ),
                // Inner top-highlight: a very narrow white glow at the top
                // edge inside the glass — the "dew-drop" effect.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: borderRadius.topLeft.x.clamp(0.0, 16.0),
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.vertical(
                          top: borderRadius.topLeft,
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withValues(
                              alpha: isDark ? 0.20 : 0.30,
                            ),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // Prismatic specular rim — gradient stroke drawn on top.
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _SpecularBorderPainter(
                        borderRadius: borderRadius,
                        strokeWidth: stroke,
                        isDark: isDark,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── GlassSurface ─────────────────────────────────────────────────────────────

/// Edge-to-edge frosted glass for chrome that fills its slot: app bars,
/// the incoming call overlay, the voice recorder tray. New *floating* chrome
/// should use [LiquidGlass].
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
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: boxShadow,
        ),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: isDark ? 0.97 : 0.99),
              borderRadius: borderRadius,
              border: border,
            ),
            child: child,
          ),
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
                    scheme.surface.withValues(alpha: isDark ? 0.48 : 0.54),
                    scheme.surface.withValues(alpha: isDark ? 0.38 : 0.46),
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

/// A raised, glass-backed panel for grouping content — used in settings,
/// profile screens, and info panels. Lighter fill than [LiquidGlass] since
/// it sits on a static background rather than live-scrolling content.
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
    final scheme = Theme.of(context).colorScheme;
    final base = tint ?? scheme.surfaceContainerLow;

    Widget glass = LiquidGlass(
      blur: blur,
      borderRadius: borderRadius,
      padding: padding,
      tint: base,
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark ? 0.24 : 0.05),
          blurRadius: 20,
          spreadRadius: -4,
          offset: const Offset(0, 8),
        ),
      ],
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
///
/// Renders as a transparent [Dialog] backed by [LiquidGlass] so the
/// backdrop blur punches through the modal barrier for a true frosted effect.
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
      child: LiquidGlass(
        blur: 56,
        borderRadius: const BorderRadius.all(Radius.circular(28)),
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
///
/// Uses [LiquidGlass] as its container so the backdrop blur is applied through
/// the modal barrier, giving a true frosted-glass appearance.
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
      child: LiquidGlass(
        blur: 56,
        borderRadius: const BorderRadius.all(Radius.circular(28)),
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
        // Base gradient
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
