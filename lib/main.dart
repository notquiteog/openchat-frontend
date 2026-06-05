import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
import 'services/mls_service.dart';
import 'services/notification_service.dart';
import 'services/push_notification_service.dart';
import 'services/secure_storage_service.dart';
import 'services/websocket_service.dart';
import 'utils/local_conversation_preferences.dart';

/// Background FCM handler — runs in a separate isolate when the app is
/// terminated. Release pushes include a notification payload so the OS can show
/// them automatically. This handler remains a data-only fallback for incoming
/// calls so older servers still surface a local call notification.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  if (message.notification == null && message.data['type'] == 'incoming_call') {
    await NotificationService.init();
    final caller = message.data['caller_username'] as String? ?? 'Unknown';
    final isVideo = message.data['is_video'] == 'true';
    final kind = isVideo ? 'video' : 'voice';
    await NotificationService.showIncomingCall(
      body: 'Incoming $kind call from @$caller',
    );
  } else if (message.notification == null &&
      message.data['type'] == 'new_message') {
    final conversationId = message.data['conversation_id'] as String? ?? 'push';
    if (!await _shouldShowMessageNotification(conversationId, message.data)) {
      return;
    }
    await NotificationService.init();
    await NotificationService.showMessage(
      conversationId: conversationId,
      title: 'OpenChat',
      body: 'New message',
      mentionedUserIds: mentionedUserIdsFromNotificationData(message.data),
      mentionedForCurrentUser: notificationDataMentionsCurrentUser(
        message.data,
        await _notificationCurrentUserId(),
      ),
    );
  }
}

Future<String> _notificationCurrentUserId() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(notificationCurrentUserPreferenceKey) ?? '';
}

Future<bool> _shouldShowMessageNotification(
  String conversationId,
  Map<String, dynamic> data,
) async {
  final prefs = await SharedPreferences.getInstance();
  final currentUserId =
      prefs.getString(notificationCurrentUserPreferenceKey) ?? '';
  final preferences = decodeConversationNotificationPreferences(
    prefs.getString(conversationNotificationPreferencesPreferenceKey),
  );
  for (final id
      in prefs.getStringList(mutedConversationsPreferenceKey) ?? const []) {
    preferences.putIfAbsent(
      id,
      () => const ConversationNotificationPreference.mutedForever(),
    );
  }
  return shouldNotifyForConversation(
    conversationId: conversationId,
    preferences: preferences,
    currentUserId: currentUserId,
    mentionedUserIds: mentionedUserIdsFromNotificationData(data),
    mentionedForCurrentUser: notificationDataMentionsCurrentUser(
      data,
      currentUserId,
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Pre-warm the liquid glass shader pipeline before any UI is painted.
  // On Impeller (iOS/Android) this unlocks real refraction + chromatic
  // aberration; on Skia it primes the lightweight fragment shader.
  await LiquidGlassWidgets.initialize();
  await DesktopStartupService.startTray();
  // Register Firebase background message handler before runApp so the
  // messaging plugin can dispatch messages when the app is terminated.
  // No-op when Firebase credentials are placeholders or platform unsupported.
  await PushNotificationService.registerBackgroundHandler(
    _firebaseBackgroundHandler,
  );
  // Configure the background WS service isolate; must run before any UI.
  await BackgroundWsService.configure();
  runApp(
    LiquidGlassWidgets.wrap(
      // Adaptive quality: benchmarks the device on first launch and adjusts
      // shader complexity (premium → standard → minimal) to keep 60 fps.
      adaptiveQuality: true,
      child: const _Providers(),
    ),
  );
}

class _Providers extends StatelessWidget {
  const _Providers();

  @override
  Widget build(BuildContext context) {
    final storage = SecureStorageService();
    final api = ApiService(storage);
    final ws = WebSocketService(storage);
    final mls = MlsService(storage);
    final callService = CallService(ws, iceServerLoader: api.getIceServers);

    return MultiProvider(
      providers: [
        Provider<SecureStorageService>.value(value: storage),
        Provider<ApiService>.value(value: api),
        Provider<MlsService>.value(value: mls),
        ChangeNotifierProvider<WebSocketService>.value(value: ws),
        Provider<CallService>.value(value: callService),
        ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        ChangeNotifierProvider(create: (_) => AuthProvider(api, storage)),
        ChangeNotifierProvider(create: (_) => KeyProvider(storage)),
        // SettingsProvider must be registered before ChatProvider so the
        // create callback can read it via ctx.read<SettingsProvider>().
        ChangeNotifierProvider(
          create: (ctx) =>
              ChatProvider(api, storage, ws, ctx.read<SettingsProvider>(), mls),
        ),
        ChangeNotifierProvider(create: (_) => CallProvider(callService)),
      ],
      child: const OpenChatApp(),
    );
  }
}
