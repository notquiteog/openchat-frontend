import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
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
  late SecureStorageService storage;
  late SettingsProvider settings;
  late _RecordingApi api;
  late _RecordingWs ws;
  late ChatProvider chat;

  Future<void> buildChat({bool strict = false}) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'user_id': 'self'});
    storage = SecureStorageService();
    settings = SettingsProvider();
    await settings.load();
    await settings.setStrictPrivacyMode(strict);
    api = _RecordingApi(storage);
    ws = _RecordingWs(storage);
    chat = ChatProvider(
      api,
      storage,
      ws,
      settings,
      MlsService(storage),
      _FakeNetwork(),
      searchService: _NoopSearch(storage),
      cacheService: _NoopCache(storage),
      outboxService: _EmptyOutbox(storage),
    );
    addTearDown(chat.dispose);
  }

  test(
    'per-chat typing override can suppress with global strict off',
    () async {
      await buildChat();
      await settings.setConversationShareTyping('conv-1', false);

      chat.sendTyping('conv-1');

      expect(ws.typingConversationIds, isEmpty);
    },
  );

  test('per-chat typing override can share with global strict on', () async {
    await buildChat(strict: true);
    await settings.setConversationShareTyping('conv-1', true);

    chat.sendTyping('conv-1');

    expect(ws.typingConversationIds, ['conv-1']);
  });

  test(
    'hidden read receipts clear local mentions and persist privately',
    () async {
      await buildChat();
      await settings.setUnreadMentionMessage('conv-1', 'mention-1');
      await settings.setConversationShareReadReceipts('conv-1', false);

      await chat.sendReadReceipt('conv-1', 'msg-1');

      expect(settings.unreadMentionMessageIdFor('conv-1'), isNull);
      // The marker is still persisted so the caller's own unread count clears,
      // but as `private` so no receipt is broadcast to other members.
      expect(api.markReadCalls, hasLength(1));
      expect(api.markReadPrivateFlags.single, isTrue);
    },
  );

  test(
    'per-chat read receipt override can share with global strict on',
    () async {
      await buildChat(strict: true);
      await settings.setConversationShareReadReceipts('conv-1', true);

      await chat.sendReadReceipt('conv-1', 'msg-1');

      expect(api.markReadCalls, hasLength(1));
      expect(api.markReadCalls.single.key, 'conv-1');
      expect(api.markReadCalls.single.value, 'msg-1');
      // Sharing on → receipt broadcast (not private).
      expect(api.markReadPrivateFlags.single, isFalse);
    },
  );
}

class _RecordingApi extends ApiService {
  _RecordingApi(super.storage);

  final List<MapEntry<String, String>> markReadCalls = [];

  final List<bool> markReadPrivateFlags = [];

  @override
  Future<void> markRead(
    String convID,
    String messageID, {
    bool private = false,
  }) async {
    markReadCalls.add(MapEntry(convID, messageID));
    markReadPrivateFlags.add(private);
  }
}

class _RecordingWs extends WebSocketService {
  _RecordingWs(super.storage);

  final List<String> typingConversationIds = [];

  @override
  Future<void> connect() async {}

  @override
  void disconnect() {}

  @override
  void sendTyping(String conversationID) {
    typingConversationIds.add(conversationID);
  }
}

class _FakeNetwork extends NetworkService {
  @override
  NetworkClass get current => NetworkClass.wifi;

  @override
  Future<void> init() async {}
}

class _EmptyOutbox extends OfflineOutboxService {
  _EmptyOutbox(super.storage);

  @override
  Future<List<OfflineOutboxItem>> list() async => const [];

  @override
  Future<void> replaceAll(List<OfflineOutboxItem> items) async {}

  @override
  Future<void> remove(String id) async {}
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
