import 'dart:convert';

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
import 'package:shared_preferences/shared_preferences.dart';

/// Regression suite for the "open and close the app → every sent MLS message
/// shows unknown sender + Unable to decrypt" bug. MLS sender-ratchet keys are
/// consumed at encrypt time, so the author can NEVER re-decrypt their own
/// ciphertext: the only durable copy of a sent/edited message's plaintext is
/// the message cache. These tests pin the cache writes on every author-side
/// path.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const selfId = 'self-user';

  late SecureStorageService storage;
  late _RecordingCache cache;
  late _FakeApi api;
  late ChatProvider provider;

  Conversation conv({required EncryptionMode mode}) => Conversation(
    id: 'conv-1',
    type: ConversationType.group,
    name: 'Ops',
    createdAt: DateTime.utc(2026, 6, 1),
    createdBy: selfId,
    encryptionMode: mode,
  );

  Message confirmedMessage({
    String id = 'msg-1',
    String payload = 'mls-cipher-1',
    String senderId = selfId,
  }) => Message(
    id: id,
    conversationId: 'conv-1',
    senderId: senderId,
    type: MessageType.text,
    encryptedPayload: payload,
    signature: '',
    isEncrypted: true,
    createdAt: DateTime.utc(2026, 6, 2),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'user_id': selfId});
    storage = SecureStorageService();
    cache = _RecordingCache(storage);
    api = _FakeApi(storage);
    provider = ChatProvider(
      api,
      storage,
      _FakeWs(storage),
      SettingsProvider(),
      _FakeMls(storage),
      searchService: _NoopSearch(storage),
      cacheService: cache,
      outboxService: _NoopOutbox(storage),
    );
    // Let the constructor's async _selfId load settle.
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() => provider.dispose());

  test('confirmed MLS send persists plaintext to the durable cache', () {
    provider.debugSeedConversation(conv(mode: EncryptionMode.mls));

    provider.debugReplacePendingWithConfirmed(
      convID: 'conv-1',
      pendingID: 'pending-1',
      confirmed: confirmedMessage(),
      plaintextPayload: 'hello world',
    );

    expect(cache.puts, hasLength(1));
    final put = cache.puts.single;
    expect(put.messageId, 'msg-1');
    expect(put.conversationId, 'conv-1');
    expect(put.encryptedPayload, 'mls-cipher-1');
    expect(put.plaintext, 'hello world');
    expect(put.senderId, selfId);
  });

  test('confirmed PGP send does not write the MLS cache', () {
    provider.debugSeedConversation(conv(mode: EncryptionMode.pgp));

    provider.debugReplacePendingWithConfirmed(
      convID: 'conv-1',
      pendingID: 'pending-1',
      confirmed: confirmedMessage(),
      plaintextPayload: 'hello world',
    );

    expect(cache.puts, isEmpty);
  });

  test('restart restore: loadMessages hydrates a sent MLS message from cache',
      () async {
    provider.debugSeedConversation(conv(mode: EncryptionMode.mls));
    // Simulate the pre-restart session having cached the sent plaintext. In
    // production the cached value is the full signed openchat_message
    // envelope (what _signedPgpCleartextPayload built at send time) — the
    // wrapped shape is what lets restore re-apply the verified sender.
    final wrappedEnvelope = jsonEncode({
      'openchat_message': 1,
      'type': 'text',
      'payload': 'hello world',
      'sender': {
        'id': selfId,
        'key_fingerprint': 'F' * 40,
        'signature': 'sig',
        'created_at': DateTime.utc(2026, 6, 2).toIso8601String(),
      },
    });
    await cache.put('msg-1', 'conv-1', 'mls-cipher-1', wrappedEnvelope, selfId);
    // Sealed sender: the refetched message carries no sender id.
    api.messages = [confirmedMessage(senderId: '')];

    await provider.loadMessages('conv-1');

    final restored = provider.messagesFor('conv-1').single;
    expect(restored.isDecrypted, isTrue,
        reason: 'restart must restore the sent plaintext from cache, '
            'never re-attempt the impossible MLS self-decrypt');
    expect(restored.decryptedContent, 'hello world');
    expect(restored.senderId, selfId, reason: 'no "unknown sender"');
  });

  test('own MLS edit echoed from a sibling device re-caches kept plaintext',
      () async {
    provider.debugSeedConversation(conv(mode: EncryptionMode.mls));
    provider.debugReplacePendingWithConfirmed(
      convID: 'conv-1',
      pendingID: 'pending-1',
      confirmed: confirmedMessage(),
      plaintextPayload: 'hello world',
    );
    cache.puts.clear();

    // The edit arrives with new ciphertext we cannot decrypt (own message).
    await provider.debugHandleEditedMessage(
      confirmedMessage(payload: 'mls-cipher-2'),
    );

    expect(cache.deletes, contains('msg-1'),
        reason: 'stale pre-edit entry must be invalidated');
    expect(cache.puts, hasLength(1),
        reason: 'kept plaintext must be re-persisted under the new '
            'fingerprint or restart loses the message');
    final put = cache.puts.single;
    expect(put.encryptedPayload, 'mls-cipher-2');
    expect(put.plaintext, 'hello world');
    expect(put.senderId, selfId);
  });

  test("another member's undecryptable edit is NOT cached with stale text",
      () async {
    provider.debugSeedConversation(conv(mode: EncryptionMode.mls));
    provider.debugReplacePendingWithConfirmed(
      convID: 'conv-1',
      pendingID: 'pending-1',
      confirmed: confirmedMessage(senderId: 'other-user'),
      plaintextPayload: 'their original',
    );
    cache.puts.clear();

    await provider.debugHandleEditedMessage(
      confirmedMessage(payload: 'mls-cipher-2', senderId: 'other-user'),
    );

    expect(cache.puts, isEmpty,
        reason: 'a transient decrypt failure of someone else\'s edit must '
            'not freeze stale plaintext into the durable cache');
  });
}

