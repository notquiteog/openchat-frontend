import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import '../crypto/pgp_service.dart';
import '../crypto/shamir.dart';
import 'api_service.dart';
import 'encrypted_backup_service.dart';
import 'secure_storage_service.dart';

/// Orchestrates Shamir social key recovery.
///
/// Setup (this device has keys): a random 32-byte recovery secret RS encrypts
/// the recovery bundle (AES-256-GCM, no KDF — RS is full-entropy); the
/// ciphertext goes to the server, RS is split k-of-n, and each share travels
/// to its guardian as a hidden E2EE message. RS then ceases to exist whole.
///
/// Recovery (a keyless device, password session): mint an EPHEMERAL PGP
/// keypair, open a ceremony; guardians verify out-of-band (the verification
/// code derives from the ephemeral key, so the server can't swap it
/// unnoticed), encrypt their share to the ephemeral key and submit; at k
/// shares the requester reconstructs RS, decrypts the blob, and imports the
/// bundle — keys, history caches, settings.
class SocialRecoveryService {
  final SecureStorageService _storage;
  final EncryptedBackupService _backup;
  final _cipher = AesGcm.with256bits();

  SocialRecoveryService({
    SecureStorageService? storage,
    EncryptedBackupService? backup,
  }) : _storage = storage ?? SecureStorageService(),
       _backup =
           backup ?? EncryptedBackupService(storage: storage);

  // ── Setup ──────────────────────────────────────────────────────────────────

