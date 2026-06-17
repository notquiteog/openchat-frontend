import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';

// notificationPreview is the body snippet the notification paths show once a
// message is decrypted: media render as a fixed label (never a leaky caption),
// text is trimmed, and anything blank degrades to "New message".
void main() {
  Message message({required String type, required String payload}) =>
      Message.fromJson({
        'id': '9590c14c-a243-4bd3-81e3-62a69049e2ee',
        'conversation_id': 'b51cb6c6-0000-0000-0000-000000000000',
        'message_type': type,
        'encrypted_payload': payload,
        'is_encrypted': false,
        'created_at': '2026-06-08T22:09:35.921233Z',
      })..setDecryptedContent(payload);

  group('Message.notificationPreview', () {
    test('text returns the decrypted text', () {
      expect(
        message(type: 'text', payload: 'are we still on?').notificationPreview,
        'are we still on?',
      );
    });

    test('media types render as a fixed label, not the caption', () {
      expect(
        message(type: 'image', payload: 'secret').notificationPreview,
        'Photo',
      );
      expect(message(type: 'video', payload: '').notificationPreview, 'Video');
      expect(
        message(type: 'voice', payload: '').notificationPreview,
        'Voice message',
      );
      expect(message(type: 'audio', payload: '').notificationPreview, 'Audio');
      expect(message(type: 'file', payload: '').notificationPreview, 'File');
      expect(
        message(type: 'sticker', payload: '').notificationPreview,
        'Sticker',
      );
    });

    test('long text is trimmed to 120 chars with an ellipsis', () {
      final preview = message(
        type: 'text',
        payload: 'x' * 200,
      ).notificationPreview;
      expect(preview.endsWith('…'), isTrue);
      expect(preview.runes.length, lessThanOrEqualTo(121));
    });

    test('empty text falls back to "New message"', () {
      expect(
        message(type: 'text', payload: '').notificationPreview,
        'New message',
      );
    });
  });
}
