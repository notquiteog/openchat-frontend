import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #47 — the Light/Dark/System theme preference is a device-local
/// SharedPreferences value persisted by `.name`, defaulting to system.
void main() {
  test('defaults to system when unset', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = SettingsProvider();
    await provider.load();
    expect(provider.themeMode, ThemeMode.system);
  });

  test(
    'setThemeMode updates, notifies, and persists across instances',
    () async {
      SharedPreferences.setMockInitialValues({});
      final provider = SettingsProvider();
      await provider.load();

      var notified = false;
      provider.addListener(() => notified = true);

      await provider.setThemeMode(ThemeMode.dark);
      expect(provider.themeMode, ThemeMode.dark);
      expect(notified, isTrue, reason: 'setThemeMode must notify listeners');

      // A fresh provider over the same mock prefs sees the persisted value.
      final reloaded = SettingsProvider();
      await reloaded.load();
      expect(reloaded.themeMode, ThemeMode.dark);
    },
  );

  test('a garbage stored value falls back to system', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'nonsense'});
    final provider = SettingsProvider();
    await provider.load();
    expect(provider.themeMode, ThemeMode.system);
  });
}
