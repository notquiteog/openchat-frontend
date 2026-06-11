import 'package:flutter/foundation.dart';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

export 'package:google_mlkit_translation/google_mlkit_translation.dart'
    show TranslateLanguage, BCP47Code;

/// On-device tap-to-translate via ML Kit (mobile only — the plugin has no
/// desktop implementation; Bergamot/FFI is a later project). Language packs
/// (~30 MB each) download on demand through [ensureLanguage] and are managed
/// from the On-device intelligence screen. Translation itself never leaves
/// the device.
class TranslationService {
  TranslationService._();

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static final OnDeviceTranslatorModelManager _models =
      OnDeviceTranslatorModelManager();

  /// The pack list offered in settings. ML Kit supports ~60; this is the
  /// curated short list — every other language still works via detection as
  /// a SOURCE as long as its pack is downloaded.
  static const List<TranslateLanguage> offeredLanguages = [
    TranslateLanguage.english,
    TranslateLanguage.spanish,
    TranslateLanguage.french,
    TranslateLanguage.german,
    TranslateLanguage.italian,
    TranslateLanguage.portuguese,
    TranslateLanguage.dutch,
    TranslateLanguage.polish,
    TranslateLanguage.russian,
    TranslateLanguage.ukrainian,
    TranslateLanguage.turkish,
    TranslateLanguage.arabic,
    TranslateLanguage.hindi,
    TranslateLanguage.chinese,
    TranslateLanguage.japanese,
    TranslateLanguage.korean,
  ];

  static Future<bool> isLanguageDownloaded(TranslateLanguage lang) =>
      _models.isModelDownloaded(lang.bcpCode);

  static Future<bool> ensureLanguage(TranslateLanguage lang) =>
      _models.downloadModel(lang.bcpCode);

  static Future<bool> deleteLanguage(TranslateLanguage lang) =>
      _models.deleteModel(lang.bcpCode);

  /// Detects the dominant language of [text]; null when ML Kit can't tell
  /// ("und") or the platform is unsupported.
  static Future<TranslateLanguage?> detectLanguage(String text) async {
    if (!isSupported) return null;
    final identifier = LanguageIdentifier(confidenceThreshold: 0.4);
    try {
      final code = await identifier.identifyLanguage(text);
      if (code == 'und') return null;
      return BCP47Code.fromRawValue(code) ??
          // ML Kit may return regioned tags ("zh-Hans") — retry the base.
          BCP47Code.fromRawValue(code.split('-').first);
    } finally {
      await identifier.close();
    }
  }

  /// Translates [text] from [source] to [target], downloading either pack if
  /// missing (Wi-Fi not required: the user explicitly asked for this).
  static Future<String> translate(
    String text, {
    required TranslateLanguage source,
    required TranslateLanguage target,
  }) async {
    if (!isSupported) {
      throw UnsupportedError('on-device translation is mobile-only');
    }
    await _models.downloadModel(source.bcpCode, isWifiRequired: false);
    await _models.downloadModel(target.bcpCode, isWifiRequired: false);
    final translator = OnDeviceTranslator(
      sourceLanguage: source,
      targetLanguage: target,
    );
    try {
      return await translator.translateText(text);
    } finally {
      await translator.close();
    }
  }
}
