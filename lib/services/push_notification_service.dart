import 'dart:async';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import '../firebase_options.dart';
import 'api_service.dart';
import 'notification_service.dart';

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

  /// Push notifications are supported only on Android and iOS.
  /// Desktop platforms use the in-app WebSocket connection instead, and
  /// firebase_messaging does not support Linux.
  static bool get _supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

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
    if (!_supported) return false;

    final firebaseOk = await _initFirebase();
    if (!firebaseOk) return false;

    final messaging = FirebaseMessaging.instance;

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
      return false;
    }

    // Obtain the FCM/APNs token. Fails when Firebase project ID is wrong or
    // the google-services / GoogleService-Info files are placeholders.
    final String? token;
    try {
      token = await messaging.getToken();
    } catch (e) {
      debugPrint('PushNotificationService: getToken failed — $e');
      return false;
    }
    if (token == null) return false;

    // Register with the OpenChat backend so it can send pushes to this device.
    try {
      await _registerToken(token, api);
    } catch (e) {
      debugPrint('PushNotificationService: backend token registration failed — $e');
      return false;
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
      if (msg.data['type'] == 'incoming_call') {
        final caller = msg.data['caller_username'] as String? ?? 'Unknown';
        final isVideo = msg.data['is_video'] == 'true';
        final kind = isVideo ? 'video' : 'voice';
        NotificationService.showIncomingCall(
          body: 'Incoming $kind call from @$caller',
        );
        return;
      }
      final notif = msg.notification;
      if (notif != null) {
        NotificationService.showMessage(
          conversationId: msg.data['conversation_id'] ?? 'push',
          title: notif.title ?? 'OpenChat',
          body: notif.body ?? 'New message',
          showSensitive: true, // title/body are already sanitised by the server
        );
      }
    });

    _registered = true;
    return true;
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

  /// Initialise Firebase exactly once. Returns false if the credentials in
  /// [firebase_options.dart] are still the placeholder template values.
  static Future<bool> _initFirebase() async {
    if (_firebaseInitialized) return true;
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }
      // Detect placeholder credentials: the template project-id is a dead
      // give-away that the operator hasn't run flutterfire configure yet.
      final opts = DefaultFirebaseOptions.currentPlatform;
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

  static Future<void> _registerToken(String token, ApiService api) async {
    await api.registerDeviceToken(
      token: token,
      platform: Platform.isAndroid ? 'fcm' : 'apns',
    );
  }
}
