import 'dart:convert';
import '../models/message.dart';

class CustomEmojiTextPayload {
  final String text;
  final String payload;
  final List<CustomEmojiEntity> entities;

  const CustomEmojiTextPayload({
    required this.text,
    required this.payload,
    required this.entities,
  });
}

List<CustomEmojiEntity> shiftCustomEmojiEntitiesForTextEdit({
  required String oldText,
  required String newText,
  required List<CustomEmojiEntity> entities,
}) {
  if (entities.isEmpty || oldText == newText) return entities;

  var prefix = 0;
  final minLength = oldText.length < newText.length
      ? oldText.length
      : newText.length;
  while (prefix < minLength &&
      oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
    prefix++;
  }

  var oldSuffix = oldText.length;
  var newSuffix = newText.length;
  while (oldSuffix > prefix &&
      newSuffix > prefix &&
      oldText.codeUnitAt(oldSuffix - 1) == newText.codeUnitAt(newSuffix - 1)) {
    oldSuffix--;
    newSuffix--;
  }

  final removedStart = prefix;
  final removedEnd = oldSuffix;
  final insertedLength = newSuffix - prefix;
  final delta = insertedLength - (removedEnd - removedStart);

  final shifted = <CustomEmojiEntity>[];
  for (final entity in entities) {
    final start = entity.offset;
    final end = entity.offset + entity.length;
    if (end <= removedStart) {
      shifted.add(entity);
    } else if (start >= removedEnd) {
      shifted.add(entity.copyWith(offset: start + delta));
    }
  }
  return shifted;
}

CustomEmojiTextPayload buildCustomEmojiTextPayload(
  String rawText,
  List<CustomEmojiEntity> draftEntities,
) {
  final text = rawText.trim();
  if (text.isEmpty || draftEntities.isEmpty) {
    return CustomEmojiTextPayload(
      text: text,
      payload: text,
      entities: const [],
    );
  }

  final leadingTrim = rawText.length - rawText.trimLeft().length;
  final shifted = draftEntities
      .map((entity) => entity.copyWith(offset: entity.offset - leadingTrim))
      .toList();
  final entities = normalizeCustomEmojiEntities(text, shifted);
  if (entities.isEmpty) {
    return CustomEmojiTextPayload(
      text: text,
      payload: text,
      entities: const [],
    );
  }

  final payload = jsonEncode({
    'text': text,
    'entities': entities.map((entity) => entity.toJson()).toList(),
  });
  return CustomEmojiTextPayload(
    text: text,
    payload: payload,
    entities: entities,
  );
}

List<CustomEmojiEntity> normalizeCustomEmojiEntities(
  String text,
  List<CustomEmojiEntity> entities,
) {
  if (text.isEmpty || entities.isEmpty) return const [];
  final normalized = <CustomEmojiEntity>[];
  final sorted = [...entities]..sort((a, b) => a.offset.compareTo(b.offset));

  for (final entity in sorted) {
    final emoji = entity.emoji;
    if (emoji.isEmpty) continue;
    var offset = entity.offset;
    final validAtOffset =
        offset >= 0 &&
        offset + emoji.length <= text.length &&
        text.substring(offset, offset + emoji.length) == emoji;
    if (!validAtOffset) {
      final hint = offset.clamp(0, text.length).toInt();
      offset = text.indexOf(emoji, hint);
      if (offset < 0) offset = text.indexOf(emoji);
    }
    if (offset < 0 || offset + emoji.length > text.length) continue;
    if (_overlapsExisting(offset, emoji.length, normalized)) continue;
    normalized.add(entity.copyWith(offset: offset, length: emoji.length));
  }
  return normalized;
}

bool _overlapsExisting(
  int offset,
  int length,
  List<CustomEmojiEntity> entities,
) {
  final end = offset + length;
  for (final entity in entities) {
    final otherEnd = entity.offset + entity.length;
    if (offset < otherEnd && end > entity.offset) return true;
  }
  return false;
}
