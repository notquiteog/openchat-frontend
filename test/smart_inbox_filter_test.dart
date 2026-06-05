import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/utils/smart_inbox_filter.dart';
import 'package:shared_preferences/shared_preferences.dart';

Conversation _conversation({
  required String id,
  required ConversationType type,
  int unreadCount = 0,
  bool botDm = false,
  DateTime? createdAt,
  Message? lastMessage,
}) {
  final now = createdAt ?? DateTime.utc(2026, 1, 1);
  return Conversation(
    id: id,
    type: type,
    name: type == ConversationType.dm ? null : id,
    createdAt: now,
    createdBy: 'me',
    unreadCount: unreadCount,
    lastMessage: lastMessage,
    members: type == ConversationType.dm
        ? [
            ConversationMember(
              conversationId: id,
              userId: 'me',
              role: MemberRole.member,
              joinedAt: now,
            ),
            ConversationMember(
              conversationId: id,
              userId: 'other',
              role: MemberRole.member,
              joinedAt: now,
              user: User(
                id: 'other',
                username: botDm ? 'helperbot' : 'alice',
                publicKey: 'pub',
                keyFingerprint: 'fingerprint',
                isBot: botDm,
                createdAt: now,
              ),
            ),
          ]
        : const [],
  );
}

Message _message(String id, DateTime createdAt, {String? text}) {
  final message = Message(
    id: id,
    conversationId: 'conv',
    senderId: 'me',
    type: MessageType.text,
    encryptedPayload: 'cipher',
    signature: '',
    isEncrypted: text == null,
    createdAt: createdAt,
  );
  if (text != null) message.setDecryptedContent(text);
  return message;
}

