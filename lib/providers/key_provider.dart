import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import '../crypto/pgp_service.dart';
import '../models/key_transparency_event.dart';
import '../models/key_trust_pin.dart';
import '../services/api_service.dart';
import '../services/key_cache_service.dart';
import '../services/mls_service.dart';
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
    try {
      _fingerprint = await _storage.getFingerprint();
      _publicKey = await _storage.getPublicKey();
    } on PlatformException catch (error) {
      if (!SecureStorageService.isRecoverableReadFailure(error)) rethrow;
      _fingerprint = null;
      _publicKey = null;
    }
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
    required MlsService mls,
    String passphrase = '',
    KeyType keyType = KeyType.defaultType,
  }) async {
    try {
      final username = await _storage.getUsername() ?? 'user';
      final userId = await _storage.getUserID() ?? '';
      final oldPrivateKey = await _storage.getPrivateKey();
      final oldFingerprint = await _storage.getFingerprint() ?? '';
      if (userId.isEmpty ||
          oldPrivateKey == null ||
          oldPrivateKey.isEmpty ||
          oldFingerprint.isEmpty) {
        return false;
      }
      final newPair = await PgpService.generateKeyPairForType(
        username: username,
        keyType: keyType,
        passphrase: passphrase,
      );
      final signature = await PgpService.sign(
        data: keyRotationSignatureData(
          userId: userId,
          oldFingerprint: oldFingerprint,
          newFingerprint: newPair.fingerprint,
          newPublicKey: newPair.publicKeyArmored,
        ),
        privateKeyArmored: oldPrivateKey,
      );
      // Crossover: sign with the NEW key, binding it to the old key/identity, so
      // contacts verify continuity without trusting the server.
      final oldPublicKey = _publicKey ?? await _storage.getPublicKey() ?? '';
      final crossoverSignature = await PgpService.sign(
        data: keyCrossoverSignatureData(
          userId: userId,
          newFingerprint: newPair.fingerprint,
          oldFingerprint: oldFingerprint,
          oldPublicKey: oldPublicKey,
        ),
        privateKeyArmored: newPair.privateKeyArmored,
      );
      await api.rotatePublicKey(
        publicKey: newPair.publicKeyArmored,
        fingerprint: newPair.fingerprint,
        signature: signature,
        crossoverSignature: crossoverSignature,
      );
      final events = await api
          .getKeyTransparencyEvents(userId)
          .catchError((_) => <KeyTransparencyEvent>[]);
      String? eventHash;
      for (final event in events) {
        if (event.newKeyFingerprint.toUpperCase() ==
            newPair.fingerprint.toUpperCase()) {
          eventHash = event.eventHash;
        }
      }
      await KeyCacheService.clear();
      await _storage.saveKeyPair(
        privateKeyArmored: newPair.privateKeyArmored,
        publicKeyArmored: newPair.publicKeyArmored,
        fingerprint: newPair.fingerprint,
      );
      await _storage.saveKeyTrustPin(
        KeyTrustPin(
          userId: userId,
          fingerprint: newPair.fingerprint.toUpperCase(),
          publicKeyHash: crypto.sha256
              .convert(utf8.encode(newPair.publicKeyArmored.trim()))
              .toString()
              .toUpperCase(),
          eventHash: eventHash,
          pinnedAt: DateTime.now(),
        ),
      );
      _publicKey = newPair.publicKeyArmored;
      _fingerprint = newPair.fingerprint;
      // Re-sign the MLS device key with the NEW private key (now in storage) so
      // the MLS-to-PGP binding the server validates stays valid; a stale signer
      // would otherwise hard-block new MLS conversations/commits. Guarded so an
      // MLS hiccup can never flip an already-persisted rotation to a failure.
      try {
        await mls.resignDeviceKeyForCurrentUser();
      } catch (_) {}
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Web-of-trust: certify [candidateUserId]'s current key for [convID] by
  /// signing the canonical vouch statement with our own key and submitting it.
  /// Returns false if our key is locked or the candidate has no key.
  Future<bool> vouchForMember({
    required ApiService api,
    required String convID,
    required String candidateUserId,
  }) async {
    try {
      final privateKey = await _storage.getPrivateKey();
      if (privateKey == null || privateKey.isEmpty) return false;
      final candidateKey = await api.getUserPublicKey(candidateUserId);
      if (candidateKey == null || candidateKey.isEmpty) return false;
      final keyHash = crypto.sha256
          .convert(utf8.encode(candidateKey.trim()))
          .toString()
          .toUpperCase();
      final statement =
          'openchat-wot-vouch-v1:$convID:$candidateUserId:$keyHash';
      final signature = await PgpService.sign(
        data: statement,
        privateKeyArmored: privateKey,
      );
      await api.vouchForMember(convID, candidateUserId, signature);
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
