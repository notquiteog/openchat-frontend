import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/admin_audit_event.dart';

void main() {
  test('admin audit event parses actors targets and metadata', () {
    final event = AdminAuditEvent.fromJson({
      'id': 'event-1',
      'conversation_id': 'conv-1',
      'actor_user_id': 'actor-1',
      'target_user_id': 'target-123456789',
      'action': 'member_banned',
      'metadata': {'has_reason': true},
      'created_at': '2026-01-02T03:04:05Z',
      'actor_username': 'alice',
      'target_username': 'bob',
    });

    expect(event.actorLabel, '@alice');
    expect(event.targetLabel, '@bob');
    expect(event.metadata['has_reason'], isTrue);
    expect(event.createdAt.toUtc(), DateTime.utc(2026, 1, 2, 3, 4, 5));
  });

  test('admin audit event falls back when usernames are unavailable', () {
    final event = AdminAuditEvent.fromJson({
      'id': 'event-2',
      'conversation_id': 'conv-1',
      'target_user_id': '123456789abcdef',
      'action': 'messages_deleted',
      'metadata': const {},
      'created_at': '2026-01-02T03:04:05Z',
    });

    expect(event.actorLabel, 'Unknown admin');
    expect(event.targetLabel, '12345678');
  });
}
