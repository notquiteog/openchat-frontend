import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/utils/message_albums.dart';

Message msg(
  String id, {
  String? group,
  String sender = 'alice',
  String type = 'image',
}) =>
    Message.fromJson({
      'id': id,
      'conversation_id': 'c1',
      'sender_id': sender,
      'message_type': type,
      'encrypted_payload': '{}',
      'is_encrypted': false,
      'created_at': '2026-06-11T10:00:00Z',
      'media_group_id': ?group,
    });

void main() {
  group('albumRunAt', () {
    test('groups a consecutive same-sender media group', () {
      final list = [
        msg('t1', group: null),
        msg('a1', group: 'g1'),
        msg('a2', group: 'g1'),
        msg('a3', group: 'g1'),
        msg('t2', group: null),
      ];
      for (final i in [1, 2, 3]) {
        final run = albumRunAt(list, i)!;
        expect(run.map((m) => m.id), ['a1', 'a2', 'a3'], reason: 'index $i');
      }
      expect(albumRunAt(list, 0), isNull);
      expect(albumRunAt(list, 4), isNull);
    });

    test('a single grouped image is not an album', () {
      final list = [msg('a1', group: 'g1'), msg('t1')];
      expect(albumRunAt(list, 0), isNull);
    });

    test('different groups and senders split runs', () {
      final list = [
        msg('a1', group: 'g1'),
        msg('a2', group: 'g1'),
        msg('b1', group: 'g2'),
        msg('b2', group: 'g2', sender: 'bob'),
        msg('b3', group: 'g2', sender: 'bob'),
      ];
      expect(albumRunAt(list, 0)!.map((m) => m.id), ['a1', 'a2']);
      expect(albumRunAt(list, 2), isNull,
          reason: 'g2 from alice is a lone member — bob\'s g2 is separate');
      expect(albumRunAt(list, 3)!.map((m) => m.id), ['b2', 'b3']);
    });

    test('non-image members never join an album', () {
      final list = [
        msg('a1', group: 'g1'),
        msg('v1', group: 'g1', type: 'video'),
        msg('a2', group: 'g1'),
      ];
      expect(albumRunAt(list, 0), isNull);
      expect(albumRunAt(list, 1), isNull);
    });
  });
}
