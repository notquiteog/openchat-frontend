import 'package:flutter/material.dart';

// ── iOS 26 glass page transition ─────────────────────────────────────────────

/// Custom [PageTransitionsBuilder] that produces the iOS 26 depth-of-glass
/// transition: the entering page slides in from the right edge with a fade
/// while the exiting page fades and very slightly scales down, creating a
/// perceptual depth-of-field through the glass surface layers.
class _GlassPageTransitionsBuilder extends PageTransitionsBuilder {
  const _GlassPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final secondaryCurved = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: Tween<double>(begin: 0.88, end: 1.0).animate(secondaryCurved)
          ..drive(Tween<double>(begin: 1.0, end: 0.88)),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.05, 0),
          end: Offset.zero,
        ).animate(curved),
        child: FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Central Material 3 theme for OpenChat. Both light and dark variants are
/// generated from a single brand seed, then refined for iOS 26 Liquid Glass:
/// softer backgrounds, ultra-rounded surfaces, specular-rim chrome and
/// translucent navigation — all while staying on the Material colour system.
class AppTheme {
  AppTheme._();

  static const Color _seed = Color(0xFF3D5AFE);

  static ThemeData light({Color? seed}) =>
      _build(Brightness.light, seed ?? _seed);
  static ThemeData dark({Color? seed}) =>
      _build(Brightness.dark, seed ?? _seed);

