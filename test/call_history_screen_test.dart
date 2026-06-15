import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/screens/call/call_history_screen.dart';
import 'package:openchat/services/call_history_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:provider/provider.dart';

Future<List<int>> _testKey() async => List<int>.generate(32, (index) => index);

CallHistoryEntry _entry({
  required String id,
  required String username,
  required CallDirection direction,
  required CallOutcomeKind outcome,
  required DateTime startedAt,
}) {
  return CallHistoryEntry(
    id: id,
    conversationId: 'conv-$id',
    peerUserId: 'peer-$id',
    peerUsername: username,
    isVideo: false,
    direction: direction,
    outcome: outcome,
    startedAt: startedAt,
    durationSecs: outcome == CallOutcomeKind.answered ? 37 : 0,
  );
}

Future<CallHistoryService> _seededService() async {
  final service = CallHistoryService(
    SecureStorageService(),
    databasePath: ':memory:',
    keyLoader: _testKey,
  );
  await service.record(
    _entry(
      id: 'answered-call',
      username: 'answered',
      direction: CallDirection.outgoing,
      outcome: CallOutcomeKind.answered,
      startedAt: DateTime.utc(2026, 6, 15, 12),
    ),
  );
  await service.record(
    _entry(
      id: 'missed-call',
      username: 'missed',
      direction: CallDirection.incoming,
      outcome: CallOutcomeKind.missed,
      startedAt: DateTime.utc(2026, 6, 15, 13),
    ),
  );
  return service;
}

Future<void> _pumpScreen(
  WidgetTester tester,
  CallHistoryService service,
) async {
  await tester.pumpWidget(
    Provider<CallHistoryService>.value(
      value: service,
      child: const MaterialApp(home: CallHistoryScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('missed segment filters out answered calls', (tester) async {
    final service = await _seededService();
    await _pumpScreen(tester, service);

    expect(find.text('@answered'), findsOneWidget);
    expect(find.text('@missed'), findsOneWidget);

    await tester.tap(find.text('Missed').first);
    await tester.pumpAndSettle();

    expect(find.text('@answered'), findsNothing);
    expect(find.text('@missed'), findsOneWidget);
  });

  testWidgets('missed segment shows a filter-aware empty state', (
    tester,
  ) async {
    final service = CallHistoryService(
      SecureStorageService(),
      databasePath: ':memory:',
      keyLoader: _testKey,
    );
    await service.record(
      _entry(
        id: 'answered-only',
        username: 'answered',
        direction: CallDirection.outgoing,
        outcome: CallOutcomeKind.answered,
        startedAt: DateTime.utc(2026, 6, 15),
      ),
    );
    await _pumpScreen(tester, service);

    await tester.tap(find.text('Missed').first);
    await tester.pumpAndSettle();

    expect(find.text('No missed calls'), findsOneWidget);
  });

  testWidgets('swiping a row deletes that call history entry', (tester) async {
    final service = await _seededService();
    await _pumpScreen(tester, service);

    await tester.drag(
      find.byKey(const ValueKey('missed-call')),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();

    expect(find.text('@missed'), findsNothing);
    expect(
      (await service.list()).map((entry) => entry.id),
      isNot(contains('missed-call')),
    );
  });

  testWidgets('clear all confirmation empties the call history', (
    tester,
  ) async {
    final service = await _seededService();
    await _pumpScreen(tester, service);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear all'));
    await tester.pumpAndSettle();

    expect(find.text('No calls yet'), findsOneWidget);
    expect(await service.list(), isEmpty);
  });
}
