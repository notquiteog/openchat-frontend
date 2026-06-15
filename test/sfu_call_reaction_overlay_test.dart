import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/screens/call/call_glass.dart';

void main() {
  testWidgets('floating reaction renders and completes its auto-remove timer', (
    tester,
  ) async {
    var completed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: FloatingReaction(
              emoji: '👍',
              onCompleted: () => completed = true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('👍'), findsOneWidget);
    expect(completed, isFalse);

    await tester.pump(const Duration(milliseconds: 2600));
    await tester.pump();

    expect(completed, isTrue);
  });

  testWidgets('raise-hand badge uses the call glass badge affordance', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: RaiseHandBadge())),
      ),
    );

    expect(find.byIcon(Icons.back_hand_rounded), findsOneWidget);
  });
}
