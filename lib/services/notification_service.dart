import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:window_manager/window_manager.dart';

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
  static const int incomingCallNotificationId = 1;
  static const String incomingCallAnswerActionId = 'openchat_call_answer';
  static const String incomingCallDismissActionId = 'openchat_call_dismiss';
  static const String incomingCallDeclineActionId = 'openchat_call_decline';
  static const String _incomingCallCategory = 'openchat_incoming_call';
  static const String _activeCallCategoryUnmuted =
      'openchat_active_call_unmuted';
  static const String _activeCallCategoryMuted = 'openchat_active_call_muted';
  static VoidCallback? _activeCallEndHandler;
  static VoidCallback? _activeCallToggleMuteHandler;
  static VoidCallback? _incomingCallAnswerHandler;
  static VoidCallback? _incomingCallDismissHandler;
  static VoidCallback? _incomingCallDeclineHandler;
  static bool _appFocused = true;

  static bool get _supported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isLinux);

  static const NotificationDetails incomingCallNotificationDetails =
      NotificationDetails(
        android: AndroidNotificationDetails(
          'calls',
          'Calls',
          channelDescription: 'Notifications for incoming calls',
          importance: Importance.max,
          priority: Priority.max,
          actions: [
            AndroidNotificationAction(
              incomingCallAnswerActionId,
              'Answer',
              cancelNotification: true,
              showsUserInterface: true,
              semanticAction: SemanticAction.call,
            ),
            AndroidNotificationAction(
              incomingCallDismissActionId,
              'Dismiss',
              cancelNotification: true,
              showsUserInterface: true,
            ),
            AndroidNotificationAction(
              incomingCallDeclineActionId,
              'Decline',
              cancelNotification: true,
              showsUserInterface: true,
            ),
          ],
        ),
        iOS: DarwinNotificationDetails(
          categoryIdentifier: _incomingCallCategory,
          presentBanner: true,
          presentList: true,
          presentSound: true,
        ),
        macOS: DarwinNotificationDetails(
          categoryIdentifier: _incomingCallCategory,
          presentBanner: true,
          presentList: true,
          presentSound: true,
        ),
        linux: LinuxNotificationDetails(
          actions: [
            LinuxNotificationAction(
              key: incomingCallAnswerActionId,
              label: 'Answer',
            ),
            LinuxNotificationAction(
              key: incomingCallDismissActionId,
              label: 'Dismiss',
            ),
            LinuxNotificationAction(
              key: incomingCallDeclineActionId,
              label: 'Decline',
            ),
          ],
        ),
        windows: WindowsNotificationDetails(
          scenario: WindowsNotificationScenario.incomingCall,
          actions: [
            WindowsAction(
              content: 'Answer',
              arguments: incomingCallAnswerActionId,
              buttonStyle: WindowsButtonStyle.success,
            ),
            WindowsAction(
              content: 'Dismiss',
              arguments: incomingCallDismissActionId,
            ),
            WindowsAction(
              content: 'Decline',
              arguments: incomingCallDeclineActionId,
              buttonStyle: WindowsButtonStyle.critical,
            ),
          ],
        ),
      );

  static void setActiveConversation(String? id) => _activeConversationId = id;
  static void setAppFocused(bool focused) => _appFocused = focused;

  static bool get _desktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static Future<bool> _isFocusedWindow() async {
    if (!_appFocused) return false;
    if (_desktop) {
      try {
        return await windowManager.isFocused();
      } catch (_) {
        return _appFocused;
      }
    }
    return _appFocused;
  }

  static Future<bool> _shouldSuppressFocusedNotification() async {
    if (!_supported) return true;
    return _isFocusedWindow();
  }

  static void setActiveCallHandlers({
    VoidCallback? onEnd,
    VoidCallback? onToggleMute,
  }) {
    _activeCallEndHandler = onEnd;
    _activeCallToggleMuteHandler = onToggleMute;
  }

  static void setIncomingCallHandlers({
    VoidCallback? onAnswer,
    VoidCallback? onDismiss,
    VoidCallback? onDecline,
  }) {
    _incomingCallAnswerHandler = onAnswer;
    _incomingCallDismissHandler = onDismiss;
    _incomingCallDeclineHandler = onDecline;
  }

  @visibleForTesting
  static void debugHandleNotificationResponse(NotificationResponse response) =>
      handleNotificationResponse(response);

  static void handleNotificationResponse(NotificationResponse response) {
    switch (response.actionId) {
      case incomingCallAnswerActionId:
        _incomingCallAnswerHandler?.call();
        unawaited(cancelIncomingCall());
        return;
      case incomingCallDismissActionId:
        _incomingCallDismissHandler?.call();
        unawaited(cancelIncomingCall());
        return;
      case incomingCallDeclineActionId:
        _incomingCallDeclineHandler?.call();
        unawaited(cancelIncomingCall());
        return;
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
    final activeCallCategories = [
      DarwinNotificationCategory(
        _incomingCallCategory,
        actions: [
          DarwinNotificationAction.plain(
            incomingCallAnswerActionId,
            'Answer',
            options: {DarwinNotificationActionOption.foreground},
          ),
          DarwinNotificationAction.plain(
            incomingCallDismissActionId,
            'Dismiss',
            options: {DarwinNotificationActionOption.foreground},
          ),
          DarwinNotificationAction.plain(
            incomingCallDeclineActionId,
            'Decline',
            options: {
              DarwinNotificationActionOption.destructive,
              DarwinNotificationActionOption.foreground,
            },
          ),
        ],
      ),
      DarwinNotificationCategory(
        _activeCallCategoryUnmuted,
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
      DarwinNotificationCategory(
        _activeCallCategoryMuted,
        actions: [
          DarwinNotificationAction.plain(
            _activeCallMuteActionId,
            'Unmute',
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
    ];
    final settings = InitializationSettings(
      android: const AndroidInitializationSettings('@mipmap/launcher_icon'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
        notificationCategories: activeCallCategories,
      ),
      macOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
        notificationCategories: activeCallCategories,
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
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
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
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      return granted ?? false;
    }
    if (Platform.isMacOS) {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      return granted ?? false;
    }
    if (Platform.isAndroid) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
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
    if (await _shouldSuppressFocusedNotification()) return;
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
    if (await _shouldSuppressFocusedNotification()) return;
    await init();
    if (!_available) return;
    await _plugin.show(
      id: incomingCallNotificationId,
      title: 'Incoming call',
      body: body,
      notificationDetails: incomingCallNotificationDetails,
    );
  }

  static Future<void> showActiveCall({
    required String title,
    required String body,
    bool muted = false,
    int? connectedAtMillis,
  }) async {
    if (!_supported) return;
    if (await _shouldSuppressFocusedNotification()) {
      await cancelActiveCall();
      return;
    }
    await init();
    if (!_available) return;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'active_calls',
        'Active calls',
        channelDescription: 'Ongoing OpenChat voice and video calls',
        icon: '@mipmap/launcher_icon',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
        showWhen: connectedAtMillis != null,
        when: connectedAtMillis,
        usesChronometer: connectedAtMillis != null,
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
        categoryIdentifier: muted
            ? _activeCallCategoryMuted
            : _activeCallCategoryUnmuted,
        presentSound: false,
        presentBanner: true,
        presentList: true,
      ),
      macOS: DarwinNotificationDetails(
        categoryIdentifier: muted
            ? _activeCallCategoryMuted
            : _activeCallCategoryUnmuted,
        presentSound: false,
        presentBanner: true,
        presentList: true,
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

  static Future<void> cancelIncomingCall() async {
    if (!_supported) return;
    await init();
    if (!_available) return;
    await _plugin.cancel(id: incomingCallNotificationId);
  }

  static Future<void> showMissedCall({required String body}) async {
    if (!_supported) return;
    if (await _shouldSuppressFocusedNotification()) return;
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
