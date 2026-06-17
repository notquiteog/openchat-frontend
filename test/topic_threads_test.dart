import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/models/conversation_topic.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/providers/chat_provider.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/message_cache_service.dart';
import 'package:openchat/services/message_search_service.dart';
import 'package:openchat/services/mls_service.dart';
import 'package:openchat/services/network_service.dart';
import 'package:openchat/services/offline_outbox_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ConversationTopic.fromJson parses fields and closed state', () {
    final closed = ConversationTopic.fromJson({
      'id': 't1',
      'conversation_id': 'c1',
      'name': 'General',
      'icon_color': '#FF8800',
      'created_by': 'u1',
      'closed_at': DateTime.utc(2026, 6, 16).toIso8601String(),
      'created_at': DateTime.utc(2026, 6, 15).toIso8601String(),
    });
    expect(closed.id, 't1');
    expect(closed.name, 'General');
    expect(closed.iconColor, '#FF8800');
    expect(closed.isClosed, isTrue);

    final open = ConversationTopic.fromJson({
      'id': 't2',
      'conversation_id': 'c1',
      'name': 'Random',
      'created_by': 'u1',
      'created_at': DateTime.utc(2026, 6, 15).toIso8601String(),
    });
    expect(open.isClosed, isFalse);
    expect(open.iconColor, isNull);
  });

  group('ChatProvider topic filter', () {
    late ChatProvider provider;

    Message msg(String id, {String? topicId}) => Message(
      id: id,
      conversationId: 'conv-1',
      senderId: 'u1',
      type: MessageType.text,
      encryptedPayload: 'body-$id',
      signature: '',
      isEncrypted: false,
      createdAt: DateTime.utc(2026, 6, 16),
      topicId: topicId,
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({'user_id': 'self'});
      final storage = SecureStorageService();
      provider = ChatProvider(
        _FakeApi(storage),
        storage,
        _FakeWs(storage),
        SettingsProvider(),
        MlsService(storage),
        NetworkService(),
        searchService: _NoopSearch(storage),
        cacheService: _NoopCache(storage),
        outboxService: _NoopOutbox(storage),
      );
      await Future<void>.delayed(Duration.zero);
    });

    tearDown(() => provider.dispose());

    test('messagesForTopic returns only that topic and never untopiced', () {
      provider.debugSeedMessages('conv-1', [
        msg('a', topicId: 't1'),
        msg('b', topicId: 't2'),
        msg('c', topicId: 't1'),
        msg('d'),
      ]);
      expect(
        provider.messagesForTopic('conv-1', 't1').map((m) => m.id).toList(),
        ['a', 'c'],
      );
      expect(
        provider.messagesForTopic('conv-1', 't2').map((m) => m.id).toList(),
        ['b'],
      );
      // The unfiltered view still shows everything.
      expect(provider.messagesFor('conv-1').length, 4);
    });

    test('setActiveTopic toggles state and notifies', () {
      var notified = 0;
      provider.addListener(() => notified++);
      expect(provider.activeTopicId, isNull);

      provider.setActiveTopic('t1');
      expect(provider.activeTopicId, 't1');
      expect(notified, greaterThan(0));

      final before = notified;
      provider.setActiveTopic('t1'); // no-op, must not notify
      expect(notified, before);

      provider.setActiveTopic(null);
      expect(provider.activeTopicId, isNull);
    });
  });
}

// ── Fakes (mirrors message_tips_test.dart) ───────────────────────────────────

class _FakeApi extends ApiService {
  _FakeApi(super.storage);
  @override
  Future<List<Conversation>> listConversations() async => const [];
}

class _FakeWs extends WebSocketService {
  _FakeWs(super.storage);
  @override
  Future<void> connect() async {}
  @override
  void disconnect() {}
}

class _NoopSearch extends MessageSearchService {
  _NoopSearch(super.storage);
  @override
  Future<void> indexMessage(Message message, {String? conversationTitle}) =>
      Future.value();
}

class _NoopCache extends MessageCacheService {
  _NoopCache(super.storage);
  @override
  Future<MessageCacheEntry?> get(String messageId, String encryptedPayload) =>
      Future.value(null);
  @override
  Future<void> put(
    String messageId,
    String conversationId,
    String encryptedPayload,
    String plaintext,
    String? senderId,
  ) => Future.value();
}

class _NoopOutbox extends OfflineOutboxService {
  _NoopOutbox(super.storage);
  @override
  Future<List<OfflineOutboxItem>> list() => Future.value(const []);
}
