import 'package:flutter/material.dart';

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
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );

    // Scaffold surfaces sit behind glass panes, so they should be richer and
    // deeper than a plain flat colour. We use a very dark navy (dark) / pure
    // near-white (light) so the glass tints read clearly against them.
    final scaffoldBg = brightness == Brightness.dark
        ? const Color(0xFF070E1B)
        : const Color(0xFFF5F7FF);

    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scaffoldBg,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
    );

    final isDark = brightness == Brightness.dark;

    return base.copyWith(
      textTheme: _textTheme(base.textTheme),

      appBarTheme: AppBarTheme(
        // GlassAppBar paints its own surface; this is just the theming fallback.
        backgroundColor: scheme.surface.withValues(alpha: isDark ? 0.48 : 0.62),
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
        height: 64,
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
        color: scheme.surfaceContainerLow.withValues(alpha: isDark ? 0.55 : 0.72),
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
          alpha: isDark ? 0.32 : 0.42,
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

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
            letterSpacing: -0.1,
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 0,
        highlightElevation: 0,
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: const CircleBorder(),
      ),

      // Dialogs are glass panels in iOS 26 — no opaque card, just blur + border.
      dialogTheme: DialogThemeData(
        elevation: 0,
        backgroundColor: scheme.surface.withValues(alpha: isDark ? 0.55 : 0.72),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(32),
          side: BorderSide(
            color: Colors.white.withValues(alpha: isDark ? 0.14 : 0.40),
            width: 0.7,
          ),
        ),
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 19,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface.withValues(alpha: isDark ? 0.55 : 0.70),
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
        color: scheme.surface.withValues(alpha: isDark ? 0.80 : 0.88),
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
