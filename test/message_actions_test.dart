import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/utils/message_actions.dart';

void main() {
  test('messageDeepLink builds stable OpenChat URI', () {
    final link = messageDeepLink(conversationId: 'conv 1', messageId: 'msg/2');

    final uri = Uri.parse(link);
    expect(uri.scheme, 'openchat');
    expect(uri.host, 'message');
    expect(uri.queryParameters['conversation_id'], 'conv 1');
    expect(uri.queryParameters['message_id'], 'msg/2');
  });

  test('suggestedAttachmentFileName sanitizes explicit names', () {
    final message = _message(MessageType.file);
    message.setDecryptedContent(
      jsonEncode({
        'attachment_id': 'att-1',
        'file_name': 'report:2026/06.pdf',
        'mime_type': 'application/pdf',
      }),
    );

    expect(suggestedAttachmentFileName(message), 'report_2026_06.pdf');
  });

  test('suggestedAttachmentFileName falls back to type extension', () {
    final message = _message(MessageType.image);
    message.setDecryptedContent(jsonEncode({'attachment_id': 'att-2'}));

    expect(suggestedAttachmentFileName(message), 'openchat_att-2.webp');
  });
}

Message _message(MessageType type) {
  return Message(
    id: 'msg-1',
    conversationId: 'conv-1',
    senderId: 'u-1',
    type: type,
    encryptedPayload: '',
    signature: '',
    createdAt: DateTime.utc(2026, 1, 1),
  );
}
