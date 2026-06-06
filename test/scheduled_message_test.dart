import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/models/scheduled_message.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';

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

  group('sealed scheduled controls', () {
    test('promotes delivered scheduled token to message token', () async {
      final storage = _FakeSecureStorage();
      const conversationId = 'conv-1';
      const messageId = 'scheduled-1';
      const token = 'schedule-token';
      await storage.saveSealedScheduleControlToken(
        conversationId,
        messageId,
        token,
      );
      final api = ApiService(storage);

      await api.promoteSealedScheduledControlToMessage(
        conversationId,
        messageId,
      );

      expect(
        await storage.getSealedScheduleControlToken(conversationId, messageId),
        isNull,
      );
      expect(
        await storage.getSealedMessageControlToken(conversationId, messageId),
        token,
      );
    });
  });
}

class _FakeSecureStorage extends SecureStorageService {
  final _scheduleTokens = <String, Map<String, String>>{};
  final _messageTokens = <String, Map<String, String>>{};

  @override
  Future<String?> getUserID() async => '';

  @override
  Future<String?> getPublicKey() async => '';

  @override
  Future<String?> getFingerprint() async => '';

  @override
  Future<String?> getPrivateKeyIfUnlocked() async => '';

  @override
  Future<String?> getSealedScheduleControlToken(
    String conversationID,
    String scheduledID,
  ) async {
    return _scheduleTokens[conversationID]?[scheduledID];
  }

  @override
  Future<void> saveSealedScheduleControlToken(
    String conversationID,
    String scheduledID,
    String token,
  ) async {
    _scheduleTokens.putIfAbsent(conversationID, () => {})[scheduledID] = token;
  }

  @override
  Future<void> deleteSealedScheduleControlToken(
    String conversationID,
    String scheduledID,
  ) async {
    _scheduleTokens[conversationID]?.remove(scheduledID);
  }

  @override
  Future<String?> getSealedMessageControlToken(
    String conversationID,
    String messageID,
  ) async {
    return _messageTokens[conversationID]?[messageID];
  }

  @override
  Future<void> saveSealedMessageControlToken(
    String conversationID,
    String messageID,
    String token,
  ) async {
    _messageTokens.putIfAbsent(conversationID, () => {})[messageID] = token;
  }
}
