import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
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

  static Duration backgroundReconnectDelay(int attempt, int jitterMillis) {
    final safeAttempt = attempt < 0 ? 0 : attempt;
    final safeJitter = jitterMillis.clamp(0, 999);
    final seconds = math.min(15, 1 << math.min(safeAttempt, 3));
    return Duration(seconds: seconds, milliseconds: safeJitter);
  }

  /// Last lifecycle state pushed by the app shell; replayed into the isolate
  /// right after start so it doesn't boot believing the app is backgrounded
  /// while the user is actively reading a chat. Defaults to true because the
  /// main isolate (the only writer) necessarily starts foregrounded.
  static bool _appForeground = true;

  /// Configure the background service. Call once at app startup.
  static Future<void> configure() async {
    if (!_mobileOnly) return;

    // Mirror the persisted user setting into the boot receiver so an enabled
    // background channel comes back after a reboot without opening the app.
    bool autoStartOnBoot = false;
    try {
      final state = await _loadLocalPrivateState();
      autoStartOnBoot = decodePrivateNotificationSettings(
        state[privateStateNotificationSettingsKey],
      ).wsBackgroundEnabled;
    } catch (_) {}
    await _configure(autoStartOnBoot: autoStartOnBoot);
  }

  /// Keep the boot receiver in sync when the setting is toggled: the plugin
  /// persists autoStartOnBoot at configure time, so re-run configure with the
  /// new flag (autoStart stays false — this never starts/stops the service).
  static Future<void> setAutoStartOnBoot(bool enabled) async {
    if (!_mobileOnly) return;
    await _configure(autoStartOnBoot: enabled);
  }

  static Future<void> _configure({required bool autoStartOnBoot}) async {
    try {
      await _service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: _onStart,
          autoStart: false,
          autoStartOnBoot: autoStartOnBoot,
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
        await updateForegroundState(_appForeground);
        await setAutoStartOnBoot(true);
        return true;
      }
      final started = await _service.startService();
      if (started) {
        await updateSensitiveContent(showSensitive);
        await updateConversationNotificationPreferences(
          conversationNotificationPreferences,
        );
        // The isolate boots assuming background (correct for boot auto-start,
        // where no main isolate exists); replay the real lifecycle state so a
        // foregrounded enable doesn't notify for the chat being read.
        await updateForegroundState(_appForeground);
        await setAutoStartOnBoot(true);
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
    // Disabled channels must not resurrect themselves after a reboot.
    await setAutoStartOnBoot(false);
  }

  /// Push a refreshed access token into the running service.
  static Future<void> updateToken(String accessToken) async {
    if (!_mobileOnly) return;
    try {
      _service.invoke('setToken', {'token': accessToken});
    } catch (_) {}
  }

  /// Sync the sensitive-content preference without restarting the service.
  static Future<void> updateSensitiveContent(bool showSensitive) async {
    if (!_mobileOnly) return;
    _service.invoke('setSensitive', {'sensitive': showSensitive});
  }

  /// Tell the isolate whether the app is foregrounded. While foreground, the
  /// main isolate handles notifications (with focus/active-chat suppression);
  /// the background isolate posting too produced system notifications for the
  /// chat the user was actively reading.
  static Future<void> updateForegroundState(bool foreground) async {
    _appForeground = foreground;
    if (!_mobileOnly) return;
    try {
      _service.invoke('setForeground', {'foreground': foreground});
    } catch (_) {}
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

    // Isolate state. Declared (and the service.on listeners below registered)
    // BEFORE the async storage loads: the main isolate fires set* events right
    // after startService(), and events on the plugin's broadcast stream are
    // dropped if no listener is attached yet.
    String? token;
    bool showSensitive = false;
    Map<String, ConversationNotificationPreference>
    conversationNotificationPreferences = const {};
    Set<String> mutedConversationIds = const {};

    WebSocketChannel? channel;
    Timer? reconnectTimer;
    bool stopped = false;
    // connect() awaits a storage read, so guard against overlapping attempts
    // (setToken and the reconnect timer can both fire it).
    bool connecting = false;
    int reconnectAttempt = 0;
    final reconnectJitter = math.Random();
    // While the app is foregrounded the MAIN isolate posts notifications (with
    // focus + active-conversation suppression); this isolate stays silent.
    // start() replays the real lifecycle state right after boot; false is the
    // correct default for the one spawn path with no main isolate (boot).
    bool appForeground = false;

    // Local notifications inside the background isolate (initialised below,
    // before the first connect).
    final notif = FlutterLocalNotificationsPlugin();

    // Declare as late so the two closures can reference each other.
    late void Function() connect;
    late void Function() reconnect;

    reconnect = () {
      reconnectTimer?.cancel();
      final delay = backgroundReconnectDelay(
        reconnectAttempt,
        reconnectJitter.nextInt(1000),
      );
      reconnectAttempt += 1;
      reconnectTimer = Timer(delay, connect);
    };

    connect = () async {
      if (stopped || connecting || channel != null) return;
      connecting = true;
      try {
        // Re-read the access token on every attempt: access tokens are
        // short-lived, so any token captured at start is stale by the first
        // reconnect after a longer disconnect. The main isolate persists
        // refreshed tokens to secure storage before pushing them here, so
        // storage is always at least as fresh as the last setToken event.
        try {
          final stored = await SecureStorageService().getAccessToken();
          if (stored != null && stored.isNotEmpty) token = stored;
        } catch (_) {
          // Keep the last known token when storage is briefly unreadable.
        }
        if (stopped || token == null) return;
        channel = WebSocketChannel.connect(
          Uri.parse(ApiConfig.wsUrl),
          protocols: ['openchat.v1', 'openchat.jwt.$token'],
        );
        channel!.stream.listen(
          (raw) {
            reconnectAttempt = 0;
            if (appForeground) return;
            _handleRaw(
              raw,
              notif,
              showSensitive,
              mutedConversationIds,
              conversationNotificationPreferences,
            );
          },
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
        channel = null;
        reconnect();
      } finally {
        connecting = false;
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
      reconnectAttempt = 0;
      channel?.sink.close();
      channel = null;
      if (!stopped && token != null) connect();
    });

    service.on('setSensitive').listen((data) {
      showSensitive = data?['sensitive'] as bool? ?? showSensitive;
    });

    service.on('setForeground').listen((data) {
      appForeground = data?['foreground'] as bool? ?? false;
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

    // Initialise local notifications inside the background isolate.
    await notif.initialize(
      settings: const InitializationSettings(
        // Transparent logo foreground for the (alpha-masked) status-bar icon;
        // the full-color app icon is shown via largeIcon per notification.
        android: AndroidInitializationSettings(
          '@drawable/ic_launcher_foreground',
        ),
        iOS: DarwinInitializationSettings(),
      ),
    );

    // Self-load persisted state: the start() invokes above are best-effort
    // (same values, already persisted), so a boot-receiver spawn with no main
    // isolate still gets token + notification rules.
    final localState = await _loadLocalPrivateState();
    token ??= await SecureStorageService().getAccessToken();
    showSensitive = decodePrivateNotificationSettings(
      localState[privateStateNotificationSettingsKey],
    ).sensitiveContent;
    conversationNotificationPreferences =
        decodePrivateConversationNotificationPreferences(
          localState[privateStateConversationNotificationPreferencesKey],
        );
    mutedConversationIds = activeMutedConversationIds(
      conversationNotificationPreferences,
    );

    if (!stopped) connect();
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
              icon: '@drawable/ic_launcher_foreground',
              largeIcon: DrawableResourceAndroidBitmap('@mipmap/launcher_icon'),
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
