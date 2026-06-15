import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/crypto/amf_service.dart';
import 'package:openchat/services/amf_key_service.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';

/// Flagship B — client AMF key pinning. The service must verify the bundle
/// self-signature, trust-on-first-use pin, serve the pinned keys offline, and
/// fail closed (AmfKeyChangedException) when the server's keys differ from the
/// pinned set.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SecureStorageService storage;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = SecureStorageService();
  });

  // Builds a bundle map {moderator_public_key, platform_public_key, signature}
  // where signature = Sign_platPriv(keyBundleSignedData(modPub, platPub)).
  Future<Map<String, String>> buildBundle({
    required List<int> modPub,
    required SimpleKeyPair platKeyPair,
  }) async {
    final platPub = await platKeyPair.extractPublicKey();
    final sig = await Ed25519().sign(
      AmfService.keyBundleSignedData(modPub, platPub.bytes),
      keyPair: platKeyPair,
    );
    return {
      'moderator_public_key': base64.encode(modPub),
      'platform_public_key': base64.encode(platPub.bytes),
      'signature': base64.encode(sig.bytes),
      'signed_by': 'platform',
    };
  }

  test('TOFU-pins a valid bundle and serves it on the next call', () async {
    final platKp = await Ed25519().newKeyPair();
    final modPub =
        (await (await Ed25519().newKeyPair()).extractPublicKey()).bytes;
    final bundle = await buildBundle(modPub: modPub, platKeyPair: platKp);
    final api = _FakeApi(storage, bundle);
    final svc = AmfKeyService(api, storage);

    final keys = await svc.pinnedKeys();
    expect(
      base64.encode(keys.moderatorPublicKey),
      bundle['moderator_public_key'],
    );
    expect(
      await storage.getAmfKeysCache(),
      isNotNull,
      reason: 'a verified bundle must be pinned',
    );

    // A fresh service instance (no in-memory cache) re-reads the pin + re-fetch.
    final keys2 = await AmfKeyService(api, storage).pinnedKeys();
    expect(
      base64.encode(keys2.platformPublicKey),
      bundle['platform_public_key'],
    );
  });

  test('rejects a bundle whose self-signature does not verify', () async {
    final platKp = await Ed25519().newKeyPair();
    final modPub =
        (await (await Ed25519().newKeyPair()).extractPublicKey()).bytes;
    final bundle = await buildBundle(modPub: modPub, platKeyPair: platKp);
    // Corrupt the signature.
    final badSig = base64.decode(bundle['signature']!);
    badSig[0] ^= 0xFF;
    bundle['signature'] = base64.encode(badSig);

    final svc = AmfKeyService(_FakeApi(storage, bundle), storage);
    await expectLater(svc.pinnedKeys(), throwsA(isA<AmfKeyException>()));
    expect(
      await storage.getAmfKeysCache(),
      isNull,
      reason: 'an unverifiable bundle must not be pinned',
    );
  });

  test(
    'fails closed when the server keys differ from the pinned set',
    () async {
      final platKp = await Ed25519().newKeyPair();
      final modPub1 =
          (await (await Ed25519().newKeyPair()).extractPublicKey()).bytes;
      final bundle1 = await buildBundle(modPub: modPub1, platKeyPair: platKp);

      // Pin the first bundle.
      await AmfKeyService(_FakeApi(storage, bundle1), storage).pinnedKeys();

      // Server now serves a DIFFERENT moderator key (validly signed by the same
      // platform key) — a possible key swap.
      final modPub2 =
          (await (await Ed25519().newKeyPair()).extractPublicKey()).bytes;
      final bundle2 = await buildBundle(modPub: modPub2, platKeyPair: platKp);

      final svc = AmfKeyService(_FakeApi(storage, bundle2), storage);
      await expectLater(
        svc.pinnedKeys(),
        throwsA(isA<AmfKeyChangedException>()),
      );
    },
  );

  test('serves the pinned keys offline when the fetch fails', () async {
    final platKp = await Ed25519().newKeyPair();
    final modPub =
        (await (await Ed25519().newKeyPair()).extractPublicKey()).bytes;
    final bundle = await buildBundle(modPub: modPub, platKeyPair: platKp);

    await AmfKeyService(_FakeApi(storage, bundle), storage).pinnedKeys();

    // Now the network is down.
    final keys = await AmfKeyService(
      _ThrowingApi(storage),
      storage,
    ).pinnedKeys();
    expect(
      base64.encode(keys.moderatorPublicKey),
      bundle['moderator_public_key'],
    );
  });

  test('throws when keys are unavailable and nothing is pinned', () async {
    final svc = AmfKeyService(_ThrowingApi(storage), storage);
    await expectLater(svc.pinnedKeys(), throwsA(isA<AmfKeyException>()));
  });
}

class _FakeApi extends ApiService {
  _FakeApi(super.storage, this.bundle);
  final Map<String, String> bundle;
  @override
  Future<Map<String, dynamic>> getAmfKeys() async =>
      Map<String, dynamic>.from(bundle);
}

class _ThrowingApi extends ApiService {
  _ThrowingApi(super.storage);
  @override
  Future<Map<String, dynamic>> getAmfKeys() async =>
      throw Exception('network down');
}
