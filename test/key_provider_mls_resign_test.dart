import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/crypto/pgp_service.dart';
import 'package:openchat/services/mls_service.dart';
import 'package:openchat/services/secure_storage_service.dart';

/// #16 — after a PGP rotation the MLS device-key signature must be re-made with
/// the NEW private key, or the server (which verifies the signer signature
/// against the account's current public key) hard-blocks new MLS conversations
/// and commits. These tests exercise the real PGP sign/verify path that backs
/// MlsService.resignDeviceKeyForCurrentUser and the Trust Center's
/// verify-against-current-key check that replaces the old false-green.
void main() {
  setUpAll(_ensureOpenPgpBridgeForUnitTests);

  // An arbitrary stand-in for the MLS device public key bytes; resign only
  // re-signs over its base64 form, so its actual contents are irrelevant.
  final mlsKeyB64 = base64Encode(List<int>.generate(32, (i) => i));

  String signedData(String userId) =>
      PgpService.deviceKeySignatureData(userId: userId, deviceKey: mlsKeyB64);

  test(
    'resign re-binds the stored MLS key to the new PGP key after rotation',
    () async {
      const userId = 'user-a';
      final oldPair = await PgpService.generateKeyPair(username: 'a');
      final newPair = await PgpService.generateKeyPair(username: 'a');

      // Seed a signer signed by the OLD key, as it would be before rotation.
      final oldSig = await PgpService.sign(
        data: signedData(userId),
        privateKeyArmored: oldPair.privateKeyArmored,
      );
      expect(
        await PgpService.verify(
          data: signedData(userId),
          signatureArmor: oldSig,
          signerPublicKeyArmored: oldPair.publicKeyArmored,
        ),
        isTrue,
        reason: 'sanity: the seeded signature verifies under the old key',
      );

      final storage = _FakeStorage(
        userId: userId,
        privateKey: oldPair.privateKeyArmored,
        publicKey: oldPair.publicKeyArmored,
        signer: MlsSignerStorage(
          signerBytes: 'SIGNER-BYTES',
          publicKey: mlsKeyB64,
          signature: oldSig,
        ),
      );

      // Rotate: the new key pair is now what storage hands out.
      storage.privateKey = newPair.privateKeyArmored;
      storage.publicKey = newPair.publicKeyArmored;

      await MlsService(storage).resignDeviceKeyForCurrentUser();

      final newSig = storage.signer!.signature;
      expect(
        await PgpService.verify(
          data: signedData(userId),
          signatureArmor: newSig,
          signerPublicKeyArmored: newPair.publicKeyArmored,
        ),
        isTrue,
        reason: 'the refreshed signature must verify under the NEW key',
      );
      expect(
        await PgpService.verify(
          data: signedData(userId),
          signatureArmor: newSig,
          signerPublicKeyArmored: oldPair.publicKeyArmored,
        ),
        isFalse,
        reason:
            'a signature made by the new key must NOT verify under the old '
            'key — this is exactly the stale-signer case the server rejects '
            'and the Trust Center must show as Prepare, not false-green',
      );
      expect(
        storage.signer!.signerBytes,
        'SIGNER-BYTES',
        reason: 'only the signature is refreshed; the signer is untouched',
      );
      expect(storage.signer!.publicKey, mlsKeyB64);
    },
  );

  test('resign is a no-op when no signer exists yet', () async {
    final pair = await PgpService.generateKeyPair(username: 'a');
    final storage = _FakeStorage(
      userId: 'user-a',
      privateKey: pair.privateKeyArmored,
      publicKey: pair.publicKeyArmored,
      signer: null,
    );

    await MlsService(storage).resignDeviceKeyForCurrentUser();

    expect(
      storage.signer,
      isNull,
      reason: 'nothing to re-sign; first MLS use will create + sign one',
    );
    expect(storage.saveCount, 0, reason: 'no write should happen');
  });

  test(
    'resign does not clobber a good signature when the private key is locked',
    () async {
      const userId = 'user-a';
      final pair = await PgpService.generateKeyPair(username: 'a');
      final goodSig = await PgpService.sign(
        data: signedData(userId),
        privateKeyArmored: pair.privateKeyArmored,
      );
      final storage = _FakeStorage(
        userId: userId,
        privateKey: null, // locked / unavailable
        publicKey: pair.publicKeyArmored,
        signer: MlsSignerStorage(
          signerBytes: 'SIGNER-BYTES',
          publicKey: mlsKeyB64,
          signature: goodSig,
        ),
      );

      await MlsService(storage).resignDeviceKeyForCurrentUser();

      expect(
        storage.signer!.signature,
        goodSig,
        reason:
            'a locked key must not replace a working signature with '
            'empty',
      );
      expect(storage.saveCount, 0);
    },
  );
}

