import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/moderation_report.dart';
import 'package:openchat/models/operator_metrics.dart';
import 'package:openchat/models/system_admin_audit_event.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/screens/admin/admin_home_screen.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:provider/provider.dart';

void main() {
  test('admin home tab gate follows system-admin role', () {
    expect(canShowAdminHome(_user(role: 'system_admin')), isTrue);
    expect(canShowAdminHome(_user(role: 'user')), isFalse);
    expect(canShowAdminHome(null), isFalse);
  });

  test('system admin audit event parses optional actor and target', () {
    final event = SystemAdminAuditEvent.fromJson({
      'id': 'audit-1',
      'actor_user_id': 'admin-123456',
      'target_user_id': 'target-123456',
      'action': 'premium_granted',
      'metadata': {'days': 30},
      'created_at': '2026-06-15T12:00:00Z',
      'actor_username': 'root',
      'target_username': 'alice',
    });

    expect(event.action, 'premium_granted');
    expect(event.metadata['days'], 30);
    expect(event.actorLabel, '@root');
    expect(event.targetLabel, '@alice');
  });

  testWidgets('admin home renders CSAM moderation and health sections', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _FakeAdminApiService();
    await tester.pumpWidget(
      Provider<ApiService>.value(
        value: api,
        child: const MaterialApp(home: AdminHomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('CSAM Reports'), findsOneWidget);
    expect(find.text('AMF inspection queue'), findsOneWidget);

    await tester.tap(find.text('Moderation'));
    await tester.pumpAndSettle();

    expect(find.text('Global moderation'), findsOneWidget);
    expect(find.text('Reported message msg-1234'), findsOneWidget);
    expect(find.text('Spam wave'), findsOneWidget);
    expect(find.text('System-admin audit'), findsOneWidget);
    expect(find.text('User Banned'), findsOneWidget);
    expect(api.reportCalls, 1);
    expect(api.auditCalls, 1);

    await tester.tap(find.text('Health'));
    await tester.pumpAndSettle();

    expect(find.text('Server Health'), findsOneWidget);
    expect(find.text('Push delivery'), findsOneWidget);
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(api.metricsCalls, 1);
  });
}

class _FakeAdminApiService extends ApiService {
  _FakeAdminApiService() : super(SecureStorageService());

  int reportCalls = 0;
  int auditCalls = 0;
  int metricsCalls = 0;

  @override
  Future<List<ModerationReport>> listAdminReportsGlobal({
    String status = 'open',
    int limit = 100,
    DateTime? before,
  }) async {
    reportCalls++;
    return [
      ModerationReport(
        id: 'report-1',
        conversationId: 'conv-1',
        messageId: 'msg-123456',
        reporterUserId: 'reporter-123456',
        reportedUserId: 'target-123456',
        reporterUsername: 'bob',
        reportedUsername: 'mallory',
        reason: 'Spam wave',
        status: 'open',
        createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
      ),
    ];
  }

  @override
  Future<List<SystemAdminAuditEvent>> listSystemAdminAuditEvents({
    int limit = 100,
  }) async {
    auditCalls++;
    return [
      SystemAdminAuditEvent(
        id: 'audit-1',
        actorUserId: 'admin-123456',
        targetUserId: 'target-123456',
        actorUsername: 'root',
        targetUsername: 'mallory',
        action: 'user_banned',
        createdAt: DateTime.now().subtract(const Duration(minutes: 2)),
      ),
    ];
  }

  @override
  Future<OperatorMetrics> getAdminMetrics() async {
    metricsCalls++;
    return OperatorMetrics.fromJson({
      'push': {
        'enabled': true,
        'sent': 12,
        'failed': 1,
        'dropped': 0,
        'queue_depth': 1,
        'queue_capacity': 4,
      },
      'db': {
        'acquired_conns': 2,
        'total_conns': 5,
        'idle_conns': 3,
        'max_conns': 10,
        'acquire_count': 20,
        'empty_acquire_count': 0,
      },
      'hub': {'users': 4, 'connections': 6},
    });
  }
}

User _user({required String role}) {
  return User(
    id: 'user-$role',
    username: role,
    publicKey: 'pub',
    keyFingerprint: 'fp',
    role: role,
    createdAt: DateTime.utc(2026, 6, 15),
  );
}
