import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/screens/settings/wallet_screen.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:provider/provider.dart';

// Pending deposits get a live-progress card in the wallet; settled ones
// (confirmed / expired) belong to the history list instead.
void main() {
  group('pendingDeposits', () {
    test('keeps only deposits that are neither confirmed nor expired', () {
      final pending = pendingDeposits([
        {'id': 'a', 'status': 'confirmed'},
        {'id': 'b', 'status': 'confirming'},
        {'id': 'c', 'status': 'expired'},
        {'id': 'd', 'status': 'nothing_sent'},
        {'id': 'e', 'status': 'unconfirmed'},
      ]);
      expect(pending.map((d) => d['id']), containsAll(['b', 'd', 'e']));
      expect(pending.length, 3);
    });

    test('sorts newest first', () {
      final pending = pendingDeposits([
        {'id': 'old', 'status': 'confirming', 'created_at': '2026-06-01'},
        {'id': 'new', 'status': 'confirming', 'created_at': '2026-06-09'},
      ]);
      expect(pending.first['id'], 'new');
    });

    test('empty input yields empty output', () {
      expect(pendingDeposits([]), isEmpty);
    });
  });

  group('PendingDepositCard', () {
    late StreamController<Map<String, dynamic>> events;
    late WebSocketService ws;

    setUp(() {
      events = StreamController<Map<String, dynamic>>.broadcast();
      ws = WebSocketService(SecureStorageService())
        ..debugSetConnectionStatus(WsConnectionStatus.connected);
    });

    tearDown(() async {
      await events.close();
      ws.dispose();
    });

    Future<void> pump(
      WidgetTester tester, {
      Map<String, dynamic>? deposit,
      VoidCallback? onTap,
      VoidCallback? onConfirmed,
    }) {
      return tester.pumpWidget(
        ChangeNotifierProvider<WebSocketService>.value(
          value: ws,
          child: MaterialApp(
            home: Scaffold(
              body: PendingDepositCard(
                deposit:
                    deposit ??
                    {
                      'id': 'dep-1',
                      'provider': 'btc',
                      'purpose': 'topup',
                      'status': 'confirming',
                      'confirmations': 2,
                      'required_confirmations': 6,
                    },
                onTap: onTap,
                onConfirmed: onConfirmed,
                progressStream: events.stream,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('shows the provider title and live progress', (tester) async {
      await pump(tester);
      expect(find.text('Deposit BTC'), findsOneWidget);
      expect(find.text('Confirming: 2 of 6'), findsOneWidget);

      events.add({
        'deposit_id': 'dep-1',
        'status': 'confirming',
        'confirmations': 5,
        'required_confirmations': 6,
      });
      await tester.pump();
      expect(find.text('Confirming: 5 of 6'), findsOneWidget);
    });

    testWidgets('labels channel subscriptions distinctly', (tester) async {
      await pump(
        tester,
        deposit: {
          'id': 'dep-2',
          'provider': 'xmr',
          'purpose': 'channel_sub',
          'status': 'nothing_sent',
        },
      );
      expect(find.text('Channel subscription XMR'), findsOneWidget);
    });

    testWidgets('tap and confirmation callbacks fire', (tester) async {
      var taps = 0;
      var confirmed = 0;
      await pump(tester, onTap: () => taps++, onConfirmed: () => confirmed++);

      await tester.tap(find.text('Deposit BTC'));
      expect(taps, 1);

      events.add({
        'deposit_id': 'dep-1',
        'status': 'confirmed',
        'confirmations': 6,
        'required_confirmations': 6,
      });
      await tester.pump();
      expect(confirmed, 1);
    });
  });
}
