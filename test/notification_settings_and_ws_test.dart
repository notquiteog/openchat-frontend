import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/services/background_ws_service.dart';
import 'package:openchat/services/foreground_ws_notification_router.dart';
import 'package:openchat/services/notification_service.dart';
import 'package:openchat/services/push_notification_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('SettingsProvider notification exclusivity', () {
    test('enabling push disables websocket notifications and persists it',
        () async {
      SharedPreferences.setMockInitialValues({
        'push_notifications_enabled': false,
        'ws_background_enabled': true,
      });

      final provider = SettingsProvider();
      await provider.load();

      await provider.setPushNotificationsEnabled(true);

      expect(provider.pushNotificationsEnabled, isTrue);
      expect(provider.wsBackgroundEnabled, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('push_notifications_enabled'), isTrue);
      expect(prefs.getBool('ws_background_enabled'), isFalse);
    });

    test('enabling websocket notifications disables push and persists it',
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
    });
  });

  group('Background websocket event notification mapping', () {
    test(
        'declares android notification channels used by push and background websocket',
        () {
      expect(
        NotificationService.androidNotificationChannelIds,
        containsAll(<String>{'messages', 'calls', 'bg_messages', 'bg_calls'}),
      );
    });

    test('ios plist declares firebase background delivery modes', () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();

      expect(plist, contains('<key>UIBackgroundModes</key>'));
      expect(plist, contains('<string>remote-notification</string>'));
      expect(plist, contains('<string>fetch</string>'));
    });

    test('persistent websocket start policy rejects ios and allows android',
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
    });

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
      const msg = RemoteMessage(data: {
        'type': 'new_message',
        'conversation_id': 'conv-1',
        'sender_username': 'alice',
      });

      final intent = PushNotificationService.foregroundNotificationIntent(msg);

      expect(intent, isNotNull);
      expect(intent!.kind, NotificationIntentKind.message);
      expect(intent.notificationId, 'conv-1'.hashCode);
      expect(intent.title, '@alice');
      expect(intent.body, 'New message');
    });

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
    test('routes desktop new_message events into message notification intents',
        () {
      final intent = ForegroundWsNotificationRouter.intentForEvent(
        WsEvent(
          type: WsEventType.newMessage,
          data: {
            'conversation_id': 'conv-1',
            'sender_username': 'alice',
          },
        ),
        showSensitive: true,
        isDesktop: true,
      );

      expect(intent, isNotNull);
      expect(intent!.kind, NotificationIntentKind.message);
      expect(intent.notificationId, 'conv-1'.hashCode);
      expect(intent.title, '@alice');
      expect(intent.body, 'New message');
    });

    test('ignores mobile foreground websocket events', () {
      final intent = ForegroundWsNotificationRouter.intentForEvent(
        WsEvent(type: WsEventType.callOffer, data: const {}),
        showSensitive: true,
        isDesktop: false,
      );

      expect(intent, isNull);
    });
  });
}
