import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/mesh/mesh_frames.dart';
import 'package:openchat/services/mesh/mesh_session.dart';
import 'package:openchat/services/mesh/nearby_mesh_service.dart';
import 'package:openchat/services/secure_storage_service.dart';

/// deliverQueuedTo against a real (fake-crypto) authenticated session pair:
/// acked nonces are skipped, everything else flows, sentCount is honest.
void main() {
  MeshSession buildSession({
    required String fp,
    required MeshFrameSender sendFrame,
    int seed = 1,
  }) => MeshSession(
    selfFingerprint: fp,
    selfPublicKeyArmored: 'KEY:$fp',
    selfDisplayName: 'user-$fp',
    sign: (data) async => 'SIG|$data|$fp',
    verify: (data, signature, publicKey) async =>
        signature == 'SIG|$data|${publicKey.substring(4)}',
    fingerprintOf: (publicKey) async => publicKey.substring(4),
    sendFrame: sendFrame,
    random: Random(seed),
  );

  test('drain skips acked nonces and counts only what was sent', () async {
    late MeshSession a, b;
    a = buildSession(
      fp: 'AAAA',
      seed: 1,
      sendFrame: (type, payload) async {
        await b.handleFrame(MeshFrame(type: type, payload: payload));
      },
    );
    b = buildSession(
      fp: 'BBBB',
      seed: 2,
      sendFrame: (type, payload) async {
        await a.handleFrame(MeshFrame(type: type, payload: payload));
      },
    );
    await a.start();
    expect(a.authenticated, isTrue);

    final received = <Map<String, dynamic>>[];
    b.messages.listen(received.add);

    Map<String, dynamic> envelope(String nonce) => {
      'conversation_id': 'dm-1',
      'encrypted_payload': 'cipher-$nonce',
      'signature': 'sig',
      'message_type': 'text',
      'client_nonce': nonce,
      'created_at': '2026-06-11T10:00:00.000Z',
    };

    final service = NearbyMeshService(
      storage: SecureStorageService(),
      onEnvelope: (e, fp) async => true,
      envelopesForPeer: (fp) async => [
        envelope('n1'),
        envelope('n2'),
        envelope('n3'),
      ],
      contactNameForFingerprint: (fp) => 'Bee',
    );
    final peer = NearbyPeer(linkId: 'link-1', session: a)
      ..ackedNonces.add('n2'); // peer already confirmed n2 this session

    await service.deliverQueuedTo(peer);
    await Future<void>.delayed(Duration.zero);

    expect(peer.sentCount, 2);
    expect(received.map((e) => e['client_nonce']), ['n1', 'n3']);
  });

  test('drain refuses to run on an unauthenticated session', () async {
    final lonely = buildSession(
      fp: 'AAAA',
      sendFrame: (type, payload) async =>
          fail('must not send on an unauthenticated session'),
    );
    final service = NearbyMeshService(
      storage: SecureStorageService(),
      onEnvelope: (e, fp) async => true,
      envelopesForPeer: (fp) async => fail('must not read the outbox'),
      contactNameForFingerprint: (fp) => null,
    );
    final peer = NearbyPeer(linkId: 'link-1', session: lonely);
    await service.deliverQueuedTo(peer); // completes without sending
    expect(peer.sentCount, 0);
  });
}
