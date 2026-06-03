import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/utils/custom_emoji_payload.dart';

void main() {
  test('builds text payload with custom emoji entities', () {
    const entity = CustomEmojiEntity(
      offset: 6,
      length: 2,
      customEmojiId: 'emoji-1',
      emoji: '🙂',
      fileUrl: '/media/custom-emojis/pack/emoji.webp',
    );

    final payload = buildCustomEmojiTextPayload('hello 🙂', [entity]);
    final decoded = jsonDecode(payload.payload) as Map<String, dynamic>;

    expect(payload.text, 'hello 🙂');
    expect(decoded['text'], 'hello 🙂');
    expect(decoded['entities'], isA<List>());
    expect((decoded['entities'] as List).single['custom_emoji_id'], 'emoji-1');
  });

  test('shifts entity offsets when text is inserted before them', () {
    const entity = CustomEmojiEntity(
      offset: 0,
      length: 2,
      customEmojiId: 'emoji-1',
      emoji: '🙂',
    );

    final shifted = shiftCustomEmojiEntitiesForTextEdit(
      oldText: '🙂',
      newText: 'hey 🙂',
      entities: [entity],
    );

    expect(shifted.single.offset, 4);
  });

  test('drops entity when its emoji text is deleted', () {
    const entity = CustomEmojiEntity(
      offset: 3,
      length: 2,
      customEmojiId: 'emoji-1',
      emoji: '🙂',
    );

    final shifted = shiftCustomEmojiEntitiesForTextEdit(
      oldText: 'hi 🙂',
      newText: 'hi ',
      entities: [entity],
    );

    expect(shifted, isEmpty);
  });

  test(
    'message text parser reads custom emoji entities only for entity payloads',
    () {
      final payload = buildCustomEmojiTextPayload('ok 🙂', [
        const CustomEmojiEntity(
          offset: 3,
          length: 2,
          customEmojiId: 'emoji-1',
          emoji: '🙂',
        ),
      ]);

      final parsed = MessageContent.parse(payload.payload, MessageType.text);
      expect(parsed.text, 'ok 🙂');
      expect(parsed.entities.single.customEmojiId, 'emoji-1');

      final literalJson = MessageContent.parse(
        '{"text":"literal"}',
        MessageType.text,
      );
      expect(literalJson.text, '{"text":"literal"}');
      expect(literalJson.entities, isEmpty);
    },
  );
}
