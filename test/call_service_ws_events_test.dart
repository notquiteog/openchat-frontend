import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/call_service.dart';
import 'package:openchat/services/call_signal_codec.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';

/// WebSocketService whose event stream is test-driven; never connects.
/// Outbound call signals are recorded instead of queued.
class _FakeWebSocketService extends WebSocketService {
  _FakeWebSocketService() : super(SecureStorageService());

  final _controller = StreamController<WsEvent>.broadcast();
  final hangups = <Map<String, String>>[];
  final rejects = <Map<String, String>>[];

  @override
  Stream<WsEvent> get events => _controller.stream;

  @override
  void sendCallHangup({
    required String targetUserId,
    required String conversationId,
    required String callId,
  }) {
    hangups.add({'target': targetUserId, 'call_id': callId});
  }

  @override
  void sendCallReject({
    required String targetUserId,
    required String conversationId,
    required String callId,
    String? reason,
  }) {
    rejects.add({'target': targetUserId, 'call_id': callId});
  }

  @override
  void sendCallRinging({
    required String targetUserId,
    required String conversationId,
    required String callId,
  }) {}

  void close() => _controller.close();
}

CallSession _session({
  required String callId,
  CallState state = CallState.calling,
  bool isIncoming = false,
  List<String> participantUserIds = const [],
}) => CallSession(
  callId: callId,
  remoteUserId: 'remote-user',
  remoteUsername: 'alice',
  conversationId: 'conv-1',
  participantUserIds: participantUserIds,
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

  group('incoming participants and hangup targets', () {
    test('group offer participants are {caller} ∪ received − self', () {
      service.debugSelfUserId = 'me';
      expect(
        service.handleIncomingCallPayload({
          'call_id': 'c-group',
          'caller_id': 'caller-1',
          'conversation_id': 'conv-1',
          'participant_user_ids': ['me', 'invitee-2'],
        }),
        isTrue,
      );
      final pending = service.debugPendingIncoming!;
      expect(pending.participantUserIds.toSet(), {'caller-1', 'invitee-2'});
      expect(pending.isGroupCall, isTrue);

      // Clear the pending ring timer, then adopt the session as accepted.
      service.debugHandleWsEvent(
        WsEvent(type: WsEventType.callCancel, data: {'call_id': 'c-group'}),
      );
      service.debugSession = pending
        ..state = CallState.connected
        ..wasConnected = true;

      service.hangup();

      expect(
        ws.hangups.map((h) => h['target']).toSet(),
        {'caller-1', 'invitee-2'},
      );
      expect(ws.hangups.every((h) => h['call_id'] == 'c-group'), isTrue);
    });

    test('1:1 incoming hangup signals the caller, not the callee', () {
      service.debugSelfUserId = 'me';
      expect(
        service.handleIncomingCallPayload({
          'call_id': 'c-dm',
          'caller_id': 'caller-1',
          'conversation_id': 'conv-1',
          // The caller's recipient list — it contains US, never the caller.
          'participant_user_ids': ['me'],
        }),
        isTrue,
      );
      final pending = service.debugPendingIncoming!;
      expect(pending.isGroupCall, isFalse);
      expect(pending.participantUserIds, ['caller-1']);

      service.debugHandleWsEvent(
        WsEvent(type: WsEventType.callCancel, data: {'call_id': 'c-dm'}),
      );
      service.debugSession = pending
        ..state = CallState.connected
        ..wasConnected = true;

      service.hangup();

      expect(ws.hangups, hasLength(1));
      expect(ws.hangups.single['target'], 'caller-1');
    });

    test('a renegotiation offer arriving after hangup does not re-ring', () {
      service.debugSession = _session(
        callId: 'c-ended',
        state: CallState.connected,
      )..wasConnected = true;

      service.hangup();
      expect(service.currentSession, isNull);

      // The peer's ICE-restart offer (same call id) races our hangup — it
      // must not ring as a brand-new incoming call (false missed call).
      expect(
        service.handleIncomingCallPayload({
          'call_id': 'c-ended',
          'caller_id': 'remote-user',
          'conversation_id': 'conv-1',
          'sdp': 'v=0\r\n',
        }),
        isFalse,
      );
      expect(service.debugPendingIncoming, isNull);
    });
  });

  group('call_reject routing', () {
    test('ignores a stale reject carrying a different call id', () {
      service.debugSession = _session(
        callId: 'call-1',
        state: CallState.connected,
      )..wasConnected = true;

      service.debugHandleWsEvent(
        WsEvent(
          type: WsEventType.callReject,
          data: {'call_id': 'previous-call', 'caller_id': 'remote-user'},
        ),
      );

      expect(service.currentSession, isNotNull);
      expect(service.currentSession?.state, CallState.connected);
    });

    test('stale group reject does not remove a live peer', () async {
      service.debugSession = _session(
        callId: 'group-call',
        state: CallState.connected,
        participantUserIds: ['remote-user', 'peer-2'],
      )..wasConnected = true;

      final emissions = <CallSession?>[];
      final sub = service.sessionStream.listen(emissions.add);

      service.debugHandleWsEvent(
        WsEvent(
          type: WsEventType.callReject,
          data: {'call_id': 'old-call', 'caller_id': 'remote-user'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // Ignored entirely: no peer removal, not even a UI refresh emission.
      expect(emissions, isEmpty);
      expect(service.currentSession?.callId, 'group-call');
      expect(service.currentSession?.state, CallState.connected);
      await sub.cancel();
    });

    test('stale reject does not dismiss a pending incoming ring', () async {
      service.debugPendingIncoming = _session(
        callId: 'fresh-ring',
        isIncoming: true,
        state: CallState.ringing,
      );

      final missed = <CallSession>[];
      final sub = service.missedCalls.listen(missed.add);

      service.debugHandleWsEvent(
        WsEvent(
          type: WsEventType.callReject,
          data: {'call_id': 'old-call', 'caller_id': 'remote-user'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(service.debugPendingIncoming, isNotNull);
      expect(missed, isEmpty);
      await sub.cancel();
    });
  });

  group('stale group hangup', () {
    test('does not remove a live peer', () async {
      service.debugSession = _session(
        callId: 'group-call',
        state: CallState.connected,
        participantUserIds: ['remote-user', 'peer-2'],
      )..wasConnected = true;

      final emissions = <CallSession?>[];
      final sub = service.sessionStream.listen(emissions.add);

      service.debugHandleWsEvent(
        WsEvent(
          type: WsEventType.callHangup,
          data: {'call_id': 'old-call', 'caller_id': 'remote-user'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(emissions, isEmpty);
      expect(service.currentSession?.callId, 'group-call');
      expect(service.currentSession?.state, CallState.connected);
      await sub.cancel();
    });
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

    test(
      'a lost_race cancel after this device also accepted tears down silently',
      () async {
        // Two devices answered; the other one won first-answer-wins and the
        // server cancelled THIS connection specifically (reason=lost_race)
        // while we were still connecting.
        service.debugSession = _session(
          callId: 'c-won-elsewhere',
          isIncoming: true,
          state: CallState.connecting,
        );

        final cancelled = <CallSession>[];
        final sub = service.cancelledCalls.listen(cancelled.add);

        service.debugHandleWsEvent(
          WsEvent(
            type: WsEventType.callCancel,
            data: {'call_id': 'c-won-elsewhere', 'reason': 'lost_race'},
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(service.currentSession, isNull);
        expect(cancelled.map((c) => c.callId), ['c-won-elsewhere']);
        // Critically: no call_hangup signal — it would carry the ACTIVE call
        // id and tear down the caller's live call with the winning device.
        expect(ws.hangups, isEmpty);
        await sub.cancel();
      },
    );

    test(
      'a handled stop-ringing cancel never tears down a call WE answered',
      () async {
        // Regression: the winning device receives its OWN stop-ringing
        // broadcast (reason=handled, fanned out to all of the user's devices)
        // a few ms after sending its answer, while still connecting. It must
        // keep the call it just answered — not mistake the broadcast for a
        // lost-race teardown and kill itself (which left the caller stuck on
        // "connecting" forever).
        service.debugSession = _session(
          callId: 'c-we-won',
          isIncoming: true,
          state: CallState.connecting,
        );

        final cancelled = <CallSession>[];
        final sub = service.cancelledCalls.listen(cancelled.add);

        // The benign stop-ringing broadcast...
        service.debugHandleWsEvent(
          WsEvent(
            type: WsEventType.callCancel,
            data: {'call_id': 'c-we-won', 'reason': 'handled'},
          ),
        );
        // ...and a legacy bare cancel from an older server (no reason) must be
        // treated just as conservatively.
        service.debugHandleWsEvent(
          WsEvent(
            type: WsEventType.callCancel,
            data: {'call_id': 'c-we-won'},
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(service.currentSession?.callId, 'c-we-won');
        expect(service.currentSession?.state, CallState.connecting);
        expect(cancelled, isEmpty);
        expect(ws.hangups, isEmpty);
        await sub.cancel();
      },
    );

    test('cancel never tears down a CONNECTED incoming call', () {
      service.debugSession = _session(
        callId: 'c-live',
        isIncoming: true,
        state: CallState.connected,
      )..wasConnected = true;

      service.debugHandleWsEvent(
        WsEvent(type: WsEventType.callCancel, data: {'call_id': 'c-live'}),
      );

      expect(service.currentSession?.callId, 'c-live');
      expect(service.currentSession?.state, CallState.connected);
    });
  });

  group('call ended events', () {
    test(
      'remote hangup of an answered incoming call emits an ended event',
      () async {
        service.debugSession = _session(
          callId: 'call-1',
          isIncoming: true,
          state: CallState.connected,
        )
          ..wasConnected = true
          ..connectedAt = DateTime.now().subtract(const Duration(seconds: 42));

        final ended = <CallEndedEvent>[];
        final sub = service.callEnded.listen(ended.add);

        service.debugHandleWsEvent(
          WsEvent(
            type: WsEventType.callHangup,
            data: {'call_id': 'call-1', 'caller_id': 'remote-user'},
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(ended, hasLength(1));
        expect(ended.single.isIncoming, isTrue);
        expect(ended.single.answered, isTrue);
        expect(ended.single.conversationId, 'conv-1');
        expect(ended.single.durationSecs, inInclusiveRange(41, 44));
        expect(service.currentSession, isNull);
        await sub.cancel();
      },
    );

    test('an outgoing ending still reports isIncoming false', () async {
      service.debugSession = _session(
        callId: 'call-out',
        state: CallState.connected,
      )
        ..wasConnected = true
        ..connectedAt = DateTime.now();

      final ended = <CallEndedEvent>[];
      final sub = service.callEnded.listen(ended.add);

      service.hangup();
      await Future<void>.delayed(Duration.zero);

      expect(ended.single.isIncoming, isFalse);
      expect(ended.single.answered, isTrue);
      await sub.cancel();
    });
  });

  group('sealed offer replay guard', () {
    test('a stale sealed offer is rejected and never rings', () {
      final old = DateTime.now()
          .toUtc()
          .subtract(const Duration(minutes: 5))
          .toIso8601String();
      expect(
        service.handleIncomingCallPayload({
          'call_id': 'replayed-call',
          'caller_id': 'mallory',
          'conversation_id': 'conv-1',
          'encryption_mode': 'pgp',
          'created_at': old,
        }),
        isFalse,
      );
      expect(service.debugPendingIncoming, isNull);
    });

    test('a fresh sealed offer still rings', () {
      final now = DateTime.now().toUtc().toIso8601String();
      expect(
        service.handleIncomingCallPayload({
          'call_id': 'fresh-call',
          'caller_id': 'alice-id',
          'conversation_id': 'conv-1',
          'encryption_mode': 'pgp',
          'created_at': now,
        }),
        isTrue,
      );
      expect(service.debugPendingIncoming?.callId, 'fresh-call');

      service.debugHandleWsEvent(
        WsEvent(type: WsEventType.callCancel, data: {'call_id': 'fresh-call'}),
      );
      expect(service.debugPendingIncoming, isNull);
    });

    test('a sealed offer without a timestamp passes (older clients)', () {
      expect(
        service.handleIncomingCallPayload({
          'call_id': 'no-ts-call',
          'caller_id': 'bob-id',
          'conversation_id': 'conv-1',
          'encryption_mode': 'pgp',
        }),
        isTrue,
      );
      service.debugHandleWsEvent(
        WsEvent(type: WsEventType.callCancel, data: {'call_id': 'no-ts-call'}),
      );
      expect(service.debugPendingIncoming, isNull);
    });
  });

  group('ring timer independence', () {
    test('dialing out does not cancel a pending incoming missed-call timer',
        () {
      fakeAsync((async) {
        final missed = <CallSession>[];
        final sub = service.missedCalls.listen(missed.add);

        service.handleIncomingCallPayload({
          'call_id': 'c-ring',
          'caller_id': 'caller-1',
          'conversation_id': 'conv-1',
        });
        expect(service.debugPendingIncoming, isNotNull);

        // Starting an outgoing dial used to clobber the shared timer field,
        // so the pending ring never timed out into a missed call.
        service.debugStartOutgoingRingTimer();

        async.elapse(CallService.ringTimeout + const Duration(seconds: 1));
        async.flushMicrotasks();

        expect(missed.map((m) => m.callId), ['c-ring']);
        expect(service.debugPendingIncoming, isNull);
        sub.cancel();
        async.flushMicrotasks();
      });
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
