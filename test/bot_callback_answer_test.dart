import 'dart:convert';

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

/// #32 — a bot's answerCallbackQuery reply reaches the user who tapped an inline
/// button over a new user-scoped `callback_answer` WS event. These tests pin the
/// parse mapping and the ChatProvider fan-out the tapped button awaits.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SecureStorageService storage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'user_id': 'self'});
    storage = SecureStorageService();
  });

  test('handleRawFrame maps callback_answer to a typed WS event', () async {
    final ws = _FakeWs(storage);
    addTearDown(ws.dispose);

    final events = <WsEvent>[];
    final sub = ws.events.listen(events.add);
    addTearDown(sub.cancel);

    ws.handleRawFrame(
      jsonEncode({
        'type': 'callback_answer',
        'data': {
          'callback_query_id': 'cb-1',
          'text': 'Added to cart',
          'show_alert': true,
        },
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(1));
    expect(events.single.type, WsEventType.callbackAnswer);
    expect(events.single.data['callback_query_id'], 'cb-1');
    expect(events.single.data['show_alert'], true);
  });

  test(
    'ChatProvider re-emits a callback_answer on its callbackAnswers stream',
    () async {
      final ws = _FakeWs(storage);
      final provider = ChatProvider(
        _FakeApi(storage),
        storage,
        ws,
        SettingsProvider(),
        MlsService(storage),
        NetworkService(),
        searchService: _NoopSearch(storage),
        cacheService: _NoopCache(storage),
        outboxService: _NoopOutbox(storage),
      );
      addTearDown(provider.dispose);
      await Future<void>.delayed(Duration.zero); // settle constructor async

      final answers = <Map<String, dynamic>>[];
      final sub = provider.callbackAnswers.listen(answers.add);
      addTearDown(sub.cancel);

      ws.handleRawFrame(
        jsonEncode({
          'type': 'callback_answer',
          'data': {
            'callback_query_id': 'cb-9',
            'text': 'Done',
            'show_alert': false,
          },
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(answers, hasLength(1));
      expect(answers.single['callback_query_id'], 'cb-9');
      expect(answers.single['text'], 'Done');
      expect(answers.single['show_alert'], false);
    },
  );
}

// ── Fakes ────────────────────────────────────────────────────────────────────

class _FakeWs extends WebSocketService {
  _FakeWs(super.storage);
  @override
  Future<void> connect() async {}
  @override
  void disconnect() {}
}

class _FakeApi extends ApiService {
  _FakeApi(super.storage);
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
}

class _NoopOutbox extends OfflineOutboxService {
  _NoopOutbox(super.storage);
  @override
  Future<List<OfflineOutboxItem>> list() => Future.value(const []);
}