// ── Fakes ────────────────────────────────────────────────────────────────────

class _PutCall {
  final String messageId;
  final String conversationId;
  final String encryptedPayload;
  final String plaintext;
  final String? senderId;
  _PutCall(
    this.messageId,
    this.conversationId,
    this.encryptedPayload,
    this.plaintext,
    this.senderId,
  );
}

/// In-memory cache mimicking the real fingerprint binding (entry only matches
/// while the ciphertext is unchanged) and recording every write.
class _RecordingCache extends MessageCacheService {
  _RecordingCache(super.storage);

  final puts = <_PutCall>[];
  final deletes = <String>[];
  final _entries = <String, _PutCall>{};

  @override
  Future<MessageCacheEntry?> get(String messageId, String encryptedPayload) {
    final entry = _entries[messageId];
    if (entry == null || entry.encryptedPayload != encryptedPayload) {
      return Future.value(null);
    }
    return Future.value(
      MessageCacheEntry(plaintext: entry.plaintext, senderId: entry.senderId),
    );
  }

  @override
  Future<void> put(
    String messageId,
    String conversationId,
    String encryptedPayload,
    String plaintext,
    String? senderId,
  ) {
    final call =
        _PutCall(messageId, conversationId, encryptedPayload, plaintext, senderId);
    puts.add(call);
    _entries[messageId] = call;
    return Future.value();
  }

  @override
  Future<void> delete(String messageId) {
    deletes.add(messageId);
    _entries.remove(messageId);
    return Future.value();
  }

  @override
  Future<void> deleteConversation(String conversationId) => Future.value();
}

class _FakeApi extends ApiService {
  _FakeApi(super.storage);

  List<Message> messages = const [];

  @override
  Future<List<Message>> getMessages(
    String convID, {
    String? beforeID,
    int limit = 50,
  }) async => messages;
}

class _FakeWs extends WebSocketService {
  _FakeWs(super.storage);

  @override
  Future<void> connect() async {}

  @override
  void disconnect() {}
}

class _FakeMls extends MlsService {
  _FakeMls(super.storage);

  @override
  Future<String?> decryptPayload({
    required ApiService api,
    required Conversation conversation,
    required String encryptedPayload,
  }) async => null; // The author can never decrypt their own MLS ciphertext.
}

class _NoopSearch extends MessageSearchService {
  _NoopSearch(super.storage);

  @override
  Future<void> indexMessage(Message message, {String? conversationTitle}) =>
      Future.value();
}

class _NoopOutbox extends OfflineOutboxService {
  _NoopOutbox(super.storage);

  @override
  Future<List<OfflineOutboxItem>> list() => Future.value(const []);
}
