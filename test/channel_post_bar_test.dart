import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
