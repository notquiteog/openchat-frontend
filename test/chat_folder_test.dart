import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/chat_folder.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/services/local_private_state_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('chat folder parses local payload and builds local json', () {
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

    expect(folder.toJson(), {
      'id': 'folder-1',
      'user_id': 'user-1',
      'name': 'Work',
      'position': 2,
      'include_archived': true,
      'conversation_ids': ['conv-1', 'conv-2'],
      'created_at': '2026-01-01T12:00:00.000Z',
      'updated_at': '2026-01-02T12:00:00.000Z',
    });
  });

  test('new chat folder json omits empty id', () {
    final folder = ChatFolder(
      id: '',
      userId: '',
      name: '  Friends  ',
      conversationIds: const ['conv-3'],
    );

    expect(folder.toJson(), {
      'name': 'Friends',
      'position': 0,
      'include_archived': false,
      'conversation_ids': ['conv-3'],
    });
  });

  test('chat folders persist in encrypted local state', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = SettingsProvider();
    await provider.load();

    final saved = await provider.saveChatFolder(
      const ChatFolder(
        id: '',
        userId: 'server-user-id',
        name: '  Work  ',
        conversationIds: ['conv-1', 'conv-1', 'conv-2'],
      ),
    );

    expect(saved.id, startsWith('local-'));
    expect(saved.userId, isEmpty);
    expect(saved.name, 'Work');
    expect(saved.conversationIds, ['conv-1', 'conv-2']);

    final prefs = await SharedPreferences.getInstance();
    final encrypted = prefs.getString(localPrivateStatePreferenceKey);
    expect(encrypted, isNotNull);
    expect(encrypted, isNot(contains('Work')));
    expect(encrypted, isNot(contains('conv-1')));

    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.chatFolders.single.id, saved.id);
    expect(reloaded.chatFolders.single.name, 'Work');
  });
}
