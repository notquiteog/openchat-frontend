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
import 'package:openchat/services/offline_outbox_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:openchat/widgets/message_bubble.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Skill-game lobby card: a joined player must see "Ready up" (the
/// join-button-forever bug locked joiners out of readying), and the
/// join/ready/leave responses must flow through provider ingestion into the
/// rebuilt card.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const selfId = 'self-user';

  late SecureStorageService storage;
  late _FakeApi api;
  late WebSocketService ws;
  late ChatProvider provider;

  Map<String, dynamic> lobbyRound({required bool selfSeated}) => {
    'id': 'round-1',
    'conversation_id': 'conv-1',
    'created_by': 'creator-1',
    'game_type': '🎲',
    'faces': 6,
    'provider': 'fun',
    'stake': '0',
    'status': 'lobby',
    'server_seed_hash': 'hash',
    'max_players': 8,
    'created_at': DateTime.utc(2026, 6, 10).toIso8601String(),
    'bets': [
      {'user_id': 'creator-1', 'ready': false},
      if (selfSeated) {'user_id': selfId, 'ready': false},
    ],
  };

  Message gameMessage() => Message(
    id: 'msg-1',
    conversationId: 'conv-1',
    senderId: 'creator-1',
    type: MessageType.game,
    encryptedPayload: jsonEncode({
      'game': {'round_id': 'round-1'},
    }),
    signature: '',
    isEncrypted: false,
    createdAt: DateTime.utc(2026, 6, 10),
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
      searchService: _NoopSearch(storage),
      cacheService: _NoopCache(storage),
      outboxService: _NoopOutbox(storage),
    );
    await Future<void>.delayed(Duration.zero); // let _selfId load
  });

  tearDown(() => provider.dispose());

  Future<void> pumpBubble(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: Provider<ApiService>.value(
            value: api,
            child: Scaffold(
              body: MessageBubble(message: gameMessage(), isMe: false),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  void ingestViaWs(Map<String, dynamic> round) {
    ws.handleRawFrame(jsonEncode({'type': 'game_updated', 'data': round}));
  }

  testWidgets('unseated viewer sees Join game', (tester) async {
    ingestViaWs(lobbyRound(selfSeated: false));
    await pumpBubble(tester);

    expect(find.text('Join game'), findsOneWidget);
    expect(find.text('Ready up'), findsNothing);
  });

  testWidgets('a seated joiner sees Ready up, not Join game', (tester) async {
    ingestViaWs(lobbyRound(selfSeated: true));
    await pumpBubble(tester);

    expect(find.text('Ready up'), findsOneWidget);
    expect(find.text('Join game'), findsNothing);
  });

  testWidgets('tapping Join flips the card to Ready up', (tester) async {
    ingestViaWs(lobbyRound(selfSeated: false));
    api.joinResponse = lobbyRound(selfSeated: true);
    await pumpBubble(tester);

    await tester.tap(find.text('Join game'));
    await tester.pumpAndSettle();

    expect(api.joinCalls, 1);
    expect(find.text('Ready up'), findsOneWidget,
        reason: 'the joined player must be able to ready up');
    expect(find.text('Join game'), findsNothing);
  });

  testWidgets('a game_updated broadcast alone flips the card', (tester) async {
    ingestViaWs(lobbyRound(selfSeated: false));
    await pumpBubble(tester);
    expect(find.text('Join game'), findsOneWidget);

    ingestViaWs(lobbyRound(selfSeated: true));
    await tester.pumpAndSettle();

    expect(find.text('Ready up'), findsOneWidget);
  });

  testWidgets(
      'fresh-install login (provider built pre-auth) still recognises own seat',
      (tester) async {
    // THE bug: ChatProvider is constructed at app boot, BEFORE login, so its
    // one-shot self-id load found nothing — and nothing reloaded it after
    // login. Every own-seat check failed: joiners saw "Join game" forever.
    provider.dispose();
    FlutterSecureStorage.setMockInitialValues({}); // no session yet
    storage = SecureStorageService();
    api = _FakeApi(storage);
    ws = _FakeWs(storage);
    provider = ChatProvider(
      api,
      storage,
      ws,
      SettingsProvider(),
      MlsService(storage),
      searchService: _NoopSearch(storage),
      cacheService: _NoopCache(storage),
      outboxService: _NoopOutbox(storage),
    );
    await tester.pump(); // flush constructor async (FakeAsync: no bare delays)

    // Login happens, then a standard post-login entry point runs. Use the
    // WS-connect trigger (hermetic — the fake socket never dials) rather than
    // loadConversations, whose real ApiService tail can attempt network in
    // the test sandbox. NOTE: inside testWidgets everything runs under
    // FakeAsync — a bare `await Future.delayed(...)` creates a fake timer
    // that never fires and hangs the test for its full 10-minute timeout;
    // microtask flushing must go through tester.pump().
    FlutterSecureStorage.setMockInitialValues({'user_id': selfId});
    await provider.connectWebSocket();
    await tester.pump(); // let the unawaited identity hydration settle

    ingestViaWs(lobbyRound(selfSeated: true));
    await pumpBubble(tester);

    expect(find.text('Ready up'), findsOneWidget,
        reason: 'self identity must re-hydrate after login');
    expect(find.text('Join game'), findsNothing);
  });
}

// ── Fakes ────────────────────────────────────────────────────────────────────

class _FakeApi extends ApiService {
  _FakeApi(super.storage);

  Map<String, dynamic>? joinResponse;
  int joinCalls = 0;

  @override
  Future<List<Conversation>> listConversations() async => const [];

  @override
  Future<Map<String, dynamic>> joinGameRound(
    String convID,
    String roundID, {
    bool isChannel = false,
  }) async {
    joinCalls++;
    return Map<String, dynamic>.from(joinResponse ?? {});
  }

  @override
  Future<Map<String, dynamic>> getGameRound(
    String convID,
    String roundID, {
    bool isChannel = false,
  }) async {
    return Map<String, dynamic>.from(joinResponse ?? {});
  }
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
