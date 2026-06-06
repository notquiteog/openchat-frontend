import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'local_private_state_service.dart';
import 'secure_storage_service.dart';

class EncryptedBackupService {
  final SecureStorageService _storage;
  final LocalPrivateStateService _privateState;
  final _cipher = AesGcm.with256bits();
  final _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 310000,
    bits: 256,
  );

  EncryptedBackupService({
    SecureStorageService? storage,
    LocalPrivateStateService? privateState,
  }) : _storage = storage ?? SecureStorageService(),
       _privateState = privateState ?? LocalPrivateStateService();

  Future<String> exportBackup({required String passphrase}) async {
    final normalized = passphrase.trim();
    if (normalized.length < 12) {
      throw ArgumentError('Backup passphrase must be at least 12 characters');
    }
    final payload = {
      'openchat_recovery_bundle': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'secure_storage': await _storage.exportRecoverySecrets(),
      'local_private_state': await _privateState.readState(),
    };
    final salt = _randomBytes(16);
    final key = await _deriveKey(normalized, salt);
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: key,
    );
    return const JsonEncoder.withIndent('  ').convert({
      'openchat_encrypted_recovery': 1,
      'kdf': 'pbkdf2-hmac-sha256',
      'iterations': 310000,
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
    final salt = base64Decode(decoded['salt'] as String? ?? '');
    final encrypted = base64Decode(decoded['payload'] as String? ?? '');
    final key = await _deriveKey(passphrase.trim(), salt);
    final box = SecretBox.fromConcatenation(
      encrypted,
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
    );
    final clear = await _cipher.decrypt(box, secretKey: key);
    final payload = jsonDecode(utf8.decode(clear));
    if (payload is! Map || payload['openchat_recovery_bundle'] != 1) {
      throw ArgumentError('Backup payload is not an OpenChat recovery bundle');
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

  Future<SecretKey> _deriveKey(String passphrase, List<int> salt) {
    return _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}
