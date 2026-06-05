import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/models/moderation_report.dart';

void main() {
  test('conversation parses anti-spam controls', () {
    final conversation = Conversation.fromJson({
      'id': 'conv-1',
      'type': 'group',
      'owner_only_post': false,
      'new_member_cooldown_seconds': 300,
      'anti_spam_block_links': true,
      'anti_spam_block_media': true,
      'anti_spam_mention_limit': 5,
      'created_at': '2026-01-02T03:04:05Z',
      'created_by': 'user-1',
    });

    expect(conversation.newMemberCooldownSeconds, 300);
    expect(conversation.antiSpamBlockLinks, isTrue);
    expect(conversation.antiSpamBlockMedia, isTrue);
    expect(conversation.antiSpamMentionLimit, 5);
  });

  test('moderation report parses status and usernames', () {
    final report = ModerationReport.fromJson({
      'id': 'report-1',
      'conversation_id': 'conv-1',
      'message_id': 'msg-1',
      'reporter_user_id': 'reporter-1',
      'reported_user_id': 'reported-1',
      'reason': 'Spam',
      'status': 'open',
      'created_at': '2026-01-02T03:04:05Z',
      'reporter_username': 'alice',
      'reported_username': 'bob',
    });

    expect(report.messageId, 'msg-1');
    expect(report.reporterUsername, 'alice');
    expect(report.reportedUsername, 'bob');
    expect(report.createdAt.toUtc(), DateTime.utc(2026, 1, 2, 3, 4, 5));
  });
}
