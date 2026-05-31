import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import '../crypto/pgp_service.dart';
import '../services/api_service.dart';
import '../services/key_cache_service.dart';
import '../services/secure_storage_service.dart';

class KeyProvider extends ChangeNotifier {
  final SecureStorageService _storage;

  String? _publicKey;
  String? _fingerprint;
  bool _hasKey = false;

  String? get publicKey => _publicKey;
  String? get fingerprint => _fingerprint;
  bool get hasKey => _hasKey;

  /// Whether the private key is unlocked for use this session.
  /// Always true when biometric key-unlock is disabled.
  /// When biometric key-unlock is enabled, becomes true after a successful
  /// [authenticateAndUnlockKey] call and is reset to false by [lockKeySession].
  bool get isKeySessionUnlocked => _storage.isKeySessionUnlocked;

  /// Lock the in-session key access — called when the app moves to background.
  void lockKeySession() {
    _storage.lockKeySession();
    notifyListeners();
  }

  /// Authenticate with biometrics and unlock private-key access for this
  /// session. Returns true on success. No-ops (returns true) if biometric
  /// key-unlock is disabled in settings.
  Future<bool> authenticateAndUnlockKey() async {
    final biometricRequired = await _storage.shouldRequireBiometricKeyUnlock();
    if (!biometricRequired) {
      _storage.unlockKeySession();
      notifyListeners();
      return true;
    }
    final auth = LocalAuthentication();
    final available =
        await auth.canCheckBiometrics || await auth.isDeviceSupported();
    if (!available) return false;
    try {
      final ok = await auth.authenticate(
        localizedReason: 'Authenticate to unlock your PGP key',
      );
      if (ok) {
        _storage.unlockKeySession();
        notifyListeners();
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  KeyProvider(this._storage);

  Future<void> load() async {
    _fingerprint = await _storage.getFingerprint();
    _publicKey = await _storage.getPublicKey();
    _hasKey = _fingerprint != null && _fingerprint!.isNotEmpty;
    notifyListeners();
  }

  /// Import an existing PGP key pair (from file or clipboard).
  Future<bool> importKeyPair({
    required String privateKeyArmored,
    String? publicKeyArmored,
    String passphrase = '',
  }) async {
    try {
      // Validate by attempting to parse
      if (!privateKeyArmored.contains('BEGIN PGP PRIVATE KEY BLOCK') &&
          !privateKeyArmored.contains('BEGIN PGP MESSAGE')) {
        return false;
      }
      // Users only need to supply their private key — derive the public half
      // locally when it isn't provided.
      final pub =
          (publicKeyArmored != null && publicKeyArmored.trim().isNotEmpty)
              ? publicKeyArmored.trim()
              : await PgpService.publicKeyFromPrivate(privateKeyArmored);
      final fp = await PgpService.fingerprintFromPublicKey(pub);
      await _storage.saveKeyPair(
        privateKeyArmored: privateKeyArmored,
        publicKeyArmored: pub,
        fingerprint: fp,
      );
      _publicKey = pub;
      _fingerprint = fp;
      _hasKey = true;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Export the public key for sharing.
  Future<String?> exportPublicKey() => _storage.getPublicKey();

  /// Export the private key for backup.
  /// WARN: only call this when the user explicitly requests it.
  Future<String?> exportPrivateKey() => _storage.getPrivateKey();

  /// Generate a new key pair and register it with the server.
  ///
  /// After success, messages from before rotation can only be decrypted with the
  /// old private key (if the user kept a backup). New senders whose caches
  /// have not yet expired (24 h) may still encrypt to the old key temporarily.
  Future<bool> rotateKey({
    required ApiService api,
    String passphrase = '',
    KeyType keyType = KeyType.curve25519,
  }) async {
    try {
      final username = await _storage.getUsername() ?? 'user';
      final newPair = switch (keyType) {
        KeyType.rsa4096 => await PgpService.generateRsaKeyPair(
            username: username, passphrase: passphrase),
        KeyType.pqc => await PgpService.generatePqcKeyPair(
            username: username, passphrase: passphrase),
        _ => await PgpService.generateKeyPair(
            username: username, passphrase: passphrase),
      };
      await api.rotatePublicKey(
        publicKey: newPair.publicKeyArmored,
        fingerprint: newPair.fingerprint,
      );
      await KeyCacheService.clear();
      await _storage.saveKeyPair(
        privateKeyArmored: newPair.privateKeyArmored,
        publicKeyArmored: newPair.publicKeyArmored,
        fingerprint: newPair.fingerprint,
      );
      _publicKey = newPair.publicKeyArmored;
      _fingerprint = newPair.fingerprint;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Delete local keys (DANGER: messages encrypted to this key become permanently unreadable).
  Future<void> deleteLocalKeys() async {
    await _storage.deleteKeyPair();
    _publicKey = null;
    _fingerprint = null;
    _hasKey = false;
    notifyListeners();
  }
}
