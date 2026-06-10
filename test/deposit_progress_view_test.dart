import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:openchat/widgets/deposit_progress_view.dart';
import 'package:provider/provider.dart';

// The deposit ring is fed by the user-scoped deposit_progress WS event. It
// must only react to ITS deposit id, flip to confirmed exactly once, and stay
// quiet for other deposits.
void main() {
  late StreamController<Map<String, dynamic>> events;
  late WebSocketService ws;

  setUp(() {
    events = StreamController<Map<String, dynamic>>.broadcast();
    ws = WebSocketService(SecureStorageService())
      // "Connected" disables the offline polling fallback in tests.
      ..debugSetConnectionStatus(WsConnectionStatus.connected);
  });

  tearDown(() async {
    await events.close();
    ws.dispose();
  });

  Future<void> pump(
    WidgetTester tester, {
    VoidCallback? onConfirmed,
  }) {
    return tester.pumpWidget(
      ChangeNotifierProvider<WebSocketService>.value(
        value: ws,
        child: MaterialApp(
          home: Scaffold(
            body: DepositProgressView(
              depositId: 'dep-1',
              initialConfirmations: 1,
              requiredConfirmations: 10,
              initialStatus: 'confirming',
              onConfirmed: onConfirmed,
              progressStream: events.stream,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders the initial confirmation count', (tester) async {
    await pump(tester);
    expect(find.text('Confirming: 1 of 10'), findsOneWidget);
  });

  testWidgets('advances when its deposit progresses', (tester) async {
    await pump(tester);

    events.add({
      'deposit_id': 'dep-1',
      'status': 'confirming',
      'confirmations': 4,
      'required_confirmations': 10,
    });
    await tester.pump();

    expect(find.text('Confirming: 4 of 10'), findsOneWidget);
  });

  testWidgets('ignores progress for other deposits', (tester) async {
    await pump(tester);

    events.add({
      'deposit_id': 'someone-elses',
      'status': 'confirming',
      'confirmations': 9,
      'required_confirmations': 10,
    });
    await tester.pump();

    expect(find.text('Confirming: 1 of 10'), findsOneWidget);
  });

  testWidgets('fires onConfirmed exactly once', (tester) async {
    var confirmedCalls = 0;
    await pump(tester, onConfirmed: () => confirmedCalls++);

    events.add({
      'deposit_id': 'dep-1',
      'status': 'confirmed',
      'confirmations': 10,
      'required_confirmations': 10,
    });
    await tester.pump();
    events.add({
      'deposit_id': 'dep-1',
      'status': 'confirmed',
      'confirmations': 11,
      'required_confirmations': 10,
    });
    await tester.pump();

    expect(confirmedCalls, 1);
    expect(find.text('Confirmed — access unlocked'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });

  testWidgets('shows the expired state', (tester) async {
    await pump(tester);

    events.add({'deposit_id': 'dep-1', 'status': 'expired'});
    await tester.pump();

    expect(find.text('This deposit window expired'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
  });
}
