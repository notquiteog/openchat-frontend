import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/crypto/shamir.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/social_recovery_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Social recovery end-to-end crypto (PGP transport excluded — that runs on
/// the native bridge): configure must produce a server blob and guardian
/// shares such that any threshold subset reconstructs the recovery secret and
/// decrypts the blob back to the exact bundle, while below-threshold subsets
/// fail the AES-GCM authentication rather than yielding plausible garbage.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      'pgp_private_key': 'PRIVATE-ARMOR',
      'pgp_public_key': 'PUBLIC-ARMOR',
      'pgp_fingerprint': 'FINGERPRINT',
      'user_id': 'self-user',
    });
  });

  Future<Uint8List> decryptBlob(String blobJson, List<int> secret) async {
    final decoded = jsonDecode(blobJson) as Map<String, dynamic>;
    expect(decoded['openchat_recovery_blob'], 1);
    final cipher = AesGcm.with256bits();
    final box = SecretBox.fromConcatenation(
      base64Decode(decoded['payload'] as String),
      nonceLength: cipher.nonceLength,
      macLength: cipher.macAlgorithm.macLength,
    );
    final clear = await cipher.decrypt(box, secretKey: SecretKey(secret));
    return Uint8List.fromList(clear);
  }

  test('configure → threshold shares decrypt the blob to the bundle',
      () async {
    final storage = SecureStorageService();
    final api = _CapturingApi(storage);
    final service = SocialRecoveryService(storage: storage);

    final deliveries = await service.configure(
      api: api,
      selfUserId: 'self-user',
      guardianUserIds: ['g1', 'g2', 'g3'],
      threshold: 2,
    );

    expect(api.blob, isNotNull, reason: 'blob must be uploaded');
    expect(api.threshold, 2);
    expect(api.guardianIds, ['g1', 'g2', 'g3']);
    expect(deliveries.keys, containsAll(['g1', 'g2', 'g3']));

    // Each delivery is a self-describing hidden-message payload.
    final share1 = jsonDecode(deliveries['g1']!) as Map<String, dynamic>;
    expect(share1['openchat_recovery_share'], 1);
    expect(share1['owner_user_id'], 'self-user');
    expect(share1['threshold'], 2);

    // Any 2 of 3 shares reconstruct the secret and decrypt the blob.
    final share3 = jsonDecode(deliveries['g3']!) as Map<String, dynamic>;
    final secret = Shamir.combine([
      base64Decode(share1['share'] as String),
      base64Decode(share3['share'] as String),
    ]);
    final bundleBytes = await decryptBlob(api.blob!, secret);
    final bundle = jsonDecode(utf8.decode(bundleBytes)) as Map<String, dynamic>;
    expect(bundle['openchat_recovery_bundle'], 1);
    final secure = bundle['secure_storage'] as Map<String, dynamic>;
    expect(secure['pgp_private_key'], 'PRIVATE-ARMOR',
        reason: 'the bundle must carry the identity key');
    expect(secure.containsKey('access_token'), isFalse,
        reason: 'session tokens never ride recovery bundles');
  });

  test('a single share cannot decrypt the blob (GCM authenticates)', () async {
    final storage = SecureStorageService();
    final api = _CapturingApi(storage);
    final service = SocialRecoveryService(storage: storage);
    final deliveries = await service.configure(
      api: api,
      selfUserId: 'self-user',
      guardianUserIds: ['g1', 'g2', 'g3'],
      threshold: 3,
    );

    // Two of three when threshold is 3 → wrong secret → authentication fails.
    final s1 = jsonDecode(deliveries['g1']!) as Map<String, dynamic>;
    final s2 = jsonDecode(deliveries['g2']!) as Map<String, dynamic>;
    final wrong = Shamir.combine([
      base64Decode(s1['share'] as String),
      base64Decode(s2['share'] as String),
    ]);
    await expectLater(
      decryptBlob(api.blob!, wrong),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('storeIncomingShare persists by owner and lists back', () async {
    final storage = SecureStorageService();
    final service = SocialRecoveryService(storage: storage);
    await service.storeIncomingShare({
      'openchat_recovery_share': 1,
      'owner_user_id': 'friend-1',
      'share': base64Encode([1, 2, 3]),
      'threshold': 2,
      'index': 1,
    });

    final held = await storage.listHeldRecoveryShares();
    expect(held.keys, contains('friend-1'));
    final parsed = jsonDecode(held['friend-1']!) as Map<String, dynamic>;
    expect(parsed['threshold'], 2);

    // Malformed payloads are ignored, never stored.
    await service.storeIncomingShare({'openchat_recovery_share': 1});
    expect((await storage.listHeldRecoveryShares()).length, 1);
  });
}

class _CapturingApi extends ApiService {
  _CapturingApi(super.storage);

  String? blob;
  int? threshold;
  List<String>? guardianIds;

  @override
  Future<void> setupRecovery({
    required String blob,
    required String sha256,
    required int threshold,
    required List<String> guardianIds,
  }) async {
    this.blob = blob;
    this.threshold = threshold;
    this.guardianIds = guardianIds;
  }
}
