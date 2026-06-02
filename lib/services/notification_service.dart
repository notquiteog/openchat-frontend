import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

@pragma('vm:entry-point')
void openChatNotificationBackgroundHandler(NotificationResponse response) {
  NotificationService.handleNotificationResponse(response);
}

/// Thin wrapper around flutter_local_notifications for OS-level notifications.
/// The plugin has no Windows/web implementation, so every entry point is guarded
/// by [_supported]; on unsupported platforms the call is a no-op.
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _inited = false;
  static bool _available = true;
  static const List<AndroidNotificationChannel> _androidChannels = [
    AndroidNotificationChannel(
      'messages',
      'Messages',
      description: 'Notifications for new messages',
      importance: Importance.high,
    ),
    AndroidNotificationChannel(
      'calls',
      'Calls',
      description: 'Notifications for incoming calls',
      importance: Importance.max,
    ),
    AndroidNotificationChannel(
      'missed_calls',
      'Missed calls',
      description: 'Notifications for missed voice and video calls',
      importance: Importance.high,
    ),
    AndroidNotificationChannel(
      'active_calls',
      'Active calls',
      description: 'Ongoing OpenChat voice and video calls',
      importance: Importance.low,
    ),
    AndroidNotificationChannel(
      'bg_messages',
      'Background Messages',
      description: 'Messages received while the app is in the background',
      importance: Importance.high,
    ),
    AndroidNotificationChannel(
      'bg_calls',
      'Background Calls',
      description:
          'Call notifications received while the app is in the background',
      importance: Importance.max,
    ),
    AndroidNotificationChannel(
      'openchat_background',
      'OpenChat background service',
      description: 'Keeps OpenChat connected for background notifications',
      importance: Importance.low,
    ),
  ];

  @visibleForTesting
  static List<String> get androidNotificationChannelIds =>
      _androidChannels.map((channel) => channel.id).toList(growable: false);

  /// Set to the currently open conversation ID so notifications for it are
  /// suppressed while the user is already reading it.
  static String? _activeConversationId;
  static const int _activeCallNotificationId = 2;
  static const String _activeCallEndActionId = 'openchat_call_end';
  static const String _activeCallMuteActionId = 'openchat_call_mute';
  static VoidCallback? _activeCallEndHandler;
  static VoidCallback? _activeCallToggleMuteHandler;

  static bool get _supported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isLinux);

  static void setActiveConversation(String? id) => _activeConversationId = id;
  static void setActiveCallHandlers({
    VoidCallback? onEnd,
    VoidCallback? onToggleMute,
  }) {
    _activeCallEndHandler = onEnd;
    _activeCallToggleMuteHandler = onToggleMute;
  }

  @visibleForTesting
  static void debugHandleNotificationResponse(NotificationResponse response) =>
      handleNotificationResponse(response);

  static void handleNotificationResponse(NotificationResponse response) {
    switch (response.actionId) {
      case _activeCallEndActionId:
        _activeCallEndHandler?.call();
        return;
      case _activeCallMuteActionId:
        _activeCallToggleMuteHandler?.call();
        return;
      default:
        return;
    }
  }

  static Future<void> init() async {
    if (!_supported || _inited || !_available) return;
    final settings = InitializationSettings(
      android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
        notificationCategories: [
          DarwinNotificationCategory(
            'openchat_active_call',
            actions: [
              DarwinNotificationAction.plain(
                _activeCallMuteActionId,
                'Mute',
                options: {DarwinNotificationActionOption.foreground},
              ),
              DarwinNotificationAction.plain(
                _activeCallEndActionId,
                'End',
                options: {
                  DarwinNotificationActionOption.destructive,
                  DarwinNotificationActionOption.foreground,
                },
              ),
            ],
          ),
        ],
      ),
      macOS: const DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
      linux: const LinuxInitializationSettings(defaultActionName: 'Open'),
      windows: const WindowsInitializationSettings(
        appName: 'OpenChat',
        appUserModelId: 'OpenChat.Client.Desktop',
        guid: '4f8aa98f-306e-4f6d-84ee-e1206cd6b623',
      ),
    );
    try {
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: handleNotificationResponse,
        onDidReceiveBackgroundNotificationResponse:
            openChatNotificationBackgroundHandler,
      );
      await _ensureAndroidChannels();
      _inited = true;
    } catch (e) {
      _available = false;
      debugPrint('NotificationService unavailable: $e');
    }
  }

  static Future<void> _ensureAndroidChannels() async {
    if (!Platform.isAndroid) return;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    for (final channel in _androidChannels) {
      await android.createNotificationChannel(channel);
    }
  }

  /// Explicitly request notification permissions. Call this when the user
  /// opts into a notification channel (e.g. background WebSocket) that uses
  /// local notifications but does NOT go through firebase_messaging (which
  /// requests its own permissions via requestPermission()).
  ///
  /// Returns true if permission was granted or is not required on this
  /// platform. On Android 13+, the POST_NOTIFICATIONS runtime permission is
  /// requested here instead of at init() time so the prompt appears in
  /// response to a clear user action.
  static Future<bool> requestPermission() async {
    if (!_supported) return true;
    await init();
    if (!_available) return false;
    if (Platform.isIOS) {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      return granted ?? false;
    }
    if (Platform.isMacOS) {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      return granted ?? false;
    }
    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return true;
      final alreadyEnabled = await android.areNotificationsEnabled();
      if (alreadyEnabled ?? false) return true;
      final granted = await android.requestNotificationsPermission();
      if (granted ?? false) return true;
      final enabledAfterRequest = await android.areNotificationsEnabled();
      return enabledAfterRequest ?? false;
    }
    return true;
  }

  static Future<void> showMessage({
    required String conversationId,
    required String title,
    required String body,
    bool showSensitive = false,
  }) async {
    if (!_supported) return;
    if (_activeConversationId == conversationId) return;
    await init();
    if (!_available) return;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'messages',
        'Messages',
        channelDescription: 'Notifications for new messages',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
      linux: LinuxNotificationDetails(),
      windows: WindowsNotificationDetails(),
    );
    final displayTitle = showSensitive ? title : 'OpenChat';
    final displayBody = showSensitive ? body : 'You have a new message';
    // One notification slot per conversation — updates in place rather than stacking.
    await _plugin.show(
      id: conversationId.hashCode,
      title: displayTitle,
      body: displayBody,
      notificationDetails: details,
    );
  }

  static Future<void> showIncomingCall({required String body}) async {
    if (!_supported) return;
    await init();
    if (!_available) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'calls',
        'Calls',
        channelDescription: 'Notifications for incoming calls',
        importance: Importance.max,
        priority: Priority.max,
      ),
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
      linux: LinuxNotificationDetails(),
      windows: WindowsNotificationDetails(
        scenario: WindowsNotificationScenario.incomingCall,
      ),
    );
    await _plugin.show(
        id: 1,
        title: 'Incoming call',
        body: body,
        notificationDetails: details);
  }

  static Future<void> showActiveCall({
    required String title,
    required String body,
    bool muted = false,
  }) async {
    if (!_supported) return;
    await init();
    if (!_available) return;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'active_calls',
        'Active calls',
        channelDescription: 'Ongoing OpenChat voice and video calls',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
        usesChronometer: true,
        actions: [
          AndroidNotificationAction(
            _activeCallMuteActionId,
            muted ? 'Unmute' : 'Mute',
            cancelNotification: false,
            showsUserInterface: true,
            semanticAction: muted ? SemanticAction.unmute : SemanticAction.mute,
          ),
          AndroidNotificationAction(
            _activeCallEndActionId,
            'End',
            cancelNotification: false,
            showsUserInterface: true,
          ),
        ],
      ),
      iOS: DarwinNotificationDetails(
        categoryIdentifier: 'openchat_active_call',
        presentSound: false,
      ),
      macOS: DarwinNotificationDetails(
        categoryIdentifier: 'openchat_active_call',
        presentSound: false,
      ),
      linux: LinuxNotificationDetails(),
      windows: WindowsNotificationDetails(),
    );
    await _plugin.show(
      id: _activeCallNotificationId,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  static Future<void> cancelActiveCall() async {
    if (!_supported) return;
    await init();
    if (!_available) return;
    await _plugin.cancel(id: _activeCallNotificationId);
  }

  static Future<void> showMissedCall({required String body}) async {
    if (!_supported) return;
    await init();
    if (!_available) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'missed_calls',
        'Missed calls',
        channelDescription: 'Notifications for missed voice and video calls',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
      linux: LinuxNotificationDetails(),
      windows: WindowsNotificationDetails(),
    );
    await _plugin.show(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: 'Missed call',
      body: body,
      notificationDetails: details,
    );
  }
}
