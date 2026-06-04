import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openpgp/openpgp.dart';
import 'package:openchat/crypto/pgp_service.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/models/user.dart';

void main() {
  group('KeyType options', () {
    test('defaults to the strongest quantum key type', () {
      expect(KeyType.defaultType, KeyType.mlkem1024X448);
      expect(KeyType.defaultType.algorithm, Algorithm.MLKEM1024X448);
      expect(KeyType.defaultType.isQuantum, isTrue);
    });

    test('exposes every supported quantum OpenPGP algorithm', () {
      expect(KeyType.quantumTypes.map((type) => type.algorithm), [
        Algorithm.MLDSA65ED25519,
        Algorithm.MLDSA87ED448,
        Algorithm.MLKEM768X25519,
        Algorithm.MLKEM1024X448,
      ]);
    });
  });

  group('PgpService OpenChat envelope', () {
    test('uses envelope policy for DMs and groups', () {
      expect(PgpService.usesOpenChatEnvelopeForRecipientCount(0), isFalse);
      expect(PgpService.usesOpenChatEnvelopeForRecipientCount(1), isTrue);
      expect(PgpService.usesOpenChatEnvelopeForRecipientCount(2), isTrue);
      expect(PgpService.usesOpenChatEnvelopeForRecipientCount(3), isTrue);
    });

    test('detects and extracts per-recipient ciphertexts', () {
      const first =
          '-----BEGIN PGP MESSAGE-----\nfirst\n-----END PGP MESSAGE-----';
      const second =
          '-----BEGIN PGP MESSAGE-----\nsecond\n-----END PGP MESSAGE-----';
      final payload = jsonEncode({
        'openchat_encrypted_envelope': 1,
        'ciphertexts': [first, second],
      });

      expect(PgpService.isOpenChatEnvelope(payload), isTrue);
      expect(PgpService.tryReadEnvelopeCiphertexts(payload), [first, second]);
    });

    test('leaves legacy armored PGP payloads untouched', () {
      const legacy =
          '-----BEGIN PGP MESSAGE-----\nlegacy\n-----END PGP MESSAGE-----';

      expect(PgpService.isOpenChatEnvelope(legacy), isFalse);
      expect(PgpService.tryReadEnvelopeCiphertexts(legacy), isNull);
    });

    test(
      'tries envelope ciphertexts until one decrypts after restart',
      () async {
        final attempts = <String>[];

        final plaintext = await PgpService.decryptEnvelopeCiphertextsForTesting(
          ['recipient-a-copy', 'sender-restart-copy'],
          (ciphertext) async {
            attempts.add(ciphertext);
            if (ciphertext == 'sender-restart-copy') return 'Hi after reopen';
            throw StateError('not encrypted to this private key');
          },
        );

        expect(plaintext, 'Hi after reopen');
        expect(attempts, ['recipient-a-copy', 'sender-restart-copy']);
      },
    );
  });

  group('Message previews', () {
    test('prefer decrypted content for conversation list previews', () {
      final message = Message(
        id: 'msg-1',
        conversationId: 'conv-1',
        senderId: 'user-1',
        type: MessageType.text,
        encryptedPayload: 'ciphertext',
        signature: 'signature',
        createdAt: DateTime.utc(2026, 5, 31),
      );

      expect(message.listPreview, '🔒 Encrypted');

      message.setDecryptedContent('Hi');

      expect(message.listPreview, 'Hi');
    });

    test('parses sender bubble color on message payloads', () {
      final message = Message.fromJson({
        'id': 'msg-1',
        'conversation_id': 'conv-1',
        'sender_id': 'user-2',
        'message_type': 'text',
        'encrypted_payload': 'ciphertext',
        'signature': 'signature',
        'created_at': DateTime.utc(2026, 5, 31).toIso8601String(),
        'sender': {
          'id': 'user-2',
          'username': 'alice',
          'public_key': 'pub',
          'key_fingerprint': 'fingerprint',
          'bubble_color': '#26323A',
          'created_at': DateTime.utc(2026, 1, 1).toIso8601String(),
        },
      });

      expect(message.sender?.bubbleColor, 0xFF26323A);
    });
  });

  group('Message locations', () {
    test('parses canonical live location payloads', () {
      final location = MessageLocation.tryParse(
        jsonEncode({
          'kind': 'live',
          'latitude': 41.8781,
          'longitude': -87.6298,
          'accuracy': 12.5,
          'share_id': 'share-1',
          'ends_at': DateTime.utc(2026, 6, 3, 18).toIso8601String(),
          'ended': false,
        }),
      );

      expect(location, isNotNull);
      expect(location!.kind, LocationMessageKind.live);
      expect(location.latitude, 41.8781);
      expect(location.longitude, -87.6298);
      expect(location.shareId, 'share-1');
    });

    test('rejects legacy location payload aliases', () {
      expect(
        MessageLocation.tryParse(
          jsonEncode({
            'type': 'live',
            'lat': 41.8781,
            'lng': -87.6298,
            'shareId': 'share-1',
            'endsAt': DateTime.utc(2026, 6, 3, 18).toIso8601String(),
          }),
        ),
        isNull,
      );
    });
  });

  group('User profile fields', () {
    test('parses public bubble color', () {
      final user = User.fromJson({
        'id': 'user-1',
        'username': 'alice',
        'public_key': 'pub',
        'key_fingerprint': 'fingerprint',
        'bubble_color': 0xFF26323A,
        'created_at': DateTime.utc(2026, 1, 1).toIso8601String(),
      });

      expect(user.bubbleColor, 0xFF26323A);
      expect(user.toJson()['bubble_color'], '#26323A');
    });

    test('parses public bubble color from canonical hex', () {
      final user = User.fromJson({
        'id': 'user-1',
        'username': 'alice',
        'public_key': 'pub',
        'key_fingerprint': 'fingerprint',
        'bubble_color': '#26323A',
        'created_at': DateTime.utc(2026, 1, 1).toIso8601String(),
      });

      expect(user.bubbleColor, 0xFF26323A);
      expect(user.toJson()['bubble_color'], '#26323A');
    });
  });
}
