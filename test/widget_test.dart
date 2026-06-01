import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/crypto/pgp_service.dart';
import 'package:openchat/models/message.dart';

void main() {
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

    test('tries envelope ciphertexts until one decrypts after restart',
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
    });
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
  });
}
