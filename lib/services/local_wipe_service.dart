import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_storage_service.dart';

/// Destroys everything this device knows: secure storage (PGP private key,
/// MLS state keys, tokens, PINs), every encrypted local database (message
/// cache, key cache, search index, MLS engine, outbox), and shared
/// preferences. After a wipe the app looks freshly installed; nothing is
/// recoverable without the server-side encrypted backup + its passphrase
/// (or the Shamir guardians).
///
/// Used by: the duress PIN's wipe action, the dead-man switch, and verified
/// remote device-wipe commands.
class LocalWipeService {
  final SecureStorageService _storage;

  LocalWipeService(this._storage);

  Future<void> wipeEverything() async {
    // Secrets first — once the keys are gone the encrypted stores on disk are
    // ciphertext garbage even if file deletion is interrupted.
    try {
      await _storage.clearAll();
    } catch (error) {
      debugPrint('LocalWipeService: secure storage wipe failed: $error');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (error) {
      debugPrint('LocalWipeService: prefs wipe failed: $error');
    }
    // Wipe every directory that can hold plaintext. The temp dir is critical:
    // the video player, voice-note player and story viewer write DECRYPTED
    // bytes there for playback (message_bubble.dart, story_viewer_screen.dart).
    // The whole point of a wipe is device seizure, so leaving decrypted media
    // readable in the OS temp dir defeats it.
    await _wipeDirContents(getApplicationSupportDirectory, 'app-support');
    await _wipeDirContents(getTemporaryDirectory, 'temp');
    await _wipeDirContents(getApplicationCacheDirectory, 'cache');
  }

  /// Best-effort per entry: one locked file must not stop the rest.
  Future<void> _wipeDirContents(
    Future<Directory> Function() resolve,
    String label,
  ) async {
    try {
      final dir = await resolve();
      if (!await dir.exists()) return;
      await for (final entry in dir.list()) {
        try {
          await entry.delete(recursive: true);
        } catch (_) {}
      }
    } catch (error) {
      debugPrint('LocalWipeService: $label wipe failed: $error');
    }
  }
}
