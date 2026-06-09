import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';

// Regression test for the empty dice/game bubble: a server-rolled dice is a
// plaintext message (is_encrypted=false) whose payload is {"dice":{...}}. After
// the plaintext decrypt path runs setDecryptedContent, MessageContent has no
// "text" field so decryptedContent becomes "" — the bug was that message.dice
// did `decryptedContent ?? decryptedPayload ?? encryptedPayload`, which stopped
// at the empty string and never reached the real payload, rendering blank.
void main() {
  Message diceMessage() => Message.fromJson({
    'id': '9590c14c-a243-4bd3-81e3-62a69049e2ee',
    'conversation_id': 'b51cb6c6-0000-0000-0000-000000000000',
    'message_type': 'dice',
    'encrypted_payload': '{"dice":{"emoji":"⚽","max":5,"value":1}}',
    'is_encrypted': false,
    'created_at': '2026-06-08T22:09:35.921233Z',
  });

  group('dice message', () {
    test('type parses to dice', () {
      expect(diceMessage().type, MessageType.dice);
    });

    test('parses from the raw payload before decryption', () {
      final dice = diceMessage().dice;
      expect(dice, isNotNull);
      expect(dice!.emoji, '⚽');
      expect(dice.value, 1);
      expect(dice.max, 5);
    });

    test('still parses after the plaintext decrypt path (the regression)', () {
      final msg = diceMessage();
      // Mirrors ChatProvider._tryDecrypt's `!isEncrypted` branch.
      msg.setDecryptedContent(msg.encryptedPayload);
      // Root cause: the decrypted *content* text is empty for a dice.
      expect(msg.decryptedContent, isEmpty);
      // Fix: the dice still resolves from decryptedPayload / encryptedPayload.
      expect(msg.dice, isNotNull);
      expect(msg.dice!.label, '1 / 5');
    });
  });

  group('game message', () {
    Message gameMessage() => Message.fromJson({
      'id': 'aaaaaaaa-0000-0000-0000-000000000000',
      'conversation_id': 'bbbbbbbb-0000-0000-0000-000000000000',
      'message_type': 'game',
      'encrypted_payload':
          '{"game":{"round_id":"cccccccc-0000-0000-0000-000000000000"}}',
      'is_encrypted': false,
      'created_at': '2026-06-08T22:09:35.921233Z',
    });

    test('type parses to game', () {
      expect(gameMessage().type, MessageType.game);
    });

    test('exposes the round id (before and after decrypt)', () {
      final msg = gameMessage();
      expect(msg.gameRoundId, 'cccccccc-0000-0000-0000-000000000000');
      msg.setDecryptedContent(msg.encryptedPayload);
      expect(msg.gameRoundId, 'cccccccc-0000-0000-0000-000000000000');
    });
  });
}
