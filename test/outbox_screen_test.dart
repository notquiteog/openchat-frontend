import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/providers/auth_provider.dart';
import 'package:openchat/providers/chat_provider.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/screens/settings/outbox_screen.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/message_cache_service.dart';
import 'package:openchat/services/message_search_service.dart';
import 'package:openchat/services/mls_service.dart';
import 'package:openchat/services/network_service.dart';
import 'package:openchat/services/offline_outbox_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SecureStorageService storage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'user_id': 'self-user'});
    storage = SecureStorageService();
  });

  OfflineOutboxItem item({
    required String id,
    required OfflineOutboxAction action,
    OfflineOutboxStatus status = OfflineOutboxStatus.queued,
    int attempts = 0,
    String? lastError,
  }) => OfflineOutboxItem(
    id: id,
    action: action,
    conversationId: 'conv-1',
    createdAt: DateTime.utc(2026, 6, 15, 12, id.endsWith('2') ? 2 : 1),
    status: status,
    attempts: attempts,
    lastError: lastError,
    data: const {
      'post_token': 'tok-1',
      'encrypted_payload': 'cipher',
      'is_encrypted': true,
      'pending_message_id': 'pm-1',
    },
  );

  ChatProvider buildProvider(_MemOutbox outbox) {
    return ChatProvider(
      _FakeApi(storage),
      storage,
      _FakeWs(storage),
      SettingsProvider(),
      MlsService(storage),
      NetworkService(),
      searchService: _NoopSearch(storage),
      cacheService: _NoopCache(storage),
      outboxService: outbox,
    );
  }

  Widget wrap(ChatProvider provider) {
    final api = _FakeApi(storage);
    return MultiProvider(
      providers: [
        Provider<SecureStorageService>.value(value: storage),
        Provider<ApiService>.value(value: api),
        ChangeNotifierProvider<AuthProvider>.value(
          value: _FakeAuthProvider(_user(), api, storage),
        ),
        ChangeNotifierProvider<ChatProvider>.value(value: provider),
      ],
      child: const MaterialApp(home: OutboxScreen()),
    );
  }

  testWidgets('renders grouped queued and failed items with errors', (
    tester,
  ) async {
    final provider = buildProvider(
      _MemOutbox(storage, [
        item(
          id: 'ob-1',
          action: OfflineOutboxAction.sendMessage,
          status: OfflineOutboxStatus.failed,
          attempts: 3,
          lastError: 'ApiException(400): VALIDATION_ERROR',
        ),
        item(id: 'ob-2', action: OfflineOutboxAction.attachmentUpload),
      ]),
    );
    addTearDown(provider.dispose);

    await tester.pumpWidget(wrap(provider));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('Unknown conversation'), findsOneWidget);
    expect(find.text('Message'), findsOneWidget);
    expect(find.text('Attachment'), findsOneWidget);
    expect(find.textContaining('Failed - 3 attempts'), findsOneWidget);
    expect(
      find.textContaining('ApiException(400): VALIDATION_ERROR'),
      findsOneWidget,
    );
    expect(find.textContaining('Queued - 0 attempts'), findsOneWidget);
    expect(find.byTooltip('Clear all'), findsOneWidget);
  });

  testWidgets('empty outbox renders empty state and no clear action', (
    tester,
  ) async {
    final provider = buildProvider(_MemOutbox(storage, const []));
    addTearDown(provider.dispose);

    await tester.pumpWidget(wrap(provider));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('Outbox is clear'), findsOneWidget);
    expect(find.text('Nothing waiting to send'), findsOneWidget);
    expect(find.byTooltip('Clear all'), findsNothing);
  });

  testWidgets('discard action removes the selected outbox item', (
    tester,
  ) async {
    final provider = buildProvider(
      _MemOutbox(storage, [
        item(
          id: 'ob-1',
          action: OfflineOutboxAction.sendMessage,
          status: OfflineOutboxStatus.failed,
          attempts: 3,
          lastError: 'bad request',
        ),
      ]),
    );
    addTearDown(provider.dispose);

    await tester.pumpWidget(wrap(provider));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    await tester.tap(find.text('Message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard').last);
    await tester.pumpAndSettle();
    expect(find.text('Discard item?'), findsOneWidget);

    await tester.tap(find.text('Discard').last);
    await tester.pumpAndSettle();

    expect(provider.pendingOutboxCount, 0);
    expect(find.text('Outbox is clear'), findsOneWidget);
  });

  test('retryOutboxItem requeues and persists a failed item', () async {
    final outbox = _MemOutbox(storage, [
      item(
        id: 'ob-1',
        action: OfflineOutboxAction.sendMessage,
        status: OfflineOutboxStatus.failed,
        attempts: 4,
        lastError: 'validation failed',
      ),
    ]);
    final provider = buildProvider(outbox);
    addTearDown(provider.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await provider.retryOutboxItem('ob-1');

    expect(provider.outboxItems.single.status, OfflineOutboxStatus.queued);
    expect(provider.outboxItems.single.attempts, 0);
    expect(provider.outboxItems.single.lastError, isNull);
    final persisted = await outbox.list();
    expect(persisted.single.status, OfflineOutboxStatus.queued);
    expect(persisted.single.attempts, 0);
    expect(persisted.single.lastError, isNull);
  });

  test('clearOutbox clears provider state and persisted store', () async {
    final outbox = _MemOutbox(storage, [
      item(id: 'ob-1', action: OfflineOutboxAction.sendMessage),
      item(id: 'ob-2', action: OfflineOutboxAction.reaction),
    ]);
    final provider = buildProvider(outbox);
    addTearDown(provider.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await provider.clearOutbox();

    expect(provider.outboxItems, isEmpty);
    expect(provider.pendingOutboxCount, 0);
    expect(await outbox.list(), isEmpty);
  });
}

class _MemOutbox extends OfflineOutboxService {
  _MemOutbox(super.storage, this._items);

  List<OfflineOutboxItem> _items;

  @override
  Future<List<OfflineOutboxItem>> list() async => List.of(_items);

  @override
  Future<void> replaceAll(List<OfflineOutboxItem> items) async {
    _items = List.of(items);
  }

  @override
  Future<void> remove(String id) async {
    _items = _items.where((item) => item.id != id).toList();
  }

  @override
  Future<void> clearAll() async {
    _items = const [];
  }
}

class _FakeApi extends ApiService {
  _FakeApi(super.storage);

  @override
  Future<Message> sendSealedMessage({
    required String convID,
    required String encryptedPayload,
    required String postToken,
    String? replyTo,
    String? attachmentId,
    String? topicId,
    bool silent = false,
    String? clientNonce,
    String? frankCom,
    String? postTokenSignature,
    String? postTokenKeyId,
  }) async {
    throw const SocketException('offline');
  }
}

class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider(this._user, ApiService api, SecureStorageService storage)
    : super(api, storage);

  final User _user;

  @override
  User? get currentUser => _user;
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

User _user() => User(
  id: 'self-user',
  username: 'maya',
  publicKey: 'PUBLIC',
  keyFingerprint: 'FINGERPRINT',
  createdAt: DateTime.utc(2026, 6, 1),
);
