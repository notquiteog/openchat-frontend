import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/models/scheduled_message.dart';

void main() {
  group('ScheduledMessage', () {
    test('parses backend fields', () {
      final scheduled = ScheduledMessage.fromJson({
        'id': 'scheduled-1',
        'conversation_id': 'conv-1',
        'sender_id': 'user-1',
        'message_type': 'image',
        'encrypted_payload': 'ciphertext',
        'signature': 'sig',
        'attachment_id': 'attach-1',
        'reply_to': 'msg-1',
        'topic_id': 'topic-1',
        'silent': true,
        'scheduled_for': '2026-06-05T17:30:00Z',
        'created_at': '2026-06-05T16:00:00Z',
        'sent_at': null,
        'canceled_at': null,
        'mentioned_user_ids': ['user-2'],
      });

      expect(scheduled.id, 'scheduled-1');
      expect(scheduled.conversationId, 'conv-1');
      expect(scheduled.senderId, 'user-1');
      expect(scheduled.type, MessageType.image);
      expect(scheduled.attachmentId, 'attach-1');
      expect(scheduled.replyTo, 'msg-1');
      expect(scheduled.topicId, 'topic-1');
      expect(scheduled.silent, true);
      expect(scheduled.scheduledFor, DateTime.parse('2026-06-05T17:30:00Z'));
      expect(scheduled.createdAt, DateTime.parse('2026-06-05T16:00:00Z'));
      expect(scheduled.mentionedUserIds, ['user-2']);
    });

    test('uses decrypted text and media filenames for previews', () {
      final scheduled = ScheduledMessage.fromJson({
        'id': 'scheduled-1',
        'conversation_id': 'conv-1',
        'sender_id': 'user-1',
        'message_type': 'video',
        'encrypted_payload': 'ciphertext',
        'scheduled_for': '2026-06-05T17:30:00Z',
        'created_at': '2026-06-05T16:00:00Z',
      });

      final withCaption = scheduled.copyWith(
        decryptedContent: jsonEncode({
          'text': 'Launch clip',
          'file_name': 'launch.mov',
        }),
      );
      final withFilename = scheduled.copyWith(
        decryptedContent: jsonEncode({'text': '', 'file_name': 'launch.mov'}),
      );

      expect(withCaption.previewText, 'Launch clip');
      expect(withFilename.previewText, 'Video: launch.mov');
      expect(scheduled.previewText, 'Video');
    });

    test(
      'copyWith can update the delivery time without losing preview state',
      () {
        final scheduled = ScheduledMessage.fromJson({
          'id': 'scheduled-1',
          'conversation_id': 'conv-1',
          'sender_id': 'user-1',
          'message_type': 'text',
          'encrypted_payload': 'ciphertext',
          'scheduled_for': '2026-06-05T17:30:00Z',
          'created_at': '2026-06-05T16:00:00Z',
        }).copyWith(decryptedContent: 'Queued note');
        final newTime = DateTime.parse('2026-06-05T18:45:00Z');

        final updated = scheduled.copyWith(scheduledFor: newTime);

        expect(updated.scheduledFor, newTime);
        expect(updated.previewText, 'Queued note');
      },
    );
  });
}
