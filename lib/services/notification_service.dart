import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:window_manager/window_manager.dart';
import '../utils/local_conversation_preferences.dart';

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
      'message_reminders',
      'Message reminders',
      description: 'Notifications for message reminders',
      importance: Importance.high,
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
  static Set<String> _mutedConversationIds = const {};
  static Map<String, ConversationNotificationPreference>
  _conversationNotificationPreferences = const {};
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
  static const String _liveLocationCancelActionId =
      'openchat_live_location_cancel';
  static const String _liveLocationCategory = 'openchat_live_location';
  static const String _messageReminderCategory = 'openchat_message_reminder';
  static VoidCallback? _activeCallEndHandler;
  static VoidCallback? _activeCallToggleMuteHandler;
  static VoidCallback? _incomingCallAnswerHandler;
  static VoidCallback? _incomingCallDismissHandler;
  static VoidCallback? _incomingCallDeclineHandler;
  static FutureOr<void> Function(Map<String, dynamic>)?
  _incomingCallPayloadHandler;
  static final List<NotificationResponse> _pendingResponses = [];
  static bool _drainingPendingResponses = false;
  static Future<void> Function(String conversationId, String messageId)?
  _liveLocationCancelHandler;
  static bool _appFocused = true;
  static bool _timeZonesInitialized = false;

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
          icon: '@drawable/ic_launcher_foreground',
          largeIcon: DrawableResourceAndroidBitmap('@mipmap/launcher_icon'),
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
              'End',
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
              label: 'End',
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
              content: 'End',
              arguments: incomingCallDeclineActionId,
              buttonStyle: WindowsButtonStyle.critical,
            ),
          ],
        ),
      );

  static void setActiveConversation(String? id) => _activeConversationId = id;
  static void setMutedConversations(Iterable<String> conversationIds) {
    _mutedConversationIds = Set.unmodifiable(conversationIds);
    _conversationNotificationPreferences = Map.unmodifiable({
      for (final id in _mutedConversationIds)
        id: const ConversationNotificationPreference.mutedForever(),
    });
  }

  static void setConversationNotificationPreferences(
    Map<String, ConversationNotificationPreference> preferences,
  ) {
    _conversationNotificationPreferences = Map.unmodifiable(preferences);
    _mutedConversationIds = Set.unmodifiable(
      activeMutedConversationIds(_conversationNotificationPreferences),
    );
  }

  static Set<String> get mutedConversationIds => _mutedConversationIds;
  static Map<String, ConversationNotificationPreference>
  get conversationNotificationPreferences =>
      _conversationNotificationPreferences;

  @visibleForTesting
  static bool debugIsConversationMuted(String conversationId) =>
      _mutedConversationIds.contains(conversationId);

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
    _drainPendingResponses();
  }

  static void setIncomingCallPayloadHandler({
    FutureOr<void> Function(Map<String, dynamic>)? onPayload,
  }) {
    _incomingCallPayloadHandler = onPayload;
    _drainPendingResponses();
  }

  static void setLiveLocationHandlers({
    Future<void> Function(String conversationId, String messageId)? onCancel,
  }) {
    _liveLocationCancelHandler = onCancel;
  }

  @visibleForTesting
  static void debugHandleNotificationResponse(NotificationResponse response) =>
      handleNotificationResponse(response);

  static void handleNotificationResponse(NotificationResponse response) {
    switch (response.actionId) {
      case incomingCallAnswerActionId:
        _handleOrQueueIncomingCallResponse(response);
        return;
      case incomingCallDismissActionId:
        _handleOrQueueIncomingCallResponse(response);
        return;
      case incomingCallDeclineActionId:
        _handleOrQueueIncomingCallResponse(response);
        return;
      case _activeCallEndActionId:
        _activeCallEndHandler?.call();
        return;
      case _activeCallMuteActionId:
        _activeCallToggleMuteHandler?.call();
        return;
      case _liveLocationCancelActionId:
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is! Map<String, dynamic>) return;
          final conversationId = decoded['conversation_id'] as String? ?? '';
          final messageId = decoded['message_id'] as String? ?? '';
          if (conversationId.isEmpty || messageId.isEmpty) return;
          unawaited(
            _liveLocationCancelHandler?.call(conversationId, messageId),
          );
        } catch (_) {}
        return;
      default:
        if (response.notificationResponseType ==
                NotificationResponseType.selectedNotification &&
            response.id == incomingCallNotificationId) {
          _handleOrQueueIncomingCallResponse(response);
        }
        return;
    }
  }

  static void _handleOrQueueIncomingCallResponse(
    NotificationResponse response,
  ) {
    if (!_canHandleIncomingCallResponse(response)) {
      _pendingResponses.add(response);
      return;
    }
    unawaited(_handleIncomingCallResponse(response));
  }

  static bool _canHandleIncomingCallResponse(NotificationResponse response) {
    final hasActionHandler =
        _incomingCallAnswerHandler != null ||
        _incomingCallDismissHandler != null ||
        _incomingCallDeclineHandler != null;
    final hasPayload = response.payload != null && response.payload!.isNotEmpty;
    return hasActionHandler &&
        (!hasPayload || _incomingCallPayloadHandler != null);
  }

  static void _drainPendingResponses() {
    if (_drainingPendingResponses || _pendingResponses.isEmpty) return;
    _drainingPendingResponses = true;
    scheduleMicrotask(() {
      try {
        final ready = _pendingResponses
            .where(_canHandleIncomingCallResponse)
            .toList(growable: false);
        _pendingResponses.removeWhere(ready.contains);
        for (final response in ready) {
          unawaited(_handleIncomingCallResponse(response));
        }
      } finally {
        _drainingPendingResponses = false;
      }
    });
  }

  static Future<void> _handleIncomingCallResponse(
    NotificationResponse response,
  ) async {
    await _handleIncomingCallPayload(response.payload);
    switch (response.actionId) {
      case incomingCallAnswerActionId:
        _incomingCallAnswerHandler?.call();
        break;
      case incomingCallDismissActionId:
        _incomingCallDismissHandler?.call();
        break;
      case incomingCallDeclineActionId:
        _incomingCallDeclineHandler?.call();
        break;
      default:
        break;
    }
    await cancelIncomingCall();
  }

  static Future<void> _handleIncomingCallPayload(String? payload) async {
    if (payload == null || payload.isEmpty) return;
    final handler = _incomingCallPayloadHandler;
    if (handler == null) return;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return;
      await handler(Map<String, dynamic>.from(decoded));
    } catch (_) {}
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
            'End',
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
      DarwinNotificationCategory(
        _liveLocationCategory,
        actions: [
          DarwinNotificationAction.plain(
            _liveLocationCancelActionId,
            'Stop sharing',
            options: {
              DarwinNotificationActionOption.destructive,
              DarwinNotificationActionOption.foreground,
            },
          ),
        ],
      ),
      DarwinNotificationCategory(_messageReminderCategory, actions: const []),
    ];
    final settings = InitializationSettings(
      // Status-bar (small) icon. Android masks the small icon to its alpha
      // channel, so we use the transparent logo foreground — the opaque
      // launcher icon would render as a solid white square. The full-color app
      // icon is shown via largeIcon on each notification instead.
      android: const AndroidInitializationSettings(
        '@drawable/ic_launcher_foreground',
      ),
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
      final launchDetails = await _plugin.getNotificationAppLaunchDetails();
      final launchResponse = launchDetails?.notificationResponse;
      if (launchDetails?.didNotificationLaunchApp == true &&
          launchResponse != null) {
        handleNotificationResponse(launchResponse);
      }
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
    // One channel per bundled message sound (Android binds sound at channel
    // creation, so per-sound routing needs per-sound channels).
    for (final id in messageNotificationSounds.keys) {
      if (id == 'default') continue;
      await android.createNotificationChannel(
        AndroidNotificationChannel(
          'messages_$id',
          'Messages (${messageNotificationSounds[id]})',
          description: 'New messages with the ${messageNotificationSounds[id]} sound',
          importance: Importance.high,
          sound: RawResourceAndroidNotificationSound(id),
        ),
      );
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
    bool mentionedForCurrentUser = false,
    String? notificationText,
  }) async {
    if (!_supported) return;
    if (!shouldNotifyForConversation(
      conversationId: conversationId,
      preferences: _conversationNotificationPreferences,
      mentionedForCurrentUser: mentionedForCurrentUser,
      notificationText: notificationText ?? '$title $body',
    )) {
      return;
    }
    if (await _shouldSuppressFocusedNotification()) return;
    if (_activeConversationId == conversationId) return;
    await init();
    if (!_available) return;
    // Per-chat custom notification sound (Batch 5.2): Android routes to a
    // per-sound channel; iOS/macOS name the bundled sound file directly.
    final soundId =
        _conversationNotificationPreferences[conversationId]?.customSoundId;
    final hasCustomSound =
        soundId != null && soundId.isNotEmpty && soundId != 'default';
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        hasCustomSound ? 'messages_$soundId' : 'messages',
        hasCustomSound
            ? 'Messages (${messageNotificationSoundLabel(soundId)})'
            : 'Messages',
        channelDescription: 'Notifications for new messages',
        icon: '@drawable/ic_launcher_foreground',
        largeIcon: const DrawableResourceAndroidBitmap('@mipmap/launcher_icon'),
        importance: Importance.high,
        priority: Priority.high,
        sound: hasCustomSound
            ? RawResourceAndroidNotificationSound(soundId)
            : null,
      ),
      iOS: DarwinNotificationDetails(
        sound: hasCustomSound ? '$soundId.caf' : null,
      ),
      macOS: DarwinNotificationDetails(
        sound: hasCustomSound ? '$soundId.caf' : null,
      ),
      linux: LinuxNotificationDetails(),
      windows: WindowsNotificationDetails(),
    );
    final displayTitle = showSensitive ? title : 'OpenChat';
    final displayBody = showSensitive ? body : 'New message';
    // One notification slot per conversation — updates in place rather than stacking.
    await _plugin.show(
      id: conversationId.hashCode,
      title: displayTitle,
      body: displayBody,
      notificationDetails: details,
    );
  }

  static Future<void> showIncomingCall({
    required String body,
    String? payload,
  }) async {
    if (!_supported) return;
    if (await _shouldSuppressFocusedNotification()) return;
    await init();
    if (!_available) return;
    await _plugin.show(
      id: incomingCallNotificationId,
      title: 'Incoming call',
      body: body,
      notificationDetails: incomingCallNotificationDetails,
      payload: payload,
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
        icon: '@drawable/ic_launcher_foreground',
        largeIcon: const DrawableResourceAndroidBitmap('@mipmap/launcher_icon'),
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

  static int _liveLocationNotificationId({
    required String conversationId,
    required String messageId,
  }) => _stableNotificationId('live_location', <String>[
    conversationId,
    messageId,
  ]);

  static String _liveLocationNotificationTag({
    required String conversationId,
    required String messageId,
  }) => 'openchat_live_location:$conversationId:$messageId';

  static int _messageReminderNotificationId(String reminderId) =>
      _stableNotificationId('message_reminder', <String>[reminderId]);

  static Future<void> _ensureTimeZonesInitialized() async {
    if (_timeZonesInitialized) return;
    tzdata.initializeTimeZones();
    _timeZonesInitialized = true;
  }

  static int _stableNotificationId(String namespace, Iterable<String> parts) {
    var hash = 0x811C9DC5;
    for (final unit in '$namespace:${parts.join(':')}'.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7FFFFFFF;
    }
    return hash == 0 ? 1 : hash;
  }

  @visibleForTesting
  static int debugLiveLocationNotificationId({
    required String conversationId,
    required String messageId,
  }) => _liveLocationNotificationId(
    conversationId: conversationId,
    messageId: messageId,
  );

  @visibleForTesting
  static String debugLiveLocationNotificationTag({
    required String conversationId,
    required String messageId,
  }) => _liveLocationNotificationTag(
    conversationId: conversationId,
    messageId: messageId,
  );

  @visibleForTesting
  static int debugMessageReminderNotificationId(String reminderId) =>
      _messageReminderNotificationId(reminderId);

  static String _liveLocationRemainingLabel(DateTime? endsAt) {
    if (endsAt == null) return 'Live location shared';
    final remaining = endsAt.difference(DateTime.now());
    if (remaining.inSeconds <= 0) return 'Live location ended';
    if (remaining.inHours >= 1) {
      final hours = remaining.inHours;
      final mins = remaining.inMinutes % 60;
      if (mins == 0) return 'Ends in ${hours}h';
      return 'Ends in ${hours}h ${mins}m';
    }
    if (remaining.inMinutes >= 1) return 'Ends in ${remaining.inMinutes}m';
    return 'Ends in ${remaining.inSeconds}s';
  }

  static Future<void> showLiveLocationNotification({
    required String messageId,
    required String conversationId,
    required String title,
    DateTime? endsAt,
    required bool live,
  }) async {
    if (!_supported) return;
    // On Android the live-location share runs as a foreground service whose
    // ongoing notification (ChatProvider._liveLocationSettings) is the single,
    // OS-mandated indicator. Posting our own here would duplicate it, so Android
    // defers entirely to that one. iOS/macOS/desktop have no such service and
    // still rely on the notification built below.
    if (Platform.isAndroid) return;
    if (await _shouldSuppressFocusedNotification()) {
      await cancelLiveLocationNotification(
        messageId: messageId,
        conversationId: conversationId,
      );
      return;
    }
    await init();
    if (!_available) return;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'live_location',
        'Live location sharing',
        channelDescription: 'Ongoing live location sharing updates',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
        onlyAlertOnce: true,
        category: AndroidNotificationCategory.locationSharing,
        tag: _liveLocationNotificationTag(
          conversationId: conversationId,
          messageId: messageId,
        ),
        actions: [
          AndroidNotificationAction(
            _liveLocationCancelActionId,
            'Stop sharing',
            cancelNotification: false,
            showsUserInterface: true,
          ),
        ],
      ),
      iOS: DarwinNotificationDetails(
        categoryIdentifier: _liveLocationCategory,
        presentBanner: live,
        presentList: live,
        presentSound: false,
      ),
      macOS: DarwinNotificationDetails(
        categoryIdentifier: _liveLocationCategory,
        presentBanner: live,
        presentList: live,
        presentSound: false,
      ),
      linux: const LinuxNotificationDetails(),
      windows: const WindowsNotificationDetails(),
    );

    await _plugin.show(
      id: _liveLocationNotificationId(
        conversationId: conversationId,
        messageId: messageId,
      ),
      title: title,
      body: _liveLocationRemainingLabel(endsAt),
      notificationDetails: details,
      payload: jsonEncode({
        'conversation_id': conversationId,
        'message_id': messageId,
      }),
    );
  }

  static Future<void> cancelLiveLocationNotification({
    required String messageId,
    required String conversationId,
  }) async {
    if (!_supported) return;
    if (Platform.isAndroid) return; // never posted on Android (FGS owns it)
    await init();
    if (!_available) return;
    await _plugin.cancel(
      id: _liveLocationNotificationId(
        conversationId: conversationId,
        messageId: messageId,
      ),
      tag: _liveLocationNotificationTag(
        conversationId: conversationId,
        messageId: messageId,
      ),
    );
  }

  static Future<void> showMessageReminder({
    required String reminderId,
    required String title,
    required String body,
    String? conversationId,
    String? messageId,
  }) async {
    if (!_supported) return;
    final granted = await requestPermission();
    if (!granted || !_available) return;
    await _plugin.show(
      id: _messageReminderNotificationId(reminderId),
      title: title,
      body: body,
      notificationDetails: _messageReminderDetails,
      payload: _messageReminderPayload(
        reminderId: reminderId,
        conversationId: conversationId,
        messageId: messageId,
      ),
    );
  }

  static Future<void> scheduleMessageReminder({
    required String reminderId,
    required String title,
    required String body,
    required DateTime remindAt,
    String? conversationId,
    String? messageId,
  }) async {
    if (!_supported) return;
    if (!remindAt.isAfter(DateTime.now())) {
      await showMessageReminder(
        reminderId: reminderId,
        title: title,
        body: body,
        conversationId: conversationId,
        messageId: messageId,
      );
      return;
    }
    final granted = await requestPermission();
    if (!granted || !_available) return;
    await _ensureTimeZonesInitialized();
    try {
      await _plugin.zonedSchedule(
        id: _messageReminderNotificationId(reminderId),
        title: title,
        body: body,
        scheduledDate: tz.TZDateTime.from(remindAt.toUtc(), tz.UTC),
        notificationDetails: _messageReminderDetails,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: _messageReminderPayload(
          reminderId: reminderId,
          conversationId: conversationId,
          messageId: messageId,
        ),
      );
    } catch (e) {
      debugPrint('Could not schedule message reminder notification: $e');
    }
  }

  static Future<void> cancelMessageReminder(String reminderId) async {
    if (!_supported) return;
    await init();
    if (!_available) return;
    await _plugin.cancel(id: _messageReminderNotificationId(reminderId));
  }

  static String _messageReminderPayload({
    required String reminderId,
    String? conversationId,
    String? messageId,
  }) => jsonEncode({
    'type': 'message_reminder',
    'reminder_id': reminderId,
    if (conversationId != null && conversationId.isNotEmpty)
      'conversation_id': conversationId,
    if (messageId != null && messageId.isNotEmpty) 'message_id': messageId,
  });

  static const NotificationDetails _messageReminderDetails =
      NotificationDetails(
        android: AndroidNotificationDetails(
          'message_reminders',
          'Message reminders',
          channelDescription: 'Notifications for message reminders',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          onlyAlertOnce: true,
        ),
        iOS: DarwinNotificationDetails(
          categoryIdentifier: _messageReminderCategory,
          presentBanner: true,
          presentList: true,
          presentSound: true,
        ),
        macOS: DarwinNotificationDetails(
          categoryIdentifier: _messageReminderCategory,
          presentBanner: true,
          presentList: true,
          presentSound: true,
        ),
        linux: LinuxNotificationDetails(),
        windows: WindowsNotificationDetails(),
      );
}
