import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/widgets/die_3d.dart';
import 'package:openchat/widgets/message_bubble.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

/// Which die value currently faces the viewer under [die]'s rotation —
/// the face whose rotated outward normal points most toward the camera.
int frontFaceValue(Die3D die) {
  final normals = <int, vm.Vector3>{
    1: vm.Vector3(0, 0, -1),
    2: vm.Vector3(1, 0, 0),
    3: vm.Vector3(0, -1, 0),
    4: vm.Vector3(0, 1, 0),
    5: vm.Vector3(-1, 0, 0),
    6: vm.Vector3(0, 0, 1),
  };
  var best = 0;
  var bestZ = double.infinity;
  normals.forEach((value, normal) {
    final z = die.rotation.transform3(normal.clone()).z;
    if (z < bestZ) {
      bestZ = z;
      best = value;
    }
  });
  return best;
}

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

  group('bare dice emoji send (Telegram behavior)', () {
    test('exactly one plain 🎲 triggers a server roll', () {
      expect(isPlainDiceMessage('🎲'), isTrue);
      expect(isPlainDiceMessage('  🎲  '), isTrue);
      expect(isPlainDiceMessage('\n🎲\n'), isTrue);
    });

    test('anything else stays an ordinary text message', () {
      expect(isPlainDiceMessage(''), isFalse);
      expect(isPlainDiceMessage('🎲🎲'), isFalse);
      expect(isPlainDiceMessage('roll 🎲'), isFalse);
      expect(isPlainDiceMessage('🎲!'), isFalse);
      expect(isPlainDiceMessage('🎯'), isFalse);
      expect(isPlainDiceMessage('dice'), isFalse);
    });
  });

  group('dice roll animation', () {
    Message rolledDie({required DateTime createdAt, String id = 'die-1'}) =>
        Message.fromJson({
          'id': id,
          'conversation_id': 'b51cb6c6-0000-0000-0000-000000000000',
          'message_type': 'dice',
          'encrypted_payload': '{"dice":{"emoji":"🎲","max":6,"value":4}}',
          'is_encrypted': false,
          'created_at': createdAt.toUtc().toIso8601String(),
        });

    testWidgets('a fresh roll tumbles, then LANDS on the server value', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              message: rolledDie(createdAt: DateTime.now(), id: 'die-fresh'),
              isMe: true,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text('Rolling…'),
        findsOneWidget,
        reason: 'the roll must visibly animate',
      );
      expect(find.text('4 / 6'), findsNothing);

      await tester.pump(const Duration(milliseconds: 1700));

      expect(find.text('Rolling…'), findsNothing);
      expect(find.text('4 / 6'), findsOneWidget);
      final die = tester.widget<Die3D>(find.byType(Die3D));
      expect(
        frontFaceValue(die),
        4,
        reason: 'the 3D die must land on the server-decided result',
      );
    });

    testWidgets('scrollback rolls render settled, no replay', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              message: rolledDie(
                createdAt: DateTime.now().subtract(const Duration(hours: 2)),
                id: 'die-old',
              ),
              isMe: false,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Rolling…'), findsNothing);
      expect(find.text('4 / 6'), findsOneWidget);
      expect(
        frontFaceValue(tester.widget<Die3D>(find.byType(Die3D))),
        4,
        reason: 'scrollback renders the settled 3D die, no replay',
      );
    });
  });
}
