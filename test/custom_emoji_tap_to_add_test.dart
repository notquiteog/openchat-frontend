import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/widgets/message_bubble.dart';
import 'package:provider/provider.dart';

// Tap-to-add for custom emoji seen in chat: tapping an inline custom emoji
// span opens a bottom sheet for its pack with an "Add to library" button.
// Must work even when the pack is NOT discoverable — the fetch endpoints
// don't gate on is_discoverable (by design).
Message _emojiMessage(String text, {required String emoji, required int offset}) {
  final msg = Message(
    id: 'msg-emoji',
    conversationId: 'conv-1',
    senderId: 'user-a',
    type: MessageType.text,
    encryptedPayload: 'cipher',
    signature: '',
    createdAt: DateTime.utc(2026, 1, 1),
  );
  // No file_url → _InlineCustomEmoji renders the unicode fallback (no network
  // image fetch in the test), but the tappable WidgetSpan is still produced.
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

class _FakeApi extends ApiService {
  _FakeApi(super.storage);

  int addCalls = 0;
  String? lastAddedPackId;

  @override
  Future<Map<String, dynamic>> getCustomEmoji(String emojiID) async {
    return {
      'id': emojiID,
      'pack_id': 'pack-1',
      'name': 'party',
      'emoji': '🙂',
      // No file_url: keeps the bubble on the unicode fallback (no network).
    };
  }

  @override
  Future<Map<String, dynamic>> getCustomEmojiPack(String packID) async {
    return {
      'id': packID,
      'name': 'Party Pack',
      'description': 'private but fetchable',
      // Deliberately NOT discoverable: the sheet must still load and offer
      // the add button.
      'is_discoverable': false,
      'custom_emojis': [
        {'id': 'emoji-1', 'name': 'party', 'emoji': '🙂'},
        {'id': 'emoji-2', 'name': 'confetti', 'emoji': '🎉'},
      ],
    };
  }

  @override
  Future<void> addCustomEmojiPackToLibrary(String packID) async {
    addCalls++;
    lastAddedPackId = packID;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeApi api;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    api = _FakeApi(SecureStorageService());
  });

  Future<void> pumpBubble(WidgetTester tester, Message message) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<ApiService>.value(
          value: api,
          child: Scaffold(body: MessageBubble(message: message, isMe: false)),
        ),
      ),
    );
    // Let the inline emoji's initial getCustomEmoji load settle.
    await tester.pumpAndSettle();
  }

  testWidgets('tapping an inline custom emoji opens its pack sheet with '
      'Add to library, even for a non-discoverable pack', (tester) async {
    final msg = _emojiMessage('hi 🙂', emoji: '🙂', offset: 3);
    await pumpBubble(tester, msg);

    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);

    await tester.tap(find.text('🙂'));
    await tester.pumpAndSettle();

    // Pack sheet appeared with the pack contents and the add affordance.
    expect(find.text('Party Pack'), findsOneWidget);
    expect(find.text('Add to library'), findsOneWidget);
    expect(find.text('🎉'), findsOneWidget);
  });

  testWidgets('Add to library adds the resolved pack and dismisses the sheet',
      (tester) async {
    final msg = _emojiMessage('hi 🙂', emoji: '🙂', offset: 3);
    await pumpBubble(tester, msg);

    await tester.tap(find.text('🙂'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add to library'));
    await tester.pumpAndSettle();

    expect(api.addCalls, 1);
    expect(api.lastAddedPackId, 'pack-1');
    expect(find.text('Party Pack'), findsNothing);
    expect(find.text('Emoji pack added to your library'), findsOneWidget);
  });
}
