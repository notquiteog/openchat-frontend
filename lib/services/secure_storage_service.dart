import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

class SecureStorageStatus {
  final bool available;
  final String? warning;

  const SecureStorageStatus.available()
      : available = true,
        warning = null;

  const SecureStorageStatus.unavailable(this.warning) : available = false;
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
      key: _keyBiometricEnabled, value: enabled ? 'true' : 'false');

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
      key: _keyAppLockEnabled, value: enabled ? 'true' : 'false');

  /// Message encryption/decryption needs the private key during normal app use.
  /// Biometric key unlock only protects explicit private-key export.
  Future<String?> getPrivateKeyIfUnlocked() async {
    return getPrivateKey();
  }

  /// Full wipe — called on logout or account deletion.
  Future<void> clearAll() => _storage.deleteAll();

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
}