  /// Configures recovery and returns one share-delivery payload per guardian
  /// (the caller delivers each as a hidden E2EE message via ChatProvider).
  Future<Map<String, String>> configure({
    required ApiService api,
    required String selfUserId,
    required List<String> guardianUserIds,
    required int threshold,
  }) async {
    if (guardianUserIds.toSet().length != guardianUserIds.length) {
      throw ArgumentError('duplicate guardians');
    }
    final recoverySecret = _randomBytes(32);
    final bundle = await _backup.buildRecoveryBundlePayload();
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(bundle)),
      secretKey: SecretKey(recoverySecret),
    );
    final blob = jsonEncode({
      'openchat_recovery_blob': 1,
      'cipher': 'aes-256-gcm',
      'payload': base64Encode(box.concatenation()),
    });

    final shares = Shamir.split(
      recoverySecret,
      shares: guardianUserIds.length,
      threshold: threshold,
    );

    await api.setupRecovery(
      blob: blob,
      sha256: crypto.sha256.convert(utf8.encode(blob)).toString(),
      threshold: threshold,
      guardianIds: guardianUserIds,
    );

    final deliveries = <String, String>{};
    for (var i = 0; i < guardianUserIds.length; i++) {
      deliveries[guardianUserIds[i]] = jsonEncode({
        'openchat_recovery_share': 1,
        'owner_user_id': selfUserId,
        'share': base64Encode(shares[i]),
        'threshold': threshold,
        'index': i + 1,
      });
    }
    // RS and the plain shares go out of scope here — nothing whole persists.
    return deliveries;
  }

  // ── Guardian side ──────────────────────────────────────────────────────────

  /// Stores a share received in-band (called from the message intercept).
  Future<void> storeIncomingShare(Map<String, dynamic> payload) async {
    final owner = payload['owner_user_id']?.toString() ?? '';
    final share = payload['share']?.toString() ?? '';
    if (owner.isEmpty || share.isEmpty) return;
    await _storage.saveHeldRecoveryShare(owner, jsonEncode(payload));
  }

  /// Approves a ceremony: encrypts the held share to the request's ephemeral
  /// key (signed with the guardian's own key — provenance) and submits it.
  /// Throws [StateError] when no share is held.
  Future<void> approveRequest({
    required ApiService api,
    required String requestId,
    required String ownerUserId,
    required String ephemeralPubkeyArmored,
  }) async {
    final held = await _storage.getHeldRecoveryShare(ownerUserId);
    if (held == null || held.isEmpty) {
      throw StateError(
        'You hold no recovery share for this account on this device.',
      );
    }
    final signingKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
    if (signingKey.isEmpty) {
      throw StateError('Your PGP key is locked or missing.');
    }
    final encrypted = await PgpService.encrypt(
      plaintext: held,
      recipients: [
        PgpRecipient(
          userId: ownerUserId,
          publicKeyArmored: ephemeralPubkeyArmored,
          keyFingerprint: await PgpService.fingerprintFromPublicKey(
            ephemeralPubkeyArmored,
          ),
        ),
      ],
      signingPrivateKeyArmored: signingKey,
    );
    await api.submitRecoveryShare(requestId, encryptedShare: encrypted);
  }

  /// Short verification code both sides display, derived from the EPHEMERAL
  /// key — read it aloud over a call before approving. A server substituting
  /// its own ephemeral key changes the code.
  static Future<String> verificationCode(String ephemeralPubkeyArmored) async {
    final fingerprint = await PgpService.fingerprintFromPublicKey(
      ephemeralPubkeyArmored,
    );
    final digest = crypto.sha256
        .convert(utf8.encode('openchat-recovery-verify:v1:$fingerprint'))
        .toString()
        .toUpperCase();
    return '${digest.substring(0, 4)}-${digest.substring(4, 8)}-${digest.substring(8, 12)}';
  }

  // ── Requester side (keyless device) ───────────────────────────────────────

  /// Opens a ceremony. Returns the request id, the verification code to read
  /// to guardians, and stores the ephemeral private key in memory only —
  /// losing it just means starting a new ceremony.
  Future<RecoveryCeremony> startCeremony({required ApiService api}) async {
    final ephemeral = await PgpService.generateKeyPair(
      username: 'openchat-recovery-ephemeral',
    );
    final request = await api.startRecoveryRequest(ephemeral.publicKeyArmored);
    return RecoveryCeremony(
      requestId: request['id'].toString(),
      ephemeralPrivateKey: ephemeral.privateKeyArmored,
      ephemeralPublicKey: ephemeral.publicKeyArmored,
      verificationCode: await verificationCode(ephemeral.publicKeyArmored),
    );
  }

  /// Attempts to finish a ceremony: decrypt collected shares with the
  /// ephemeral key, recombine, decrypt the blob, import the bundle. Returns
  /// false when fewer than threshold shares have arrived yet.
  Future<bool> tryFinishCeremony({
    required ApiService api,
    required RecoveryCeremony ceremony,
  }) async {
    final state = await api.getRecoveryRequest(ceremony.requestId);
    final threshold = (state['threshold'] as num?)?.toInt() ?? 0;
    final encryptedShares = ((state['encrypted_shares'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    if (threshold < 2 || encryptedShares.length < threshold) return false;

    final shares = <Uint8List>[];
    for (final armored in encryptedShares) {
      final clear = await PgpService.decrypt(
        encryptedArmor: armored,
        privateKeyArmored: ceremony.ephemeralPrivateKey,
      );
      final payload = jsonDecode(clear);
      if (payload is! Map || payload['openchat_recovery_share'] != 1) continue;
      shares.add(base64Decode(payload['share'].toString()));
    }
    if (shares.length < threshold) return false;

    final recoverySecret = Shamir.combine(shares.sublist(0, threshold));
    final blobJson = jsonDecode(state['blob'].toString());
    if (blobJson is! Map || blobJson['openchat_recovery_blob'] != 1) {
      throw StateError('Recovery blob is malformed.');
    }
    final box = SecretBox.fromConcatenation(
      base64Decode(blobJson['payload'].toString()),
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
    );
    // AES-GCM authenticates: a wrong reconstruction (or tampered blob) throws
    // here rather than importing garbage.
    final clear = await _cipher.decrypt(
      box,
      secretKey: SecretKey(recoverySecret),
    );
    await _backup.importBundlePayload(jsonDecode(utf8.decode(clear)));
    await api.completeRecoveryRequest(ceremony.requestId, status: 'fulfilled');
    return true;
  }

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}

class RecoveryCeremony {
  final String requestId;
  final String ephemeralPrivateKey;
  final String ephemeralPublicKey;
  final String verificationCode;

  const RecoveryCeremony({
    required this.requestId,
    required this.ephemeralPrivateKey,
    required this.ephemeralPublicKey,
    required this.verificationCode,
  });
}
