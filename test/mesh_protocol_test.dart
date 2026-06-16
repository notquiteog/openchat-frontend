import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/mesh/mesh_frames.dart';
import 'package:openchat/services/mesh/mesh_outbox_drain.dart';
import 'package:openchat/services/mesh/mesh_session.dart';
import 'package:openchat/services/offline_outbox_service.dart';

void main() {
  group('frame codec', () {
    test('round-trips type + payload', () {
      final payload = Uint8List.fromList(List.generate(1000, (i) => i % 251));
      final frame = decodeMeshFrame(encodeMeshFrame(meshFrameMessage, payload));
      expect(frame.type, meshFrameMessage);
      expect(frame.payload, payload);
    });

    test('rejects a flipped bit via CRC', () {
      final encoded = encodeMeshFrame(
        meshFrameHello,
        Uint8List.fromList('hello mesh'.codeUnits),
      );
      encoded[10] ^= 0x40;
      expect(
        () => decodeMeshFrame(encoded),
        throwsA(isA<MeshFrameException>()),
      );
    });

    test('rejects truncation and garbage', () {
      final encoded = encodeMeshFrame(meshFrameAck, Uint8List(0));
      expect(
        () => decodeMeshFrame(Uint8List.sublistView(encoded, 0, 6)),
        throwsA(isA<MeshFrameException>()),
      );
      expect(
        () => decodeMeshFrame(Uint8List.fromList(List.filled(40, 9))),
        throwsA(isA<MeshFrameException>()),
      );
    });
  });

  group('chunker + reassembler', () {
    test('splits to MTU-sized chunks and reassembles', () {
      final frame = encodeMeshFrame(
        meshFrameMessage,
        Uint8List.fromList(List.generate(5000, (i) => (i * 7) % 256)),
      );
      final chunks = splitMeshFrame(frame, 185); // typical Android MTU slice
      expect(chunks.length, greaterThan(20));
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(185));
      }
      final reassembler = MeshReassembler();
      Uint8List? result;
      for (final c in chunks) {
        result = reassembler.addChunk(c);
      }
      expect(result, frame);
      // The reassembled frame still passes CRC.
      expect(decodeMeshFrame(result!).payload.length, 5000);
    });

    test('empty frame still produces one chunk', () {
      final frame = encodeMeshFrame(meshFrameAck, Uint8List(0));
      final chunks = splitMeshFrame(frame, 500);
      expect(chunks, hasLength(1));
      expect(MeshReassembler().addChunk(chunks.first), frame);
    });

    test('detects chunk gaps and recovers on the next frame', () {
      final frame = encodeMeshFrame(
        meshFrameMessage,
        Uint8List.fromList(List.generate(600, (i) => i % 256)),
      );
      final chunks = splitMeshFrame(frame, 100);
      expect(chunks.length, greaterThan(2));
      final reassembler = MeshReassembler();
      reassembler.addChunk(chunks[0]);
      expect(
        () => reassembler.addChunk(chunks[2]), // dropped chunks[1]
        throwsA(isA<MeshFrameException>()),
      );
      // A fresh frame after the failure reassembles fine.
      Uint8List? result;
      for (final c in chunks) {
        result = reassembler.addChunk(c);
      }
      expect(result, frame);
    });
  });

  group('session handshake', () {
    // Fake crypto: signatures are 'SIG|<data>|<key fingerprint>' and verify
    // checks structure. fingerprintOf extracts from 'KEY:<fp>' armors.
    MeshSession buildSession({
      required String fp,
      required MeshFrameSender sendFrame,
      int seed = 1,
      MeshVerify? verify,
    }) {
      return MeshSession(
        selfFingerprint: fp,
        selfPublicKeyArmored: 'KEY:$fp',
        selfDisplayName: 'user-$fp',
        sign: (data) async => 'SIG|$data|$fp',
        verify:
            verify ??
            (data, signature, publicKey) async =>
                signature == 'SIG|$data|${publicKey.substring(4)}',
        fingerprintOf: (publicKey) async {
          if (!publicKey.startsWith('KEY:')) throw const FormatException();
          return publicKey.substring(4);
        },
        sendFrame: sendFrame,
        random: Random(seed),
      );
    }

    /// Wires two sessions so each one's sendFrame feeds the other's
    /// handleFrame (async, like a real transport).
    (MeshSession, MeshSession) wiredPair({MeshVerify? bVerify}) {
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
        verify: bVerify,
        sendFrame: (type, payload) async {
          await a.handleFrame(MeshFrame(type: type, payload: payload));
        },
      );
      return (a, b);
    }

    test('mutual authentication when both proofs verify', () async {
      final (a, b) = wiredPair();
      await a.start();
      expect(a.authenticated, isTrue, reason: a.failure ?? '');
      expect(b.authenticated, isTrue, reason: b.failure ?? '');
      expect(a.peer!.fingerprint, 'BBBB');
      expect(b.peer!.fingerprint, 'AAAA');
    });

    test('messages flow only after authentication', () async {
      final (a, b) = wiredPair();
      expect(() => a.sendMessageEnvelope({'x': 1}), throwsStateError);
      await a.start();
      final received = <Map<String, dynamic>>[];
      b.messages.listen(received.add);
      await a.sendMessageEnvelope({'conversation_id': 'c1', 'n': 42});
      await Future<void>.delayed(Duration.zero);
      expect(received, [
        {'conversation_id': 'c1', 'n': 42},
      ]);
    });

    test('a forged proof fails the session', () async {
      final (a, b) = wiredPair(
        // B's verifier rejects everything — as if A's signature were forged.
        bVerify: (data, signature, publicKey) async => false,
      );
      await a.start();
      expect(b.state, MeshSessionState.failed);
      expect(b.failure, contains('identity proof'));
      expect(b.authenticated, isFalse);
    });

    test('claiming a fingerprint that does not match the key fails', () async {
      late MeshSession victim;
      final liarFrames = StreamController<MeshFrame>();
      victim = buildSession(fp: 'AAAA', sendFrame: (type, payload) async {});
      liarFrames.stream.listen((f) => victim.handleFrame(f));
      // Liar presents key BBBB but claims fingerprint CCCC (a real contact's).
      await victim.handleFrame(
        MeshFrame(
          type: meshFrameHello,
          payload: Uint8List.fromList(
            '{"session_id":"liar","fingerprint":"CCCC","public_key":"KEY:BBBB","challenge":"deadbeef","name":"liar"}'
                .codeUnits,
          ),
        ),
      );
      expect(victim.state, MeshSessionState.failed);
      expect(victim.failure, contains('fingerprint'));
    });

    test('acks round-trip after authentication', () async {
      final (a, b) = wiredPair();
      await a.start();
      final received = <MeshAck>[];
      a.acks.listen(received.add);

      // sendAck is illegal pre-auth on a fresh session…
      final lonely = buildSession(fp: 'CCCC', sendFrame: (t, p) async {});
      expect(() => lonely.sendAck('n-1', accepted: true), throwsStateError);

      // …and round-trips on an authenticated one.
      await b.sendAck('nonce-1', accepted: true);
      await b.sendAck('nonce-2', accepted: false);
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(2));
      expect(received[0].nonce, 'nonce-1');
      expect(received[0].accepted, isTrue);
      expect(received[1].nonce, 'nonce-2');
      expect(received[1].accepted, isFalse);
    });

    test('an ack before authentication fails the session', () async {
      final victim = buildSession(fp: 'AAAA', sendFrame: (t, p) async {});
      await victim.handleFrame(
        MeshFrame(
          type: meshFrameAck,
          payload: Uint8List.fromList(
            '{"nonce":"x","accepted":true}'.codeUnits,
          ),
        ),
      );
      expect(victim.state, MeshSessionState.failed);
      expect(victim.failure, contains('ack before authentication'));
    });

    test(
      'a replayed proof from another session fails (challenge binding)',
      () async {
        // First, a legitimate exchange to capture A's proof signature.
        String? capturedProof;
        late MeshSession a1, b1;
        a1 = buildSession(
          fp: 'AAAA',
          seed: 1,
          sendFrame: (type, payload) async {
            if (type == meshFrameProof) {
              capturedProof = String.fromCharCodes(payload);
            }
            await b1.handleFrame(MeshFrame(type: type, payload: payload));
          },
        );
        b1 = buildSession(
          fp: 'BBBB',
          seed: 2,
          sendFrame: (type, payload) async {
            await a1.handleFrame(MeshFrame(type: type, payload: payload));
          },
        );
        await a1.start();
        expect(b1.authenticated, isTrue);
        expect(capturedProof, isNotNull);

        // New victim session (fresh ids + challenge): replay A's old hello +
        // proof. The proof was bound to the old session pair, so it must fail.
        final victim = buildSession(
          fp: 'BBBB',
          seed: 9,
          sendFrame: (type, payload) async {},
        );
        await victim.handleFrame(
          MeshFrame(
            type: meshFrameHello,
            payload: Uint8List.fromList(
              '{"session_id":"${a1.sessionId}","fingerprint":"AAAA","public_key":"KEY:AAAA","challenge":"ff","name":"a"}'
                  .codeUnits,
            ),
          ),
        );
        await victim.handleFrame(
          MeshFrame(
            type: meshFrameProof,
            payload: Uint8List.fromList(capturedProof!.codeUnits),
          ),
        );
        expect(victim.authenticated, isFalse);
        expect(victim.state, MeshSessionState.failed);
      },
    );
  });

  group('outbox drain selection', () {
    OfflineOutboxItem item({
      required String id,
      required String conv,
      OfflineOutboxAction action = OfflineOutboxAction.sendMessage,
      OfflineOutboxStatus status = OfflineOutboxStatus.queued,
      bool encrypted = true,
      String payload = 'cipher',
      int minute = 0,
    }) => OfflineOutboxItem(
      id: id,
      action: action,
      conversationId: conv,
      createdAt: DateTime.utc(2026, 6, 11, 10, minute),
      status: status,
      data: {
        'pending_message_id': 'nonce-$id',
        'encrypted_payload': payload,
        'signature': 'sig-$id',
        'message_type': 'text',
        'is_encrypted': encrypted,
        'created_at': DateTime.utc(2026, 6, 11, 10, minute).toIso8601String(),
      },
    );

    test(
      'selects only queued encrypted sends for the peer DM, oldest first',
      () {
        final items = [
          item(id: 'b', conv: 'dm-1', minute: 5),
          item(id: 'a', conv: 'dm-1', minute: 1),
          item(id: 'other-conv', conv: 'dm-2'),
          item(id: 'failed', conv: 'dm-1', status: OfflineOutboxStatus.failed),
          item(id: 'plaintext', conv: 'dm-1', encrypted: false),
          item(
            id: 'reaction',
            conv: 'dm-1',
            action: OfflineOutboxAction.reaction,
          ),
          item(id: 'empty', conv: 'dm-1', payload: ''),
        ];
        final selected = meshDeliverableItems(items, 'dm-1');
        expect(selected.map((i) => i.id), ['a', 'b']);
      },
    );

    test('envelope carries exactly the receiver-side ingest fields', () {
      final envelope = meshEnvelopeForItem(item(id: 'x', conv: 'dm-1'));
      expect(envelope, {
        'conversation_id': 'dm-1',
        'encrypted_payload': 'cipher',
        'signature': 'sig-x',
        'message_type': 'text',
        'client_nonce': 'nonce-x',
        'created_at': '2026-06-11T10:00:00.000Z',
      });
    });
  });
}
