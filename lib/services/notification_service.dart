import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper around flutter_local_notifications for OS-level notifications.
/// The plugin has no Windows/web implementation, so every entry point is guarded
/// by [_supported]; on unsupported platforms the call is a no-op.
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  /// Set to the currently open conversation ID so notifications for it are
  /// suppressed while the user is already reading it.
  static String? _activeConversationId;

  static bool get _supported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isLinux);

  static void setActiveConversation(String? id) => _activeConversationId = id;

  static Future<void> init() async {
    if (!_supported || _inited) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
      macOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
      linux: LinuxInitializationSettings(defaultActionName: 'Open'),
      windows: WindowsInitializationSettings(
        appName: 'OpenChat',
        appUserModelId: 'OpenChat.Client.Desktop',
        guid: '4f8aa98f-306e-4f6d-84ee-e1206cd6b623',
      ),
    );
    await _plugin.initialize(settings: settings);
    _inited = true;
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
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      return granted ?? true;
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
    const details = NotificationDetails(
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
    await _plugin.show(id: 1, title: 'Incoming call', body: body, notificationDetails: details);
  }

  static Future<void> showMissedCall({required String body}) async {
    if (!_supported) return;
    await init();
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
