import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config/api_config.dart';
import '../utils/local_conversation_preferences.dart';
import 'background_notification_intent.dart' as intent_mapper;
import 'background_notification_intent.dart' show NotificationIntent;
import 'local_private_state_service.dart';
import 'notification_service.dart';
import 'secure_storage_service.dart';

export 'background_notification_intent.dart'
    show NotificationIntent, NotificationIntentKind;

/// Persists a WebSocket connection while the app is in the background so that
/// users receive message and call notifications without relying on Firebase.
///
/// ──────────────────────────────────────────────────────────────────────────
/// Native setup required for full background execution on mobile:
///
/// Android — add to AndroidManifest.xml inside `<application>`:
///   ```xml
///   <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
///   <uses-permission android:name="android.permission.FOREGROUND_SERVICE_REMOTE_MESSAGING"/>
///   <service
///     android:name="id.flutter.flutter_background_service.BackgroundService"
///     android:exported="false"
///     android:foregroundServiceType="remoteMessaging"/>
///   ```
///
/// iOS — enable "Background Modes" in Xcode: tick "Background fetch" and
/// "Remote notifications". Note: iOS cannot keep a persistent TCP connection
/// alive in the background — push notifications (Firebase) are preferred.
///
/// Desktop (Windows / macOS / Linux): no setup needed; the process stays alive
/// and the main WebSocketService already handles notifications.
/// ──────────────────────────────────────────────────────────────────────────
class BackgroundWsService {
  static bool supportsPersistentBackgroundWebSocket({
    required bool isWeb,
    required bool isAndroid,
    required bool isIOS,
  }) => !isWeb && isAndroid && !isIOS;

  static bool get _mobileOnly => supportsPersistentBackgroundWebSocket(
    isWeb: kIsWeb,
    isAndroid: !kIsWeb && Platform.isAndroid,
    isIOS: !kIsWeb && Platform.isIOS,
  );

  static final _service = FlutterBackgroundService();

