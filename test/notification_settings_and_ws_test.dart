import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/services/background_ws_service.dart';
import 'package:openchat/services/foreground_ws_notification_router.dart';
import 'package:openchat/services/local_private_state_service.dart';
import 'package:openchat/services/notification_service.dart';
import 'package:openchat/services/push_notification_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:openchat/utils/local_conversation_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('SettingsProvider notification exclusivity', () {
    test(
      'enabling push disables websocket notifications and persists it',
      () async {
        SharedPreferences.setMockInitialValues({});

        final provider = SettingsProvider();
        await provider.load();
        await provider.setWsBackgroundEnabled(true);

        expect(provider.isLoaded, isTrue);

        await provider.setPushNotificationsEnabled(true);

        expect(provider.pushNotificationsEnabled, isTrue);
        expect(provider.wsBackgroundEnabled, isFalse);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('push_notifications_enabled'), isNull);
        expect(prefs.getBool('ws_background_enabled'), isNull);
        final encrypted = prefs.getString(localPrivateStatePreferenceKey);
        expect(encrypted, isNotNull);
        expect(encrypted, isNot(contains('push_enabled')));
      },
    );

    test(
      'enabling websocket notifications disables push and persists it',
      () async {
        SharedPreferences.setMockInitialValues({});

        final provider = SettingsProvider();
        await provider.load();
        await provider.setPushNotificationsEnabled(true);

        await provider.setWsBackgroundEnabled(true);

        expect(provider.wsBackgroundEnabled, isTrue);
        expect(provider.pushNotificationsEnabled, isFalse);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('ws_background_enabled'), isNull);
        expect(prefs.getBool('push_notifications_enabled'), isNull);
        final encrypted = prefs.getString(localPrivateStatePreferenceKey);
        expect(encrypted, isNotNull);
        expect(encrypted, isNot(contains('ws_background_enabled')));
      },
    );

    test('load is idempotent while startup waits on settings', () async {
      SharedPreferences.setMockInitialValues({'channels_own_tab': true});

      final provider = SettingsProvider();
      final firstLoad = provider.load();
      final secondLoad = provider.load();
      await Future.wait([firstLoad, secondLoad]);

      expect(provider.isLoaded, isTrue);
      expect(provider.channelsOwnTab, isTrue);
    });

    test(
      'strict privacy leaves notification content as a solo toggle',
      () async {
        SharedPreferences.setMockInitialValues({
          'strict_privacy_mode': true,
          'link_previews_enabled': true,
        });

        final provider = SettingsProvider();
        await provider.load();
        await provider.setNotificationSensitiveContent(true);

        expect(provider.strictPrivacyMode, isTrue);
        expect(provider.notificationSensitiveContent, isTrue);
        expect(provider.linkPreviewsEnabled, isFalse);

        await provider.setStrictPrivacyMode(false);

        expect(provider.notificationSensitiveContent, isTrue);
        expect(provider.linkPreviewsEnabled, isTrue);

        await provider.setNotificationSensitiveContent(false);

        expect(provider.notificationSensitiveContent, isFalse);
        expect(provider.strictPrivacyMode, isFalse);
      },
    );
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
            'message_reminders',
          }),
        );
      },
    );

    test('live location notifications keep a stable update slot', () {
      final first = NotificationService.debugLiveLocationNotificationId(
        conversationId: 'conv-1',
        messageId: 'msg-1',
      );
      final second = NotificationService.debugLiveLocationNotificationId(
        conversationId: 'conv-1',
        messageId: 'msg-1',
      );
      final other = NotificationService.debugLiveLocationNotificationId(
        conversationId: 'conv-1',
        messageId: 'msg-2',
      );

      expect(first, second);
      expect(first, isNot(other));
      expect(
        NotificationService.debugLiveLocationNotificationTag(
          conversationId: 'conv-1',
          messageId: 'msg-1',
        ),
        'openchat_live_location:conv-1:msg-1',
      );
    });

    test('message reminders keep stable local notification ids', () {
      expect(
        NotificationService.debugMessageReminderNotificationId('reminder-1'),
        NotificationService.debugMessageReminderNotificationId('reminder-1'),
      );
      expect(
        NotificationService.debugMessageReminderNotificationId('reminder-1'),
        isNot(
          NotificationService.debugMessageReminderNotificationId('reminder-2'),
        ),
      );
    });

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

    test('suppresses muted background websocket message intents', () {
      final intent = BackgroundWsService.notificationIntentFromRawLine(
        '{"type":"new_message","data":{"conversation_id":"conv-1","sender_username":"alice"}}',
        showSensitive: true,
        mutedConversationIds: {'conv-1'},
      );

      expect(intent, isNull);
    });

    test('mentions-only websocket intents ignore server mention metadata', () {
      final preferences = {
        'conv-1': const ConversationNotificationPreference.mentionsOnly(),
      };

      final untrustedMetadata = BackgroundWsService.notificationIntentFromRawLine(
        '{"type":"new_message","data":{"conversation_id":"conv-1","sender_username":"alice","mentioned_user_ids":["u-2"]}}',
        showSensitive: true,
        conversationNotificationPreferences: preferences,
      );
      final matchingMetadata = BackgroundWsService.notificationIntentFromRawLine(
        '{"type":"new_message","data":{"conversation_id":"conv-1","sender_username":"alice","mentioned_user_ids":["u-1"]}}',
        showSensitive: true,
        conversationNotificationPreferences: preferences,
      );

      expect(untrustedMetadata, isNull);
      expect(matchingMetadata, isNull);
    });

    test('keyword rules can notify in mentions-only conversations', () {
      final shouldNotify = shouldNotifyForConversation(
        conversationId: 'conv-1',
        preferences: {
          'conv-1': const ConversationNotificationPreference(
            mode: ConversationNotificationMode.mentionsOnly,
            keywords: ['deploy'],
          ),
        },
        notificationText: 'The deploy is ready',
      );

      expect(shouldNotify, isTrue);
    });

    test('local decrypted mention state can notify in mentions-only chats', () {
      final shouldNotify = shouldNotifyForConversation(
        conversationId: 'conv-1',
        preferences: {
          'conv-1': const ConversationNotificationPreference.mentionsOnly(),
        },
        mentionedForCurrentUser: true,
      );

      expect(shouldNotify, isTrue);
    });

    test('quiet hours suppress unless the conversation is priority', () {
      final quiet = ConversationNotificationPreference(
        quietHoursStartMinute: 22 * 60,
        quietHoursEndMinute: 7 * 60,
      );
      final duringQuietHours = DateTime(2026, 1, 2, 23, 30);

      expect(
        shouldNotifyForConversation(
          conversationId: 'conv-1',
          preferences: {'conv-1': quiet},
          now: duringQuietHours,
        ),
        isFalse,
      );
      expect(
        shouldNotifyForConversation(
          conversationId: 'conv-1',
          preferences: {'conv-1': quiet.copyWith(priority: true)},
          now: duringQuietHours,
        ),
        isTrue,
      );
    });

    test('notification rule preferences round-trip through storage json', () {
      final encoded = encodeConversationNotificationPreferences({
        'conv-1': const ConversationNotificationPreference(
          mode: ConversationNotificationMode.mentionsOnly,
          keywords: ['urgent', 'deploy'],
          priority: true,
          quietHoursStartMinute: 22 * 60,
          quietHoursEndMinute: 7 * 60,
        ),
      });

      final decoded = decodeConversationNotificationPreferences(encoded);

      expect(
        decoded['conv-1']?.mode,
        ConversationNotificationMode.mentionsOnly,
      );
      expect(decoded['conv-1']?.keywords, ['urgent', 'deploy']);
      expect(decoded['conv-1']?.priority, isTrue);
      expect(decoded['conv-1']?.quietHoursStartMinute, 22 * 60);
    });

    test('expired mute-until websocket preference no longer suppresses', () {
      final intent = BackgroundWsService.notificationIntentFromRawLine(
        '{"type":"new_message","data":{"conversation_id":"conv-1","sender_username":"alice"}}',
        showSensitive: true,
        conversationNotificationPreferences: {
          'conv-1': ConversationNotificationPreference(
            mode: ConversationNotificationMode.muted,
            mutedUntil: DateTime.now().subtract(const Duration(minutes: 1)),
          ),
        },
      );

      expect(intent, isNotNull);
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

    test('suppresses muted foreground push message intents', () {
      const msg = RemoteMessage(
        data: {
          'type': 'new_message',
          'conversation_id': 'conv-1',
          'sender_username': 'alice',
        },
      );

      final intent = PushNotificationService.foregroundNotificationIntent(
        msg,
        mutedConversationIds: {'conv-1'},
      );

      expect(intent, isNull);
    });

    test('mentions-only foreground push ignores server mention flags', () {
      const msg = RemoteMessage(
        data: {
          'type': 'new_message',
          'conversation_id': 'conv-1',
          'sender_username': 'alice',
          'mentioned': 'true',
        },
      );

      final intent = PushNotificationService.foregroundNotificationIntent(
        msg,
        conversationNotificationPreferences: {
          'conv-1': const ConversationNotificationPreference.mentionsOnly(),
        },
      );

      expect(intent, isNull);
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

    test('maps join_request into a reviewable notification intent', () {
      final intent = BackgroundWsService.notificationIntentFromRawLine(
        '{"type":"join_request","data":{"conversation_id":"conv-1","user_id":"u-9"}}',
        showSensitive: true,
      );

      expect(intent, isNotNull);
      expect(intent!.kind, NotificationIntentKind.message);
      expect(intent.notificationId, 'conv-1'.hashCode);
      expect(intent.body, 'New join request');
    });

    test('muted conversations suppress join_request intents too', () {
      final intent = BackgroundWsService.notificationIntentFromRawLine(
        '{"type":"join_request","data":{"conversation_id":"conv-1","user_id":"u-9"}}',
        showSensitive: true,
        mutedConversationIds: {'conv-1'},
      );

      expect(intent, isNull);
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

    test('suppresses muted desktop websocket message intents', () {
      final intent = ForegroundWsNotificationRouter.intentForEvent(
        WsEvent(
          type: WsEventType.newMessage,
          data: {'conversation_id': 'conv-1', 'sender_username': 'alice'},
        ),
        showSensitive: true,
        isDesktop: true,
        mutedConversationIds: {'conv-1'},
      );

      expect(intent, isNull);
    });

    test('routes desktop join_request events into notification intents', () {
      final intent = ForegroundWsNotificationRouter.intentForEvent(
        WsEvent(
          type: WsEventType.joinRequest,
          data: {'conversation_id': 'conv-1', 'user_id': 'u-9'},
        ),
        showSensitive: true,
        isDesktop: true,
      );

      expect(intent, isNotNull);
      expect(intent!.kind, NotificationIntentKind.message);
      expect(intent.body, 'New join request');
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

  group('Message notification tap routing', () {
    tearDown(() => NotificationService.setMessageOpenedHandler(null));

    test('routes message notification taps to the conversation', () {
      final opened = <String>[];
      NotificationService.setMessageOpenedHandler(opened.add);

      NotificationService.debugHandleNotificationResponse(
        NotificationResponse(
          id: 'conv-1'.hashCode,
          payload: '{"type":"message","conversation_id":"conv-1"}',
          notificationResponseType:
              NotificationResponseType.selectedNotification,
        ),
      );

      expect(opened, ['conv-1']);
    });

    test('routes reminder notification taps to the conversation', () {
      final opened = <String>[];
      NotificationService.setMessageOpenedHandler(opened.add);

      NotificationService.debugHandleNotificationResponse(
        const NotificationResponse(
          id: 99,
          payload:
              '{"type":"message_reminder","reminder_id":"r-1","conversation_id":"conv-2","message_id":"m-1"}',
          notificationResponseType:
              NotificationResponseType.selectedNotification,
        ),
      );

      expect(opened, ['conv-2']);
    });

    test('queues cold-start taps until the app shell wires the handler',
        () async {
      // Launch-details tap arrives before initState wiring — must not be lost.
      NotificationService.debugHandleNotificationResponse(
        const NotificationResponse(
          id: 98,
          payload: '{"type":"message","conversation_id":"conv-3"}',
          notificationResponseType:
              NotificationResponseType.selectedNotification,
        ),
      );

      final opened = <String>[];
      NotificationService.setMessageOpenedHandler(opened.add);
      await Future<void>.delayed(Duration.zero);

      expect(opened, ['conv-3']);
    });

    test('ignores taps without a routable payload', () {
      final opened = <String>[];
      NotificationService.setMessageOpenedHandler(opened.add);

      NotificationService.debugHandleNotificationResponse(
        const NotificationResponse(
          id: 97,
          notificationResponseType:
              NotificationResponseType.selectedNotification,
        ),
      );
      NotificationService.debugHandleNotificationResponse(
        const NotificationResponse(
          id: 96,
          // Live-location payloads carry ids but no routable type.
          payload: '{"conversation_id":"conv-4","message_id":"m-2"}',
          notificationResponseType:
              NotificationResponseType.selectedNotification,
        ),
      );
      NotificationService.debugHandleNotificationResponse(
        const NotificationResponse(
          id: 95,
          payload: 'not json',
          notificationResponseType:
              NotificationResponseType.selectedNotification,
        ),
      );

      expect(opened, isEmpty);
    });
  });

  group('Incoming call notification contract', () {
    // The notification IS the native ring experience on a locked/idle Android
    // device — these properties are what make the OS treat it like a call
    // (full-screen launch, call ranking, un-swipeable mid-ring, self-expiring
    // just past the ring window + offer buffer).
    test('is a full-screen, non-dismissable call-category notification', () {
      final android =
          NotificationService.incomingCallNotificationDetails.android;
      expect(android, isNotNull);
      expect(android!.category, AndroidNotificationCategory.call);
      expect(android.fullScreenIntent, isTrue);
      expect(android.ongoing, isTrue);
      expect(android.autoCancel, isFalse);
      expect(android.timeoutAfter, 35000);
      expect(android.actions, hasLength(3));
    });

    test('breaks through Focus modes on iOS and macOS', () {
      final ios = NotificationService.incomingCallNotificationDetails.iOS;
      final macos = NotificationService.incomingCallNotificationDetails.macOS;
      expect(ios?.interruptionLevel, InterruptionLevel.timeSensitive);
      expect(macos?.interruptionLevel, InterruptionLevel.timeSensitive);
    });
  });
}
