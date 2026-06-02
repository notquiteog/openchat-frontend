import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/call_provider.dart';
import 'package:openchat/screens/call/call_screen.dart';
import 'package:openchat/services/call_audio.dart';
import 'package:openchat/services/call_foreground_service.dart';
import 'package:openchat/services/call_service.dart';
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

  group('Call overlay minimize and expand', () {
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

  group('Incoming call lifecycle', () {
    test('rejecting a pending call does not re-emit it as incoming', () async {
      final service = CallService(WebSocketService(SecureStorageService()));
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
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(foreground.starts.length, 1);
      expect(foreground.starts.single.isVideo, isTrue);
      expect(foreground.starts.single.muted, isFalse);

      provider.setMicMuted(true);
      await Future<void>.delayed(Duration.zero);

      expect(foreground.starts.length, 2);
      expect(foreground.starts.last.muted, isTrue);

      provider.hangup();
      await Future<void>.delayed(Duration.zero);

      expect(foreground.stopCalls, 1);

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

  const _ForegroundStart({
    required this.title,
    required this.body,
    required this.isVideo,
    required this.muted,
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
  }) async {
    starts.add(
      _ForegroundStart(
        title: title,
        body: body,
        isVideo: isVideo,
        muted: muted,
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
  _FakeCallService({this.throwOnSelectAudioOutput = false})
    : super(WebSocketService(SecureStorageService()));

  final bool throwOnSelectAudioOutput;
  final _sessionController = StreamController<CallSession?>.broadcast();
  final _incomingController = StreamController<CallSession>.broadcast();
  final _missedController = StreamController<CallSession>.broadcast();
  final _endedController = StreamController<CallEndedEvent>.broadcast();
  CallSession? _session;
  int selectAudioOutputCalls = 0;
  int hangupCalls = 0;
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
  Future<void> selectAudioOutput(String deviceId) async {
    selectAudioOutputCalls += 1;
    if (throwOnSelectAudioOutput) {
      throw UnsupportedError('unsupported');
    }
  }

  @override
  void setMicMuted(bool muted) {
    micMuteValues.add(muted);
  }

  @override
  void hangup() {
    hangupCalls += 1;
  }

  @override
  void setCameraEnabled(bool enabled) {
    cameraEnabledValues.add(enabled);
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
