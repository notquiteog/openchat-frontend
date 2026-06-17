import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/l10n/app_localizations.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('Spanish locale is supported and translated', () {
    final l10n = lookupAppLocalizations(const Locale('es'));

    expect(AppLocalizations.supportedLocales, contains(const Locale('es')));
    expect(l10n.appearance, 'Apariencia');
    expect(l10n.languageSystemDefault, 'Predeterminado del sistema');
  });

  test('SettingsProvider parses persisted Spanish app locale', () async {
    SharedPreferences.setMockInitialValues({'app_locale_tag': 'es'});
    final provider = SettingsProvider();
    await provider.load();

    expect(provider.locale, const Locale('es'));
    expect(provider.localeTag, 'es');
  });
}
