import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'providers/auth_provider.dart';
import 'providers/call_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/key_provider.dart';
import 'providers/settings_provider.dart';
import 'services/api_service.dart';
import 'services/background_ws_service.dart';
import 'services/call_service.dart';
import 'services/desktop_startup_service.dart';
import 'services/notification_service.dart';
import 'services/push_notification_service.dart';
import 'services/secure_storage_service.dart';
import 'services/websocket_service.dart';

/// Background FCM handler — runs in a separate isolate when the app is
/// terminated. Regular messages carry a notification payload so the system
/// shows them automatically. Incoming-call pushes are data-only (no
/// notification payload) so we display a local notification here.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  if (message.data['type'] == 'incoming_call') {
    await NotificationService.init();
    final caller = message.data['caller_username'] as String? ?? 'Unknown';
    final isVideo = message.data['is_video'] == 'true';
    final kind = isVideo ? 'video' : 'voice';
    await NotificationService.showIncomingCall(
      body: 'Incoming $kind call from @$caller',
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  DesktopStartupService.configureDatabaseFactory();
  await DesktopStartupService.startTray();
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
    final callService = CallService(ws, iceServerLoader: api.getIceServers);

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
