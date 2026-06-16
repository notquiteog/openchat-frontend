# Localization (l10n)

OpenChat uses Flutter's `gen-l10n`. English (`app_en.arb`) is the template.

## Add a translation

1. Copy `app_en.arb` to `app_<locale>.arb` (e.g. `app_es.arb`, `app_pt_BR.arb`).
2. Translate the **values** only — never the keys, and keep the `@key`
   description blocks (drop them from the non-template file if you prefer).
3. Register the tag + display name in `_supportedLanguages` in
   `lib/screens/settings/settings_screen.dart` so it appears in the Language
   picker.
4. Run `flutter gen-l10n` (NOT build_runner — this is a separate, lighter
   codegen path). The generated `app_localizations*.dart` files are
   source-controlled here.
5. `flutter analyze` + `flutter test` to verify.

## Scope

This is the i18n **scaffolding** (#46): delegates wired into `MaterialApp`, a
device-level language preference (`SettingsProvider.locale`, survives logout),
and a seed of high-traffic keys. Extracting the long tail of UI strings into
`AppLocalizations.of(context)` is incremental follow-up work — `intl`
`DateFormat`/`timeago` are separate locale systems and out of scope here.
