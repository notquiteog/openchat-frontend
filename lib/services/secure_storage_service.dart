import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

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

  // ---- In-memory session state (never persisted) ----

  /// True once the user has biometrically authenticated to unlock their PGP key
  /// this session. Reset to false on app lock or restart.
  bool _keySessionUnlocked = false;

  bool get isKeySessionUnlocked => _keySessionUnlocked;
  void unlockKeySession() => _keySessionUnlocked = true;
  void lockKeySession() => _keySessionUnlocked = false;

  // ---- PGP keys ----

  Future<void> saveKeyPair({
    required String privateKeyArmored,
    required String publicKeyArmored,
    required String fingerprint,
  }) async {
    await _storage.write(key: _keyPrivateKey, value: privateKeyArmored);
    await _storage.write(key: _keyPublicKey, value: publicKeyArmored);
    await _storage.write(key: _keyFingerprint, value: fingerprint);
  }

  Future<String?> getPrivateKey() => _storage.read(key: _keyPrivateKey);
  Future<String?> getPublicKey() => _storage.read(key: _keyPublicKey);
  Future<String?> getFingerprint() => _storage.read(key: _keyFingerprint);

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

  Future<String?> getAccessToken() => _storage.read(key: _keyAccessToken);
  Future<String?> getRefreshToken() => _storage.read(key: _keyRefreshToken);
  Future<String?> getUserID() => _storage.read(key: _keyUserID);
  Future<String?> getUsername() => _storage.read(key: _keyUsername);

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
    final v = await _storage.read(key: _keyBiometricEnabled);
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
    final v = await _storage.read(key: _keyAppLockEnabled);
    return v == 'true';
  }

  Future<void> setAppLockEnabled(bool enabled) => _storage.write(
      key: _keyAppLockEnabled, value: enabled ? 'true' : 'false');

  /// Returns the private key only when biometric key unlock is disabled OR the
  /// session has been explicitly unlocked via [unlockKeySession]. Returns null
  /// otherwise so callers can prompt the user to authenticate.
  Future<String?> getPrivateKeyIfUnlocked() async {
    final biometricRequired = await shouldRequireBiometricKeyUnlock();
    if (biometricRequired && !_keySessionUnlocked) return null;
    return getPrivateKey();
  }

  /// Full wipe — called on logout or account deletion.
  Future<void> clearAll() => _storage.deleteAll();
}
