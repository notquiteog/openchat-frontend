import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../models/key_trust_pin.dart';

class SecureStorageStatus {
  final bool available;
  final String? warning;

  const SecureStorageStatus.available() : available = true, warning = null;

  const SecureStorageStatus.unavailable(this.warning) : available = false;
}

/// Thrown when secure storage is temporarily unavailable (e.g. the Linux
/// keyring is locked at launch) at the moment a key protecting an *existing*
/// encrypted store is read. Callers must degrade for this session — NOT mint a
/// replacement key, which would orphan the store — and may surface [message].
class SecureStorageUnavailableException implements Exception {
  final String message;

  const SecureStorageUnavailableException(this.message);

  @override
  String toString() => 'SecureStorageUnavailableException: $message';
}

class MlsSignerStorage {
  final String signerBytes;
  final String publicKey;
  final String signature;

  const MlsSignerStorage({
    required this.signerBytes,
    required this.publicKey,
    this.signature = '',
  });
}

/// Manages secure storage of cryptographic keys and session tokens.
///
/// Platform backing:
/// - iOS/macOS: Keychain
/// - Android: EncryptedSharedPreferences + Android Keystore
/// - Windows: Windows Credential Manager
/// - Linux: libsecret (GNOME Keyring / KWallet)
class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock),
    lOptions: LinuxOptions(),
    wOptions: WindowsOptions(),
  );

  static const _keyPrivateKey = 'pgp_private_key';
  static const _keyPublicKey = 'pgp_public_key';
  static const _keyFingerprint = 'pgp_fingerprint';
  static const _keyUsername = 'username';
  static const _keyUserID = 'user_id';
  static const _keyAccessToken = 'access_token';
  static const _keyRefreshToken = 'refresh_token';
  static const _keyBiometricEnabled = 'biometric_enabled';
  static const _keyAppLockEnabled = 'app_lock_enabled';
  static const _keySearchIndexKey = 'search_index_key_v1';
  static const _keyOutboxKey = 'offline_outbox_key_v1';
  static const _keyLocalPrivateStateKey = 'local_private_state_key_v1';
  static const _keyMessageCacheKey = 'message_cache_key_v1';
  static const _keyTrustPins = 'key_trust_pins_v1';
  static const _keyMlsEngineKeyPrefix = 'mls_engine_key_v1';
  static const _keyMlsSignerBytesPrefix = 'mls_signer_bytes_v1';
  static const _keyMlsSignerPublicKeyPrefix = 'mls_signer_public_key_v1';
  static const _keyMlsSignerSignaturePrefix = 'mls_signer_signature_v1';
  static const _keyMlsCredentialIdentityPrefix = 'mls_credential_identity_v1';
  static const _keyPgpPostTokenPrefix = 'pgp_post_token_v1';
  static const _keySealedScheduleControlsPrefix = 'sealed_schedule_controls_v1';
  static const _keySealedMessageControlsPrefix = 'sealed_message_controls_v1';
  static const _keySelfStateLogSequence = 'self_state_log_sequence_v1';
  static const _keyStorageProbe = '_openchat_secure_storage_probe';

  static const linuxKeyringWarning =
      'OpenChat cannot access your Linux keyring. Unlock GNOME Keyring or '
      'KWallet and try again. If you use autologin or passwordless login, '
      'sign in with your password so the keyring can unlock.';

  // ---- In-memory session state (kept for migration compatibility) ----

  /// Legacy key-session state. Biometric key unlock now protects only private
  /// key export, but older provider code may still read this value.
  bool _keySessionUnlocked = false;

  bool get isKeySessionUnlocked => _keySessionUnlocked;
  void unlockKeySession() => _keySessionUnlocked = true;
  void lockKeySession() => _keySessionUnlocked = false;

  // ---- PGP keys ----

  Future<SecureStorageStatus> checkAvailability() async {
    try {
      await _storage.write(key: _keyStorageProbe, value: 'ok');
      final value = await _storage.read(key: _keyStorageProbe);
      await _storage.delete(key: _keyStorageProbe);
      if (value == 'ok') return const SecureStorageStatus.available();
      return const SecureStorageStatus.unavailable(linuxKeyringWarning);
    } on PlatformException catch (error) {
      final warning = warningFor(error);
      if (warning != null) return SecureStorageStatus.unavailable(warning);
      rethrow;
    }
  }

  Future<void> saveKeyPair({
    required String privateKeyArmored,
    required String publicKeyArmored,
    required String fingerprint,
  }) async {
    await _storage.write(key: _keyPrivateKey, value: privateKeyArmored);
    await _storage.write(key: _keyPublicKey, value: publicKeyArmored);
    await _storage.write(key: _keyFingerprint, value: fingerprint);
  }

  Future<String?> getPrivateKey() => _readOrNull(_keyPrivateKey);
  Future<String?> getPublicKey() => _readOrNull(_keyPublicKey);
  Future<String?> getFingerprint() => _readOrNull(_keyFingerprint);

  Future<bool> hasKeyPair() async {
    final fp = await getFingerprint();
    return fp != null && fp.isNotEmpty;
  }

  Future<void> deleteKeyPair() async {
    await Future.wait([
      _storage.delete(key: _keyPrivateKey),
      _storage.delete(key: _keyPublicKey),
      _storage.delete(key: _keyFingerprint),
    ]);
  }

  // ---- Session ----

  Future<void> saveSession({
    required String userID,
    required String username,
    required String accessToken,
    required String refreshToken,
  }) async {
    await _storage.write(key: _keyUserID, value: userID);
    await _storage.write(key: _keyUsername, value: username);
    await _storage.write(key: _keyAccessToken, value: accessToken);
    await _storage.write(key: _keyRefreshToken, value: refreshToken);
  }

  Future<String?> getAccessToken() => _readOrNull(_keyAccessToken);
  Future<String?> getRefreshToken() => _readOrNull(_keyRefreshToken);
  Future<String?> getUserID() => _readOrNull(_keyUserID);
  Future<String?> getUsername() => _readOrNull(_keyUsername);

  Future<String> getOrCreateSearchIndexKey() async {
    final existing = await _readOrNull(_keySearchIndexKey);
    if (existing != null && existing.isNotEmpty) return existing;
    return _createRandomStorageKey(_keySearchIndexKey);
  }

  Future<String> getOrCreateOutboxKey() async {
    final existing = await _readOrNull(_keyOutboxKey);
    if (existing != null && existing.isNotEmpty) return existing;
    return _createRandomStorageKey(_keyOutboxKey);
  }

  Future<String> getOrCreateLocalPrivateStateKey() async {
    final existing = await _readOrNull(_keyLocalPrivateStateKey);
    if (existing != null && existing.isNotEmpty) return existing;
    return _createRandomStorageKey(_keyLocalPrivateStateKey);
  }

  /// Key for the at-rest decrypted-message cache. Uses [_getOrCreateProtectedKey]
  /// so a locked keyring at launch cannot mint a fresh key that orphans the
  /// cache DB — which would make every past MLS message show "Unable to decrypt"
  /// after a restart.
  Future<String> getOrCreateMessageCacheKey() =>
      _getOrCreateProtectedKey(_keyMessageCacheKey);

  Future<Map<String, KeyTrustPin>> getKeyTrustPins() async {
    final raw = await _readOrNull(_keyTrustPins);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((key, value) {
        return MapEntry(
          key.toString(),
          KeyTrustPin.fromJson(Map<String, dynamic>.from(value as Map)),
        );
      });
    } catch (_) {
      return {};
    }
  }

  Future<KeyTrustPin?> getKeyTrustPin(String userId) async {
    final pins = await getKeyTrustPins();
    return pins[userId];
  }

  Future<void> saveKeyTrustPin(KeyTrustPin pin) async {
    final pins = await getKeyTrustPins();
    pins[pin.userId] = pin;
    await _storage.write(
      key: _keyTrustPins,
      value: jsonEncode(
        pins.map((key, value) => MapEntry(key, value.toJson())),
      ),
    );
  }

  /// SQLCipher key for the per-user MLS engine DB (group state + ratchet tree).
  /// Protected: a locked keyring must not mint a new key, which would orphan the
  /// engine DB and lose all group state (and thus all decryptable history).
  Future<String> getOrCreateMlsEngineKey(String userID) =>
      _getOrCreateProtectedKey(_scopedKey(_keyMlsEngineKeyPrefix, userID));

  /// Stable MLS credential identity. Protected so a locked keyring can't mint a
  /// new identity that would diverge from the one baked into existing groups.
  Future<String> getOrCreateMlsCredentialIdentity(String userID) =>
      _getOrCreateProtectedKey(
        _scopedKey(_keyMlsCredentialIdentityPrefix, userID),
      );

  Future<MlsSignerStorage?> getMlsSigner(String userID) async {
    final signer = await _readOrNull(
      _scopedKey(_keyMlsSignerBytesPrefix, userID),
    );
    final publicKey = await _readOrNull(
      _scopedKey(_keyMlsSignerPublicKeyPrefix, userID),
    );
    final signature =
        await _readOrNull(_scopedKey(_keyMlsSignerSignaturePrefix, userID)) ??
        '';
    if (signer == null ||
        signer.isEmpty ||
        publicKey == null ||
        publicKey.isEmpty) {
      return null;
    }
    return MlsSignerStorage(
      signerBytes: signer,
      publicKey: publicKey,
      signature: signature,
    );
  }

  Future<void> saveMlsSigner({
    required String userID,
    required String signerBytes,
    required String publicKey,
    String signature = '',
  }) async {
    await Future.wait([
      _storage.write(
        key: _scopedKey(_keyMlsSignerBytesPrefix, userID),
        value: signerBytes,
      ),
      _storage.write(
        key: _scopedKey(_keyMlsSignerPublicKeyPrefix, userID),
        value: publicKey,
      ),
      _storage.write(
        key: _scopedKey(_keyMlsSignerSignaturePrefix, userID),
        value: signature,
      ),
    ]);
  }

  Future<String?> getPgpPostToken(String conversationID) {
    return _readOrNull(_scopedKey(_keyPgpPostTokenPrefix, conversationID));
  }

  Future<void> savePgpPostToken(String conversationID, String token) {
    return _storage.write(
      key: _scopedKey(_keyPgpPostTokenPrefix, conversationID),
      value: token,
    );
  }

  Future<void> deletePgpPostToken(String conversationID) {
    return _storage.delete(
      key: _scopedKey(_keyPgpPostTokenPrefix, conversationID),
    );
  }

  Future<Map<String, String>> getSealedScheduleControlTokens(
    String conversationID,
  ) async {
    final raw = await _readOrNull(
      _scopedKey(_keySealedScheduleControlsPrefix, conversationID),
    );
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      )..removeWhere((key, value) => key.isEmpty || value.isEmpty);
    } catch (_) {
      return {};
    }
  }

  Future<String?> getSealedScheduleControlToken(
    String conversationID,
    String scheduledID,
  ) async {
    final tokens = await getSealedScheduleControlTokens(conversationID);
    return tokens[scheduledID];
  }

  Future<void> saveSealedScheduleControlToken(
    String conversationID,
    String scheduledID,
    String token,
  ) async {
    if (conversationID.isEmpty || scheduledID.isEmpty || token.isEmpty) return;
    final tokens = await getSealedScheduleControlTokens(conversationID);
    tokens[scheduledID] = token;
    await _storage.write(
      key: _scopedKey(_keySealedScheduleControlsPrefix, conversationID),
      value: jsonEncode(tokens),
    );
  }

  Future<void> deleteSealedScheduleControlToken(
    String conversationID,
    String scheduledID,
  ) async {
    final tokens = await getSealedScheduleControlTokens(conversationID);
    tokens.remove(scheduledID);
    final key = _scopedKey(_keySealedScheduleControlsPrefix, conversationID);
    if (tokens.isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: jsonEncode(tokens));
    }
  }

  Future<Map<String, String>> getSealedMessageControlTokens(
    String conversationID,
  ) async {
    final raw = await _readOrNull(
      _scopedKey(_keySealedMessageControlsPrefix, conversationID),
    );
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      )..removeWhere((key, value) => key.isEmpty || value.isEmpty);
    } catch (_) {
      return {};
    }
  }

  Future<String?> getSealedMessageControlToken(
    String conversationID,
    String messageID,
  ) async {
    final tokens = await getSealedMessageControlTokens(conversationID);
    return tokens[messageID];
  }

  Future<void> saveSealedMessageControlToken(
    String conversationID,
    String messageID,
    String token,
  ) async {
    if (conversationID.isEmpty || messageID.isEmpty || token.isEmpty) return;
    final tokens = await getSealedMessageControlTokens(conversationID);
    tokens[messageID] = token;
    await _storage.write(
      key: _scopedKey(_keySealedMessageControlsPrefix, conversationID),
      value: jsonEncode(tokens),
    );
  }

  Future<void> deleteSealedMessageControlToken(
    String conversationID,
    String messageID,
  ) async {
    final tokens = await getSealedMessageControlTokens(conversationID);
    tokens.remove(messageID);
    final key = _scopedKey(_keySealedMessageControlsPrefix, conversationID);
    if (tokens.isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: jsonEncode(tokens));
    }
  }

  Future<List<String>> getAllSealedMessageControlTokens() {
    return _allScopedValues(_keySealedMessageControlsPrefix);
  }

  Future<List<String>> getAllSealedScheduleControlTokens() {
    return _allScopedValues(_keySealedScheduleControlsPrefix);
  }

  Future<int> getSelfStateLogSequence() async {
    final raw = await _readOrNull(_keySelfStateLogSequence);
    return int.tryParse(raw ?? '') ?? 0;
  }

  Future<void> saveSelfStateLogSequence(int sequence) {
    return _storage.write(
      key: _keySelfStateLogSequence,
      value: sequence.toString(),
    );
  }

  String _scopedKey(String prefix, String userID) => '$prefix:$userID';

  Future<String> _createRandomStorageKey(String key) async {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final encoded = base64Encode(bytes);
    await _storage.write(key: key, value: encoded);
    return encoded;
  }

  /// Reads a key that protects an *existing* encrypted store, creating a fresh
  /// random key ONLY when the key is genuinely absent (first run).
  ///
  /// Unlike [_readOrNull], a recoverable keyring failure (e.g. the Linux keyring
  /// locked at launch) is NOT swallowed into `null`: it throws
  /// [SecureStorageUnavailableException]. Returning null here would make this
  /// method mint a brand-new key and overwrite the real one, orphaning the
  /// encrypted store it protects (message cache, MLS engine DB) and destroying
  /// data that is fully recoverable once the keyring unlocks. Failing loudly
  /// lets the caller degrade for this session instead (and the store survives).
  Future<String> _getOrCreateProtectedKey(String key) async {
    String? existing;
    try {
      existing = await _storage.read(key: key);
    } on PlatformException catch (error) {
      if (isRecoverableReadFailure(error)) {
        throw const SecureStorageUnavailableException(linuxKeyringWarning);
      }
      rethrow;
    }
    if (existing != null && existing.isNotEmpty) return existing;
    return _createRandomStorageKey(key);
  }

  Future<bool> isLoggedIn() async {
    final token = await getAccessToken();
    return token != null && token.isNotEmpty;
  }

  Future<void> updateTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _storage.write(key: _keyAccessToken, value: accessToken);
    await _storage.write(key: _keyRefreshToken, value: refreshToken);
  }

  Future<void> clearSession() async {
    await Future.wait([
      _storage.delete(key: _keyUserID),
      _storage.delete(key: _keyUsername),
      _storage.delete(key: _keyAccessToken),
      _storage.delete(key: _keyRefreshToken),
    ]);
  }

  // ---- Biometric preference ----

  Future<bool> getBiometricEnabled() async {
    final v = await _readOrNull(_keyBiometricEnabled);
    return v == 'true';
  }

  Future<void> setBiometricEnabled(bool enabled) => _storage.write(
    key: _keyBiometricEnabled,
    value: enabled ? 'true' : 'false',
  );

  Future<bool> shouldRequireBiometricKeyUnlock() async {
    if (!await getBiometricEnabled()) return false;
    try {
      final auth = LocalAuthentication();
      return await auth.canCheckBiometrics || await auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  // ---- App lock ----

  Future<bool> getAppLockEnabled() async {
    final v = await _readOrNull(_keyAppLockEnabled);
    return v == 'true';
  }

  Future<void> setAppLockEnabled(bool enabled) => _storage.write(
    key: _keyAppLockEnabled,
    value: enabled ? 'true' : 'false',
  );

  /// Message encryption/decryption needs the private key during normal app use.
  /// Biometric key unlock only protects explicit private-key export.
  Future<String?> getPrivateKeyIfUnlocked() async {
    return getPrivateKey();
  }

  /// Full wipe — called on logout or account deletion.
  Future<void> clearAll() => _storage.deleteAll();

  Future<Map<String, String>> exportRecoverySecrets() async {
    final all = await _storage.readAll();
    final blocked = {
      _keyAccessToken,
      _keyRefreshToken,
      _keyBiometricEnabled,
      _keyAppLockEnabled,
      _keyStorageProbe,
    };
    return {
      for (final entry in all.entries)
        if (!blocked.contains(entry.key) && entry.value.isNotEmpty)
          entry.key: entry.value,
    };
  }

  Future<void> importRecoverySecrets(Map<String, String> values) async {
    final blocked = {
      _keyAccessToken,
      _keyRefreshToken,
      _keyBiometricEnabled,
      _keyAppLockEnabled,
      _keyStorageProbe,
    };
    for (final entry in values.entries) {
      if (blocked.contains(entry.key) || entry.value.isEmpty) continue;
      await _storage.write(key: entry.key, value: entry.value);
    }
  }

  static bool isRecoverableReadFailure(PlatformException error) {
    return isLinuxKeyringFailure(error);
  }

  static bool isLinuxKeyringFailure(PlatformException error) {
    final text = _errorText(error);
    return error.code == 'KeyringLocked' ||
        text.contains('keyringlocked') ||
        text.contains('keyring locked') ||
        text.contains('collection is locked') ||
        text.contains('no such secret collection') ||
        text.contains('org.freedesktop.secrets') ||
        text.contains('secret service');
  }

  static String? warningFor(Object error) {
    if (error is PlatformException && isLinuxKeyringFailure(error)) {
      return linuxKeyringWarning;
    }
    return null;
  }

  static String _errorText(PlatformException error) {
    return '${error.code} ${error.message} ${error.details}'.toLowerCase();
  }

  static Future<String?> _readOrNull(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException catch (error) {
      if (!isRecoverableReadFailure(error)) rethrow;
      return null;
    }
  }

  static Future<List<String>> _allScopedValues(String prefix) async {
    try {
      final all = await _storage.readAll();
      final values = <String>[];
      for (final entry in all.entries) {
        if (!entry.key.startsWith('$prefix:')) continue;
        try {
          final decoded = jsonDecode(entry.value);
          if (decoded is! Map) continue;
          values.addAll(
            decoded.values
                .map((value) => value.toString().trim())
                .where((value) => value.isNotEmpty),
          );
        } catch (_) {}
      }
      return values.toSet().toList()..sort();
    } on PlatformException catch (error) {
      if (!isRecoverableReadFailure(error)) rethrow;
      return const [];
    }
  }
}
