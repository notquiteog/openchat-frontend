import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide Message;
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config/api_config.dart';
import '../crypto/pgp_service.dart';
import '../models/message.dart';
import '../utils/local_conversation_preferences.dart';
import 'background_notification_intent.dart' as intent_mapper;
import 'background_notification_intent.dart'
    show NotificationIntent, NotificationContentVisibility;
import 'local_private_state_service.dart';
import 'notification_service.dart';
import 'secure_storage_service.dart';

export 'background_notification_intent.dart'
    show
        NotificationIntent,
        NotificationIntentKind,
        NotificationContentVisibility;

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
    required NotificationContentVisibility visibility,
    Map<String, ConversationNotificationPreference>
        conversationNotificationPreferences =
        const {},
    int? notificationsPausedUntilMs,
    int? globalQuietStartMinute,
    int? globalQuietEndMinute,
    bool pauseAllowsCalls = true,
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
        await updateContentVisibility(visibility);
        await updateConversationNotificationPreferences(
          conversationNotificationPreferences,
        );
        await updateGlobalNotificationPause(
          notificationsPausedUntilMs: notificationsPausedUntilMs,
          globalQuietStartMinute: globalQuietStartMinute,
          globalQuietEndMinute: globalQuietEndMinute,
          pauseAllowsCalls: pauseAllowsCalls,
        );
        await updateForegroundState(_appForeground);
        await setAutoStartOnBoot(true);
        return true;
      }
      final started = await _service.startService();
      if (started) {
        await updateContentVisibility(visibility);
        await updateConversationNotificationPreferences(
          conversationNotificationPreferences,
        );
        await updateGlobalNotificationPause(
          notificationsPausedUntilMs: notificationsPausedUntilMs,
          globalQuietStartMinute: globalQuietStartMinute,
          globalQuietEndMinute: globalQuietEndMinute,
          pauseAllowsCalls: pauseAllowsCalls,
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

  /// Sync the notification content-visibility preferences (show sender / show
  /// preview) into the running isolate without restarting the service.
  static Future<void> updateContentVisibility(
    NotificationContentVisibility visibility,
  ) async {
    if (!_mobileOnly) return;
    _service.invoke('setContentVisibility', {
      'showSender': visibility.showSender,
      'showPreview': visibility.showPreview,
    });
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

  static Future<void> updateGlobalNotificationPause({
    int? notificationsPausedUntilMs,
    int? globalQuietStartMinute,
    int? globalQuietEndMinute,
    bool pauseAllowsCalls = true,
  }) async {
    if (!_mobileOnly) return;
    _service.invoke('setGlobalNotificationPause', {
      'notificationsPausedUntilMs': notificationsPausedUntilMs,
      'globalQuietStartMinute': globalQuietStartMinute,
      'globalQuietEndMinute': globalQuietEndMinute,
      'pauseAllowsCalls': pauseAllowsCalls,
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
    var visibility = NotificationContentVisibility.hidden;
    Map<String, ConversationNotificationPreference>
    conversationNotificationPreferences = const {};
    Set<String> mutedConversationIds = const {};
    int? notificationsPausedUntilMs;
    int? globalQuietStartMinute;
    int? globalQuietEndMinute;
    bool pauseAllowsCalls = true;

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
            unawaited(
              _handleRaw(
                raw,
                notif,
                visibility,
                mutedConversationIds,
                conversationNotificationPreferences,
                notificationsPausedUntilMs,
                globalQuietStartMinute,
                globalQuietEndMinute,
                pauseAllowsCalls,
              ),
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

    service.on('setContentVisibility').listen((data) {
      visibility = NotificationContentVisibility(
        showSender: data?['showSender'] as bool? ?? visibility.showSender,
        showPreview: data?['showPreview'] as bool? ?? visibility.showPreview,
      );
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

    service.on('setGlobalNotificationPause').listen((data) {
      notificationsPausedUntilMs = data?['notificationsPausedUntilMs'] as int?;
      globalQuietStartMinute = data?['globalQuietStartMinute'] as int?;
      globalQuietEndMinute = data?['globalQuietEndMinute'] as int?;
      pauseAllowsCalls = data?['pauseAllowsCalls'] as bool? ?? true;
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
    final notificationSettings = decodePrivateNotificationSettings(
      localState[privateStateNotificationSettingsKey],
    );
    visibility = NotificationContentVisibility(
      showSender: notificationSettings.showSender,
      showPreview: notificationSettings.showPreview,
    );
    notificationsPausedUntilMs =
        notificationSettings.notificationsPausedUntilMs;
    globalQuietStartMinute = notificationSettings.globalQuietHoursStartMinute;
    globalQuietEndMinute = notificationSettings.globalQuietHoursEndMinute;
    pauseAllowsCalls = notificationSettings.pauseAllowsCalls;
    conversationNotificationPreferences =
        decodePrivateConversationNotificationPreferences(
          localState[privateStateConversationNotificationPreferencesKey],
        );
    mutedConversationIds = activeMutedConversationIds(
      conversationNotificationPreferences,
    );

    if (!stopped) connect();
  }

  static Future<void> _handleRaw(
    dynamic raw,
    FlutterLocalNotificationsPlugin notif,
    NotificationContentVisibility visibility,
    Set<String> mutedConversationIds,
    Map<String, ConversationNotificationPreference>
    conversationNotificationPreferences,
    int? notificationsPausedUntilMs,
    int? globalQuietStartMinute,
    int? globalQuietEndMinute,
    bool pauseAllowsCalls,
  ) async {
    if (raw is! String) return;
    for (final line in raw.trim().split('\n')) {
      if (line.isEmpty) continue;
      Map<String, dynamic> json;
      try {
        json = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final type = json['type'] as String?;
      if (type == null) continue;
      final data = (json['data'] as Map<String, dynamic>?) ?? const {};
      // Resolve the group/channel name and a decrypted body snippet locally —
      // both are absent from the sealed event. Best-effort: any failure leaves
      // the relevant field null and the mapper falls back to generic text.
      String? conversationTitle;
      String? previewText;
      if (type == 'new_message') {
        final extras = await _resolveNewMessageExtras(data, visibility);
        conversationTitle = extras.$1;
        previewText = extras.$2;
      }
      final intent = intent_mapper.notificationIntentFromEvent(
        type: type,
        data: data,
        visibility: visibility,
        conversationTitle: conversationTitle,
        previewText: previewText,
        mutedConversationIds: mutedConversationIds,
        conversationNotificationPreferences:
            conversationNotificationPreferences,
        notificationsPausedUntilMs: notificationsPausedUntilMs,
        globalQuietStartMinute: globalQuietStartMinute,
        globalQuietEndMinute: globalQuietEndMinute,
        pauseAllowsCalls: pauseAllowsCalls,
      );
      if (intent == null) continue;
      _showIntent(notif, intent);
    }
  }

  /// Resolves the two receiver-side bits the isolate can't read off a sealed
  /// event: the group/channel display name (for the title) and a decrypted
  /// body snippet (for the preview). Reads are gated on the matching visibility
  /// flag so we never touch the keyring/decrypt when the user keeps content
  /// hidden. Returns (conversationTitle, previewText); either may be null.
  static Future<(String?, String?)> _resolveNewMessageExtras(
    Map<String, dynamic> data,
    NotificationContentVisibility visibility,
  ) async {
    String? conversationTitle;
    String? previewText;
    final convId = data['conversation_id'] as String?;
    if (visibility.showSender && convId != null && convId.isNotEmpty) {
      try {
        final state = await LocalPrivateStateService().readState();
        final meta = decodeConversationMeta(
          state[privateStateConversationMetaKey],
        )[convId];
        if (meta != null &&
            meta.isGroupOrChannel &&
            meta.name.trim().isNotEmpty) {
          conversationTitle = meta.name.trim();
        }
      } catch (_) {}
    }
    if (visibility.showPreview) {
      try {
        final cipher = data['encrypted_payload'] as String?;
        final privateKey = await SecureStorageService().getPrivateKey();
        if (cipher != null &&
            cipher.isNotEmpty &&
            privateKey != null &&
            privateKey.isNotEmpty) {
          final plaintext = await PgpService.decrypt(
            encryptedArmor: cipher,
            privateKeyArmored: privateKey,
          );
          if (plaintext.isNotEmpty) {
            final msg = Message.fromJson(data)..setDecryptedContent(plaintext);
            previewText = msg.notificationPreview;
          }
        }
      } catch (_) {
        // Keyring locked, FFI unavailable in this isolate, malformed payload —
        // leave previewText null so the body stays a generic "New message".
      }
    }
    return (conversationTitle, previewText);
  }

  static NotificationIntent? notificationIntentFromRawLine(
    String rawLine, {
    required NotificationContentVisibility visibility,
    String? conversationTitle,
    String? previewText,
    Set<String> mutedConversationIds = const {},
    Map<String, ConversationNotificationPreference>
        conversationNotificationPreferences =
        const {},
    int? notificationsPausedUntilMs,
    int? globalQuietStartMinute,
    int? globalQuietEndMinute,
    bool pauseAllowsCalls = true,
  }) => intent_mapper.notificationIntentFromRawLine(
    rawLine,
    visibility: visibility,
    conversationTitle: conversationTitle,
    previewText: previewText,
    mutedConversationIds: mutedConversationIds,
    conversationNotificationPreferences: conversationNotificationPreferences,
    notificationsPausedUntilMs: notificationsPausedUntilMs,
    globalQuietStartMinute: globalQuietStartMinute,
    globalQuietEndMinute: globalQuietEndMinute,
    pauseAllowsCalls: pauseAllowsCalls,
  );

  static NotificationIntent? notificationIntentFromEvent({
    required String type,
    required Map<String, dynamic> data,
    required NotificationContentVisibility visibility,
    String? conversationTitle,
    String? previewText,
    Set<String> mutedConversationIds = const {},
    Map<String, ConversationNotificationPreference>
        conversationNotificationPreferences =
        const {},
    int? notificationsPausedUntilMs,
    int? globalQuietStartMinute,
    int? globalQuietEndMinute,
    bool pauseAllowsCalls = true,
  }) => intent_mapper.notificationIntentFromEvent(
    type: type,
    data: data,
    visibility: visibility,
    conversationTitle: conversationTitle,
    previewText: previewText,
    mutedConversationIds: mutedConversationIds,
    conversationNotificationPreferences: conversationNotificationPreferences,
    notificationsPausedUntilMs: notificationsPausedUntilMs,
    globalQuietStartMinute: globalQuietStartMinute,
    globalQuietEndMinute: globalQuietEndMinute,
    pauseAllowsCalls: pauseAllowsCalls,
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