  static ThemeData _build(Brightness brightness, Color seed) {
    final isDark = brightness == Brightness.dark;

    // Pure black / pure white base — maximum contrast beneath glass layers.
    final scaffoldBg = isDark ? Colors.black : Colors.white;

    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      // Anchor surface to the scaffold colour so glass tints read cleanly.
      surface: scaffoldBg,
      onSurface: isDark ? Colors.white : Colors.black,
    );

    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scaffoldBg,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      // Apply the depth-of-glass transition on every platform.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: _GlassPageTransitionsBuilder(),
          TargetPlatform.android: _GlassPageTransitionsBuilder(),
          TargetPlatform.macOS: _GlassPageTransitionsBuilder(),
          TargetPlatform.windows: _GlassPageTransitionsBuilder(),
          TargetPlatform.linux: _GlassPageTransitionsBuilder(),
          TargetPlatform.fuchsia: _GlassPageTransitionsBuilder(),
        },
      ),
    );

    return base.copyWith(
      textTheme: _textTheme(base.textTheme),

      appBarTheme: AppBarTheme(
        // GlassAppBar paints its own surface; this is just the theming fallback.
        backgroundColor: scheme.surface.withValues(alpha: isDark ? 0.20 : 0.28),
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        // Transparent — the LiquidGlass.capsule wrapping it supplies the fill.
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 56,
        indicatorShape: const StadiumBorder(),
        indicatorColor: scheme.primary.withValues(alpha: isDark ? 0.26 : 0.20),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11.5,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
            letterSpacing: -0.1,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
            size: 22,
          ),
        ),
      ),

      // Cards are glass-backed; remove any default elevation/tint.
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow.withValues(alpha: isDark ? 0.24 : 0.32),
        surfaceTintColor: Colors.transparent,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(
            color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.25),
            width: 0.5,
          ),
        ),
      ),

      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
        minVerticalPadding: 10,
      ),

      // Hairline dividers — glass surfaces do the separation visually.
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.12),
        thickness: 0.33,
        space: 0.33,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(
          alpha: isDark ? 0.16 : 0.20,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(
            color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.22),
            width: 0.5,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(
            color: Colors.white.withValues(alpha: isDark ? 0.10 : 0.26),
            width: 0.5,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        hintStyle: TextStyle(
          color: scheme.onSurface.withValues(alpha: 0.38),
          fontWeight: FontWeight.w400,
        ),
      ),

      // ── Buttons — iOS 26 Liquid Glass ────────────────────────────────────
      // All buttons use a stadium (full-pill) shape. FilledButton gains a thin
      // white specular rim; TextButton becomes a ghost capsule; OutlinedButton
      // gets a refined glass-quality border; FAB picks up a specular ring.

      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          ),
          shape: WidgetStateProperty.all(const StadiumBorder()),
          textStyle: WidgetStateProperty.all(
            const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              letterSpacing: -0.2,
            ),
          ),
          elevation: WidgetStateProperty.all(0),
          // Specular rim — white highlight that gives the glass-pill quality.
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return BorderSide.none;
            return BorderSide(
              color: Colors.white.withValues(
                alpha: isDark ? 0.22 : 0.38,
              ),
              width: 0.5,
            );
          }),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return Colors.white.withValues(alpha: 0.14);
            }
            if (states.contains(WidgetState.hovered)) {
              return Colors.white.withValues(alpha: 0.08);
            }
            return null;
          }),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            letterSpacing: -0.1,
          ),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          shape: const StadiumBorder(),
          backgroundColor: scheme.surfaceContainerHigh.withValues(
            alpha: isDark ? 0.60 : 0.78,
          ),
          foregroundColor: scheme.onSurface,
          side: BorderSide(
            color: Colors.white.withValues(alpha: isDark ? 0.14 : 0.30),
            width: 0.5,
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          shape: const StadiumBorder(),
          side: BorderSide(
            color: scheme.outline.withValues(alpha: isDark ? 0.50 : 0.65),
            width: 0.8,
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 15,
            letterSpacing: -0.1,
          ),
        ),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 0,
        highlightElevation: 0,
        backgroundColor: scheme.primary.withValues(alpha: isDark ? 0.82 : 0.92),
        foregroundColor: scheme.onPrimary,
        shape: CircleBorder(
          side: BorderSide(
            color: Colors.white.withValues(alpha: isDark ? 0.24 : 0.40),
            width: 0.5,
          ),
        ),
        extendedPadding: const EdgeInsets.symmetric(horizontal: 24),
        extendedTextStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 15,
          letterSpacing: -0.2,
        ),
        extendedIconLabelSpacing: 10,
      ),

      // Dialogs use GlassAlertDialog which manages its own surface — set the
      // container to transparent so the LiquidGlass blur shows through.
      // barrierColor is lightened so the frosted glass reads clearly.
      dialogTheme: DialogThemeData(
        elevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.35),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(28)),
        ),
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 19,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface.withValues(alpha: isDark ? 0.26 : 0.32),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        ),
        dragHandleColor: Colors.white.withValues(alpha: isDark ? 0.22 : 0.40),
        dragHandleSize: const Size(36, 4),
      ),

      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(
          color: Colors.white.withValues(alpha: isDark ? 0.10 : 0.28),
          width: 0.5,
        ),
        backgroundColor: scheme.surfaceContainerHighest.withValues(
          alpha: isDark ? 0.40 : 0.55,
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface.withValues(alpha: 0.92),
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 0,
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
      ),

      // PopupMenus follow the glass card treatment.
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface.withValues(alpha: isDark ? 0.38 : 0.44),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: Colors.white.withValues(alpha: isDark ? 0.10 : 0.28),
            width: 0.5,
          ),
        ),
      ),
    );
  }

  static TextTheme _textTheme(TextTheme base) => base.copyWith(
        displayLarge: base.displayLarge?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -1.0,
        ),
        displayMedium: base.displayMedium?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.8,
        ),
        displaySmall: base.displaySmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.6,
        ),
        headlineLarge: base.headlineLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        headlineMedium: base.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        headlineSmall: base.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        titleLarge: base.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        titleMedium: base.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
        ),
        labelLarge: base.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
        ),
        bodyLarge: base.bodyLarge?.copyWith(letterSpacing: -0.1),
        bodyMedium: base.bodyMedium?.copyWith(letterSpacing: -0.1),
      );
}
