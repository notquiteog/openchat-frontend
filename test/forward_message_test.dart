import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/utils/message_actions.dart';

void main() {
  test('image forward preserves attachment metadata and attribution', () {
    final message = _message(MessageType.image);
    message.setDecryptedContent(
      jsonEncode({
        'text': 'look',
        'attachment_id': 'att-1',
        'file_key': 'file-key',
        'file_nonce': 'file-nonce',
        'file_name': 'photo.webp',
        'mime_type': 'image/webp',
        'view_once': true,
        'has_spoiler': true,
      }),
    );

    final payload = buildForwardPayload(
      message,
      anonymous: false,
      fromUsername: 'alice',
      wireTypeOf: messageTypeWireName,
    );

    expect(payload?.messageType, 'image');
    expect(payload?.attachmentId, 'att-1');
    final content = _decodedContent(payload!.plaintext);
    expect(content.text, 'look');
    expect(content.attachmentId, 'att-1');
    expect(content.fileKey, 'file-key');
    expect(content.fileNonce, 'file-nonce');
    expect(content.fileName, 'photo.webp');
    expect(content.mimeType, 'image/webp');
    expect(content.forwardedFrom, '@alice');
    expect(content.viewOnce, isFalse);
    expect(content.hasSpoiler, isTrue);

    final anonymous = buildForwardPayload(
      message,
      anonymous: true,
      fromUsername: 'alice',
      wireTypeOf: messageTypeWireName,
    );
    expect(_decodedContent(anonymous!.plaintext).forwardedFrom, isNull);
  });

  test('voice and special media wire names round-trip', () {
    final voice = _message(MessageType.voice);
    voice.setDecryptedContent(
      jsonEncode({
        'attachment_id': 'voice-1',
        'duration_ms': 4200,
        'waveform': [0.1, 0.7, 1.2],
      }),
    );
    final voicePayload = buildForwardPayload(
      voice,
      anonymous: false,
      fromUsername: null,
      wireTypeOf: messageTypeWireName,
    );
    final voiceContent = _decodedContent(voicePayload!.plaintext);
    expect(voicePayload.messageType, 'voice');
    expect(voiceContent.durationMs, 4200);
    expect(voiceContent.waveform, [0.1, 0.7, 1.0]);

    final videoNote = _message(MessageType.videoNote)
      ..setDecryptedContent(jsonEncode({'attachment_id': 'video-note-1'}));
    final livePhoto = _message(MessageType.livePhoto)
      ..setDecryptedContent(jsonEncode({'attachment_id': 'live-photo-1'}));

    expect(
      buildForwardPayload(
        videoNote,
        anonymous: false,
        fromUsername: null,
        wireTypeOf: messageTypeWireName,
      )?.messageType,
      'video_note',
    );
    expect(
      buildForwardPayload(
        livePhoto,
        anonymous: false,
        fromUsername: null,
        wireTypeOf: messageTypeWireName,
      )?.messageType,
      'live_photo',
    );
  });

  test(
    'sticker contact and location forwards preserve their payload shape',
    () {
      final sticker = _message(MessageType.sticker)..setDecryptedContent('s-1');
      final stickerPayload = buildForwardPayload(
        sticker,
        anonymous: false,
        fromUsername: 'alice',
        wireTypeOf: messageTypeWireName,
      );
      expect(stickerPayload?.messageType, 'sticker');
      expect(stickerPayload?.plaintext, 's-1');

      final contact = _message(MessageType.contact);
      contact.setDecryptedContent(
        jsonEncode({
          'contact': {
            'user_id': 'u-2',
            'username': 'bob',
            'display_name': 'Bob',
            'fingerprint': 'fp',
          },
        }),
      );
      final contactPayload = buildForwardPayload(
        contact,
        anonymous: false,
        fromUsername: 'alice',
        wireTypeOf: messageTypeWireName,
      );
      final contactContent = _decodedContent(contactPayload!.plaintext);
      expect(contactPayload.messageType, 'contact');
      expect(contactContent.contact?.username, 'bob');
      expect(contactContent.forwardedFrom, '@alice');

      final locationJson = jsonEncode({
        'kind': 'one_time',
        'latitude': 12.34,
        'longitude': 56.78,
        'share_id': 'share-1',
        'ended': false,
      });
      final location = _message(MessageType.location)
        ..setDecryptedContent(locationJson);
      final locationPayload = buildForwardPayload(
        location,
        anonymous: false,
        fromUsername: 'alice',
        wireTypeOf: messageTypeWireName,
      );

      expect(locationPayload?.messageType, 'location');
      expect(locationPayload?.plaintext, locationJson);
      expect(
        MessageLocation.tryParse(locationPayload!.plaintext)?.latitude,
        12.34,
      );
    },
  );

  test(
    'isForwardable allows reproducible content and rejects unsafe types',
    () {
      for (final type in [
        MessageType.text,
        MessageType.image,
        MessageType.video,
        MessageType.voice,
        MessageType.audio,
        MessageType.animation,
        MessageType.videoNote,
        MessageType.livePhoto,
        MessageType.file,
        MessageType.location,
        MessageType.venue,
        MessageType.contact,
        MessageType.sticker,
        MessageType.poll,
      ]) {
        expect(
          isForwardable(_forwardableMessage(type)),
          isTrue,
          reason: '$type',
        );
      }

      for (final type in [
        MessageType.system,
        MessageType.dice,
        MessageType.game,
        MessageType.checklist,
        MessageType.invoice,
        MessageType.paymentRequest,
        MessageType.paymentTransfer,
      ]) {
        final message = _message(type)..setDecryptedContent('payload');
        expect(isForwardable(message), isFalse, reason: '$type');
      }

      expect(isForwardable(_message(MessageType.text)), isFalse);
    },
  );
}