// ── Fakes ────────────────────────────────────────────────────────────────────

class _FakeStorage extends SecureStorageService {
  _FakeStorage({
    required this.userId,
    required this.privateKey,
    required this.publicKey,
    required this.signer,
  });

  String userId;
  String? privateKey;
  String publicKey;
  MlsSignerStorage? signer;
  int saveCount = 0;

  @override
  Future<String?> getUserID() async => userId;

  @override
  Future<String?> getPrivateKey() async => privateKey;

  @override
  Future<String?> getPublicKey() async => publicKey;

  @override
  Future<MlsSignerStorage?> getMlsSigner(String userID) async => signer;

  @override
  Future<void> saveMlsSigner({
    required String userID,
    required String signerBytes,
    required String publicKey,
    String signature = '',
  }) async {
    saveCount++;
    signer = MlsSignerStorage(
      signerBytes: signerBytes,
      publicKey: publicKey,
      signature: signature,
    );
  }
}

// ── OpenPGP native-bridge bootstrap for host-VM unit tests ───────────────────
// Mirrors test/call_signal_codec_test.dart: copies the bundled libopenpgp
// bridge next to the test runner so real PGP sign/verify works under
// `flutter test`.

Future<void> _ensureOpenPgpBridgeForUnitTests() async {
  final target = _openPgpBridgeTestTarget();
  if (target == null || target.existsSync()) return;
  final source = await _bundledOpenPgpBridge();
  if (source == null || !source.existsSync()) return;
  await target.parent.create(recursive: true);
  await source.copy(target.path);
}

File? _openPgpBridgeTestTarget() {
  if (Platform.isLinux) {
    final arch = Platform.resolvedExecutable.contains('x64') ? 'x64' : 'arm64';
    return File('build/linux/$arch/debug/bundle/lib/libopenpgp_bridge.so');
  }
  if (Platform.isWindows) {
    final arch = Platform.resolvedExecutable.contains('x64') ? 'x64' : 'arm64';
    return File('build/windows/$arch/runner/Debug/libopenpgp_bridge.dll');
  }
  if (Platform.isMacOS) {
    return File(
      'build/macos/Build/Products/Debug/Contents/Frameworks/'
      'libopenpgp_bridge.dylib',
    );
  }
  return null;
}

Future<File?> _bundledOpenPgpBridge() async {
  final packageRoot = await _packageRoot('openpgp');
  if (packageRoot == null) return null;
  if (Platform.isLinux) {
    final arch = Platform.resolvedExecutable.contains('x64')
        ? 'x86_64'
        : 'aarch64';
    return File('${packageRoot.path}/linux/shared/$arch/libopenpgp_bridge.so');
  }
  if (Platform.isWindows) {
    return File('${packageRoot.path}/windows/shared/libopenpgp_bridge.dll');
  }
  if (Platform.isMacOS) {
    return File('${packageRoot.path}/macos/libopenpgp_bridge.dylib');
  }
  return null;
}

Future<Directory?> _packageRoot(String packageName) async {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) return null;
  final decoded =
      jsonDecode(await config.readAsString()) as Map<String, dynamic>;
  final packages = (decoded['packages'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>();
  final package = packages
      .where((pkg) => pkg['name'] == packageName)
      .firstOrNull;
  if (package == null) return null;
  final rootUri = package['rootUri'] as String?;
  if (rootUri == null) return null;
  final packageConfigUri = config.absolute.parent.uri;
  return Directory.fromUri(packageConfigUri.resolve(rootUri));
}
