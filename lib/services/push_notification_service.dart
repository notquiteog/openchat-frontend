import 'dart:async';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import '../firebase_options.dart';
import '../utils/local_conversation_preferences.dart';
import 'api_service.dart';
import 'background_notification_intent.dart';
import 'notification_service.dart';

enum PushNotificationInitFailure {
  unsupported,
  firebaseConfigMissing,
  permissionDenied,
  tokenUnavailable,
  backendRegistrationFailed,
}

class PushNotificationInitResult {
  final bool success;
  final PushNotificationInitFailure? failure;

  const PushNotificationInitResult._({required this.success, this.failure});

  const PushNotificationInitResult.success()
    : this._(success: true, failure: null);

  const PushNotificationInitResult.failed(PushNotificationInitFailure failure)
    : this._(success: false, failure: failure);
}

/// Firebase Cloud Messaging / APNs push notification service.
///
/// Push notifications are OPTIONAL and off by default. They require:
///   - A Firebase project with FCM enabled (see lib/firebase_options.dart)
///   - The server configured with FIREBASE_SERVICE_ACCOUNT_JSON
///
/// When Firebase credentials are not configured (placeholder values) the
/// service fails gracefully: [init] returns false and Settings shows
/// "Firebase not configured on this server."
class PushNotificationService {
  // Firebase init state. Firebase.initializeApp must only be called once per
  // process; this flag prevents double-init across hot restarts and re-auth.
  static bool _firebaseInitialized = false;

  // Whether the user's device is currently registered for push messages.
  static bool _registered = false;
  static bool get isRegistered => _registered;

  static StreamSubscription<RemoteMessage>? _foregroundSub;
  static StreamSubscription<String>? _tokenRefreshSub;
  static void Function(Map<String, dynamic>)? _foregroundIncomingCallHandler;

  /// Push notifications are supported only on Android and iOS.
  /// Desktop platforms use the in-app WebSocket connection instead, and
  /// firebase_messaging does not support Linux.
  static bool get _supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static void setForegroundIncomingCallHandler(
    void Function(Map<String, dynamic>)? handler,
  ) {
    _foregroundIncomingCallHandler = handler;
  }

  // ── Startup ──────────────────────────────────────────────────────────────────

  /// Register the background message handler. Must be called from [main()]
  /// before [runApp()] so Firebase can dispatch messages when the app is
  /// terminated. No-op on unsupported platforms or when Firebase is not
  /// configured.
  static Future<void> registerBackgroundHandler(
    Future<void> Function(RemoteMessage) handler,
  ) async {
    if (!_supported) return;
    final ok = await _initFirebase();
    if (!ok) return;
    await NotificationService.init();
    FirebaseMessaging.onBackgroundMessage(handler);
  }

  /// Re-register on app restart when push was previously enabled in Settings.
  /// Failures are silent — the user can re-enable from Settings if needed.
  static Future<void> initFromSettings({required ApiService api}) async {
    await init(api: api); // return value intentionally ignored
  }

  // ── Public API ───────────────────────────────────────────────────────────────

  /// Initialise Firebase, request permission, obtain an FCM/APNs token, and
  /// register it with the backend.
  ///
  /// Returns `true` on success, `false` when:
  ///  - the platform is unsupported
  ///  - Firebase credentials are placeholder / unconfigured
  ///  - the user denied notification permission
  ///  - the backend does not have FCM configured
  static Future<bool> init({required ApiService api}) async {
    final result = await initDetailed(api: api);
    return result.success;
  }

