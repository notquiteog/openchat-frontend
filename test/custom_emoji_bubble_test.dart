import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/widgets/message_bubble.dart';

// Regression: a message containing an inline custom emoji renders an emoji
// WidgetSpan inside the bubble. _CollapsibleText measures overflow with a bare
// TextPainter; before the fix it called layout() without supplying placeholder
// dimensions, which throws on the first WidgetSpan and replaces the whole
// bubble body with a gray ErrorWidget ("giant white/grey square").
Message _emojiMessage(
  String text, {
  required String emoji,
  required int offset,
}) {
  final msg = Message(
    id: 'msg-emoji',
    conversationId: 'conv-1',
    senderId: 'user-a',
    type: MessageType.text,
    encryptedPayload: 'cipher',
    signature: '',
    createdAt: DateTime.utc(2026, 1, 1),
  );
  // No file_url → _InlineCustomEmoji renders the unicode fallback (no network),
  // but the WidgetSpan is still produced, which is what triggered the crash.
  final payload = jsonEncode({
    'text': text,
    'entities': [
      {
        'type': 'custom_emoji',
        'offset': offset,
        'length': emoji.length,
        'custom_emoji_id': 'emoji-1',
        'emoji': emoji,
      },
    ],
  });
  msg.setDecryptedContent(payload);
  return msg;
}

Future<void> _pump(WidgetTester tester, Message message) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: MessageBubble(message: message, isMe: true)),
    ),
  );
}

void main() {
  testWidgets('inline custom emoji renders without an ErrorWidget', (
    tester,
  ) async {
    final msg = _emojiMessage('hi 🙂', emoji: '🙂', offset: 3);
    expect(msg.content!.entities, isNotEmpty);

    await _pump(tester, msg);

    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byType(MessageBubble), findsOneWidget);
  });

  testWidgets('long message with a custom emoji still renders + collapses', (
    tester,
  ) async {
    final body = List.filled(40, 'wrap line of text').join(' ');
    final msg = _emojiMessage('🙂 $body', emoji: '🙂', offset: 0);

    await _pump(tester, msg);

    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    // Overflow detection (now placeholder-aware) drives the Read more affordance.
    expect(find.text('Read more'), findsOneWidget);
  });
}