MessageContent _decodedContent(String raw) {
  return MessageContent.fromJson(
    Map<String, dynamic>.from(jsonDecode(raw) as Map),
  );
}

Message _forwardableMessage(MessageType type) {
  final message = _message(
    type,
    poll: type == MessageType.poll ? _poll() : null,
  );
  switch (type) {
    case MessageType.text:
      message.setDecryptedContent('hello');
    case MessageType.sticker:
      message.setDecryptedContent('sticker-1');
    case MessageType.image:
    case MessageType.video:
    case MessageType.voice:
    case MessageType.audio:
    case MessageType.animation:
    case MessageType.videoNote:
    case MessageType.livePhoto:
    case MessageType.file:
      message.setDecryptedContent(jsonEncode({'attachment_id': 'att-1'}));
    case MessageType.location:
      message.setDecryptedContent(
        jsonEncode({
          'kind': 'one_time',
          'latitude': 1,
          'longitude': 2,
          'share_id': 'share-1',
          'ended': false,
        }),
      );
    case MessageType.venue:
      message.setDecryptedContent(jsonEncode({'title': 'Cafe'}));
    case MessageType.contact:
      message.setDecryptedContent(
        jsonEncode({
          'contact': {'username': 'bob'},
        }),
      );
    case MessageType.poll:
      message.setDecryptedContent(
        jsonEncode({
          'poll': {'id': 'poll-1'},
        }),
      );
    case MessageType.system:
    case MessageType.dice:
    case MessageType.game:
    case MessageType.checklist:
    case MessageType.invoice:
    case MessageType.paymentRequest:
    case MessageType.paymentTransfer:
      message.setDecryptedContent('payload');
  }
  return message;
}

Message _message(MessageType type, {Poll? poll}) {
  return Message(
    id: 'msg-${type.name}',
    conversationId: 'conv-1',
    senderId: 'u-1',
    type: type,
    encryptedPayload: '',
    signature: '',
    poll: poll,
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

Poll _poll() => const Poll(
  id: 'poll-1',
  question: 'Lunch?',
  type: 'regular',
  isAnonymous: true,
  allowsMultipleAnswers: false,
  allowsRevoting: true,
  isClosed: false,
  totalVoterCount: 0,
  options: [
    PollOption(id: 'o-1', index: 0, text: 'Soup', voterCount: 0),
    PollOption(id: 'o-2', index: 1, text: 'Salad', voterCount: 0),
  ],
);
