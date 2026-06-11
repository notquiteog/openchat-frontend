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

/// Revoting on a single-answer poll must MOVE the mark: after tapping a new
/// option, the previously selected option may not stay marked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const selfId = 'self-user';

  late SecureStorageService storage;
  late _FakeApi api;
  late _FakeWs ws;
  late ChatProvider provider;

  Message pollMessage({required bool anonymous}) => Message(
    id: 'msg-1',
    conversationId: 'conv-1',
    senderId: 'creator-1',
    type: MessageType.poll,
    encryptedPayload: '',
    signature: '',
    isEncrypted: false,
    createdAt: DateTime.utc(2026, 6, 11),
    poll: Poll(
      id: 'poll-1',
      messageId: 'msg-1',
      question: 'Where to?',
      type: 'regular',
      isAnonymous: anonymous,
      allowsMultipleAnswers: false,
      allowsRevoting: true,
      isClosed: false,
      totalVoterCount: 0,
      options: const [
        PollOption(id: 'opt-a', index: 0, text: 'Beach', voterCount: 0),
        PollOption(id: 'opt-b', index: 1, text: 'Hills', voterCount: 0),
      ],
    ),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'user_id': selfId});
    storage = SecureStorageService();
    api = _FakeApi(storage);
    ws = _FakeWs(storage);
    api.ws = ws;
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

  Future<void> pumpPoll(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: Scaffold(
            // Mirror the chat screen: rebuild the bubble from the provider's
            // current message on every notify.
            body: Consumer<ChatProvider>(
              builder: (context, chat, _) => MessageBubble(
                message: chat.messagesFor('conv-1').first,
                isMe: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder selectedIconIn(String optionText) => find.descendant(
    of: find.ancestor(
      of: find.text(optionText),
      matching: find.byType(InkWell),
    ),
    matching: find.byIcon(Icons.check_circle),
  );

  testWidgets('revote after restart moves the refetch-echoed mark',
      (tester) async {
    // Post-restart state for a non-anonymous poll: the refetched payload
    // echoes the old vote, and so does the device-local memory.
    await storage.savePollVoteSelections('poll-1', ['opt-a']);
    final msg = pollMessage(anonymous: false);
    provider.debugSeedMessages('conv-1', [
      msg.copyWith(
        poll: msg.poll!.copyWith(
          voterOptionIds: ['opt-a'],
          options: const [
            PollOption(id: 'opt-a', index: 0, text: 'Beach', voterCount: 1),
            PollOption(id: 'opt-b', index: 1, text: 'Hills', voterCount: 0),
          ],
        ),
      ),
    ]);
    api.serverVotes = ['opt-a'];
    await pumpPoll(tester);
    expect(selectedIconIn('Beach'), findsOneWidget);

    await tester.tap(find.text('Hills'));
    await tester.pumpAndSettle();
    expect(selectedIconIn('Hills'), findsOneWidget);
    expect(selectedIconIn('Beach'), findsNothing,
        reason: 'old selection must be unmarked after revoting');
    expect(await storage.getPollVoteSelections('poll-1'), ['opt-b']);
  });

  for (final anonymous in [false, true]) {
    testWidgets(
      'revote moves the mark (anonymous: $anonymous)',
      (tester) async {
        if (anonymous) {
          await storage.savePollVoteToken('poll-1', 'blind-token');
        }
        provider.debugSeedMessages('conv-1', [
          pollMessage(anonymous: anonymous),
        ]);
        await pumpPoll(tester);

        await tester.tap(find.text('Beach'));
        await tester.pumpAndSettle();
        expect(selectedIconIn('Beach'), findsOneWidget);
        expect(selectedIconIn('Hills'), findsNothing);

        await tester.tap(find.text('Hills'));
        await tester.pumpAndSettle();
        expect(selectedIconIn('Hills'), findsOneWidget,
            reason: 'new selection must be marked');
        expect(selectedIconIn('Beach'), findsNothing,
            reason: 'old selection must be unmarked after revoting');

        // The marked state the next session would restore from storage.
        expect(await storage.getPollVoteSelections('poll-1'), ['opt-b']);
      },
    );
  }

  // ── Channel-shaped hosts ────────────────────────────────────────────────
  // The channel screen renders posts from a screen-local list that is loaded
  // once and never refreshed from ChatProvider — the bubble must still show
  // votes correctly via the provider's poll state.

  Future<void> pumpStaleHost(WidgetTester tester, Message msg) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: Scaffold(
            // Like channel _posts: the message object never changes.
            body: MessageBubble(message: msg, isMe: false, isChannel: true),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('channel: revote moves the stale refetch-echoed mark',
      (tester) async {
    // The post was fetched with the old vote echoed; the message is NOT in
    // ChatProvider._messages (channels keep their own post list).
    await storage.savePollVoteSelections('poll-1', ['opt-a']);
    api.serverVotes = ['opt-a'];
    final msg = pollMessage(anonymous: false);
    await pumpStaleHost(
      tester,
      msg.copyWith(
        poll: msg.poll!.copyWith(
          voterOptionIds: ['opt-a'],
          options: const [
            PollOption(id: 'opt-a', index: 0, text: 'Beach', voterCount: 1),
            PollOption(id: 'opt-b', index: 1, text: 'Hills', voterCount: 0),
          ],
        ),
      ),
    );
    expect(selectedIconIn('Beach'), findsOneWidget);

    await tester.tap(find.text('Hills'));
    await tester.pumpAndSettle();
    expect(selectedIconIn('Hills'), findsOneWidget,
        reason: 'new selection must be marked');
    expect(selectedIconIn('Beach'), findsNothing,
        reason: 'old selection must be unmarked after revoting');
  });

  testWidgets('channel: anonymous poll votes through the blind-token path',
      (tester) async {
    api.anonymousPoll = true;
    await storage.savePollVoteToken('poll-1', 'blind-token');
    await pumpStaleHost(tester, pollMessage(anonymous: true));

    await tester.tap(find.text('Beach'));
    await tester.pumpAndSettle();
    // The provider can't see the message (not in its list) — it must still
    // pick the anonymous endpoint, not the attributed one (which the server
    // rejects for anonymous polls).
    expect(api.attributedVoteCalls, 0);
    expect(selectedIconIn('Beach'), findsOneWidget);
  });

  testWidgets('channel: poll_updated broadcast refreshes tallies',
      (tester) async {
    await pumpStaleHost(tester, pollMessage(anonymous: false));
    expect(find.text('0%'), findsNWidgets(2));

    // Another member votes — the conversation has no messages loaded in the
    // provider, but the broadcast must still reach the rendered bubble.
    api.serverVotes = ['opt-a'];
    ws.handleRawFrame(
      jsonEncode({
        'type': 'poll_updated',
        'data': {
          'conversation_id': 'conv-1',
          'message_id': 'msg-1',
          'poll_id': 'poll-1',
          'poll': api.pollJson(voter: const []),
        },
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);
  });
}

// ── Fakes ────────────────────────────────────────────────────────────────────

/// Mimics the server: votes replace the user's previous votes, the WS
/// pollUpdated broadcast (voter ids stripped) goes out BEFORE the HTTP
/// response resolves, and the response echoes only the new selection.
class _FakeApi extends ApiService {
  _FakeApi(super.storage);

  late _FakeWs ws;
  List<String> serverVotes = [];
  bool anonymousPoll = false;
  int attributedVoteCalls = 0;

  @override
  Future<List<Conversation>> listConversations() async => const [];

  Map<String, dynamic> pollJson({required List<String> voter}) => {
    'id': 'poll-1',
    'message_id': 'msg-1',
    'question': 'Where to?',
    'type': 'regular',
    'is_anonymous': anonymousPoll,
    'allows_multiple_answers': false,
    'allows_revoting': true,
    'total_voter_count': 1,
    'options': [
      {
        'id': 'opt-a',
        'option_index': 0,
        'text': 'Beach',
        'voter_count': serverVotes.contains('opt-a') ? 1 : 0,
      },
      {
        'id': 'opt-b',
        'option_index': 1,
        'text': 'Hills',
        'voter_count': serverVotes.contains('opt-b') ? 1 : 0,
      },
    ],
    if (voter.isNotEmpty) 'voter_option_ids': voter,
  };

  Poll _vote(List<String> optionIDs, {required bool echoVoter}) {
    serverVotes = List.of(optionIDs); // replace previous votes
    ws.handleRawFrame(
      jsonEncode({
        'type': 'poll_updated',
        'data': {
          'conversation_id': 'conv-1',
          'message_id': 'msg-1',
          'poll_id': 'poll-1',
          'poll': pollJson(voter: const []),
        },
      }),
    );
    return Poll.fromJson(
      pollJson(voter: echoVoter ? optionIDs : const []),
    );
  }

  @override
  Future<Poll> votePoll(String pollID, List<String> optionIDs) async {
    attributedVoteCalls++;
    if (anonymousPoll) {
      // The real server refuses attributed votes on anonymous polls.
      throw Exception('anonymous poll requires a vote token');
    }
    return _vote(optionIDs, echoVoter: true);
  }

  @override
  Future<Poll> votePollAnonymous(
    String pollID,
    String token,
    List<String> optionIDs,
  ) async =>
      // The server can't attribute anonymous votes, so it can't echo them.
      _vote(optionIDs, echoVoter: false);
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
