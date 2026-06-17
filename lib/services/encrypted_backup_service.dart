import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import 'api_service.dart';
import 'local_private_state_service.dart';
import 'passphrase_strength.dart';
import 'secure_storage_service.dart';

class EncryptedBackupService {
  static const _defaultIterations = 310000;
  // Floor for imports: a tampered backup file must not be able to downgrade
  // the KDF cost to something brute-forceable.
  static const _minImportIterations = 100000;

  final SecureStorageService _storage;
  final LocalPrivateStateService _privateState;
  final _cipher = AesGcm.with256bits();

  EncryptedBackupService({
    SecureStorageService? storage,
    LocalPrivateStateService? privateState,
  }) : _storage = storage ?? SecureStorageService(),
       _privateState = privateState ?? LocalPrivateStateService();

  /// The raw recovery bundle (also the payload social recovery encrypts under
  /// its Shamir-split secret).
  Future<Map<String, Object?>> buildRecoveryBundlePayload() async {
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final secureStorage = await _storage.exportRecoverySecrets();
    final localPrivateState = await _privateState.readState();
    return {
      'openchat_recovery_bundle': 1,
      'created_at': createdAt,
      'manifest': recoveryBundleManifest(
        secureStorage: secureStorage,
        localPrivateState: localPrivateState,
        createdAt: createdAt,
      ),
      'secure_storage': secureStorage,
      'local_private_state': localPrivateState,
    };
  }