  static Future<PushNotificationInitResult> initDetailed({
    required ApiService api,
  }) async {
    if (!_supported) {
      return const PushNotificationInitResult.failed(
        PushNotificationInitFailure.unsupported,
      );
    }

    await NotificationService.init();

    final firebaseOk = await _initFirebase();
    if (!firebaseOk) {
      return const PushNotificationInitResult.failed(
        PushNotificationInitFailure.firebaseConfigMissing,
      );
    }

    final messaging = FirebaseMessaging.instance;
    await messaging.setAutoInitEnabled(true);

    // Both iOS and Android 13+ (API 33+) require a runtime permission prompt.
    // firebase_messaging.requestPermission() handles both platforms: on iOS it
    // shows the system alert; on Android it requests POST_NOTIFICATIONS.
    // Without this, Android 13+ users are silently denied and never see a prompt.
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    if (settings.authorizationStatus != AuthorizationStatus.authorized &&
        settings.authorizationStatus != AuthorizationStatus.provisional) {
      return const PushNotificationInitResult.failed(
        PushNotificationInitFailure.permissionDenied,
      );
    }

    // Obtain the FCM/APNs token. Fails when Firebase project ID is wrong or
    // the google-services / GoogleService-Info files are placeholders.
    final token = await _getFcmToken(messaging);
    if (token == null) {
      return const PushNotificationInitResult.failed(
        PushNotificationInitFailure.tokenUnavailable,
      );
    }

    // Register with the OpenChat backend so it can send pushes to this device.
    try {
      await _registerToken(token, api);
    } catch (e) {
      debugPrint(
        'PushNotificationService: backend token registration failed — $e',
      );
      return const PushNotificationInitResult.failed(
        PushNotificationInitFailure.backendRegistrationFailed,
      );
    }

    // Rotate the token on the backend whenever FCM issues a new one.
    _tokenRefreshSub?.cancel();
    _tokenRefreshSub = messaging.onTokenRefresh.listen(
      (t) => _registerToken(t, api).catchError((_) {}),
    );

    // Show an in-app local notification when a message arrives while the app
    // is open (FCM does not display the system notification in this case).
    _foregroundSub?.cancel();
    _foregroundSub = FirebaseMessaging.onMessage.listen((RemoteMessage msg) {
      final intent = foregroundNotificationIntent(
        msg,
        mutedConversationIds: NotificationService.mutedConversationIds,
        conversationNotificationPreferences:
            NotificationService.conversationNotificationPreferences,
      );
      if (intent == null) return;
      switch (intent.kind) {
        case NotificationIntentKind.message:
          NotificationService.showMessage(
            conversationId: msg.data['conversation_id'] as String? ?? 'push',
            title: intent.title,
            body: intent.body,
            showSensitive:
                true, // title/body are already sanitised by the server
            notificationText: notificationRuleTextFromData(msg.data),
          );
          break;
        case NotificationIntentKind.incomingCall:
          _foregroundIncomingCallHandler?.call(
            Map<String, dynamic>.from(msg.data),
          );
          NotificationService.showIncomingCall(body: intent.body);
          break;
      }
    });

    _registered = true;
    return const PushNotificationInitResult.success();
  }

  static String messageForInitFailure(PushNotificationInitFailure failure) {
    return switch (failure) {
      PushNotificationInitFailure.unsupported =>
        'Push notifications are only available on Android and iOS.',
      PushNotificationInitFailure.firebaseConfigMissing =>
        'Firebase client config is missing from this app build. Rebuild with the Firebase GitHub secrets injected.',
      PushNotificationInitFailure.permissionDenied =>
        'Notification permission is required before Firebase notifications can be enabled.',
      PushNotificationInitFailure.tokenUnavailable =>
        'Firebase could not issue a device token. Check the Firebase app IDs and google-services files.',
      PushNotificationInitFailure.backendRegistrationFailed =>
        'This device could not register with the OpenChat backend for push notifications.',
    };
  }

  /// Unregister this device from push notifications. The backend stops sending
  /// FCM messages to this token and the FCM token itself is invalidated.
  static Future<void> disable({required ApiService api}) async {
    _foregroundSub?.cancel();
    _foregroundSub = null;
    _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
    if (!_registered) return;
    try {
      await api.removeDeviceToken();
    } catch (_) {}
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
    _registered = false;
  }

  // ── Internals ────────────────────────────────────────────────────────────────

