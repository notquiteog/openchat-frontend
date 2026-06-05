import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation_invite.dart';
import 'package:openchat/utils/invite_links.dart';

void main() {
  test('inviteDeepLink builds stable OpenChat invite URI', () {
    final link = inviteDeepLink(token: 'abc_123');

    final uri = Uri.parse(link);
    expect(uri.scheme, 'openchat');
    expect(uri.host, 'invite');
    expect(uri.pathSegments, ['abc_123']);
  });

  test('inviteTokenFromUri parses path and query token forms', () {
    expect(
      inviteTokenFromUri(Uri.parse('openchat://invite/token-1')),
      'token-1',
    );
    expect(
      inviteTokenFromUri(Uri.parse('openchat://invite?token=token-2')),
      'token-2',
    );
  });

  test('inviteTokenFromUri rejects non invite links', () {
    expect(inviteTokenFromUri(Uri.parse('openchat://message/abc')), isNull);
    expect(
      inviteTokenFromUri(Uri.parse('https://example.com/invite/a')),
      isNull,
    );
  });

  test('conversation invite parses controls and analytics', () {
    final link = ConversationInviteLink.fromJson({
      'id': 'link-1',
      'conversation_id': 'conv-1',
      'token': 'token-1',
      'created_by': 'user-1',
      'approval_required': true,
      'expires_at': '2026-01-03T03:04:05Z',
      'usage_limit': 10,
      'usage_count': 4,
      'preview_count': 12,
      'join_count': 3,
      'join_request_count': 1,
      'last_used_at': '2026-01-02T05:04:05Z',
      'created_at': '2026-01-02T03:04:05Z',
    });

    expect(link.approvalRequired, isTrue);
    expect(link.usageLimit, 10);
    expect(link.usageCount, 4);
    expect(link.previewCount, 12);
    expect(link.joinCount, 3);
    expect(link.joinRequestCount, 1);
    expect(link.expiresAt?.toUtc(), DateTime.utc(2026, 1, 3, 3, 4, 5));
  });
}