  /// Imports a decrypted recovery-bundle payload (the inverse of
  /// [buildRecoveryBundlePayload]); shared by passphrase backups and social
  /// recovery.
  Future<void> importBundlePayload(dynamic payload) async {
    if (payload is! Map || payload['openchat_recovery_bundle'] != 1) {
      throw ArgumentError('Payload is not an OpenChat recovery bundle');
    }
    final secure = payload['secure_storage'];
    if (secure is Map) {
      await _storage.importRecoverySecrets(
        secure.map((key, value) => MapEntry(key.toString(), value.toString())),
      );
    }
    final privateState = payload['local_private_state'];
    if (privateState is Map) {
      await _privateState.writeState(
        privateState.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
  }

  Future<String> exportBackup({
    required String passphrase,
    bool requireStrong = false,
  }) async {
    final normalized = passphrase.trim();
    if (normalized.length < 12) {
      throw ArgumentError('Backup passphrase must be at least 12 characters');
    }
    if (requireStrong &&
        !PassphraseStrength.isStrongEnoughForServer(normalized)) {
      throw ArgumentError(
        'Backup passphrase is too weak for server upload; choose a longer/more varied passphrase',
      );
    }
    final payload = await buildRecoveryBundlePayload();
    final salt = _randomBytes(16);
    final key = await _deriveKey(normalized, salt, _defaultIterations);
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: key,
    );
    return const JsonEncoder.withIndent('  ').convert({
      'openchat_encrypted_recovery': 1,
      'kdf': 'pbkdf2-hmac-sha256',
      'iterations': _defaultIterations,
      'salt': base64Encode(salt),
      'cipher': 'aes-256-gcm',
      'payload': base64Encode(box.concatenation()),
    });
  }

  Future<void> importBackup({
    required String encodedBackup,
    required String passphrase,
  }) async {
    final decoded = jsonDecode(encodedBackup);
    if (decoded is! Map) {
      throw ArgumentError('Backup file is not a JSON object');
    }
    final version = decoded['openchat_encrypted_recovery'];
    if (version != 1) {
      throw ArgumentError('Unsupported OpenChat backup format');
    }
    // Honor the KDF parameters stored in the file (with a floor) instead of
    // assuming the current export constants — otherwise the moment the export
    // iteration count changes, every older backup silently fails to decrypt.
    final kdf = decoded['kdf'] as String? ?? 'pbkdf2-hmac-sha256';
    if (kdf != 'pbkdf2-hmac-sha256') {
      throw ArgumentError('Unsupported backup KDF: $kdf');
    }
    final iterations = switch (decoded['iterations']) {
      final int value => value,
      final num value => value.toInt(),
      _ => _defaultIterations,
    };
    if (iterations < _minImportIterations) {
      throw ArgumentError('Backup KDF iteration count is too low');
    }
    final salt = base64Decode(decoded['salt'] as String? ?? '');
    final encrypted = base64Decode(decoded['payload'] as String? ?? '');
    final key = await _deriveKey(passphrase.trim(), salt, iterations);
    final box = SecretBox.fromConcatenation(
      encrypted,
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
    );
    final clear = await _cipher.decrypt(box, secretKey: key);
    await importBundlePayload(jsonDecode(utf8.decode(clear)));
  }

  /// Builds the encrypted bundle and stores it server-side as an opaque blob
  /// (zero-knowledge: the passphrase/key never leaves this device). Replaces
  /// any previous server backup.
  Future<void> uploadToServer({
    required ApiService api,
    required String passphrase,
  }) async {
    final latest = await api.getLatestBackup();
    final baseRevision = (latest?['revision'] is num)
        ? (latest!['revision'] as num).toInt()
        : 0;
    final encoded = await exportBackup(
      passphrase: passphrase,
      requireStrong: true,
    );
    final bytes = utf8.encode(encoded);
    final digest = crypto.sha256.convert(bytes).toString();
    final grant = await api.requestBackupUpload(
      size: bytes.length,
      sha256: digest,
      baseRevision: baseRevision,
    );
    await api.uploadBytes(
      grant['upload_url'] as String,
      bytes,
      'application/octet-stream',
    );
    await api.confirmBackupUpload(grant['object_key'] as String);
  }

  /// Downloads the server-stored blob and restores it with [importBackup]
  /// (which enforces the format/KDF floors). Throws [StateError] when no
  /// server backup exists.
  Future<void> restoreFromServer({
    required ApiService api,
    required String passphrase,
  }) async {
    final meta = await api.getLatestBackup();
    if (meta == null) {
      throw StateError('No backup is stored on the server.');
    }
    final bytes = await api.downloadBytes(meta['download_url'] as String);
    final expected = meta['sha256'] as String? ?? '';
    if (expected.isNotEmpty &&
        crypto.sha256.convert(bytes).toString() != expected) {
      throw StateError('Backup download is corrupted (checksum mismatch).');
    }
    await importBackup(
      encodedBackup: utf8.decode(bytes),
      passphrase: passphrase,
    );
  }

  /// The local timestamp of the most recent server backup, or null when none
  /// exists. Prefers `updated_at` (last confirmed upload) over `created_at` so
  /// re-uploads reset the age. Centralizes the null/404 handling that
  /// [ApiService.getLatestBackup] already does.
  Future<DateTime?> latestBackupTimestamp({required ApiService api}) async {
    final meta = await api.getLatestBackup();
    if (meta == null) return null;
    final raw = (meta['updated_at'] ?? meta['created_at']) as String?;
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  Future<SecretKey> _deriveKey(
    String passphrase,
    List<int> salt,
    int iterations,
  ) {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    return kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}

Map<String, Object?> recoveryBundleManifest({
  required Map<String, String> secureStorage,
  required Map<String, Object?> localPrivateState,
  required String createdAt,
}) {
  final privateStateKeys =
      localPrivateState.keys
          .map((key) => key.toString())
          .where((key) => key.trim().isNotEmpty)
          .toList()
        ..sort();
  final fingerprint = _manifestString(
    secureStorage['pgp_fingerprint'],
  )?.toUpperCase();
  return {
    'version': 1,
    'created_at': createdAt,
    'user_id': _manifestString(secureStorage['user_id']),
    'username': _manifestString(secureStorage['username']),
    'key_fingerprint': fingerprint,
    'has_private_key':
        _manifestString(secureStorage['pgp_private_key']) != null,
    'has_public_key': _manifestString(secureStorage['pgp_public_key']) != null,
    'local_private_state_keys': privateStateKeys,
  };
}

String? _manifestString(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) return null;
  return text;
}
