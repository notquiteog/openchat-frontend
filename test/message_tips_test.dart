import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';
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
import 'package:openchat/widgets/message_bubble.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Anonymous post tips: a message_tipped WS broadcast must hydrate the
/// message's per-provider aggregates in memory, and the bubble must render
/// them as chips — totals only, never a tipper identity.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const selfId = 'self-user';

  late SecureStorageService storage;
  late _FakeApi api;
  late WebSocketService ws;
  late ChatProvider provider;

  Message post() => Message(
    id: 'msg-1',
    conversationId: 'conv-1',
    senderId: 'creator-1',
    type: MessageType.text,
    encryptedPayload: 'hello subscribers',
    signature: '',
    isEncrypted: false,
    createdAt: DateTime.utc(2026, 6, 11),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'user_id': selfId});
    storage = SecureStorageService();
    api = _FakeApi(storage);
    ws = _FakeWs(storage);
    provider = ChatProvider(
      api,
      storage,
      ws,
      SettingsProvider(),
      MlsService(storage),
      NetworkService(),
      searchService: _NoopSearch(storage),
      cacheService: _NoopCache(storage),
      outboxService: _NoopOutbox(storage),
    );
    await Future<void>.delayed(Duration.zero); // let _selfId load
  });

  tearDown(() => provider.dispose());

  void tipViaWs(List<Map<String, dynamic>> tips) {
    ws.handleRawFrame(
      jsonEncode({
        'type': 'message_tipped',
        'data': {
          'conversation_id': 'conv-1',
          'message_id': 'msg-1',
          'tips': tips,
        },
      }),
    );
  }

  testWidgets('message_tipped broadcast hydrates the aggregates', (
    tester,
  ) async {
    provider.debugSeedMessages('conv-1', [post()]);
    expect(provider.messagesFor('conv-1').first.tips, isEmpty);

    tipViaWs([
      {'provider': 'btc', 'total': '0.75', 'tippers': 2},
    ]);
    await tester.pump();

    final tips = provider.messagesFor('conv-1').first.tips;
    expect(tips, hasLength(1));
    expect(tips.first.provider, 'btc');
    expect(tips.first.total, '0.75');
    expect(tips.first.tippers, 2);

    // A later broadcast fully replaces the aggregates (server is the source
    // of truth — no client-side accumulation drift).
    tipViaWs([
      {'provider': 'btc', 'total': '1.75', 'tippers': 3},
      {'provider': 'xmr', 'total': '0.2', 'tippers': 1},
    ]);
    await tester.pump();

    final updated = provider.messagesFor('conv-1').first.tips;
    expect(updated, hasLength(2));
    expect(updated.first.total, '1.75');
  });

  testWidgets('bubble renders one anonymous chip per provider', (tester) async {
    provider.debugSeedMessages('conv-1', [post()]);
    tipViaWs([
      {'provider': 'btc', 'total': '0.75', 'tippers': 2},
    ]);
    await tester.pump();

    final msg = provider.messagesFor('conv-1').first;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: Provider<ApiService>.value(
            value: api,
            child: Scaffold(body: MessageBubble(message: msg, isMe: false)),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('⚡ 0.75 BTC · 2'), findsOneWidget);
  });
}

// ── Fakes ────────────────────────────────────────────────────────────────────

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
  ) =>
      Future.value();
}

class _NoopOutbox extends OfflineOutboxService {
  _NoopOutbox(super.storage);

  @override
  Future<List<OfflineOutboxItem>> list() => Future.value(const []);
}
