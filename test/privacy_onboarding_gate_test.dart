import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/screens/onboarding/privacy_onboarding_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('privacy onboarding "viewed" flag is per-user and survives reload', () async {
    final provider = SettingsProvider();
    await provider.load();

    expect(provider.hasViewedPrivacyOnboarding('u1'), isFalse);
    await provider.markPrivacyOnboardingViewed('u1');
    expect(provider.hasViewedPrivacyOnboarding('u1'), isTrue);

    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.hasViewedPrivacyOnboarding('u1'), isTrue);
    // The flag is scoped to the user id, so a different account on the same
    // device still gets its own onboarding.
    expect(reloaded.hasViewedPrivacyOnboarding('u2'), isFalse);
  });

  testWidgets('paging to the last step invokes onComplete exactly once', (
    tester,
  ) async {
    var completed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PrivacyOnboardingScreen(onComplete: () => completed++),
      ),
    );

    expect(find.byKey(const Key('privacy-onboarding')), findsOneWidget);

    // Six pages: five "Next" taps advance, the sixth ("Finish") completes.
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byKey(const Key('privacy-onboarding-next')));
      await tester.pumpAndSettle();
    }

    expect(completed, 1);
  });
}
