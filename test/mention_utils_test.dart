import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/utils/mention_utils.dart';

void main() {
  test('findMentionRanges detects valid handles with word boundaries', () {
    final ranges = findMentionRanges(
      'hi @alice and @bob_123, not email@test or bad@carol',
    );

    expect(ranges.map((range) => range.handle), ['alice', 'bob_123']);
    expect(ranges.first.start, 3);
    expect(ranges.first.end, 9);
  });

  test('textMentionsUsername is case insensitive and exact', () {
    expect(textMentionsUsername('Ping @Alice today', 'alice'), isTrue);
    expect(textMentionsUsername('Ping @alice2 today', 'alice'), isFalse);
    expect(textMentionsUsername('Ping @alice today', ''), isFalse);
  });

  test('findActiveMentionQuery returns the mention token at the cursor', () {
    final query = findActiveMentionQuery('hello @ali there', 10);

    expect(query, isNotNull);
    expect(query!.start, 6);
    expect(query.end, 10);
    expect(query.query, 'ali');
  });

  test('findActiveMentionQuery expands replacement through handle suffix', () {
    final query = findActiveMentionQuery('hello @alice today', 10);

    expect(query, isNotNull);
    expect(query!.start, 6);
    expect(query.end, 12);
    expect(query.query, 'ali');
  });

  test('findActiveMentionQuery ignores non-boundary at signs', () {
    expect(findActiveMentionQuery('email@test', 10), isNull);
    expect(findActiveMentionQuery('bad@alice', 9), isNull);
  });

  test(
    'mentionSuggestionsForMembers excludes current user and prefers prefix',
    () {
      final active = const ActiveMentionQuery(start: 0, end: 3, query: 'al');
      final suggestions = mentionSuggestionsForMembers(
        active: active,
        currentUserId: 'me',
        members: [
          _member(id: 'me', username: 'alex'),
          _member(id: 'u-1', username: 'paloma'),
          _member(id: 'u-2', username: 'alice'),
        ],
      );

      expect(suggestions.map((m) => m.user!.username), ['alice', 'paloma']);
    },
  );

  test('unreadMentionMessageId returns latest unread mention target', () {
    final conversation = _conversation(
      unreadCount: 2,
      lastMessage: _message(id: 'm-1', text: 'Ping @alice'),
    );

    expect(unreadMentionMessageId(conversation, 'alice'), 'm-1');
    expect(unreadMentionMessageId(conversation, 'ali'), isNull);
    expect(
      unreadMentionMessageId(conversation.copyWith(unreadCount: 0), 'alice'),
      isNull,
    );
  });

  test('unreadMentionMessageId prefers server indexed target', () {
    final conversation = _conversation(
      unreadCount: 0,
      lastMessage: _message(id: 'm-latest', text: 'Plain update'),
      unreadMentionMessageId: 'm-mentioned',
    );

    expect(unreadMentionMessageId(conversation, 'alice'), 'm-mentioned');
  });

  test('mentionedMemberIdsInText maps exact handles to member ids', () {
    final ids = mentionedMemberIdsInText('Hi @alice and @bob_123 and @Alice', [
      _member(id: 'me', username: 'alice'),
      _member(id: 'u-1', username: 'alice'),
      _member(id: 'u-2', username: 'bob_123'),
      _member(id: 'u-3', username: 'ali'),
    ], currentUserId: 'me');

    expect(ids, ['u-1', 'u-2']);
  });
}

Conversation _conversation({
  required int unreadCount,
  required Message lastMessage,
  String? unreadMentionMessageId,
}) {
  return Conversation(
    id: 'c-1',
    type: ConversationType.group,
    name: 'Group',
    createdAt: DateTime(2024),
    createdBy: 'u-1',
    lastMessage: lastMessage,
    unreadCount: unreadCount,
    unreadMentionMessageId: unreadMentionMessageId,
  );
}

Message _message({required String id, required String text}) {
  final message = Message(
    id: id,
    conversationId: 'c-1',
    senderId: 'u-2',
    type: MessageType.text,
    encryptedPayload: '',
    signature: '',
    isEncrypted: false,
    createdAt: DateTime(2024),
  );
  message.setDecryptedContent(text);
  return message;
}

ConversationMember _member({required String id, required String username}) {
  return ConversationMember(
    conversationId: 'c-1',
    userId: id,
    role: MemberRole.member,
    joinedAt: DateTime(2024),
    user: User(
      id: id,
      username: username,
      publicKey: '',
      keyFingerprint: '',
      createdAt: DateTime(2024),
    ),
  );
}
