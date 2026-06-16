import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #50 — Accessibility settings: bold text, reduce motion, and an app-wide UI
/// text scale. All three are device-level SharedPreferences prefs that survive
/// logout, and reduce-motion short-circuits the glass page transition.
void main() {
  group('SettingsProvider accessibility prefs', () {
    test('default to off / 1.0 when unset', () async {
      SharedPreferences.setMockInitialValues({});
      final p = SettingsProvider();
      await p.load();
      expect(p.boldText, isFalse);
      expect(p.reduceMotion, isFalse);
      expect(p.uiTextScale, 1.0);
    });

    test('setters notify and persist across instances', () async {
      SharedPreferences.setMockInitialValues({});
      final p = SettingsProvider();
      await p.load();

      var notified = 0;
      p.addListener(() => notified++);

      await p.setBoldText(true);
      await p.setReduceMotion(true);
      await p.setUiTextScale(1.2);
      expect(p.boldText, isTrue);
      expect(p.reduceMotion, isTrue);
      expect(p.uiTextScale, 1.2);
      expect(notified, greaterThanOrEqualTo(3));

      final reloaded = SettingsProvider();
      await reloaded.load();
      expect(reloaded.boldText, isTrue);
      expect(reloaded.reduceMotion, isTrue);
      expect(reloaded.uiTextScale, 1.2);
    });

    test('uiTextScale is clamped to [min, max]', () async {
      SharedPreferences.setMockInitialValues({});
      final p = SettingsProvider();
      await p.load();

      await p.setUiTextScale(5.0);
      expect(p.uiTextScale, SettingsProvider.maxUiTextScale);
      await p.setUiTextScale(0.1);
      expect(p.uiTextScale, SettingsProvider.minUiTextScale);
    });

    test('out-of-range stored uiTextScale is clamped on load', () async {
      SharedPreferences.setMockInitialValues({'a11y_ui_text_scale': 9.0});
      final p = SettingsProvider();
      await p.load();
      expect(p.uiTextScale, SettingsProvider.maxUiTextScale);
    });

    test(
      'accessibility prefs survive resetPrivateLocalState (logout)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final p = SettingsProvider();
        await p.load();
        await p.setReduceMotion(true);
        await p.setUiTextScale(1.25);

        p.resetPrivateLocalState();

        expect(
          p.reduceMotion,
          isTrue,
          reason: 'device-level pref must survive',
        );
        expect(p.uiTextScale, 1.25);
      },
    );
  });

  test('reduce-motion installs the glass page transition for every platform', () {
    // The reduce-motion flag threads into AppTheme's PageTransitionsTheme; the
    // builder short-circuits to an instant swap. Assert the wiring (the glass
    // builder is installed for every platform) rather than transition internals,
    // which are framework-version-fragile.
    final builders = AppTheme.light(
      reduceMotion: true,
    ).pageTransitionsTheme.builders;
    expect(builders.length, TargetPlatform.values.length);
    for (final p in TargetPlatform.values) {
      expect(
        builders[p].runtimeType.toString(),
        contains('Glass'),
        reason: 'every platform must use the glass page transition',
      );
    }
  });

  testWidgets('navigation completes under the reduce-motion theme', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(reduceMotion: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('second page')),
                  ),
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('second page'), findsOneWidget);
  });
}
