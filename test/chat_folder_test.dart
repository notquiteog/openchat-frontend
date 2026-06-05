import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/chat_folder.dart';

void main() {
  test('chat folder parses server payload and builds upsert body', () {
    final folder = ChatFolder.fromJson({
      'id': 'folder-1',
      'user_id': 'user-1',
      'name': 'Work',
      'position': 2,
      'include_archived': true,
      'conversation_ids': ['conv-1', 'conv-2'],
      'created_at': '2026-01-01T12:00:00Z',
      'updated_at': '2026-01-02T12:00:00Z',
    });

    expect(folder.id, 'folder-1');
    expect(folder.userId, 'user-1');
    expect(folder.name, 'Work');
    expect(folder.position, 2);
    expect(folder.includeArchived, isTrue);
    expect(folder.conversationIds, ['conv-1', 'conv-2']);
    expect(folder.createdAt?.toUtc(), DateTime.utc(2026, 1, 1, 12));
    expect(folder.updatedAt?.toUtc(), DateTime.utc(2026, 1, 2, 12));

    expect(folder.toUpsertJson(), {
      'id': 'folder-1',
      'name': 'Work',
      'position': 2,
      'include_archived': true,
      'conversation_ids': ['conv-1', 'conv-2'],
    });
  });

  test('new chat folder upsert omits empty id', () {
    final folder = ChatFolder(
      id: '',
      userId: '',
      name: '  Friends  ',
      conversationIds: const ['conv-3'],
    );

    expect(folder.toUpsertJson(), {
      'name': 'Friends',
      'position': 0,
      'include_archived': false,
      'conversation_ids': ['conv-3'],
    });
  });
}
