import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/providers/auth_provider.dart';
import 'package:openchat/providers/chat_provider.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/message_search_service.dart';
import 'package:openchat/services/mls_service.dart';
import 'package:openchat/services/network_service.dart';
import 'package:openchat/services/offline_outbox_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:openchat/widgets/chat_search_results_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Leaf-level coverage for the shared search results view (the full screen
// can't be pumped — ChatProvider opens sockets). Queries shorter than two
// characters never touch providers, so the idle/hint state is testable.
void main() {
  Future<void> pump(WidgetTester tester, String query) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatSearchResultsView(query: query, onSelect: (_) {}),
        ),
      ),
    );
  }

  testWidgets('empty query shows the search hint', (tester) async {
    await pump(tester, '');
    expect(
      find.text('Search users, channels, and local messages'),
      findsOneWidget,
    );
  });

  testWidgets('single-character query still shows the hint', (tester) async {
    await pump(tester, 'a');
    expect(
      find.text('Search users, channels, and local messages'),
      findsOneWidget,
    );
  });

  test('selection types carry their payloads', () {
    const user = UserSearchSelection('user-1');
    expect(user.userID, 'user-1');
    // The sealed hierarchy is what the home shell switches on.
    expect(user, isA<ChatSearchSelection>());

    final group = GroupSearchSelection(_conversation('group-1', 'Group'));
    expect(group.group.id, 'group-1');
  });

  testWidgets('entity sections render before local messages', (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'user_id': 'self'});
    final storage = SecureStorageService();
    final api = _SearchApi(storage);
    final settings = SettingsProvider();
    await settings.load();
    final chat = ChatProvider(
      api,
      storage,
      _FakeWs(storage),
      settings,
      MlsService(storage),
      _FakeNetwork(),
      searchService: _FakeMessageSearch(storage),
      outboxService: _FakeOutbox(storage),
    );
    chat.debugSeedConversation(
      _conversation(
        'group-alpine',
        'Alpine Group',
        type: ConversationType.group,
      ),
    );
    chat.debugSeedConversation(
      _conversation(
        'channel-alpine',
        'Alpine Channel',
        type: ConversationType.channel,
        handle: 'alpine',
      ),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiService>.value(value: api),
          ChangeNotifierProvider<AuthProvider>.value(
            value: _FakeAuthProvider(_user('self', 'me'), api, storage),
          ),
          ChangeNotifierProvider<ChatProvider>.value(value: chat),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ChatSearchResultsView(query: 'alp', onSelect: (_) {}),
          ),
        ),
      ),
    );
    await tester.pump();

    final peopleY = tester.getTopLeft(find.text('People and bots')).dy;
    final groupsY = tester.getTopLeft(find.text('Groups')).dy;
    final channelsY = tester.getTopLeft(find.text('Channels')).dy;
    final messagesY = tester
        .getTopLeft(find.text('Messages on this device'))
        .dy;

    expect(peopleY, lessThan(groupsY));
    expect(groupsY, lessThan(channelsY));
    expect(channelsY, lessThan(messagesY));
    expect(find.text('Remote Alpine Group'), findsOneWidget);
  });
}

User _user(String id, String username, {bool isBot = false}) => User(
  id: id,
  username: username,
  publicKey: 'pub-$id',
  keyFingerprint: 'fingerprint-$id',
  isBot: isBot,
  createdAt: DateTime(2026),
);

Conversation _conversation(
  String id,
  String name, {
  ConversationType type = ConversationType.group,
  String? handle,
}) => Conversation(
  id: id,
  type: type,
  name: name,
  handle: handle,
  isPublic: type == ConversationType.channel,
  createdAt: DateTime(2026),
  createdBy: 'self',
);

class _SearchApi extends ApiService {
  _SearchApi(super.storage);

  @override
  Future<List<User>> searchUsers(String query) async => [
    _user('alice', 'alice'),
  ];

  @override
  Future<List<Conversation>> searchChannels(
    String query, {
    bool includeGroups = false,
  }) async => [
    _conversation(
      'remote-channel',
      'Alpine Broadcast',
      type: ConversationType.channel,
      handle: 'alpine-broadcast',
    ),
    if (includeGroups)
      _conversation(
        'remote-group',
        'Remote Alpine Group',
        type: ConversationType.group,
      ),
  ];
}

class _FakeMessageSearch extends MessageSearchService {
  _FakeMessageSearch(super.storage);

  @override
  Future<List<MessageSearchResult>> search(
    String query, {
    String? conversationId,
    String? senderId,
    DateTime? from,
    DateTime? to,
    Set<MessageSearchCategory>? categories,
    int limit = 40,
  }) async => [
    MessageSearchResult(
      messageId: 'msg-1',
      conversationId: 'group-alpine',
      senderId: 'alice',
      messageType: MessageType.text,
      category: MessageSearchCategory.messages,
      createdAt: DateTime(2026),
      title: 'Alpine message',
      snippet: 'A message hit',
    ),
  ];
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

class _FakeNetwork extends NetworkService {
  @override
  NetworkClass get current => NetworkClass.wifi;

  @override
  Future<void> init() async {}
}

class _FakeOutbox extends OfflineOutboxService {
  _FakeOutbox(super.storage);

  @override
  Future<List<OfflineOutboxItem>> list() async => const [];
}