  /// Configure the background service. Call once at app startup.
  static Future<void> configure() async {
    if (!_mobileOnly) return;

    try {
      await _service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: _onStart,
          autoStart: false,
          autoStartOnBoot: false,
          isForegroundMode: true,
          notificationChannelId: 'openchat_background',
          initialNotificationTitle: 'OpenChat',
          initialNotificationContent: 'Waiting for messages…',
          foregroundServiceNotificationId: 8888,
          foregroundServiceTypes: const [AndroidForegroundType.remoteMessaging],
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: _onStart,
          onBackground: _onIosBackground,
        ),
      );
    } catch (e) {
      debugPrint('Background WebSocket configure failed: $e');
    }
  }

  /// Start the background service. The isolated service reads tokens from
  /// secure storage and notification rules from encrypted local state.
  static Future<bool> start({
    required String accessToken,
    required bool showSensitive,
    Map<String, ConversationNotificationPreference>
        conversationNotificationPreferences =
        const {},
  }) async {
    if (!kIsWeb && Platform.isIOS) {
      return false;
    }
    if (!_mobileOnly) {
      return true; // desktop: process stays alive, nothing to do
    }
    if (accessToken.isEmpty) return false;

    try {
      if (await _service.isRunning()) {
        await updateToken(accessToken);
        await updateSensitiveContent(showSensitive);
        await updateConversationNotificationPreferences(
          conversationNotificationPreferences,
        );
        return true;
      }
      final started = await _service.startService();
      if (started) {
        await updateSensitiveContent(showSensitive);
        await updateConversationNotificationPreferences(
          conversationNotificationPreferences,
        );
      }
      return started;
    } catch (e) {
      debugPrint('Background WebSocket start failed: $e');
      return false;
    }
  }

  /// Stop the background service.
  static Future<void> stop() async {
    if (!_mobileOnly) return;
    try {
      _service.invoke('stop');
    } catch (e) {
      debugPrint('Background WebSocket stop failed: $e');
    }
  }

  /// Push a refreshed access token into the running service.
  static Future<void> updateToken(String accessToken) async {
    if (!_mobileOnly) return;
    _service.invoke('setToken', {'token': accessToken});
  }

  /// Sync the sensitive-content preference without restarting the service.
  static Future<void> updateSensitiveContent(bool showSensitive) async {
    if (!_mobileOnly) return;
    _service.invoke('setSensitive', {'sensitive': showSensitive});
  }

  static Future<void> updateConversationNotificationPreferences(
    Map<String, ConversationNotificationPreference> preferences,
  ) async {
    final encoded = encodeConversationNotificationPreferences(preferences);
    if (!_mobileOnly) return;
    _service.invoke('setConversationNotificationPreferences', {
      'preferences': encoded,
    });
  }

  // ── iOS background handler ─────────────────────────────────────────────────

  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground(ServiceInstance service) async {
    return true;
  }

  // ── Background isolate entry point ─────────────────────────────────────────

  @pragma('vm:entry-point')
  static void _onStart(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    // Initialise local notifications inside the background isolate.
    final notif = FlutterLocalNotificationsPlugin();
    await notif.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/launcher_icon'),
        iOS: DarwinInitializationSettings(),
      ),
    );

    final localState = await _loadLocalPrivateState();
    String? token = await SecureStorageService().getAccessToken();
    bool showSensitive = decodePrivateNotificationSettings(
      localState[privateStateNotificationSettingsKey],
    ).sensitiveContent;
    Map<String, ConversationNotificationPreference>
    conversationNotificationPreferences =
        decodePrivateConversationNotificationPreferences(
          localState[privateStateConversationNotificationPreferencesKey],
        );
    Set<String> mutedConversationIds = activeMutedConversationIds(
      conversationNotificationPreferences,
    );

    WebSocketChannel? channel;
    Timer? reconnectTimer;
    bool stopped = false;

    // Declare as late so the two closures can reference each other.
    late void Function() connect;
    late void Function() reconnect;

    reconnect = () {
      reconnectTimer?.cancel();
      reconnectTimer = Timer(const Duration(seconds: 8), connect);
    };

    connect = () {
      if (stopped || token == null) return;
      try {
        channel = WebSocketChannel.connect(
          Uri.parse('${ApiConfig.wsUrl}?token=$token'),
        );
        channel!.stream.listen(
          (raw) => _handleRaw(
            raw,
            notif,
            showSensitive,
            mutedConversationIds,
            conversationNotificationPreferences,
          ),
          onError: (_) {
            channel = null;
            reconnect();
          },
          onDone: () {
            channel = null;
            reconnect();
          },
        );
      } catch (_) {
        reconnect();
      }
    };

    service.on('stop').listen((_) {
      stopped = true;
      reconnectTimer?.cancel();
      channel?.sink.close();
      service.stopSelf();
    });

    service.on('setToken').listen((data) {
      token = data?['token'] as String?;
      reconnectTimer?.cancel();
      channel?.sink.close();
      channel = null;
      if (!stopped && token != null) connect();
    });

    service.on('setSensitive').listen((data) {
      showSensitive = data?['sensitive'] as bool? ?? showSensitive;
    });

    service.on('setConversationNotificationPreferences').listen((data) {
      conversationNotificationPreferences =
          decodeConversationNotificationPreferences(
            data?['preferences'] as String?,
          );
      mutedConversationIds = activeMutedConversationIds(
        conversationNotificationPreferences,
      );
    });

    connect();
  }

  static void _handleRaw(
    dynamic raw,
    FlutterLocalNotificationsPlugin notif,
    bool showSensitive,
    Set<String> mutedConversationIds,
    Map<String, ConversationNotificationPreference>
    conversationNotificationPreferences,
  ) {
    if (raw is! String) return;
    for (final line in raw.trim().split('\n')) {
      if (line.isEmpty) continue;
      final intent = notificationIntentFromRawLine(
        line,
        showSensitive: showSensitive,
        mutedConversationIds: mutedConversationIds,
        conversationNotificationPreferences:
            conversationNotificationPreferences,
      );
      if (intent == null) continue;
      _showIntent(notif, intent);
    }
  }

  static NotificationIntent? notificationIntentFromRawLine(
    String rawLine, {
    required bool showSensitive,
    Set<String> mutedConversationIds = const {},
    Map<String, ConversationNotificationPreference>
        conversationNotificationPreferences =
        const {},
  }) => intent_mapper.notificationIntentFromRawLine(
    rawLine,
    showSensitive: showSensitive,
    mutedConversationIds: mutedConversationIds,
    conversationNotificationPreferences: conversationNotificationPreferences,
  );

  static NotificationIntent? notificationIntentFromEvent({
    required String type,
    required Map<String, dynamic> data,
    required bool showSensitive,
    Set<String> mutedConversationIds = const {},
    Map<String, ConversationNotificationPreference>
        conversationNotificationPreferences =
        const {},
  }) => intent_mapper.notificationIntentFromEvent(
    type: type,
    data: data,
    showSensitive: showSensitive,
    mutedConversationIds: mutedConversationIds,
    conversationNotificationPreferences: conversationNotificationPreferences,
  );

  static Future<Map<String, dynamic>> _loadLocalPrivateState() async {
    try {
      return await LocalPrivateStateService().readState();
    } catch (_) {
      return const {};
    }
  }

  static void _showIntent(
    FlutterLocalNotificationsPlugin notif,
    intent_mapper.NotificationIntent intent,
  ) {
    switch (intent.kind) {
      case intent_mapper.NotificationIntentKind.message:
        notif.show(
          id: intent.notificationId,
          title: intent.title,
          body: intent.body,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'bg_messages',
              'Background Messages',
              channelDescription:
                  'Messages received while the app is in the background',
              importance: Importance.high,
              priority: Priority.high,
            ),
            iOS: DarwinNotificationDetails(),
          ),
        );
        break;
      case intent_mapper.NotificationIntentKind.incomingCall:
        notif.show(
          id: intent.notificationId,
          title: intent.title,
          body: intent.body,
          notificationDetails:
              NotificationService.incomingCallNotificationDetails,
        );
        break;
    }
  }
}
