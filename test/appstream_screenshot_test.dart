import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/auth_provider.dart';
import 'package:openchat/providers/key_provider.dart';
import 'package:openchat/screens/auth/login_screen.dart';
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
      ChangeNotifierProvider<KeyProvider>(create: (_) => KeyProvider(storage)),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('renders the AppStream login screenshot', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(_authHarness(const LoginScreen()));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../packaging/linux/screenshots/openchat-login.png'),
    );
  });
}
