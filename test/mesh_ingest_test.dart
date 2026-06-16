import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/models/user.dart';
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

/// Mesh ingest invariants: an envelope from a verified peer only lands in
/// THAT peer's existing DM, retransmits dedup, and the eventual server copy
/// replaces the mesh copy instead of doubling the message.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const selfId = 'self-user';
  const peerFp = 'AAAA1111BBBB2222';

  late ChatProvider provider;

  Conversation dmWith({
    required String convId,
    required String peerId,
    required String fingerprint,
  }) => Conversation(
    id: convId,
    type: ConversationType.dm,
    createdAt: DateTime.utc(2026, 6, 1),
    createdBy: selfId,
    members: [
      ConversationMember(
        conversationId: convId,
        userId: selfId,
        role: MemberRole.member,
        joinedAt: DateTime.utc(2026, 6, 1),
        user: User(
          id: selfId,
          username: 'me',
          publicKey: 'KEY:me',
          keyFingerprint: 'SELF0000',
          createdAt: DateTime.utc(2026),
        ),
      ),
      ConversationMember(
        conversationId: convId,
        userId: peerId,
        role: MemberRole.member,
        joinedAt: DateTime.utc(2026, 6, 1),
        user: User(
          id: peerId,
          username: 'peer',
          publicKey: 'KEY:peer',
          keyFingerprint: fingerprint,
          createdAt: DateTime.utc(2026),
        ),
      ),
    ],
  );

  Map<String, dynamic> envelope({String nonce = 'n1', String conv = 'dm-1'}) =>
      {
        'conversation_id': conv,
        'encrypted_payload': 'CIPHERTEXT-$nonce',
        'signature': 'sig',
        'message_type': 'text',
        'client_nonce': nonce,
        'created_at': '2026-06-11T12:00:00.000Z',
      };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'user_id': selfId});
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
    provider.debugSeedConversation(
      dmWith(convId: 'dm-1', peerId: 'peer-1', fingerprint: peerFp),
    );
    provider.debugSeedMessages('dm-1', const []);
  });

  tearDown(() => provider.dispose());

  test('resolves the DM by the peer key fingerprint', () {
    expect(provider.dmConversationIdForFingerprint(peerFp), 'dm-1');
    expect(provider.dmConversationIdForFingerprint('UNKNOWN'), isNull);
  });

  test('accepts an envelope into the verified peer DM exactly once', () async {
    expect(await provider.ingestMeshMessage(envelope(), peerFp), isTrue);
    var msgs = provider.messagesFor('dm-1');
    expect(msgs, hasLength(1));
    expect(msgs.single.id, 'mesh-n1');

    // Retransmit (BLE links flap): no duplicate.
    expect(await provider.ingestMeshMessage(envelope(), peerFp), isTrue);
    msgs = provider.messagesFor('dm-1');
    expect(msgs, hasLength(1));
  });

  test('rejects envelopes aimed at conversations the peer is not in', () async {
    provider.debugSeedConversation(
      dmWith(convId: 'dm-2', peerId: 'peer-2', fingerprint: 'OTHERFP9'),
    );
    provider.debugSeedMessages('dm-2', const []);
    // Verified peer (peerFp) tries to inject into dm-2.
    expect(
      await provider.ingestMeshMessage(envelope(conv: 'dm-2'), peerFp),
      isFalse,
    );
    expect(provider.messagesFor('dm-2'), isEmpty);
    // Unknown conversation entirely.
    expect(
      await provider.ingestMeshMessage(envelope(conv: 'nope'), peerFp),
      isFalse,
    );
  });

  test('the server copy later replaces the mesh copy (no doubles)', () async {
    await provider.ingestMeshMessage(envelope(), peerFp);
    expect(provider.messagesFor('dm-1').single.id, 'mesh-n1');

    // Connectivity returns; the same logical message arrives from the server
    // with a real id but the identical encrypted payload.
    final serverCopy = Message(
      id: 'server-uuid-1',
      conversationId: 'dm-1',
      senderId: '',
      type: MessageType.text,
      encryptedPayload: 'CIPHERTEXT-n1',
      signature: 'sig',
      isEncrypted: true,
      createdAt: DateTime.utc(2026, 6, 11, 12),
    );
    await provider.debugHandleIncomingMessage(serverCopy);

    final msgs = provider.messagesFor('dm-1');
    expect(msgs, hasLength(1), reason: 'mesh copy must be replaced, not kept');
    expect(msgs.single.id, 'server-uuid-1');
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
  ) => Future.value();
}

class _NoopOutbox extends OfflineOutboxService {
  _NoopOutbox(super.storage);

  @override
  Future<List<OfflineOutboxItem>> list() => Future.value(const []);
}
