import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/key_trust_pin.dart';
import 'package:openchat/widgets/key_verification_badge.dart';

KeyTrustPin _pin({String? verifiedVia, String? warning}) => KeyTrustPin(
  userId: 'user-1',
  fingerprint: 'fingerprint',
  publicKeyHash: 'hash',
  warning: warning,
  pinnedAt: DateTime.utc(2026, 1, 1),
  verifiedVia: verifiedVia,
);

void main() {
  Future<void> pumpBadge(WidgetTester tester, KeyTrustPin? pin) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: KeyVerificationBadge(pin: pin)),
        ),
      ),
    );
  }

  testWidgets('verified pin renders verified badge', (tester) async {
    await pumpBadge(tester, _pin(verifiedVia: 'smp'));

    expect(find.text('Verified'), findsOneWidget);
    expect(find.byIcon(Icons.verified_user_rounded), findsOneWidget);
    expect(find.text('Key changed'), findsNothing);
  });

  testWidgets('warning pin renders key changed badge', (tester) async {
    await pumpBadge(tester, _pin(warning: 'fingerprint changed'));

    expect(find.text('Key changed'), findsOneWidget);
    expect(find.byIcon(Icons.gpp_bad_rounded), findsOneWidget);
    expect(find.text('Verified'), findsNothing);
  });

  testWidgets('plain TOFU and null pins render nothing', (tester) async {
    await pumpBadge(tester, _pin());
    expect(find.text('Verified'), findsNothing);
    expect(find.text('Key changed'), findsNothing);

    await pumpBadge(tester, null);
    expect(find.text('Verified'), findsNothing);
    expect(find.text('Key changed'), findsNothing);
  });
}
