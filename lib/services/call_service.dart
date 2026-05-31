import 'dart:async';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import '../config/api_config.dart' show IceServer;
import '../services/websocket_service.dart';

enum CallState {
  idle,
  ringing, // incoming, awaiting accept / outgoing, peer is ringing
  calling, // outgoing, offer sent, not yet acknowledged
  connecting, // answered; negotiating media (ICE), not yet flowing
  connected, // media is flowing
  ended,
}

class CallSession {
  final String callId;
  final String remoteUserId;
  final String? remoteUsername;
  final String? remoteAvatarUrl;
  // DM conversation this call belongs to. Used to post the "missed" / "answered"
  // call event into the thread when the call ends. Null when started outside a
  // DM context.
  final String? conversationId;
  final bool isVideo;
  final bool isIncoming;
  CallState state;

  // Set once media actually connects, so the end-of-call event can distinguish
  // an answered call (→ "Call ended · 1:23") from a missed one.
  bool wasConnected = false;
  DateTime? connectedAt;

  CallSession({
    required this.callId,
    required this.remoteUserId,
    this.remoteUsername,
    this.remoteAvatarUrl,
    this.conversationId,
    required this.isVideo,
    required this.isIncoming,
    this.state = CallState.ringing,
  });
}

/// Emitted by [CallService] when an outgoing call ends, so the caller's client
/// can record a deletable event in the DM. Only the caller emits these (it is
/// the single writer) to avoid both peers posting duplicate events.
class CallEndedEvent {
  final String conversationId;
  final bool answered;
  final bool isVideo;
  final int durationSecs;

  const CallEndedEvent({
    required this.conversationId,
    required this.answered,
    required this.isVideo,
    required this.durationSecs,
  });
}

/// Manages a single WebRTC call. Handles offer/answer, ICE candidates,
/// and forwards signaling through the WebSocket service.
class CallService {
  final WebSocketService _ws;
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  CallSession? _session;

  final _sessionController = StreamController<CallSession?>.broadcast();
  final _remoteStreamController = StreamController<MediaStream?>.broadcast();
  final _localStreamController = StreamController<MediaStream?>.broadcast();
  final _incomingCallController = StreamController<CallSession>.broadcast();
  final _missedCallController = StreamController<CallSession>.broadcast();
  final _callEndedController = StreamController<CallEndedEvent>.broadcast();

  Stream<CallSession?> get sessionStream => _sessionController.stream;
  Stream<MediaStream?> get remoteStream => _remoteStreamController.stream;
  Stream<MediaStream?> get localStream => _localStreamController.stream;
  Stream<CallSession> get incomingCalls => _incomingCallController.stream;

  /// Fires when an incoming call ends before the user answered it (the caller
  /// hung up or the offer was withdrawn while still ringing).
  Stream<CallSession> get missedCalls => _missedCallController.stream;

  /// Fires (caller side only) when an outgoing call ends, so a "missed" /
  /// "answered" event can be written into the DM.
  Stream<CallEndedEvent> get callEnded => _callEndedController.stream;

  /// How long an unanswered call rings before it's given up as missed.
  static const ringTimeout = Duration(seconds: 30);

  /// How long to wait for media to actually connect after the call is answered
  /// before giving up (covers ICE failures with no reachable TURN server).
  static const connectTimeout = Duration(seconds: 30);
  Timer? _ringTimer;
  Timer? _connectTimer;

  // Incoming call that is ringing but not yet accepted. Used to distinguish a
  // "missed call" (ended while this is set) from a normal hang-up.
  CallSession? _pendingIncoming;

  CallSession? get currentSession => _session;
  MediaStream? get currentLocalStream => _localStream;
  MediaStream? get currentRemoteStream => _remoteStream;

  StreamSubscription<WsEvent>? _wsSub;

