import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/encrypted_backup_service.dart';
import 'package:openchat/services/local_private_state_service.dart';
import 'package:openchat/services/secure_storage_service.dart';

// Zero-knowledge server backup: the blob that reaches the (fake) server must
// be the passphrase-encrypted bundle — never plaintext — and a fresh device
// restoring it must recover the original secrets.
class _FakeBackupStorage extends SecureStorageService {
  Map<String, String> secrets;
  Map<String, Object?> privateState;

  _FakeBackupStorage({
    Map<String, String>? secrets,
    this.privateState = const {},
  }) : secrets = secrets ?? {};

  @override
  Future<Map<String, String>> exportRecoverySecrets() async => secrets;

  @override
  Future<void> importRecoverySecrets(Map<String, String> values) async {
    secrets = Map.of(values);
  }
}

class _FakePrivateState extends LocalPrivateStateService {
  final _FakeBackupStorage backing;
  _FakePrivateState(this.backing) : super(storage: backing);

  @override
  Future<Map<String, dynamic>> readState() async =>
      Map<String, dynamic>.from(backing.privateState);

  @override
  Future<void> writeState(Map<String, Object?> state) async {
    backing.privateState = Map.of(state);
  }
}

/// In-memory "server": presigned URLs are fake keys into a blob map.
class _FakeBackupApi extends ApiService {
  _FakeBackupApi() : super(SecureStorageService());

  final Map<String, Uint8List> blobs = {};
  String? confirmedKey;
  String? latestSha;

  @override
  Future<Map<String, dynamic>> requestBackupUpload({
    required int size,
    required String sha256,
  }) async {
    latestSha = sha256;
    return {
      'object_key': 'backups/user/blob-${blobs.length + 1}',
      'upload_url': 'fake://upload/${blobs.length + 1}',
      'expires_in': 900,
    };
  }

  @override
  Future<void> uploadBytes(
    String uploadUrl,
    Uint8List bytes,
    String mimeType, {
    UploadProgressCallback? onProgress,
  }) async {
    blobs[uploadUrl] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> confirmBackupUpload(String objectKey) async {
    confirmedKey = objectKey;
  }

  @override
  Future<Map<String, dynamic>?> getLatestBackup() async {
    if (blobs.isEmpty || confirmedKey == null) return null;
    return {
      'download_url': blobs.keys.last,
      'sha256': latestSha,
      'size_bytes': blobs.values.last.length,
    };
  }

  @override
  Future<Uint8List> downloadBytes(String url) async => blobs[url]!;
}

void main() {
  const passphrase = 'a-very-long-test-passphrase';

  test(
    'upload stores only ciphertext and restore recovers the secrets',
    () async {
      final source = _FakeBackupStorage(
        secrets: {'private_key': 'SECRET-PGP-KEY-MATERIAL'},
        privateState: {
          'chat_folders': ['work'],
        },
      );
      final api = _FakeBackupApi();

      await EncryptedBackupService(
        storage: source,
        privateState: _FakePrivateState(source),
      ).uploadToServer(api: api, passphrase: passphrase);

      expect(api.confirmedKey, isNotNull);
      expect(api.blobs, hasLength(1));
      final stored = utf8.decode(api.blobs.values.single);
      // Zero-knowledge: the secret never appears in what the server holds.
      expect(stored.contains('SECRET-PGP-KEY-MATERIAL'), isFalse);
      expect(
        jsonDecode(stored),
        containsPair('openchat_encrypted_recovery', 1),
      );
      // The recorded checksum matches the stored bytes.
      expect(
        crypto.sha256.convert(api.blobs.values.single).toString(),
        api.latestSha,
      );

      // Fresh device restores from the server blob.
      final fresh = _FakeBackupStorage();
      await EncryptedBackupService(
        storage: fresh,
        privateState: _FakePrivateState(fresh),
      ).restoreFromServer(api: api, passphrase: passphrase);

      expect(fresh.secrets['private_key'], 'SECRET-PGP-KEY-MATERIAL');
      expect(fresh.privateState['chat_folders'], ['work']);
    },
  );

  test('restore fails cleanly when no server backup exists', () async {
    final fresh = _FakeBackupStorage();
    final api = _FakeBackupApi();
    expect(
      () => EncryptedBackupService(
        storage: fresh,
        privateState: _FakePrivateState(fresh),
      ).restoreFromServer(api: api, passphrase: passphrase),
      throwsStateError,
    );
  });

  test(
    'server upload rejects weak passphrases before storing a blob',
    () async {
      final source = _FakeBackupStorage(secrets: {'private_key': 'SECRET'});
      final api = _FakeBackupApi();

      expect(
        () => EncryptedBackupService(
          storage: source,
          privateState: _FakePrivateState(source),
        ).uploadToServer(api: api, passphrase: 'password1234'),
        throwsArgumentError,
      );
      expect(api.blobs, isEmpty);
      expect(api.confirmedKey, isNull);
    },
  );

  test('restore rejects a corrupted blob (checksum mismatch)', () async {
    final source = _FakeBackupStorage(secrets: {'k': 'v'});
    final api = _FakeBackupApi();
    await EncryptedBackupService(
      storage: source,
      privateState: _FakePrivateState(source),
    ).uploadToServer(api: api, passphrase: passphrase);

    // Flip a byte in the stored blob.
    final key = api.blobs.keys.single;
    final tampered = Uint8List.fromList(api.blobs[key]!);
    tampered[tampered.length ~/ 2] ^= 0xFF;
    api.blobs[key] = tampered;

    final fresh = _FakeBackupStorage();
    expect(
      () => EncryptedBackupService(
        storage: fresh,
        privateState: _FakePrivateState(fresh),
      ).restoreFromServer(api: api, passphrase: passphrase),
      throwsStateError,
    );
  });

  group('latestBackupTimestamp (#18)', () {
    EncryptedBackupService service(_FakeBackupStorage storage) =>
        EncryptedBackupService(
          storage: storage,
          privateState: _FakePrivateState(storage),
        );

    test('returns null when no backup is stored', () async {
      final api = _MetaOnlyApi()..meta = null;
      expect(
        await service(_FakeBackupStorage()).latestBackupTimestamp(api: api),
        isNull,
      );
    });

    test('prefers updated_at over created_at', () async {
      final api = _MetaOnlyApi()
        ..meta = {
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-06-10T08:00:00Z',
        };
      final at = await service(
        _FakeBackupStorage(),
      ).latestBackupTimestamp(api: api);
      expect(at!.toUtc(), DateTime.parse('2026-06-10T08:00:00Z').toUtc());
    });

    test('falls back to created_at when updated_at is absent', () async {
      final api = _MetaOnlyApi()..meta = {'created_at': '2026-03-03T03:03:03Z'};
      final at = await service(
        _FakeBackupStorage(),
      ).latestBackupTimestamp(api: api);
      expect(at!.toUtc(), DateTime.parse('2026-03-03T03:03:03Z').toUtc());
    });
  });
}

/// Returns only the metadata map for latestBackupTimestamp, without the
/// blob-derived shape of [_FakeBackupApi].
class _MetaOnlyApi extends ApiService {
  _MetaOnlyApi() : super(SecureStorageService());

  Map<String, dynamic>? meta;

  @override
  Future<Map<String, dynamic>?> getLatestBackup() async => meta;
}
