import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/services/message_search_service.dart';
import 'package:openchat/services/secure_storage_service.dart';

Message _decryptedMessage({
  required String id,
  required MessageType type,
  required String raw,
  DateTime? createdAt,
}) {
  final message = Message(
    id: id,
    conversationId: 'conv-1',
    senderId: 'user-1',
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
}
