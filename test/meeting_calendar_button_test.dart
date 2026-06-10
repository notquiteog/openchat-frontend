import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/widgets/message_bubble.dart';

// "Add to calendar" exports the best-voted slot of a meeting poll. It must
// only appear once at least one vote exists (no votes → no agreed slot), and
// it must be visible on the creator's own bubble too — the regression was a
// primary-colored TextButton on the sender's primary-colored bubble.
Message _meetingMessage({required int votes}) {
  final msg = Message(
    id: 'msg-meeting',
    conversationId: 'conv-1',
    senderId: 'user-a',
    type: MessageType.poll,
    encryptedPayload: 'cipher',
    signature: '',
    createdAt: DateTime.utc(2026, 6, 1),
  );
  msg.poll = Poll(
    id: 'poll-1',
    question: '📅 Sprint planning',
    type: 'meeting',
    isAnonymous: false,
    allowsMultipleAnswers: true,
    allowsRevoting: true,
    isClosed: false,
    totalVoterCount: votes,
    options: [
      PollOption(
        id: 'opt-1',
        index: 0,
        text: '2026-06-12T10:00:00Z',
        voterCount: votes,
        persistentId: 'opt-1',
      ),
      PollOption(
        id: 'opt-2',
        index: 1,
        text: '2026-06-13T15:00:00Z',
        voterCount: 0,
        persistentId: 'opt-2',
      ),
    ],
  );
  return msg;
}

Future<void> _pumpBubble(
  WidgetTester tester,
  Message message, {
  required bool isMe,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: MessageBubble(message: message, isMe: isMe)),
    ),
  );
}

void main() {
  testWidgets('hidden while the meeting has no votes', (tester) async {
    await _pumpBubble(tester, _meetingMessage(votes: 0), isMe: false);
    expect(find.text('Add to calendar'), findsNothing);
  });

  testWidgets('shown to recipients once a slot has a vote', (tester) async {
    await _pumpBubble(tester, _meetingMessage(votes: 1), isMe: false);
    expect(find.text('Add to calendar'), findsOneWidget);
  });

  testWidgets('shown and legible on the creator\'s own bubble', (
    tester,
  ) async {
    await _pumpBubble(tester, _meetingMessage(votes: 2), isMe: true);
    final label = find.text('Add to calendar');
    expect(label, findsOneWidget);

    // The button must follow the bubble's text color, not the theme primary
    // (which matches the own-bubble background and rendered invisible).
    final button = tester.widget<TextButton>(
      find.ancestor(of: label, matching: find.byType(TextButton)),
    );
    final foreground = button.style?.foregroundColor?.resolve(const {});
    final bubbleTextColor = tester
        .widget<Text>(find.text('📅 Sprint planning'))
        .style
        ?.color;
    expect(foreground, isNotNull);
    expect(foreground, bubbleTextColor);
  });
}