  List<IceServer> _iceServers = const [
    IceServer(url: 'stun:stun.l.google.com:19302'),
    IceServer(url: 'stun:stun1.l.google.com:19302'),
  ];

  CallService(this._ws) {
    _wsSub = _ws.events.listen(_handleWsEvent);
  }

  void updateIceServers(List<IceServer> servers) {
    if (servers.isNotEmpty) _iceServers = servers;
  }

  // ---- Outgoing call ----

  Future<void> startCall({
    required String targetUserId,
    String? targetUsername,
    String? conversationId,
    required bool isVideo,
  }) async {
    if (_session != null) return; // already in a call

    final callId = const Uuid().v4();
    _session = CallSession(
      callId: callId,
      remoteUserId: targetUserId,
      remoteUsername: targetUsername,
      conversationId: conversationId,
      isVideo: isVideo,
      isIncoming: false,
      state: CallState.calling,
    );
    _sessionController.add(_session);

    try {
      await _initPeerConnection(targetUserId, callId);
      await _captureLocalMedia(isVideo: isVideo);

      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);

      _ws.sendCallOffer(
        targetUserId: targetUserId,
        callId: callId,
        sdp: offer.sdp!,
        isVideo: isVideo,
        conversationId: conversationId,
      );

      // Give up (as a missed/no-answer call) if the callee never picks up.
      _startRingTimer();
    } catch (_) {
      _cleanup(emitEndedEvent: false);
      rethrow;
    }
  }

  void _startRingTimer() {
    _ringTimer?.cancel();
    _ringTimer = Timer(ringTimeout, () {
      final s = _session;
      if (s != null && s.state != CallState.connected) {
        // Tell the peer to stop ringing, then tear down. _cleanup emits the
        // missed-call event for the caller.
        hangup();
      }
    });
  }

  void _cancelRingTimer() {
    _ringTimer?.cancel();
    _ringTimer = null;
  }

  // ---- Incoming call actions ----

  Future<void> acceptIncomingCall(CallSession session) async {
    _cancelRingTimer();
    _pendingIncoming = null;
    _session = session..state = CallState.calling;
    _sessionController.add(_session);

    try {
      await _initPeerConnection(session.remoteUserId, session.callId);
      await _captureLocalMedia(isVideo: session.isVideo);

      _ws.sendCallRinging(
        targetUserId: session.remoteUserId,
        callId: session.callId,
      );
    } catch (_) {
      _cleanup(emitEndedEvent: false);
      rethrow;
    }
  }

  Future<void> answerCall({required String sdpOffer}) async {
    final session = _session;
    if (session == null || _pc == null) return;

    await _pc!.setRemoteDescription(RTCSessionDescription(sdpOffer, 'offer'));
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);

    _ws.sendCallAnswer(
      targetUserId: session.remoteUserId,
      callId: session.callId,
      sdp: answer.sdp!,
    );
    _enterConnecting();
  }

  /// Moves the session into the "connecting" (media-negotiation) phase and arms
  /// a timeout so a call that never establishes media (e.g. ICE fails with no
  /// reachable TURN server) tears down instead of hanging on the call screen.
  void _enterConnecting() {
    final s = _session;
    if (s == null || s.state == CallState.connected) return;
    _cancelRingTimer();
    s.state = CallState.connecting;
    _sessionController.add(s);
    _connectTimer?.cancel();
    _connectTimer = Timer(connectTimeout, () {
      final cur = _session;
      if (cur != null && cur.state != CallState.connected) {
        hangup(); // give up; _cleanup posts the call event for the caller
      }
    });
  }

  /// Marks the active session connected and records the connect time so the
  /// end-of-call event can report the talk duration.
  void _markConnected() {
    final s = _session;
    if (s == null) return;
    _cancelRingTimer();
    _connectTimer?.cancel();
    _connectTimer = null;
    if (!s.wasConnected) {
      s.wasConnected = true;
      s.connectedAt = DateTime.now();
    }
    s.state = CallState.connected;
    _sessionController.add(s);
  }

  void rejectCall(CallSession session) {
    _cancelRingTimer();
    _pendingIncoming = null;
    _ws.sendCallReject(
      targetUserId: session.remoteUserId,
      callId: session.callId,
    );
    _incomingCallController.add(session..state = CallState.ended);
  }

  void hangup() {
    final session = _session;
    if (session != null) {
      _ws.sendCallHangup(
        targetUserId: session.remoteUserId,
        callId: session.callId,
      );
    }
    _cleanup();
  }

  // ---- Media controls ----

  void setMicMuted(bool muted) {
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !muted);
  }

  void setCameraEnabled(bool enabled) {
    _localStream?.getVideoTracks().forEach((t) => t.enabled = enabled);
  }

  // ---- WebSocket events ----

  void _handleWsEvent(WsEvent event) {
    switch (event.type) {
      case WsEventType.callOffer:
        final callId = event.data['call_id'] as String? ?? '';
        final callerId = event.data['caller_id'] as String? ?? '';
        final callerName = event.data['caller_username'] as String?;
        final callerAvatar = event.data['caller_avatar'] as String?;
        final conversationId = event.data['conversation_id'] as String?;
        final sdp = event.data['sdp'] as String? ?? '';
        final isVideo = event.data['is_video'] as bool? ?? false;

        if (_session != null || _pendingIncoming != null) {
          // Already in / handling a call — auto-reject the new one.
          _ws.sendCallReject(targetUserId: callerId, callId: callId);
          return;
        }

        final incoming = CallSession(
          callId: callId,
          remoteUserId: callerId,
          remoteUsername: callerName,
          remoteAvatarUrl: callerAvatar,
          conversationId: conversationId,
          isVideo: isVideo,
          isIncoming: true,
          state: CallState.ringing,
        );
        // Store the offer SDP so we can answer later
        _pendingOfferSdp = sdp;
        _pendingIncoming = incoming;
        _incomingCallController.add(incoming);

        // Backstop: if the caller's hang-up never arrives, stop ringing on our
        // side too and surface it as a missed call.
        _ringTimer?.cancel();
        _ringTimer = Timer(ringTimeout, () {
          if (_session == null && _pendingIncoming == incoming) {
            _pendingIncoming = null;
            _pendingOfferSdp = null;
            _missedCallController.add(incoming);
          }
        });

      case WsEventType.callAnswer:
        final sdp = event.data['sdp'] as String? ?? '';
        _cancelRingTimer();
        _pc?.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        // Peer answered — we're negotiating media now. Actual "connected" is
        // driven by the ICE/peer-connection state, not the answer itself.
        _enterConnecting();

      case WsEventType.callIceCandidate:
        final candidateMap = event.data['candidate'] as Map<String, dynamic>?;
        if (candidateMap != null) {
          _pc?.addCandidate(RTCIceCandidate(
            candidateMap['candidate'] as String?,
            candidateMap['sdpMid'] as String?,
            candidateMap['sdpMLineIndex'] as int?,
          ));
        }

      case WsEventType.callHangup:
      case WsEventType.callReject:
        // If a call was still ringing (never answered) when the caller hung up,
        // that's a missed call — surface it instead of silently cleaning up.
        if (_session == null && _pendingIncoming != null) {
          final missed = _pendingIncoming!;
          _pendingIncoming = null;
          _pendingOfferSdp = null;
          _missedCallController.add(missed);
        } else {
          _cleanup();
        }

      case WsEventType.callRinging:
        // The callee's device is now ringing. Only reflect this while we're
        // still placing the call — never downgrade a connecting/connected call.
        final s = _session;
        if (s != null &&
            (s.state == CallState.calling || s.state == CallState.ringing)) {
          s.state = CallState.ringing;
          _sessionController.add(s);
        }

      default:
        break;
    }
  }

  String? _pendingOfferSdp;
  String? get pendingOfferSdp => _pendingOfferSdp;

  // ---- Internals ----

  Future<void> _initPeerConnection(String remoteUserId, String callId) async {
    final config = {
      'iceServers': _iceServers.map((s) => s.toRtcMap()).toList(),
    };

    _pc = await createPeerConnection(config);

    _pc!.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _ws.sendIceCandidate(
        targetUserId: remoteUserId,
        callId: callId,
        candidate: {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      );
    };

    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        _remoteStream!.getAudioTracks().forEach((track) {
          track.enabled = true;
        });
        _remoteStreamController.add(_remoteStream);
      }
    };

    _pc!.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          // Media is actually flowing now — this is the real "connected".
          _markConnected();
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _cleanup();
        default:
          break;
      }
    };
  }

  Future<void> _captureLocalMedia({required bool isVideo}) async {
    final isMobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    final constraints = <String, dynamic>{
      'audio': true,
      'video': isVideo
          ? (isMobile
              ? {'facingMode': 'user', 'width': 640, 'height': 480}
              : {'width': 1280, 'height': 720})
          : false,
    };
    _localStream = await navigator.mediaDevices.getUserMedia(constraints);
    // setSpeakerphoneOnButPreferBluetooth is mobile-only audio routing.
    // On Windows/desktop the underlying API does not exist, so skip it entirely
    // rather than relying on try/catch to absorb a potential native crash.
    if (isMobile) {
      try {
        await Helper.setSpeakerphoneOnButPreferBluetooth();
      } catch (_) {}
    }
    _localStreamController.add(_localStream);

    for (final track in _localStream!.getTracks()) {
      _pc!.addTrack(track, _localStream!);
    }
  }

  bool _isCleaningUp = false;

  /// Tears down the active call exactly once. Idempotent and exception-safe:
  /// the previous version could run twice (e.g. the ring/connect timeout's
  /// hangup() and onConnectionState=Failed firing together on a call that never
  /// connected), double-closing native WebRTC objects and crashing the app. The
  /// guard plus try/catch make re-entrant calls no-ops, and the peer-owned
  /// remote stream is dropped (not disposed) since closing the connection frees it.
  void _cleanup({bool emitEndedEvent = true}) {
    if (_isCleaningUp) return;
    _isCleaningUp = true;
    _cancelRingTimer();
    _connectTimer?.cancel();
    _connectTimer = null;

    // Caller side only: record a deletable event in the DM describing how the
    // call ended. The callee doesn't post (the caller is the single writer) so
    // both peers see exactly one event.
    final ending = _session;
    if (emitEndedEvent &&
        ending != null &&
        !ending.isIncoming &&
        ending.conversationId != null) {
      final dur = ending.wasConnected && ending.connectedAt != null
          ? DateTime.now().difference(ending.connectedAt!).inSeconds
          : 0;
      _callEndedController.add(CallEndedEvent(
        conversationId: ending.conversationId!,
        answered: ending.wasConnected,
        isVideo: ending.isVideo,
        durationSecs: dur,
      ));
    }

    try {
      _localStream?.getTracks().forEach((t) => t.stop());
      _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    // The remote stream is owned by the peer connection; closing the connection
    // releases it. Disposing it here would double-free and crash native code.
    _remoteStream = null;
    try {
      _pc?.close();
    } catch (_) {}
    _pc = null;
    _pendingOfferSdp = null;
    _session = null;

    _sessionController.add(null);
    _remoteStreamController.add(null);
    _localStreamController.add(null);
    _isCleaningUp = false;
  }

  void dispose() {
    _cleanup();
    _cancelRingTimer();
    _connectTimer?.cancel();
    _wsSub?.cancel();
    _sessionController.close();
    _remoteStreamController.close();
    _localStreamController.close();
    _incomingCallController.close();
    _missedCallController.close();
    _callEndedController.close();
  }
}
