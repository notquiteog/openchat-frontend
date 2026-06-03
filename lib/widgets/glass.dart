import 'dart:ui';
import 'package:flutter/material.dart';

/// Whether the platform/user has asked for reduced transparency.
///
/// Flutter does not surface iOS "Reduce Transparency" directly, so we treat the
/// closest exposed accessibility signal — "Increase Contrast" (highContrast) —
/// as the trigger to drop the live blur in favour of flat, high-opacity fills.
/// Every Liquid Glass surface honours this so legibility never depends on the
/// content behind it.
bool glassReduceTransparency(BuildContext context) =>
    MediaQuery.highContrastOf(context);

/// The functional/navigation layer material: a free-floating "Liquid Glass"
/// surface for chrome that hovers over content — nav pills, toolbars, the
/// message composer. It refracts the canvas with a heavy backdrop blur (sigma
/// 25-30), carries a hairline white specular stroke that reads as light
/// catching the rim, and lifts off the page with a soft ambient shadow.
///
/// The whole surface is isolated in a [RepaintBoundary] so the expensive blur
/// is not re-rasterised when sibling content repaints, and it collapses to a
/// flat opaque fill when [glassReduceTransparency] is set.
class LiquidGlass extends StatelessWidget {
  final Widget child;

  /// Backdrop blur sigma. Apple's Liquid Glass sits in the 25-30 range.
  final double blur;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;

  /// Ambient drop shadow. Defaults to a soft, theme-aware lift.
  final List<BoxShadow>? boxShadow;

  /// Fill tint. Defaults to the theme surface so the canvas colour bleeds
  /// through. Pass a brand colour for accented controls (e.g. a send button).
  final Color? tint;

  /// Specular rim width in logical pixels (Apple spec ≈ 0.5dp).
  final double stroke;

  const LiquidGlass({
    super.key,
    required this.child,
    this.blur = 28,
    this.borderRadius = const BorderRadius.all(Radius.circular(28)),
    this.padding,
    this.boxShadow,
    this.tint,
    this.stroke = 0.5,
  });

  /// A full-height capsule (pill) — the default geometry for floating bars.
  const LiquidGlass.capsule({
    super.key,
    required this.child,
    this.blur = 28,
    this.padding,
    this.boxShadow,
    this.tint,
    this.stroke = 0.5,
  }) : borderRadius = const BorderRadius.all(Radius.circular(999));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = tint ?? scheme.surface;

    final shadow = boxShadow ??
        [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.42 : 0.10),
            blurRadius: 24,
            spreadRadius: -4,
            offset: const Offset(0, 12),
          ),
        ];

    // Accessibility fallback: a flat, high-opacity panel with no live blur.
    if (glassReduceTransparency(context)) {
      return DecoratedBox(
        decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: shadow),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: base.withValues(alpha: isDark ? 0.97 : 0.99),
              borderRadius: borderRadius,
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
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
        decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: shadow),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: Container(
              padding: padding,
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                // Brighter at the top edge so light appears to pool along the
                // rim, fading as it bends through the body of the glass.
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    base.withValues(alpha: isDark ? 0.52 : 0.64),
                    base.withValues(alpha: isDark ? 0.28 : 0.42),
                  ],
                ),
                // 0.5dp inner white stroke — the specular reflection. Kept a
                // uniform colour so it stays compatible with [borderRadius].
                border: Border.all(
                  color: Colors.white.withValues(alpha: isDark ? 0.20 : 0.55),
                  width: stroke,
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

/// A frosted-glass surface: a backdrop blur behind a translucent, faintly
/// gradient fill with a hairline highlight border. Retained for chrome that
/// fills its slot edge-to-edge (app bars, the call banner, recorder tray).
/// New floating chrome should prefer [LiquidGlass].
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
    this.blur = 24,
    this.borderRadius = BorderRadius.zero,
    this.padding,
    this.border,
    this.boxShadow,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Honour reduced transparency: swap the blur for a flat, legible fill.
    if (glassReduceTransparency(context)) {
      return DecoratedBox(
        decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: boxShadow),
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

    // Default to a faint specular rim when the caller doesn't supply a border.
    final effectiveBorder = border ??
        Border.all(
          color: Colors.white.withValues(alpha: isDark ? 0.16 : 0.45),
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
                    scheme.surface.withValues(alpha: isDark ? 0.52 : 0.66),
                    scheme.surface.withValues(alpha: isDark ? 0.30 : 0.46),
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

/// A frosted, floating [AppBar] for screens that opt into
/// [Scaffold.extendBodyBehindAppBar]. Content scrolls underneath the blurred
/// bar for the signature glass effect. The harsh bottom divider is gone — the
/// specular rim and gradient now separate the bar from the canvas.
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
      blur: 28,
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
