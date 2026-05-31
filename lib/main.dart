import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'app.dart';
import 'providers/auth_provider.dart';
import 'providers/call_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/key_provider.dart';
import 'providers/settings_provider.dart';
import 'services/api_service.dart';
import 'services/background_ws_service.dart';
import 'services/call_service.dart';
import 'services/push_notification_service.dart';
import 'services/secure_storage_service.dart';
import 'services/websocket_service.dart';

/// Background FCM handler — runs in a separate isolate when the app is
/// terminated. Firebase automatically shows the system notification for
/// messages that carry a `notification` payload; nothing extra is needed here.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  // No-op: the system notification is shown automatically by FCM.
  // If you send data-only messages (no notification payload), add local
  // notification display logic here after re-initialising Firebase and
  // NotificationService in this isolate.
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  // Register Firebase background message handler before runApp so the
  // messaging plugin can dispatch messages when the app is terminated.
  // No-op when Firebase credentials are placeholders or platform unsupported.
  await PushNotificationService.registerBackgroundHandler(
    _firebaseBackgroundHandler,
  );
  // Configure the background WS service isolate; must run before any UI.
  await BackgroundWsService.configure();
  runApp(const _Providers());
}

class _Providers extends StatelessWidget {
  const _Providers();

  @override
  Widget build(BuildContext context) {
    final storage = SecureStorageService();
    final api = ApiService(storage);
    final ws = WebSocketService(storage);
    final callService = CallService(ws);

    return MultiProvider(
      providers: [
        Provider<SecureStorageService>.value(value: storage),
        Provider<ApiService>.value(value: api),
        Provider<WebSocketService>.value(value: ws),
        Provider<CallService>.value(value: callService),
        ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        ChangeNotifierProvider(create: (_) => AuthProvider(api, storage)),
        ChangeNotifierProvider(create: (_) => KeyProvider(storage)),
        // SettingsProvider must be registered before ChatProvider so the
        // create callback can read it via ctx.read<SettingsProvider>().
        ChangeNotifierProvider(
          create: (ctx) =>
              ChatProvider(api, storage, ws, ctx.read<SettingsProvider>()),
        ),
        ChangeNotifierProvider(create: (_) => CallProvider(callService)),
      ],
      child: const OpenChatApp(),
    );
  }
}
