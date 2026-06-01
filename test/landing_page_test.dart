import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/auth_provider.dart';
import 'package:openchat/providers/key_provider.dart';
import 'package:openchat/screens/auth/login_screen.dart';
import 'package:openchat/screens/auth/register_screen.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:provider/provider.dart';

Widget _authHarness(Widget child) {
  final storage = SecureStorageService();
  final api = ApiService(storage);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => AuthProvider(api, storage),
      ),
      ChangeNotifierProvider<KeyProvider>(
        create: (_) => KeyProvider(storage),
      ),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('login screen is the full-height landing hero', (tester) async {
    await tester.pumpWidget(_authHarness(const LoginScreen()));

    final scaffold = tester.getSize(find.byType(Scaffold));
    final hero = tester.getSize(find.byKey(const Key('auth-landing-hero')));

    expect(hero.height, scaffold.height);
    expect(find.text('Secure. Open. Encrypted.'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.widgetWithText(TextButton, 'Sign in'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign up'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Create your account'),
        findsOneWidget);
  });

  testWidgets('register screen keeps the landing visual language',
      (tester) async {
    await tester.pumpWidget(_authHarness(const RegisterScreen()));

    expect(find.byType(AppBar), findsNothing);
    expect(find.byKey(const Key('auth-landing-hero')), findsOneWidget);
    expect(find.text('Secure. Open. Encrypted.'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Sign in'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Create account'), findsOneWidget);
  });
}
