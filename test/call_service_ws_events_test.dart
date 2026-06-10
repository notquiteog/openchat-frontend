import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/call_service.dart';
import 'package:openchat/services/call_signal_codec.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';

/// WebSocketService whose event stream is test-driven; never connects.
class _FakeWebSocketService extends WebSocketService {
  _FakeWebSocketService() : super(SecureStorageService());

  final _controller = StreamController<WsEvent>.broadcast();

  @override
  Stream<WsEvent> get events => _controller.stream;

  void close() => _controller.close();
}

CallSession _session({
  required String callId,
  CallState state = CallState.calling,
  bool isIncoming = false,
}) => CallSession(
  callId: callId,
  remoteUserId: 'remote-user',
  remoteUsername: 'alice',
  conversationId: 'conv-1',
  isVideo: false,
  isIncoming: isIncoming,
  state: state,
);

void main() {
  late _FakeWebSocketService ws;
  late CallService service;

  setUp(() {
    ws = _FakeWebSocketService();
    service = CallService(ws, ApiService(SecureStorageService()));
  });

  tearDown(() {
    ws.close();
  });

  group('call_ringing state transitions', () {
    test('moves an outgoing call from calling to ringing', () {
      service.debugSession = _session(callId: 'call-1');

      service.debugHandleWsEvent(
        WsEvent(type: WsEventType.callRinging, data: {'call_id': 'call-1'}),
      );

      expect(service.currentSession?.state, CallState.ringing);
    });

    test('ignores a late ringing event once the call is connected', () {
      service.debugSession = _session(
        callId: 'call-1',
        state: CallState.connected,
      )..wasConnected = true;

      service.debugHandleWsEvent(
        WsEvent(type: WsEventType.callRinging, data: {'call_id': 'call-1'}),
      );

      expect(service.currentSession?.state, CallState.connected);
    });

    test('ignores a ringing event while connecting', () {
      service.debugSession = _session(
        callId: 'call-1',
        state: CallState.connecting,
      );

      service.debugHandleWsEvent(
        WsEvent(type: WsEventType.callRinging, data: {'call_id': 'call-1'}),
      );

      expect(service.currentSession?.state, CallState.connecting);
    });

    test('ignores a ringing event for a different call id', () {
      service.debugSession = _session(callId: 'call-1');

      service.debugHandleWsEvent(
        WsEvent(type: WsEventType.callRinging, data: {'call_id': 'stale-id'}),
      );

      expect(service.currentSession?.state, CallState.calling);
    });
  });

  group('call_hangup routing', () {
    test('ignores a stale hangup carrying a different call id', () {
      service.debugSession = _session(
        callId: 'call-1',
        state: CallState.connected,
      )..wasConnected = true;

      service.debugHandleWsEvent(
        WsEvent(
          type: WsEventType.callHangup,
          data: {'call_id': 'previous-call', 'caller_id': 'remote-user'},
        ),
      );

      // The active call must survive a hangup that belongs to an older call.
      expect(service.currentSession, isNotNull);
      expect(service.currentSession?.state, CallState.connected);
    });

    test(
      'dismisses a pending incoming ring while another call is active',
      () async {
        service.debugSession = _session(
          callId: 'active-call',
          state: CallState.connected,
        )..wasConnected = true;
        service.debugPendingIncoming = _session(
          callId: 'second-call',
          isIncoming: true,
          state: CallState.ringing,
        );

        final missed = <CallSession>[];
        final sub = service.missedCalls.listen(missed.add);

        service.debugHandleWsEvent(
          WsEvent(
            type: WsEventType.callHangup,
            data: {'call_id': 'second-call', 'caller_id': 'remote-user'},
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(service.debugPendingIncoming, isNull);
        expect(missed.map((m) => m.callId), ['second-call']);
        // The active call is untouched.
        expect(service.currentSession?.callId, 'active-call');
        expect(service.currentSession?.state, CallState.connected);
        await sub.cancel();
      },
    );
  });

  group('call_cancel routing', () {
    test(
      'dismisses the matching pending ring while another call is active',
      () async {
        service.debugSession = _session(
          callId: 'active-call',
          state: CallState.connected,
        )..wasConnected = true;
        service.debugPendingIncoming = _session(
          callId: 'second-call',
          isIncoming: true,
          state: CallState.ringing,
        );

        final cancelled = <CallSession>[];
        final sub = service.cancelledCalls.listen(cancelled.add);

        service.debugHandleWsEvent(
          WsEvent(
            type: WsEventType.callCancel,
            data: {'call_id': 'second-call'},
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(service.debugPendingIncoming, isNull);
        expect(cancelled.map((c) => c.callId), ['second-call']);
        expect(service.currentSession?.callId, 'active-call');
        await sub.cancel();
      },
    );

    test('requires an explicit call id match while a call is active', () {
      service.debugSession = _session(
        callId: 'active-call',
        state: CallState.connected,
      )..wasConnected = true;
      service.debugPendingIncoming = _session(
        callId: 'second-call',
        isIncoming: true,
        state: CallState.ringing,
      );

      // An empty cancel id is too ambiguous to act on mid-call.
      service.debugHandleWsEvent(
        WsEvent(type: WsEventType.callCancel, data: const {}),
      );

      expect(service.debugPendingIncoming, isNotNull);
    });

    test('empty cancel id still dismisses when no call is active', () async {
      service.debugPendingIncoming = _session(
        callId: 'only-call',
        isIncoming: true,
        state: CallState.ringing,
      );

      service.debugHandleWsEvent(
        WsEvent(type: WsEventType.callCancel, data: const {}),
      );
      await Future<void>.delayed(Duration.zero);

      expect(service.debugPendingIncoming, isNull);
    });
  });

  group('call_escalate routing', () {
    test('matching escalate tears down the mesh and reports the room',
        () async {
      service.debugSession = _session(
        callId: 'mesh-call',
        state: CallState.connected,
      )..wasConnected = true;

      final escalations = <EscalatedCall>[];
      final sub = service.escalatedCalls.listen(escalations.add);

      service.debugHandleWsEvent(
        WsEvent(
          type: WsEventType.callEscalate,
          data: {'call_id': 'mesh-call', 'conversation_id': 'conv-1'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(escalations, hasLength(1));
      expect(escalations.single.conversationId, 'conv-1');
      // Mesh side is gone — the listener joins the LiveKit room instead.
      expect(service.currentSession, isNull);
      await sub.cancel();
    });

    test('escalate for an unknown call id is ignored', () async {
      service.debugSession = _session(
        callId: 'mesh-call',
        state: CallState.connected,
      )..wasConnected = true;

      final escalations = <EscalatedCall>[];
      final sub = service.escalatedCalls.listen(escalations.add);

      service.debugHandleWsEvent(
        WsEvent(
          type: WsEventType.callEscalate,
          data: {'call_id': 'stale-call', 'conversation_id': 'conv-1'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(escalations, isEmpty);
      expect(service.currentSession?.callId, 'mesh-call');
      await sub.cancel();
    });

    test('an escalate carrying a frame key caches it and hands it on',
        () async {
      service.debugSession = _session(
        callId: 'mesh-call',
        state: CallState.connected,
      )..wasConnected = true;

      final escalations = <EscalatedCall>[];
      final sub = service.escalatedCalls.listen(escalations.add);

      service.debugHandleWsEvent(
        WsEvent(
          type: WsEventType.callEscalate,
          data: {
            'call_id': 'mesh-call',
            'conversation_id': 'conv-1',
            'e2ee_key': 'a-shared-frame-key',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(escalations.single.e2eeKeyB64, 'a-shared-frame-key');
      // Cached so a later banner join (or key request from a peer) has it.
      expect(service.sfuKeyFor('conv-1'), 'a-shared-frame-key');
      await sub.cancel();
    });
  });

  group('SFU media E2EE keys', () {
    test('createSfuKey yields a cached 32-byte key, fresh per call', () {
      final first = service.createSfuKey('conv-1');
      expect(base64Decode(first), hasLength(32));
      expect(service.sfuKeyFor('conv-1'), first);

      final second = service.createSfuKey('conv-1');
      expect(second, isNot(first));
      expect(service.sfuKeyFor('conv-1'), second);
    });

    test('an incoming call_e2ee_key is stored for its conversation', () async {
      service.debugHandleWsEvent(
        WsEvent(
          type: WsEventType.callE2EEKey,
          data: {
            'conversation_id': 'conv-9',
            'e2ee_key': 'key-from-a-participant',
            'caller_id': 'participant-1',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(service.sfuKeyFor('conv-9'), 'key-from-a-participant');
      expect(service.sfuKeyFor('conv-other'), isNull);
    });

    test('requestSfuKey resolves when a participant answers', () async {
      final pending = service.requestSfuKey(
        'conv-2',
        fromUserIds: const ['participant-1'],
      );

      service.debugHandleWsEvent(
        WsEvent(
          type: WsEventType.callE2EEKey,
          data: {
            'conversation_id': 'conv-2',
            'e2ee_key': 'answered-key',
            'caller_id': 'participant-1',
          },
        ),
      );

      expect(await pending, 'answered-key');
    });

    test('requestSfuKey returns the cached key without waiting', () async {
      final key = service.createSfuKey('conv-3');
      expect(
        await service.requestSfuKey('conv-3', fromUserIds: const ['p1']),
        key,
      );
    });

    test('requestSfuKey times out to null when nobody answers', () async {
      final result = await service.requestSfuKey(
        'conv-4',
        fromUserIds: const ['participant-1'],
        timeout: const Duration(milliseconds: 50),
      );
      expect(result, isNull);
    });

    test('requestSfuKey with no participants gives up immediately', () async {
      expect(
        await service.requestSfuKey('conv-5', fromUserIds: const []),
        isNull,
      );
    });
  });

  group('sealed call signaling (E2EE chip)', () {
    test('sealedCallPayload keys off a codec-asserted encryption_mode', () {
      expect(sealedCallPayload({'encryption_mode': 'pgp'}), isTrue);
      expect(sealedCallPayload({'encryption_mode': 'mls'}), isTrue);
      expect(sealedCallPayload(const {}), isFalse);
      expect(sealedCallPayload({'encryption_mode': '  '}), isFalse);
    });

    test('the plain codec strips a spoofed encryption_mode', () async {
      const codec = PlainCallSignalCodec();
      final decoded = await codec.decode({
        'call_id': 'c1',
        // Attacker-supplied on a plaintext signal — must never survive to
        // light up the E2EE chip.
        'encryption_mode': 'pgp',
      });
      expect(decoded, isNot(contains('encryption_mode')));
    });

    test('a sealed incoming offer marks the pending session sealed', () {
      expect(
        service.handleIncomingCallPayload({
          'call_id': 'sealed-call',
          'caller_id': 'alice-id',
          'conversation_id': 'conv-1',
          'encryption_mode': 'pgp',
        }),
        isTrue,
      );
      expect(service.debugPendingIncoming?.sealed, isTrue);

      // Clear the pending ring so its timer doesn't outlive the test.
      service.debugHandleWsEvent(
        WsEvent(
          type: WsEventType.callCancel,
          data: {'call_id': 'sealed-call'},
        ),
      );
      expect(service.debugPendingIncoming, isNull);
    });

    test('a plaintext incoming offer stays unsealed', () {
      expect(
        service.handleIncomingCallPayload({
          'call_id': 'plain-call',
          'caller_id': 'bob-id',
          'conversation_id': 'conv-2',
        }),
        isTrue,
      );
      expect(service.debugPendingIncoming?.sealed, isFalse);

      service.debugHandleWsEvent(
        WsEvent(type: WsEventType.callCancel, data: {'call_id': 'plain-call'}),
      );
      expect(service.debugPendingIncoming, isNull);
    });
  });

  group('video upgrade signals', () {
    test('a flagged renegotiation offer never busy-rejects the call', () async {
      // Connected 1:1 call; the peer's upgrade offer reuses the call id.
      service.debugSession = _session(
        callId: 'call-1',
        state: CallState.connected,
      )..wasConnected = true;

      service.debugHandleWsEvent(
        WsEvent(
          type: WsEventType.callOffer,
          data: {
            'call_id': 'call-1',
            'caller_id': 'remote-user',
            'conversation_id': 'conv-1',
            'sdp': 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF\r\nm=video 9 '
                'UDP/TLS/RTP/SAVPF\r\n',
            'video_upgrade': true,
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // Without a live peer connection nothing can be applied in a unit
      // test, but the session must survive (no busy-reject/teardown).
      expect(service.currentSession?.callId, 'call-1');
      expect(service.currentSession?.state, CallState.connected);
    });
  });
}
