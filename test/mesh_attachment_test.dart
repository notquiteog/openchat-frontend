import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/mesh/mesh_frames.dart';
import 'package:openchat/services/mesh/mesh_outbox_drain.dart';
import 'package:openchat/services/mesh/mesh_session.dart';
import 'package:openchat/services/offline_outbox_service.dart';

/// #26 — mesh attachment transfer over LAN. Covers the attachment frame
/// ceiling, the outbox selection/framing of pre-sealed attachments, and the
/// session-level delivery of an attachment envelope between two wired sessions.
void main() {
  group('attachment frame ceiling (#26)', () {
    test(
      'a >control-ceiling payload round-trips under the attachment ceiling',
      () {
        final big = Uint8List.fromList(
          List.generate(meshMaxFrameBytes + 50000, (i) => i % 256),
        );
        // Default (control) ceiling rejects it...
        expect(
          () => encodeMeshFrame(meshFrameAttachment, big),
          throwsA(isA<MeshFrameException>()),
        );
        // ...but the attachment ceiling accepts and round-trips it.
        final encoded = encodeMeshFrame(
          meshFrameAttachment,
          big,
          maxBytes: meshMaxAttachmentFrameBytes,
        );
        final frame = decodeMeshFrame(
          encoded,
          maxBytes: meshMaxAttachmentFrameBytes,
        );
        expect(frame.type, meshFrameAttachment);
        expect(frame.payload, big);
      },
    );

    test('decode still rejects a payload past the attachment ceiling', () {
      // Forge a header claiming a length above the ceiling.
      final encoded = encodeMeshFrame(
        meshFrameAttachment,
        Uint8List.fromList([1, 2, 3]),
        maxBytes: meshMaxAttachmentFrameBytes,
      );
      final view = ByteData.sublistView(encoded);
      view.setUint32(4, meshMaxAttachmentFrameBytes + 1, Endian.little);
      expect(
        () => decodeMeshFrame(encoded, maxBytes: meshMaxAttachmentFrameBytes),
        throwsA(isA<MeshFrameException>()),
      );
    });

    test('reassembler honours the attachment ceiling', () {
      final frame = encodeMeshFrame(
        meshFrameAttachment,
        Uint8List.fromList(List.generate(meshMaxFrameBytes + 20000, (i) => i)),
        maxBytes: meshMaxAttachmentFrameBytes,
      );
      // A control-ceiling reassembler overflows on this oversize frame...
      final small = MeshReassembler();
      final chunks = splitMeshFrame(frame, 16384);
      var threw = false;
      try {
        for (final c in chunks) {
          small.addChunk(c);
        }
      } on MeshFrameException {
        threw = true;
      }
      expect(threw, isTrue);
      // ...the attachment-ceiling reassembler completes it.
      final big = MeshReassembler(maxBytes: meshMaxAttachmentFrameBytes);
      Uint8List? result;
      for (final c in chunks) {
        result = big.addChunk(c);
      }
      expect(result, frame);
    });
  });

  group('outbox attachment selection + framing (#26)', () {
    OfflineOutboxItem item({
      required String id,
      String conv = 'dm-1',
      OfflineOutboxStatus status = OfflineOutboxStatus.queued,
      bool sealed = true,
      String envelope = 'sealed-cipher',
      String clientAttId = 'att-uuid',
      String ciphertextPath = '/tmp/ct.bin',
      int minute = 0,
    }) => OfflineOutboxItem(
      id: id,
      action: OfflineOutboxAction.attachmentUpload,
      conversationId: conv,
      createdAt: DateTime.utc(2026, 6, 11, 10, minute),
      status: status,
      data: {
        'pending_message_id': 'nonce-$id',
        'message_type': 'image',
        'ciphertext_path': ciphertextPath,
        if (sealed) 'sealed_attachment': true,
        if (sealed) 'sealed_encrypted_payload': envelope,
        if (sealed) 'sealed_signature': 'sig-$id',
        if (sealed) 'client_attachment_id': clientAttId,
        'created_at': DateTime.utc(2026, 6, 11, 10, minute).toIso8601String(),
      },
    );

    test(
      'selects only pre-sealed attachment items for the DM, oldest first',
      () {
        final items = [
          item(id: 'b', minute: 5),
          item(id: 'a', minute: 1),
          item(id: 'other', conv: 'dm-2'),
          item(id: 'failed', status: OfflineOutboxStatus.failed),
          item(id: 'unsealed', sealed: false), // legacy seal-at-drain
          item(id: 'no-path', ciphertextPath: ''),
          item(id: 'no-id', clientAttId: ''),
        ];
        final selected = meshDeliverableAttachments(items, 'dm-1');
        expect(selected.map((i) => i.id), ['a', 'b']);
      },
    );

    test('frame carries the sealed envelope, stable id, and ciphertext', () {
      final ciphertext = Uint8List.fromList([9, 8, 7, 6]);
      final frame = meshAttachmentFrameForItem(item(id: 'x'), ciphertext);
      expect(frame['conversation_id'], 'dm-1');
      expect(frame['encrypted_payload'], 'sealed-cipher');
      expect(frame['signature'], 'sig-x');
      expect(frame['message_type'], 'image');
      expect(frame['client_nonce'], 'nonce-x');
      expect(frame['attachment_id'], 'att-uuid');
      expect(frame['ciphertext_b64'], 'CQgHBg=='); // base64([9,8,7,6])
    });
  });

  group('session attachment delivery (#26)', () {
    MeshSession buildSession({
      required String fp,
      required MeshFrameSender sendFrame,
      int seed = 1,
    }) {
      return MeshSession(
        selfFingerprint: fp,
        selfPublicKeyArmored: 'KEY:$fp',
        selfDisplayName: 'user-$fp',
        sign: (data) async => 'SIG|$data|$fp',
        verify: (data, signature, publicKey) async =>
            signature == 'SIG|$data|${publicKey.substring(4)}',
        fingerprintOf: (publicKey) async {
          if (!publicKey.startsWith('KEY:')) throw const FormatException();
          return publicKey.substring(4);
        },
        sendFrame: sendFrame,
        random: Random(seed),
      );
    }

    (MeshSession, MeshSession) wiredPair() {
      late MeshSession a, b;
      a = buildSession(
        fp: 'AAAA',
        seed: 1,
        sendFrame: (type, payload) async =>
            b.handleFrame(MeshFrame(type: type, payload: payload)),
      );
      b = buildSession(
        fp: 'BBBB',
        seed: 2,
        sendFrame: (type, payload) async =>
            a.handleFrame(MeshFrame(type: type, payload: payload)),
      );
      return (a, b);
    }

    test('attachment envelopes flow only after authentication', () async {
      final (a, b) = wiredPair();
      expect(() => a.sendAttachmentEnvelope({'x': 1}), throwsStateError);
      await a.start();
      expect(a.authenticated, isTrue, reason: a.failure ?? '');

      final received = <Map<String, dynamic>>[];
      b.attachments.listen(received.add);
      await a.sendAttachmentEnvelope({
        'conversation_id': 'c1',
        'attachment_id': 'att-1',
        'ciphertext_b64': 'AAEC',
      });
      await Future<void>.delayed(Duration.zero);
      expect(received, [
        {
          'conversation_id': 'c1',
          'attachment_id': 'att-1',
          'ciphertext_b64': 'AAEC',
        },
      ]);
    });

    test('attachment frame and message frame use separate streams', () async {
      final (a, b) = wiredPair();
      await a.start();
      final msgs = <Map<String, dynamic>>[];
      final atts = <Map<String, dynamic>>[];
      b.messages.listen(msgs.add);
      b.attachments.listen(atts.add);
      await a.sendMessageEnvelope({'conversation_id': 'c1', 'kind': 'msg'});
      await a.sendAttachmentEnvelope({'conversation_id': 'c1', 'kind': 'att'});
      await Future<void>.delayed(Duration.zero);
      expect(msgs, [
        {'conversation_id': 'c1', 'kind': 'msg'},
      ]);
      expect(atts, [
        {'conversation_id': 'c1', 'kind': 'att'},
      ]);
    });
  });
}
