import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/call_provider.dart';
import 'package:openchat/screens/call/call_screen.dart';
import 'package:openchat/services/call_audio.dart';
import 'package:openchat/services/call_foreground_service.dart';
import 'package:openchat/services/call_media_permissions.dart';
import 'package:openchat/services/call_service.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/notification_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:provider/provider.dart';

void main() {
  group('CallProvider audio sync', () {
    test(
      'stops connecting tone when session becomes connected then null',
      () async {
        final service = _FakeCallService();
        final audio = _FakeCallAudio();
        final provider = CallProvider(service, audio: audio);

        final connecting = CallSession(
          callId: 'c1',
          remoteUserId: 'u2',
          remoteUsername: 'alice',
          isVideo: false,
          isIncoming: false,
          state: CallState.connecting,
        );

        service.emitSession(connecting);
        await Future<void>.delayed(Duration.zero);
        expect(audio.lastTone, 'connecting');

        final connected = CallSession(
          callId: 'c1',
          remoteUserId: 'u2',
          remoteUsername: 'alice',
          isVideo: false,
          isIncoming: false,
          state: CallState.connected,
        );
        service.emitSession(connected);
        await Future<void>.delayed(Duration.zero);
        expect(audio.stopCalls, 1);

        service.emitSession(null);
        await Future<void>.delayed(Duration.zero);
        expect(audio.stopCalls, 2);

        provider.dispose();
        service.dispose();
      },
    );
  });

  group('Call status timer', () {
    test('shows 01:05 for connected call after 65 seconds', () async {
      final now = DateTime.utc(2026, 6, 1, 12, 1, 5);
      final connectedAt = DateTime.utc(2026, 6, 1, 12, 0, 0);
      final service = _FakeCallService();
      final provider = CallProvider(
        service,
        audio: _FakeCallAudio(),
        now: () => now,
      );
      final session = CallSession(
        callId: 'c2',
        remoteUserId: 'u3',
        remoteUsername: 'bob',
        isVideo: false,
        isIncoming: false,
        state: CallState.connected,
      )..connectedAt = connectedAt;
      service.emitSession(session);
      await Future<void>.delayed(Duration.zero);

      expect(provider.callStatusText, '01:05');

      provider.dispose();
      service.dispose();
    });
  });

  group('Call media permissions', () {
    test('outgoing calls request media permissions before dialing', () async {
      final service = _FakeCallService();
      final requested = <bool>[];
      final provider = CallProvider(
        service,
        audio: _FakeCallAudio(),
        mediaPermissionGate: ({required bool isVideo}) async {
          requested.add(isVideo);
        },
      );

      await provider.startCall(
        targetUserId: 'u-permission',
        targetUsername: 'ivy',
        conversationId: 'dm-permission',
        isVideo: true,
      );

      expect(requested, <bool>[true]);
      expect(service.startCallCalls, 1);
      expect(service.startCallIsVideo, <bool>[true]);

      provider.dispose();
      service.dispose();
    });

    test(
      'outgoing calls do not dial when media permission is denied',
      () async {
        final service = _FakeCallService();
        final provider = CallProvider(
          service,
          audio: _FakeCallAudio(),
          mediaPermissionGate: ({required bool isVideo}) async {
            throw const CallPermissionException('Microphone permission denied');
          },
        );

        await expectLater(
          provider.startCall(
            targetUserId: 'u-denied',
            conversationId: 'dm-denied',
            isVideo: false,
          ),
          throwsA(isA<CallPermissionException>()),
        );
        expect(service.startCallCalls, 0);

        provider.dispose();
        service.dispose();
      },
    );

    test(
      'incoming calls stay pending when answer media permission is denied',
      () async {
        final service = _FakeCallService();
        final incoming = CallSession(
          callId: 'c-denied-answer',
          remoteUserId: 'u-incoming',
          remoteUsername: 'jules',
          isVideo: true,
          isIncoming: true,
          state: CallState.ringing,
        );
        final provider = CallProvider(
          service,
          audio: _FakeCallAudio(),
          mediaPermissionGate: ({required bool isVideo}) async {
            throw const CallPermissionException('Camera permission denied');
          },
        );

        service.emitIncoming(incoming);
        await Future<void>.delayed(Duration.zero);

        await expectLater(
          provider.acceptIncomingCall(),
          throwsA(isA<CallPermissionException>()),
        );

        expect(provider.incomingCall, same(incoming));
        expect(service.acceptIncomingCalls, 0);

        provider.dispose();
        service.dispose();
      },
    );
  });

  group('Call overlay minimize and expand', () {
    test('uses RTC renderers only for video sessions', () {
      final videoSession = CallSession(
        callId: 'c-video-policy',
        remoteUserId: 'u-desktop',
        remoteUsername: 'desktop',
        isVideo: true,
        isIncoming: false,
        state: CallState.connected,
      );
      final voiceSession = CallSession(
        callId: 'c-voice-policy',
        remoteUserId: 'u-desktop',
        remoteUsername: 'desktop',
        isVideo: false,
        isIncoming: false,
        state: CallState.connected,
      );

      expect(shouldUseCallVideoRenderersForTesting(videoSession), isTrue);
      expect(shouldUseCallVideoRenderersForTesting(voiceSession), isFalse);
      expect(shouldUseCallVideoRenderersForTesting(null), isFalse);
    });

    testWidgets('keeps desktop voice call controls tappable', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      final service = _FakeCallService();
      final provider = CallProvider(service, audio: _FakeCallAudio());
      try {
        final session = CallSession(
          callId: 'c-desktop-audio',
          remoteUserId: 'u-desktop',
          remoteUsername: 'desktop',
          isVideo: false,
          isIncoming: false,
          state: CallState.connected,
        )..connectedAt = DateTime.now();

        service.emitSession(session);

        await tester.pumpWidget(
          ChangeNotifierProvider<CallProvider>.value(
            value: provider,
            child: const MaterialApp(home: Scaffold(body: CallOverlay())),
          ),
        );
        await tester.pump();

        expect(find.byType(CallScreen), findsOneWidget);
        await tester.tap(find.byKey(const Key('minimize-call-button')));
        await tester.pump();
        expect(provider.isCallMinimized, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        provider.dispose();
        service.dispose();
      }
    });

    testWidgets('keeps desktop video call controls tappable', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      final service = _FakeCallService();
      final provider = CallProvider(service, audio: _FakeCallAudio());
      try {
        final session = CallSession(
          callId: 'c-desktop-video',
          remoteUserId: 'u-desktop',
          remoteUsername: 'desktop',
          isVideo: true,
          isIncoming: false,
          state: CallState.connected,
        )..connectedAt = DateTime.now();

        service.emitSession(session);

        await tester.pumpWidget(
          ChangeNotifierProvider<CallProvider>.value(
            value: provider,
            child: const MaterialApp(home: Scaffold(body: CallOverlay())),
          ),
        );
        await tester.pump();

        expect(find.byType(CallScreen), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('call-control-mute')),
            matching: find.byType(IconButton),
          ),
          findsNothing,
        );
        await tester.tap(find.byKey(const Key('call-control-mute')));
        await tester.pump();
        expect(provider.isMicMuted, isTrue);
        expect(service.micMuteValues, <bool>[true]);
        await tester.tap(find.byKey(const Key('call-control-end')));
        await tester.pump();
        expect(service.hangupCalls, 1);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        provider.dispose();
        service.dispose();
      }
    });

    testWidgets('shows camera flip control on mobile video calls', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final service = _FakeCallService(nextFrontCamera: false);
      final provider = CallProvider(service, audio: _FakeCallAudio());
      try {
        final session = CallSession(
          callId: 'c-mobile-video',
          remoteUserId: 'u-mobile',
          remoteUsername: 'mobile',
          isVideo: true,
          isIncoming: false,
          state: CallState.connected,
        )..connectedAt = DateTime.now();

        service.emitSession(session);

        await tester.pumpWidget(
          ChangeNotifierProvider<CallProvider>.value(
            value: provider,
            child: const MaterialApp(home: Scaffold(body: CallOverlay())),
          ),
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('call-control-switch-camera')));
        await tester.pump();

        expect(service.switchCameraCalls, 1);
        expect(provider.isFrontCamera, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        provider.dispose();
        service.dispose();
      }
    });

    testWidgets('constrains desktop call controls in wide windows', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 800);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final service = _FakeCallService();
      final provider = CallProvider(service, audio: _FakeCallAudio());
      try {
        final session = CallSession(
          callId: 'c-desktop-wide',
          remoteUserId: 'u-desktop',
          remoteUsername: 'desktop',
          isVideo: true,
          isIncoming: false,
          state: CallState.connected,
        )..connectedAt = DateTime.now();

        service.emitSession(session);

        await tester.pumpWidget(
          ChangeNotifierProvider<CallProvider>.value(
            value: provider,
            child: const MaterialApp(home: Scaffold(body: CallOverlay())),
          ),
        );
        await tester.pump();

        final controlsSize = tester.getSize(
          find.byKey(const Key('call-controls-bar')),
        );
        expect(controlsSize.width, lessThanOrEqualTo(560));
        expect(controlsSize.width, greaterThan(280));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        provider.dispose();
        service.dispose();
      }
    });

    testWidgets('shows compact affordance and expands back to full', (
      tester,
    ) async {
      final service = _FakeCallService();
      final provider = CallProvider(service, audio: _FakeCallAudio());
      final session = CallSession(
        callId: 'c3',
        remoteUserId: 'u4',
        remoteUsername: 'charlie',
        isVideo: false,
        isIncoming: false,
        state: CallState.connected,
      )..connectedAt = DateTime.now().subtract(const Duration(seconds: 5));

      service.emitSession(session);
      provider.setCallMinimized(true);

      await tester.pumpWidget(
        ChangeNotifierProvider<CallProvider>.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: CallOverlay())),
        ),
      );

      expect(find.byKey(const Key('minimized-call-overlay')), findsOneWidget);
      await tester.tap(find.byKey(const Key('expand-call-button')));
      await tester.pump();

      expect(provider.isCallMinimized, isFalse);

      provider.dispose();
      service.dispose();
    });
  });

  group('Call media capture constraints', () {
    test('audio calls do not request video capture', () {
      final attempts = buildCallMediaCaptureAttemptsForTesting(
        isVideo: false,
        isMobile: false,
        isWeb: false,
        isDesktop: true,
      );

      expect(attempts, const [
        {'audio': true, 'video': false},
      ]);
    });

    test('video calls use the LiveKit default capture profile', () {
      final attempts = buildCallMediaCaptureAttemptsForTesting(
        isVideo: true,
        isMobile: false,
        isWeb: false,
        isDesktop: true,
      );

      expect(attempts, const [
        {
          'audio': true,
          'video': {'width': 640, 'height': 480, 'frameRate': 30},
        },
      ]);
    });
  });

  group('Incoming call lifecycle', () {
    test('incoming payload carries caller profile into the session', () async {
      final storage = SecureStorageService();
      final service = CallService(
        WebSocketService(storage),
        ApiService(storage),
      );
      final seen = Completer<CallSession>();
      final sub = service.incomingCalls.listen(seen.complete);

      final handled = service.handleIncomingCallPayload({
        'call_id': 'c-profile',
        'caller_id': 'u-profile',
        'caller_username': ' alice ',
        'caller_avatar': ' https://example.test/a.png ',
        'is_video': 'true',
      });

      expect(handled, isTrue);
      final incoming = await seen.future;
      expect(incoming.remoteUsername, 'alice');
      expect(incoming.remoteAvatarUrl, 'https://example.test/a.png');
      expect(incoming.isVideo, isTrue);

      await sub.cancel();
      service.dispose();
    });

    test('rejecting a pending call does not re-emit it as incoming', () async {
      final storage = SecureStorageService();
      final service = CallService(
        WebSocketService(storage),
        ApiService(storage),
      );
      var emitted = false;
      final sub = service.incomingCalls.listen((_) => emitted = true);

      service.rejectCall(
        CallSession(
          callId: 'c-reject',
          remoteUserId: 'u-reject',
          isVideo: false,
          isIncoming: true,
          state: CallState.ringing,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(emitted, isFalse);

      await sub.cancel();
      service.dispose();
    });

    test('provider ignores ended incoming sessions defensively', () async {
      final service = _FakeCallService();
      final provider = CallProvider(service, audio: _FakeCallAudio());

      service.emitIncoming(
        CallSession(
          callId: 'c-ended',
          remoteUserId: 'u-ended',
          isVideo: false,
          isIncoming: true,
          state: CallState.ended,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(provider.incomingCall, isNull);

      provider.dispose();
      service.dispose();
    });

    test(
      'notification actions answer dismiss and decline incoming calls',
      () async {
        final service = _FakeCallService();
        final provider = CallProvider(
          service,
          audio: _FakeCallAudio(),
          mediaPermissionGate: ({required bool isVideo}) async {},
        );

        service.emitIncoming(
          CallSession(
            callId: 'c-incoming-answer',
            remoteUserId: 'u-incoming',
            isVideo: false,
            isIncoming: true,
            state: CallState.ringing,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        NotificationService.debugHandleNotificationResponse(
          const NotificationResponse(
            id: 1,
            actionId: 'openchat_call_answer',
            notificationResponseType:
                NotificationResponseType.selectedNotificationAction,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(service.acceptIncomingCalls, 1);
        expect(provider.incomingCall, isNull);

        service.emitIncoming(
          CallSession(
            callId: 'c-incoming-dismiss',
            remoteUserId: 'u-incoming',
            isVideo: false,
            isIncoming: true,
            state: CallState.ringing,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        NotificationService.debugHandleNotificationResponse(
          const NotificationResponse(
            id: 1,
            actionId: 'openchat_call_dismiss',
            notificationResponseType:
                NotificationResponseType.selectedNotificationAction,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(service.rejectCalls, 0);
        expect(provider.incomingCall, isNull);

        service.emitIncoming(
          CallSession(
            callId: 'c-incoming-decline',
            remoteUserId: 'u-incoming',
            isVideo: false,
            isIncoming: true,
            state: CallState.ringing,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        NotificationService.debugHandleNotificationResponse(
          const NotificationResponse(
            id: 1,
            actionId: 'openchat_call_decline',
            notificationResponseType:
                NotificationResponseType.selectedNotificationAction,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(service.rejectCalls, 1);
        expect(provider.incomingCall, isNull);

        provider.dispose();
        service.dispose();
      },
    );

    testWidgets('shows incoming caller name in a bounded desktop prompt', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 800);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final service = _FakeCallService();
      final provider = CallProvider(service, audio: _FakeCallAudio());
      try {
        await tester.pumpWidget(
          ChangeNotifierProvider<CallProvider>.value(
            value: provider,
            child: const MaterialApp(home: Scaffold(body: CallOverlay())),
          ),
        );

        service.emitIncoming(
          CallSession(
            callId: 'c-incoming-desktop',
            remoteUserId: 'u-incoming',
            remoteUsername: 'alex',
            isVideo: false,
            isIncoming: true,
            state: CallState.ringing,
          ),
        );
        await tester.pump();

        expect(find.text('@alex'), findsOneWidget);
        expect(find.text('Unknown caller'), findsNothing);
        final panelSize = tester.getSize(
          find.byKey(const Key('incoming-call-panel')),
        );
        expect(panelSize.width, lessThanOrEqualTo(480));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        provider.dispose();
        service.dispose();
      }
    });
  });

  group('Audio output controls', () {
    test(
      'provider routes selection call and swallows unsupported errors',
      () async {
        final service = _FakeCallService(throwOnSelectAudioOutput: true);
        final provider = CallProvider(service, audio: _FakeCallAudio());

        await provider.selectAudioOutput('speaker');
        expect(service.selectAudioOutputCalls, 1);

        provider.dispose();
        service.dispose();
      },
    );

    test('provider keeps mute state in sync with the call service', () {
      final service = _FakeCallService();
      final provider = CallProvider(service, audio: _FakeCallAudio());

      provider.setMicMuted(true);
      provider.setMicMuted(false);

      expect(provider.isMicMuted, isFalse);
      expect(service.micMuteValues, <bool>[true, false]);

      provider.dispose();
      service.dispose();
    });

    test('provider flips mobile camera and tracks mirror state', () async {
      final service = _FakeCallService(nextFrontCamera: false);
      final provider = CallProvider(service, audio: _FakeCallAudio());

      await provider.switchCamera();

      expect(service.switchCameraCalls, 1);
      expect(provider.isFrontCamera, isFalse);
      expect(provider.isCameraEnabled, isTrue);

      provider.dispose();
      service.dispose();
    });

    test('provider resets media control defaults after calls end', () async {
      final service = _FakeCallService();
      final provider = CallProvider(service, audio: _FakeCallAudio());

      service.emitSession(
        CallSession(
          callId: 'c3',
          remoteUserId: 'u4',
          isVideo: true,
          isIncoming: false,
          state: CallState.connected,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      provider.setMicMuted(true);
      provider.setCameraEnabled(false);

      service.emitSession(null);
      await Future<void>.delayed(Duration.zero);

      expect(provider.isMicMuted, isFalse);
      expect(provider.isCameraEnabled, isTrue);
      expect(service.micMuteValues, <bool>[true, false]);
      expect(service.cameraEnabledValues, <bool>[false, true]);

      provider.dispose();
      service.dispose();
    });

    test('provider swallows native control errors', () {
      final service = _FakeCallService(
        throwOnSetMicMuted: true,
        throwOnSetCameraEnabled: true,
        throwOnHangup: true,
      );
      final provider = CallProvider(service, audio: _FakeCallAudio());

      provider.setMicMuted(true);
      provider.setCameraEnabled(false);
      provider.hangup();

      expect(provider.isMicMuted, isTrue);
      expect(provider.isCameraEnabled, isFalse);
      expect(service.micMuteValues, <bool>[true]);
      expect(service.cameraEnabledValues, <bool>[false]);
      expect(service.hangupCalls, 1);

      provider.dispose();
      service.dispose();
    });
  });

  group('Active call notification controls', () {
    test('end action hangs up the current call', () async {
      final service = _FakeCallService();
      final provider = CallProvider(
        service,
        audio: _FakeCallAudio(),
        foreground: _FakeCallForeground(),
      );
      service.emitSession(
        CallSession(
          callId: 'c4',
          remoteUserId: 'u5',
          remoteUsername: 'dana',
          isVideo: false,
          isIncoming: false,
          state: CallState.connected,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      NotificationService.debugHandleNotificationResponse(
        const NotificationResponse(
          id: 2,
          actionId: 'openchat_call_end',
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
        ),
      );

      expect(service.hangupCalls, 1);

      provider.dispose();
      service.dispose();
    });

    test(
      'mute action toggles provider mute state without hanging up',
      () async {
        final service = _FakeCallService();
        final provider = CallProvider(
          service,
          audio: _FakeCallAudio(),
          foreground: _FakeCallForeground(),
        );
        service.emitSession(
          CallSession(
            callId: 'c5',
            remoteUserId: 'u6',
            remoteUsername: 'erin',
            isVideo: false,
            isIncoming: false,
            state: CallState.connected,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        NotificationService.debugHandleNotificationResponse(
          const NotificationResponse(
            id: 2,
            actionId: 'openchat_call_mute',
            notificationResponseType:
                NotificationResponseType.selectedNotificationAction,
          ),
        );

        expect(provider.isMicMuted, isTrue);
        expect(service.micMuteValues, <bool>[true]);
        expect(service.hangupCalls, 0);

        provider.dispose();
        service.dispose();
      },
    );

    test('tapping active call notification body does not hang up', () async {
      final service = _FakeCallService();
      final provider = CallProvider(
        service,
        audio: _FakeCallAudio(),
        foreground: _FakeCallForeground(),
      );
      service.emitSession(
        CallSession(
          callId: 'c6',
          remoteUserId: 'u7',
          remoteUsername: 'finn',
          isVideo: false,
          isIncoming: false,
          state: CallState.connected,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      NotificationService.debugHandleNotificationResponse(
        const NotificationResponse(
          id: 2,
          notificationResponseType:
              NotificationResponseType.selectedNotification,
        ),
      );

      expect(service.hangupCalls, 0);

      provider.dispose();
      service.dispose();
    });

    test('active calls start and stop android foreground service', () async {
      final foreground = _FakeCallForeground();
      final service = _FakeCallService();
      final connectedAt = DateTime.utc(2026, 6, 3, 12, 0);
      final provider = CallProvider(
        service,
        audio: _FakeCallAudio(),
        foreground: foreground,
      );

      service.emitSession(
        CallSession(
          callId: 'c7',
          remoteUserId: 'u8',
          remoteUsername: 'gail',
          isVideo: true,
          isIncoming: false,
          state: CallState.connected,
        )..connectedAt = connectedAt,
      );
      await Future<void>.delayed(Duration.zero);

      expect(foreground.starts.length, 1);
      expect(foreground.starts.single.isVideo, isTrue);
      expect(foreground.starts.single.muted, isFalse);
      expect(foreground.starts.single.body, 'Call in progress');
      expect(
        foreground.starts.single.connectedAtMillis,
        connectedAt.millisecondsSinceEpoch,
      );

      provider.setMicMuted(true);
      await Future<void>.delayed(Duration.zero);

      expect(foreground.starts.length, 2);
      expect(foreground.starts.last.muted, isTrue);
      expect(
        foreground.starts.last.connectedAtMillis,
        connectedAt.millisecondsSinceEpoch,
      );

      provider.hangup();
      await Future<void>.delayed(Duration.zero);

      expect(foreground.stopCalls, 1);

      provider.dispose();
      service.dispose();
    });

    test('foreground service waits until local media is ready', () async {
      final foreground = _FakeCallForeground();
      final service = _FakeCallService(hasLocalMedia: false);
      final session = CallSession(
        callId: 'c8',
        remoteUserId: 'u9',
        remoteUsername: 'hank',
        isVideo: true,
        isIncoming: false,
        state: CallState.calling,
      );
      final provider = CallProvider(
        service,
        audio: _FakeCallAudio(),
        foreground: foreground,
      );

      service.emitSession(session);
      await Future<void>.delayed(Duration.zero);

      expect(foreground.starts, isEmpty);

      service.localMediaReady = true;
      service.emitSession(session);
      await Future<void>.delayed(Duration.zero);

      expect(foreground.starts.length, 1);
      expect(foreground.starts.single.isVideo, isTrue);

      provider.dispose();
      service.dispose();
    });
  });
}

class _FakeCallAudio implements CallAudioController {
  String? lastTone;
  int stopCalls = 0;

  @override
  Future<void> update({CallState? state, bool incoming = false}) async {
    if (incoming) {
      lastTone = 'ringing';
      return;
    }
    switch (state) {
      case CallState.calling:
      case CallState.ringing:
        lastTone = 'ringing';
      case CallState.connecting:
        lastTone = 'connecting';
      default:
        stopCalls += 1;
    }
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }

  @override
  void dispose() {}
}

class _ForegroundStart {
  final String title;
  final String body;
  final bool isVideo;
  final bool muted;
  final int? connectedAtMillis;

  const _ForegroundStart({
    required this.title,
    required this.body,
    required this.isVideo,
    required this.muted,
    this.connectedAtMillis,
  });
}

class _FakeCallForeground implements CallForegroundController {
  final List<_ForegroundStart> starts = [];
  int stopCalls = 0;

  @override
  Future<bool> start({
    required String title,
    required String body,
    required bool isVideo,
    required bool muted,
    int? connectedAtMillis,
  }) async {
    starts.add(
      _ForegroundStart(
        title: title,
        body: body,
        isVideo: isVideo,
        muted: muted,
        connectedAtMillis: connectedAtMillis,
      ),
    );
    return true;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }
}

class _FakeCallService extends CallService {
  _FakeCallService({
    this.throwOnSelectAudioOutput = false,
    this.throwOnSetMicMuted = false,
    this.throwOnSetCameraEnabled = false,
    this.throwOnHangup = false,
    this.nextFrontCamera = true,
    bool hasLocalMedia = true,
  }) : localMediaReady = hasLocalMedia,
       super(
         WebSocketService(SecureStorageService()),
         ApiService(SecureStorageService()),
       );

  final bool throwOnSelectAudioOutput;
  final bool throwOnSetMicMuted;
  final bool throwOnSetCameraEnabled;
  final bool throwOnHangup;
  final bool nextFrontCamera;
  final _sessionController = StreamController<CallSession?>.broadcast();
  final _incomingController = StreamController<CallSession>.broadcast();
  final _missedController = StreamController<CallSession>.broadcast();
  final _endedController = StreamController<CallEndedEvent>.broadcast();
  CallSession? _session;
  int selectAudioOutputCalls = 0;
  int acceptIncomingCalls = 0;
  int rejectCalls = 0;
  int hangupCalls = 0;
  int startCallCalls = 0;
  int switchCameraCalls = 0;
  bool localMediaReady;
  final List<bool> startCallIsVideo = [];
  final List<List<String>> startCallAdditionalUserIds = [];
  final List<bool> micMuteValues = [];
  final List<bool> cameraEnabledValues = [];

  void emitSession(CallSession? session) {
    _session = session;
    _sessionController.add(session);
  }

  void emitIncoming(CallSession session) {
    _incomingController.add(session);
  }

  @override
  CallSession? get currentSession => _session;

  @override
  Stream<CallSession?> get sessionStream => _sessionController.stream;

  @override
  Stream<CallSession> get incomingCalls => _incomingController.stream;

  @override
  Stream<CallSession> get missedCalls => _missedController.stream;

  @override
  Stream<CallEndedEvent> get callEnded => _endedController.stream;

  @override
  bool get hasLocalMedia => localMediaReady;

  @override
  Future<void> startCall({
    required String targetUserId,
    String? targetUsername,
    required String conversationId,
    required bool isVideo,
    List<String> additionalUserIds = const [],
  }) async {
    startCallCalls += 1;
    startCallIsVideo.add(isVideo);
    startCallAdditionalUserIds.add(additionalUserIds);
    _session = CallSession(
      callId: 'started-$startCallCalls',
      remoteUserId: targetUserId,
      remoteUsername: targetUsername,
      conversationId: conversationId,
      participantUserIds: [targetUserId, ...additionalUserIds],
      isVideo: isVideo,
      isIncoming: false,
      state: CallState.calling,
    );
    _sessionController.add(_session);
  }

  @override
  Future<void> selectAudioOutput(String deviceId) async {
    selectAudioOutputCalls += 1;
    if (throwOnSelectAudioOutput) {
      throw UnsupportedError('unsupported');
    }
  }

  @override
  Future<bool> switchCamera() async {
    switchCameraCalls += 1;
    return nextFrontCamera;
  }

  @override
  Future<void> acceptIncomingCall(CallSession session) async {
    acceptIncomingCalls += 1;
    _session = session..state = CallState.calling;
    _sessionController.add(_session);
  }

  @override
  void rejectCall(CallSession session) {
    rejectCalls += 1;
  }

  @override
  void setMicMuted(bool muted) {
    micMuteValues.add(muted);
    if (throwOnSetMicMuted) throw UnsupportedError('unsupported mic');
  }

  @override
  void hangup() {
    hangupCalls += 1;
    if (throwOnHangup) throw UnsupportedError('unsupported hangup');
  }

  @override
  void setCameraEnabled(bool enabled) {
    cameraEnabledValues.add(enabled);
    if (throwOnSetCameraEnabled) {
      throw UnsupportedError('unsupported camera');
    }
  }

  @override
  void dispose() {
    _sessionController.close();
    _incomingController.close();
    _missedController.close();
    _endedController.close();
    super.dispose();
  }
}
