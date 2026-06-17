import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/services/message_search_service.dart';
import 'package:openchat/services/secure_storage_service.dart';

Message _decryptedMessage({
  required String id,
  required MessageType type,
  required String raw,
  String senderId = 'user-1',
  String conversationId = 'conv-1',
  DateTime? createdAt,
}) {
  final message = Message(
    id: id,
    conversationId: conversationId,
    senderId: senderId,
    type: type,
    encryptedPayload: 'ciphertext',
    signature: '',
    createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
  );
  message.setDecryptedContent(raw);
  return message;
}

MessageSearchService _service() {
  return MessageSearchService(
    SecureStorageService(),
    databasePath: ':memory:',
    keyLoader: () async => List<int>.generate(32, (index) => index),
  );
}

void main() {
  test(
    'indexes decrypted messages and searches by encrypted token hashes',
    () async {
      final service = _service();
      final text = _decryptedMessage(
        id: 'msg-text',
        type: MessageType.text,
        raw: 'Launch notes and video checklist',
        createdAt: DateTime.utc(2026, 1, 2),
      );
      final file = _decryptedMessage(
        id: 'msg-file',
        type: MessageType.file,
        raw: jsonEncode({
          'text': 'Final roadmap pack',
          'file_name': 'roadmap.pdf',
          'mime_type': 'application/pdf',
        }),
        createdAt: DateTime.utc(2026, 1, 3),
      );

      await service.indexMessage(text, conversationTitle: 'Planning');
      await service.indexMessage(file, conversationTitle: 'Planning');

      final launchResults = await service.search('launch');
      expect(launchResults.map((result) => result.messageId), ['msg-text']);
      expect(launchResults.single.title, 'Launch notes and video checklist');

      final fileResults = await service.search(
        'road',
        categories: {MessageSearchCategory.files},
      );
      expect(fileResults.map((result) => result.messageId), ['msg-file']);
      expect(fileResults.single.title, 'roadmap.pdf');

      await service.deleteMessage('msg-file');
      expect(
        await service.search(
          'roadmap',
          categories: {MessageSearchCategory.files},
        ),
        isEmpty,
      );
    },
  );

  test('filters search results by sender id', () async {
    final service = _service();
    final alice = _decryptedMessage(
      id: 'msg-alice',
      type: MessageType.text,
      raw: 'Deploy notes',
      senderId: 'user-alice',
    );
    final bob = _decryptedMessage(
      id: 'msg-bob',
      type: MessageType.text,
      raw: 'Deploy notes',
      senderId: 'user-bob',
    );

    await service.indexMessage(alice, conversationTitle: 'Planning');
    await service.indexMessage(bob, conversationTitle: 'Planning');

    final results = await service.search('deploy', senderId: 'user-bob');

    expect(results.map((result) => result.messageId), ['msg-bob']);
  });

  test('filters search results by conversation id', () async {
    final service = _service();
    final planning = _decryptedMessage(
      id: 'msg-planning',
      type: MessageType.text,
      raw: 'Launch window',
      conversationId: 'conv-planning',
    );
    final finance = _decryptedMessage(
      id: 'msg-finance',
      type: MessageType.text,
      raw: 'Launch window',
      conversationId: 'conv-finance',
    );

    await service.indexMessage(planning, conversationTitle: 'Planning');
    await service.indexMessage(finance, conversationTitle: 'Finance');

    final results = await service.search(
      'launch',
      conversationId: 'conv-finance',
    );

    expect(results.map((result) => result.messageId), ['msg-finance']);
  });

  test('filters search results by inclusive local date range', () async {
    final service = _service();
    final january = _decryptedMessage(
      id: 'msg-jan',
      type: MessageType.text,
      raw: 'Budget review',
      createdAt: DateTime.utc(2026, 1, 1, 12),
    );
    final february = _decryptedMessage(
      id: 'msg-feb',
      type: MessageType.text,
      raw: 'Budget review',
      createdAt: DateTime.utc(2026, 2, 1, 18),
    );
    final march = _decryptedMessage(
      id: 'msg-mar',
      type: MessageType.text,
      raw: 'Budget review',
      createdAt: DateTime.utc(2026, 3, 1, 12),
    );

    await service.indexMessage(january, conversationTitle: 'Finance');
    await service.indexMessage(february, conversationTitle: 'Finance');
    await service.indexMessage(march, conversationTitle: 'Finance');

    final fromFebruary = await service.search(
      'budget',
      from: DateTime(2026, 2, 1),
    );
    final throughFebruary = await service.search(
      'budget',
      to: DateTime(2026, 2, 1),
    );

    expect(fromFebruary.map((result) => result.messageId), [
      'msg-mar',
      'msg-feb',
    ]);
    expect(throughFebruary.map((result) => result.messageId), [
      'msg-feb',
      'msg-jan',
    ]);
  });
}
