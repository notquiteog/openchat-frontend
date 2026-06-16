import 'dart:io';

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

/// #24 — the offline outbox must recover stuck items: drainOutbox() bails on the
/// first retryable failure, so a connectivity-regain kick (and a retry timer)
/// are what stop a transient error from stranding a queued message forever.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SecureStorageService storage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'user_id': 'self'});
    storage = SecureStorageService();
  });

  OfflineOutboxItem queuedSealed() => OfflineOutboxItem(
    id: 'ob-1',
    action: OfflineOutboxAction.sendMessage,
    conversationId: 'conv-1',
    createdAt: DateTime.utc(2026, 6, 15),
    data: const {
      'post_token': 'tok-1',
      'encrypted_payload': 'cipher',
      'is_encrypted': true,
      'pending_message_id': 'pm-1',
    },
  );

  ChatProvider build(NetworkService net, OfflineOutboxService outbox,
      ApiService api) {
    return ChatProvider(
      api,
      storage,
      _FakeWs(storage),
      SettingsProvider(),
      MlsService(storage),
      net,
      searchService: _NoopSearch(storage),
      cacheService: _NoopCache(storage),
      outboxService: outbox,
    );
  }

  test('connectivity regain (none -> online) kicks an outbox drain', () async {
    final net = _FakeNetwork(NetworkClass.none);
    final api = _CountingApi(storage);
    final provider = build(net, _MemOutbox(storage, [queuedSealed()]), api);
    addTearDown(provider.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 10)); // _loadOutbox

    expect(provider.pendingOutboxCount, 1);
    expect(api.sealedSendCount, 0,
        reason: 'nothing should drain while offline with no trigger');

    net.set(NetworkClass.wifi); // regain
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(api.sealedSendCount, greaterThanOrEqualTo(1),
        reason: 'a none->online transition must kick a drain');
    expect(provider.pendingOutboxCount, 1,
        reason: 'a retryable failure must keep the item queued for retry');
  });

  test('a successful retry delivers and clears the queued item', () async {
    final net = _FakeNetwork(NetworkClass.wifi);
    final api = _FlakyApi(storage, failures: 1); // fail once, then succeed
    final outbox = _MemOutbox(storage, [queuedSealed()]);
    final provider = build(net, outbox, api);
    addTearDown(provider.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // First drain hits the retryable failure and leaves the item queued.
    await provider.drainOutbox();
    expect(api.sealedSendCount, 1);
    expect(provider.pendingOutboxCount, 1);

    // A subsequent drain (what the retry timer / regain kick triggers) succeeds.
    await provider.drainOutbox();
    expect(api.sealedSendCount, 2);
    expect(provider.pendingOutboxCount, 0,
        reason: 'the item must be removed once it finally delivers');
  });
}

// ── Fakes ────────────────────────────────────────────────────────────────────

class _FakeWs extends WebSocketService {
  _FakeWs(super.storage);
  @override
  Future<void> connect() async {}
  @override
  void disconnect() {}
}

class _FakeNetwork extends NetworkService {
  _FakeNetwork(this._c);
  NetworkClass _c;
  @override
  NetworkClass get current => _c;
  @override
  Future<void> init() async {}
  void set(NetworkClass c) {
    _c = c;
    notifyListeners();
  }
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
    _items = _items.where((i) => i.id != id).toList();
  }
}

class _CountingApi extends ApiService {
  _CountingApi(super.storage);
  int sealedSendCount = 0;
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
    sealedSendCount++;
    throw const SocketException('offline'); // retryable
  }
}

class _FlakyApi extends ApiService {
  _FlakyApi(super.storage, {required this.failures});
  int failures;
  int sealedSendCount = 0;
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
    sealedSendCount++;
    if (failures-- > 0) {
      throw const SocketException('transient');
    }
    return Message(
      id: 'pm-1',
      conversationId: convID,
      senderId: '',
      type: MessageType.text,
      encryptedPayload: encryptedPayload,
      signature: '',
      isEncrypted: true,
      createdAt: DateTime.utc(2026, 6, 15),
    );
  }
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
