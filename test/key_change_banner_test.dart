import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/models/key_trust_pin.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/providers/auth_provider.dart';
import 'package:openchat/providers/chat_provider.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/providers/smp_provider.dart';
import 'package:openchat/screens/settings/smp_verify_screen.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/message_cache_service.dart';
import 'package:openchat/services/message_search_service.dart';
import 'package:openchat/services/mls_service.dart';
import 'package:openchat/services/network_service.dart';
import 'package:openchat/services/offline_outbox_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:openchat/widgets/key_change_banner.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SecureStorageService storage;
  late _FakeApi api;
  late ChatProvider chat;
  late SmpProvider smp;
  late AuthProvider auth;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storage = SecureStorageService();
    api = _FakeApi(storage);
    chat = ChatProvider(
      api,
      storage,
      _FakeWs(storage),
      SettingsProvider(),
      MlsService(storage),
      NetworkService(),
      searchService: _NoopSearch(storage),
      cacheService: _NoopCache(storage),
      outboxService: _NoopOutbox(storage),
    );
    smp = SmpProvider(chat: chat, storage: storage);
    auth = AuthProvider(api, storage);
  });

  tearDown(() {
    smp.dispose();
    chat.dispose();
    auth.dispose();
  });

  Future<void> seedPin({String? warning, String? verifiedVia}) async {
    await storage.saveKeyTrustPin(
      KeyTrustPin(
        userId: 'peer',
        fingerprint: 'PEERFINGERPRINT',
        publicKeyHash: 'hash',
        warning: warning,
        pinnedAt: DateTime.utc(2026, 1, 1),
        verifiedVia: verifiedVia,
      ),
    );
  }

  Future<void> pumpBanner(
    WidgetTester tester,
    Conversation conversation,
  ) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiService>.value(value: api),
          Provider<SecureStorageService>.value(value: storage),
          ChangeNotifierProvider<ChatProvider>.value(value: chat),
          ChangeNotifierProvider<SmpProvider>.value(value: smp),
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: KeyChangeBanner(
              conversation: conversation,
              currentUserId: 'self',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows warning banner for an unverified changed DM key', (
    tester,
  ) async {
    await seedPin(warning: 'Unexplained key replacement');
    await pumpBanner(tester, _dmConversation());

    expect(find.textContaining('safety number changed'), findsOneWidget);
    expect(find.text('Verify'), findsOneWidget);
  });

  testWidgets('hides when the changed key has been verified', (tester) async {
    await seedPin(warning: 'Unexplained key replacement', verifiedVia: 'smp');
    await pumpBanner(tester, _dmConversation());

    expect(find.textContaining('safety number changed'), findsNothing);
  });

  testWidgets('hides for non-DM conversations', (tester) async {
    await seedPin(warning: 'Unexplained key replacement');
    await pumpBanner(tester, _groupConversation());

    expect(find.textContaining('safety number changed'), findsNothing);
  });

  testWidgets('dismiss hides the banner for the current chat session', (
    tester,
  ) async {
    await seedPin(warning: 'Unexplained key replacement');
    await pumpBanner(tester, _dmConversation());

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();

    expect(find.textContaining('safety number changed'), findsNothing);
  });

  testWidgets('verify opens SMP verification with the contact flow', (
    tester,
  ) async {
    await seedPin(warning: 'Unexplained key replacement');
    await pumpBanner(tester, _dmConversation());

    await tester.tap(find.text('Verify'));
    await tester.pumpAndSettle();

    expect(find.byType(SmpVerifyScreen), findsOneWidget);
    expect(find.text('Start a verification'), findsOneWidget);
  });
}

Conversation _dmConversation() {
  final now = DateTime.utc(2026, 6, 15);
  return Conversation(
    id: 'conv-1',
    type: ConversationType.dm,
    createdAt: now,
    createdBy: 'self',
    members: [
      ConversationMember(
        conversationId: 'conv-1',
        userId: 'self',
        role: MemberRole.member,
        joinedAt: now,
        user: _user('self', 'me', 'Me'),
      ),
      ConversationMember(
        conversationId: 'conv-1',
        userId: 'peer',
        role: MemberRole.member,
        joinedAt: now,
        user: _user('peer', 'bee', 'Bee'),
      ),
    ],
  );
}

Conversation _groupConversation() {
  final now = DateTime.utc(2026, 6, 15);
  return Conversation(
    id: 'group-1',
    type: ConversationType.group,
    name: 'Group',
    createdAt: now,
    createdBy: 'self',
    members: [
      ConversationMember(
        conversationId: 'group-1',
        userId: 'self',
        role: MemberRole.member,
        joinedAt: now,
        user: _user('self', 'me', 'Me'),
      ),
      ConversationMember(
        conversationId: 'group-1',
        userId: 'peer',
        role: MemberRole.member,
        joinedAt: now,
        user: _user('peer', 'bee', 'Bee'),
      ),
    ],
  );
}

User _user(String id, String username, String displayName) => User(
  id: id,
  username: username,
  profileDisplayName: displayName,
  publicKey: 'PUBLIC-$id',
  keyFingerprint: 'FINGERPRINT-$id',
  createdAt: DateTime.utc(2026, 1, 1),
);

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
