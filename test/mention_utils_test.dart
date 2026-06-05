import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';
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
          _member(id: 'u-2', username: 'alice', publicDiscovery: false),
        ],
      );

      expect(suggestions.map((m) => m.user!.username), ['alice', 'paloma']);
    },
  );

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

ConversationMember _member({
  required String id,
  required String username,
  bool publicDiscovery = true,
}) {
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
      publicDiscovery: publicDiscovery,
      createdAt: DateTime(2024),
    ),
  );
}