void main() {
  test('available filters respect separate bot and channel tabs', () {
    expect(
      availableSmartInboxFilters(channelsOwnTab: false, botsOwnTab: false),
      containsAll([
        SmartInboxFilter.mentions,
        SmartInboxFilter.channels,
        SmartInboxFilter.bots,
      ]),
    );

    expect(
      availableSmartInboxFilters(channelsOwnTab: true, botsOwnTab: true),
      isNot(contains(SmartInboxFilter.channels)),
    );
    expect(
      availableSmartInboxFilters(channelsOwnTab: true, botsOwnTab: true),
      isNot(contains(SmartInboxFilter.bots)),
    );
    expect(
      availableSmartInboxFilters(
        channelsOwnTab: true,
        botsOwnTab: true,
        hasArchived: true,
      ),
      contains(SmartInboxFilter.archived),
    );
  });

  test('hidden selected filters fall back to all', () {
    expect(
      effectiveSmartInboxFilter(
        SmartInboxFilter.channels,
        channelsOwnTab: true,
        botsOwnTab: false,
      ),
      SmartInboxFilter.all,
    );
    expect(
      effectiveSmartInboxFilter(
        SmartInboxFilter.archived,
        channelsOwnTab: false,
        botsOwnTab: false,
        hasArchived: false,
      ),
      SmartInboxFilter.all,
    );
  });

  test(
    'conversation filters distinguish unread dms groups channels and bots',
    () {
      final dm = _conversation(id: 'dm', type: ConversationType.dm);
      final unreadDm = _conversation(
        id: 'unread',
        type: ConversationType.dm,
        unreadCount: 2,
      );
      final bot = _conversation(
        id: 'bot',
        type: ConversationType.dm,
        botDm: true,
      );
      final group = _conversation(id: 'group', type: ConversationType.group);
      final channel = _conversation(
        id: 'channel',
        type: ConversationType.channel,
      );
      final mentioned = _conversation(
        id: 'mentioned',
        type: ConversationType.group,
        unreadCount: 1,
        lastMessage: _message(
          'mentioned-message',
          DateTime.utc(2026, 1, 4),
          text: 'Ping @alice',
        ),
      );

      final conversations = [dm, unreadDm, bot, group, channel, mentioned];

      expect(
        conversations.where(
          (conversation) => conversationMatchesSmartInboxFilter(
            conversation,
            filter: SmartInboxFilter.dms,
            currentUserId: 'me',
          ),
        ),
        [dm, unreadDm],
      );
      expect(
        conversationMatchesSmartInboxFilter(
          unreadDm,
          filter: SmartInboxFilter.unread,
          currentUserId: 'me',
        ),
        isTrue,
      );
      expect(
        conversationMatchesSmartInboxFilter(
          mentioned,
          filter: SmartInboxFilter.mentions,
          currentUserId: 'me',
          currentUsername: 'alice',
        ),
        isTrue,
      );
      expect(
        conversationMatchesSmartInboxFilter(
          mentioned,
          filter: SmartInboxFilter.mentions,
          currentUserId: 'me',
          currentUsername: 'ali',
        ),
        isFalse,
      );
      expect(
        conversationMatchesSmartInboxFilter(
          bot,
          filter: SmartInboxFilter.bots,
          currentUserId: 'me',
        ),
        isTrue,
      );
      expect(
        conversationMatchesSmartInboxFilter(
          group,
          filter: SmartInboxFilter.groups,
          currentUserId: 'me',
        ),
        isTrue,
      );
      expect(
        conversationMatchesSmartInboxFilter(
          channel,
          filter: SmartInboxFilter.channels,
          currentUserId: 'me',
        ),
        isTrue,
      );
    },
  );

  test('selected smart inbox filter persists in settings', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = SettingsProvider();
    await provider.load();

    await provider.setSmartInboxFilter(SmartInboxFilter.unread);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('smart_inbox_filter'), SmartInboxFilter.unread.name);
  });

  test(
    'inbox ordering keeps pinned chats above draft and message activity',
    () {
      final olderPinned = _conversation(
        id: 'pinned',
        type: ConversationType.dm,
        lastMessage: _message('old', DateTime.utc(2026, 1, 1)),
      );
      final newerDraft = _conversation(
        id: 'draft',
        type: ConversationType.dm,
        lastMessage: _message('mid', DateTime.utc(2026, 1, 2)),
      );
      final newerMessage = _conversation(
        id: 'message',
        type: ConversationType.dm,
        lastMessage: _message('new', DateTime.utc(2026, 1, 3)),
      );
      final conversations = [newerDraft, olderPinned, newerMessage]
        ..sort(
          (a, b) => compareConversationsForInbox(
            a,
            b,
            drafts: {
              'draft': MessageDraft(
                text: 'later today',
                updatedAt: DateTime.utc(2026, 1, 4),
              ),
            },
            pinnedConversationIds: {'pinned'},
          ),
        );

      expect(conversations.map((conversation) => conversation.id), [
        'pinned',
        'draft',
        'message',
      ]);
    },
  );

  test('archived chats only match the archived filter', () {
    final archived = _conversation(
      id: 'archived',
      type: ConversationType.dm,
      unreadCount: 4,
    );
    final active = _conversation(
      id: 'active',
      type: ConversationType.dm,
      unreadCount: 1,
    );
    const archivedIds = {'archived'};

    expect(
      conversationMatchesSmartInboxFilter(
        archived,
        filter: SmartInboxFilter.all,
        currentUserId: 'me',
        archivedConversationIds: archivedIds,
      ),
      isFalse,
    );
    expect(
      conversationMatchesSmartInboxFilter(
        archived,
        filter: SmartInboxFilter.unread,
        currentUserId: 'me',
        archivedConversationIds: archivedIds,
      ),
      isFalse,
    );
    expect(
      conversationMatchesSmartInboxFilter(
        archived,
        filter: SmartInboxFilter.archived,
        currentUserId: 'me',
        archivedConversationIds: archivedIds,
      ),
      isTrue,
    );
    expect(
      conversationMatchesSmartInboxFilter(
        active,
        filter: SmartInboxFilter.archived,
        currentUserId: 'me',
        archivedConversationIds: archivedIds,
      ),
      isFalse,
    );
  });
}
