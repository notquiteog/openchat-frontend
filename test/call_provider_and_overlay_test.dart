import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/call_provider.dart';
import 'package:openchat/screens/call/call_screen.dart';
import 'package:openchat/services/call_audio.dart';
import 'package:openchat/services/call_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:provider/provider.dart';

void main() {
  group('CallProvider audio sync', () {
    test('stops connecting tone when session becomes connected then null',
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
    });
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
    testWidgets('shows compact affordance and expands back to full',
        (tester) async {
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

  group('Audio output controls', () {
    test('provider routes selection call and swallows unsupported errors',
        () async {
      final service = _FakeCallService(throwOnSelectAudioOutput: true);
      final provider = CallProvider(service, audio: _FakeCallAudio());

      await provider.selectAudioOutput('speaker');
      expect(service.selectAudioOutputCalls, 1);

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

  void emitSession(CallSession? session) {
    _session = session;
    _sessionController.add(session);
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
  void dispose() {
    _sessionController.close();
    _incomingController.close();
    _missedController.close();
    _endedController.close();
    super.dispose();
  }
}
