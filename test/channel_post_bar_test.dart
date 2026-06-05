import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/screens/channels/channel_screen.dart';

void main() {
  testWidgets(
    'channel post bar exposes custom emoji, sticker, and attachment buttons',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChannelPostBar(
              controller: TextEditingController(),
              showStickers: false,
              showCustomEmojis: false,
              onToggleCustomEmojis: () {},
              onToggleStickers: () {},
              onAttach: () {},
              onMentionSelected: (_) {},
              onPost: () {},
            ),
          ),
        ),
      );

      expect(find.byTooltip('Custom emoji'), findsOneWidget);
      expect(find.byTooltip('Stickers'), findsOneWidget);
      expect(find.byTooltip('Attach file'), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
    },
  );

  testWidgets('channel post bar renders mention suggestions', (tester) async {
    final user = User(
      id: 'u-1',
      username: 'alice',
      publicKey: '',
      keyFingerprint: '',
      createdAt: DateTime(2024),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChannelPostBar(
            controller: TextEditingController(text: '@a'),
            showStickers: false,
            showCustomEmojis: false,
            mentionSuggestions: [
              ConversationMember(
                conversationId: 'c-1',
                userId: user.id,
                role: MemberRole.member,
                joinedAt: DateTime(2024),
                user: user,
              ),
            ],
            onToggleCustomEmojis: () {},
            onToggleStickers: () {},
            onAttach: () {},
            onMentionSelected: (_) {},
            onPost: () {},
          ),
        ),
      ),
    );

    expect(find.text('@alice'), findsOneWidget);
  });
}
