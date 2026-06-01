import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config/api_config.dart';

enum NotificationIntentKind { message, incomingCall }

class NotificationIntent {
  final NotificationIntentKind kind;
  final int notificationId;
  final String title;
  final String body;

  const NotificationIntent({
    required this.kind,
    required this.notificationId,
    required this.title,
    required this.body,
  });
}

/// Persists a WebSocket connection while the app is in the background so that
/// users receive message and call notifications without relying on Firebase.
///
/// ──────────────────────────────────────────────────────────────────────────
/// Native setup required for full background execution on mobile:
///
/// Android — add to AndroidManifest.xml inside `<application>`:
///   ```xml
///   <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
///   <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>
///   <service
///     android:name="id.flutter/flutter_background_service_android.BackgroundService"
///     android:exported="false"
///     android:foregroundServiceType="dataSync"/>
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
  static const _kToken = 'bg_ws_access_token';
  static const _kSensitive = 'bg_ws_sensitive_content';

  static bool get _mobileOnly =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

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

  /// Start the background service. Stores [accessToken] and [showSensitive] in
  /// SharedPreferences so the isolated service can read them.
  static Future<bool> start({
    required String accessToken,
    required bool showSensitive,
  }) async {
    if (!_mobileOnly) {
      return true; // desktop: process stays alive, nothing to do
    }
    if (accessToken.isEmpty) return false;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kToken, accessToken);
      await prefs.setBool(_kSensitive, showSensitive);

      if (await _service.isRunning()) {
        await updateToken(accessToken);
        await updateSensitiveContent(showSensitive);
        return true;
      }
      return _service.startService();
    } catch (e) {
      debugPrint('Background WebSocket start failed: $e');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kToken);
      return false;
    }
  }

  /// Stop the background service and clean up the stored token.
  static Future<void> stop() async {
    if (!_mobileOnly) return;
    try {
      _service.invoke('stop');
    } catch (e) {
      debugPrint('Background WebSocket stop failed: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
  }

  /// Push a refreshed access token into the running service.
  static Future<void> updateToken(String accessToken) async {
    if (!_mobileOnly) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kToken, accessToken);
    _service.invoke('setToken', {'token': accessToken});
  }

  /// Sync the sensitive-content preference without restarting the service.
  static Future<void> updateSensitiveContent(bool showSensitive) async {
    if (!_mobileOnly) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSensitive, showSensitive);
    _service.invoke('setSensitive', {'sensitive': showSensitive});
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
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    String? token = prefs.getString(_kToken);
    bool showSensitive = prefs.getBool(_kSensitive) ?? false;

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
          (raw) => _handleRaw(raw, notif, showSensitive),
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

    connect();
  }

  static void _handleRaw(
    dynamic raw,
    FlutterLocalNotificationsPlugin notif,
    bool showSensitive,
  ) {
    if (raw is! String) return;
    for (final line in raw.trim().split('\n')) {
      if (line.isEmpty) continue;
      final intent = notificationIntentFromRawLine(
        line,
        showSensitive: showSensitive,
      );
      if (intent == null) continue;
      _showIntent(notif, intent);
    }
  }

  static NotificationIntent? notificationIntentFromRawLine(
    String rawLine, {
    required bool showSensitive,
  }) {
    try {
      final json = jsonDecode(rawLine) as Map<String, dynamic>;
      final type = json['type'] as String?;
      final data = (json['data'] as Map<String, dynamic>?) ?? {};
      if (type == null) return null;
      return notificationIntentFromEvent(
        type: type,
        data: data,
        showSensitive: showSensitive,
      );
    } catch (_) {
      return null;
    }
  }

  static NotificationIntent? notificationIntentFromEvent({
    required String type,
    required Map<String, dynamic> data,
    required bool showSensitive,
  }) {
    if (type == 'new_message') {
      final convId = data['conversation_id'] as String? ?? 'msg';
      final sender = data['sender_username'] as String?;
      return NotificationIntent(
        kind: NotificationIntentKind.message,
        notificationId: convId.hashCode,
        title: showSensitive && sender != null ? '@$sender' : 'OpenChat',
        body: showSensitive ? 'New message' : 'You have a new message',
      );
    }

    if (type == 'call_offer' || type == 'incoming_call') {
      final caller = data['caller_username'] as String?;
      return NotificationIntent(
        kind: NotificationIntentKind.incomingCall,
        notificationId: 1,
        title: 'Incoming call',
        body:
            showSensitive && caller != null ? '@$caller is calling' : 'Incoming call',
      );
    }

    return null;
  }

  static void _showIntent(
    FlutterLocalNotificationsPlugin notif,
    NotificationIntent intent,
  ) {
    switch (intent.kind) {
      case NotificationIntentKind.message:
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
      case NotificationIntentKind.incomingCall:
        notif.show(
          id: intent.notificationId,
          title: intent.title,
          body: intent.body,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'bg_calls',
              'Background Calls',
              channelDescription:
                  'Call notifications received while the app is in the background',
              importance: Importance.max,
              priority: Priority.max,
            ),
            iOS: DarwinNotificationDetails(),
          ),
        );
        break;
    }
  }
}