  /// Maps a foreground FCM message to the local notification OpenChat should
  /// display while the app is open.
  @visibleForTesting
  static NotificationIntent? foregroundNotificationIntent(
    RemoteMessage msg, {
    Set<String> mutedConversationIds = const {},
    Map<String, ConversationNotificationPreference>
        conversationNotificationPreferences =
        const {},
  }) {
    final type = msg.data['type'] as String?;
    if (type == 'incoming_call') {
      final isVideo = msg.data['is_video'] == 'true';
      final kind = isVideo ? 'video' : 'voice';
      return NotificationIntent(
        kind: NotificationIntentKind.incomingCall,
        notificationId: 1,
        title: 'Incoming call',
        body: 'Incoming $kind call',
      );
    }
    if (type == 'new_message') {
      final conversationId = msg.data['conversation_id'] as String? ?? 'push';
      final preferences = <String, ConversationNotificationPreference>{
        ...conversationNotificationPreferences,
        for (final id in mutedConversationIds)
          if (!conversationNotificationPreferences.containsKey(id))
            id: const ConversationNotificationPreference.mutedForever(),
      };
      if (!shouldNotifyForConversation(
        conversationId: conversationId,
        preferences: preferences,
      )) {
        return null;
      }
      final notification = msg.notification;
      if (notification != null) {
        return NotificationIntent(
          kind: NotificationIntentKind.message,
          notificationId: conversationId.hashCode,
          title: notification.title ?? 'OpenChat',
          body: notification.body ?? 'New message',
        );
      }
      return notificationIntentFromEvent(
        type: 'new_message',
        data: msg.data,
        showSensitive: true,
        mutedConversationIds: mutedConversationIds,
        conversationNotificationPreferences:
            conversationNotificationPreferences,
      );
    }
    return null;
  }

  /// Initialise Firebase exactly once. Returns false if the credentials in
  /// [firebase_options.dart] are still the placeholder template values.
  static Future<bool> _initFirebase() async {
    if (_firebaseInitialized) return true;
    try {
      if (Firebase.apps.isEmpty) {
        final dartOptions = _firebaseOptionsForCurrentPlatform();
        if (dartOptions != null) {
          await Firebase.initializeApp(options: dartOptions);
        } else {
          await Firebase.initializeApp();
        }
      }
      // Detect placeholder credentials after init. Native google-services /
      // GoogleService-Info files are accepted, while the generated Dart
      // placeholder is still rejected when no injected config exists.
      final opts = Firebase.app().options;
      if (opts.projectId == 'your-firebase-project-id' ||
          opts.apiKey.startsWith('REPLACE_WITH')) {
        debugPrint(
          'PushNotificationService: placeholder Firebase credentials detected — '
          'run flutterfire configure to enable push notifications.',
        );
        return false;
      }
      _firebaseInitialized = true;
      return true;
    } catch (e) {
      debugPrint('PushNotificationService: Firebase init failed — $e');
      return false;
    }
  }

  static FirebaseOptions? _firebaseOptionsForCurrentPlatform() {
    try {
      final options = DefaultFirebaseOptions.currentPlatform;
      if (options.projectId == 'your-firebase-project-id' ||
          options.apiKey.startsWith('REPLACE_WITH')) {
        return null;
      }
      return options;
    } on UnsupportedError {
      return null;
    } catch (e) {
      debugPrint(
        'PushNotificationService: Firebase Dart config unavailable — $e',
      );
      return null;
    }
  }

  static Future<void> _registerToken(String token, ApiService api) async {
    await api.registerDeviceToken(
      token: token,
      platform: registrationPlatformForCurrentDevice(),
    );
  }

  @visibleForTesting
  static String registrationPlatformForCurrentDevice({
    bool? isAndroid,
    bool? isIOS,
  }) {
    // FirebaseMessaging.getToken() returns an FCM registration token on both
    // Android and Apple platforms. APNs tokens are only an intermediate input
    // Firebase uses on iOS, so the backend should store this as an FCM token.
    if (isAndroid ?? Platform.isAndroid) return 'fcm';
    if (isIOS ?? Platform.isIOS) return 'fcm';
    return 'fcm';
  }

  static Future<String?> _getFcmToken(FirebaseMessaging messaging) async {
    if (Platform.isIOS) {
      final apnsToken = await _waitForApnsToken(messaging);
      if (apnsToken == null) {
        debugPrint('PushNotificationService: APNs token unavailable');
        return null;
      }
    }

    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final token = await messaging.getToken();
        if (token != null && token.isNotEmpty) return token;
      } catch (e) {
        debugPrint('PushNotificationService: getToken failed — $e');
      }
      await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
    }
    return null;
  }

  static Future<String?> _waitForApnsToken(FirebaseMessaging messaging) async {
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        final token = await messaging.getAPNSToken();
        if (token != null && token.isNotEmpty) return token;
      } catch (e) {
        debugPrint('PushNotificationService: getAPNSToken failed — $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return null;
  }
}
