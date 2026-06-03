import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/services/background_ws_service.dart';
import 'package:openchat/services/foreground_ws_notification_router.dart';
import 'package:openchat/services/notification_service.dart';
import 'package:openchat/services/push_notification_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('SettingsProvider notification exclusivity', () {
    test(
      'enabling push disables websocket notifications and persists it',
      () async {
        SharedPreferences.setMockInitialValues({
          'push_notifications_enabled': false,
          'ws_background_enabled': true,
        });

        final provider = SettingsProvider();
        await provider.load();

        expect(provider.isLoaded, isTrue);

        await provider.setPushNotificationsEnabled(true);

        expect(provider.pushNotificationsEnabled, isTrue);
        expect(provider.wsBackgroundEnabled, isFalse);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('push_notifications_enabled'), isTrue);
        expect(prefs.getBool('ws_background_enabled'), isFalse);
      },
    );

    test(
      'enabling websocket notifications disables push and persists it',
      () async {
        SharedPreferences.setMockInitialValues({
          'push_notifications_enabled': true,
          'ws_background_enabled': false,
        });

        final provider = SettingsProvider();
        await provider.load();

        await provider.setWsBackgroundEnabled(true);

        expect(provider.wsBackgroundEnabled, isTrue);
        expect(provider.pushNotificationsEnabled, isFalse);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('ws_background_enabled'), isTrue);
        expect(prefs.getBool('push_notifications_enabled'), isFalse);
      },
    );

    test('load is idempotent while startup waits on settings', () async {
      SharedPreferences.setMockInitialValues({
        'push_notifications_enabled': true,
      });

      final provider = SettingsProvider();
      final firstLoad = provider.load();
      final secondLoad = provider.load();
      await Future.wait([firstLoad, secondLoad]);

      expect(provider.isLoaded, isTrue);
      expect(provider.pushNotificationsEnabled, isTrue);
    });
  });

  group('Firebase push registration', () {
    test('registers iOS Firebase getToken values as FCM tokens', () {
      expect(
        PushNotificationService.registrationPlatformForCurrentDevice(
          isAndroid: false,
          isIOS: true,
        ),
        'fcm',
      );
    });
  });

  group('Background websocket event notification mapping', () {
    test('push failure messages identify the failed setup stage', () {
      expect(
        PushNotificationService.messageForInitFailure(
          PushNotificationInitFailure.permissionDenied,
        ),
        contains('Notification permission'),
      );
      expect(
        PushNotificationService.messageForInitFailure(
          PushNotificationInitFailure.firebaseConfigMissing,
        ),
        contains('Firebase client config'),
      );
      expect(
        PushNotificationService.messageForInitFailure(
          PushNotificationInitFailure.backendRegistrationFailed,
        ),
        contains('backend'),
      );
    });

    test(
      'declares android notification channels used by push and background websocket',
      () {
        expect(
          NotificationService.androidNotificationChannelIds,
          containsAll(<String>{
            'messages',
            'calls',
            'active_calls',
            'bg_messages',
            'bg_calls',
          }),
        );
      },
    );

    test('ios plist declares firebase background delivery modes', () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();

      expect(plist, contains('<key>UIBackgroundModes</key>'));
      expect(plist, contains('<string>remote-notification</string>'));
      expect(plist, contains('<string>fetch</string>'));
    });

    test('ios runner declares push notification entitlements', () {
      final entitlements = File(
        'ios/Runner/Runner.entitlements',
      ).readAsStringSync();
      final project = File(
        'ios/Runner.xcodeproj/project.pbxproj',
      ).readAsStringSync();

      expect(entitlements, contains('<key>aps-environment</key>'));
      expect(
        project,
        contains('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements'),
      );
      expect(project, contains('APS_ENVIRONMENT = production;'));
    });

    test(
      'persistent websocket start policy rejects ios and allows android',
      () {
        expect(
          BackgroundWsService.supportsPersistentBackgroundWebSocket(
            isWeb: false,
            isAndroid: false,
            isIOS: true,
          ),
          isFalse,
        );
        expect(
          BackgroundWsService.supportsPersistentBackgroundWebSocket(
            isWeb: false,
            isAndroid: true,
            isIOS: false,
          ),
          isTrue,
        );
      },
    );

    test('maps new_message into a message notification intent', () {
      final intent = BackgroundWsService.notificationIntentFromRawLine(
        '{"type":"new_message","data":{"conversation_id":"conv-1","sender_username":"alice"}}',
        showSensitive: true,
      );

      expect(intent, isNotNull);
      expect(intent!.kind, NotificationIntentKind.message);
      expect(intent.notificationId, 'conv-1'.hashCode);
      expect(intent.title, '@alice');
      expect(intent.body, 'New message');
    });

    test(
      'maps data-only foreground push new_message into a message notification intent',
      () {
        const msg = RemoteMessage(
          data: {
            'type': 'new_message',
            'conversation_id': 'conv-1',
            'sender_username': 'alice',
          },
        );

        final intent = PushNotificationService.foregroundNotificationIntent(
          msg,
        );

        expect(intent, isNotNull);
        expect(intent!.kind, NotificationIntentKind.message);
        expect(intent.notificationId, 'conv-1'.hashCode);
        expect(intent.title, '@alice');
        expect(intent.body, 'New message');
      },
    );

    test('maps call_offer into an incoming-call notification intent', () {
      final intent = BackgroundWsService.notificationIntentFromRawLine(
        '{"type":"call_offer","data":{"caller_username":"bob"}}',
        showSensitive: true,
      );

      expect(intent, isNotNull);
      expect(intent!.kind, NotificationIntentKind.incomingCall);
      expect(intent.notificationId, 1);
      expect(intent.title, 'Incoming call');
      expect(intent.body, '@bob is calling');
    });

    test('ignores malformed payloads and unsupported events', () {
      expect(
        BackgroundWsService.notificationIntentFromRawLine(
          'not json',
          showSensitive: true,
        ),
        isNull,
      );

      expect(
        BackgroundWsService.notificationIntentFromRawLine(
          '{"type":"typing","data":{"conversation_id":"conv-1"}}',
          showSensitive: true,
        ),
        isNull,
      );
    });
  });

  group('Foreground desktop websocket notification routing', () {
    test(
      'routes desktop new_message events into message notification intents',
      () {
        final intent = ForegroundWsNotificationRouter.intentForEvent(
          WsEvent(
            type: WsEventType.newMessage,
            data: {'conversation_id': 'conv-1', 'sender_username': 'alice'},
          ),
          showSensitive: true,
          isDesktop: true,
        );

        expect(intent, isNotNull);
        expect(intent!.kind, NotificationIntentKind.message);
        expect(intent.notificationId, 'conv-1'.hashCode);
        expect(intent.title, '@alice');
        expect(intent.body, 'New message');
      },
    );

    test('ignores mobile foreground websocket events', () {
      final intent = ForegroundWsNotificationRouter.intentForEvent(
        WsEvent(type: WsEventType.callOffer, data: const {}),
        showSensitive: true,
        isDesktop: false,
      );

      expect(intent, isNull);
    });
  });

  group('Foreground websocket connection status', () {
    test('reports monitoring only while connected', () {
      final ws = WebSocketService(SecureStorageService());
      addTearDown(ws.dispose);

      expect(ws.connectionStatus, WsConnectionStatus.disconnected);
      expect(ws.isMonitoring, isFalse);

      ws.debugSetConnectionStatus(WsConnectionStatus.connecting);
      expect(ws.isMonitoring, isFalse);

      ws.debugSetConnectionStatus(WsConnectionStatus.connected);
      expect(ws.isMonitoring, isTrue);
    });
  });
}
