import 'dart:async';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
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

class CallAudioOutput {
  final String deviceId;
  final String label;

  const CallAudioOutput({required this.deviceId, required this.label});
}

/// Manages a single WebRTC call. Handles offer/answer, ICE candidates,
/// and forwards signaling through the WebSocket service.
class CallService {
  final WebSocketService _ws;
  final Future<List<IceServer>> Function()? _iceServerLoader;
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  CallSession? _session;
  bool _micMuted = false;
  bool _cameraEnabled = true;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

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

  CallService(this._ws, {Future<List<IceServer>> Function()? iceServerLoader})
      : _iceServerLoader = iceServerLoader {
    _wsSub = _ws.events.listen(_handleWsEvent);
  }

  void updateIceServers(List<IceServer> servers) {
    if (servers.isNotEmpty) _iceServers = servers;
  }

  Future<void> refreshIceServers() async {
    final loader = _iceServerLoader;
    if (loader == null) return;
    try {
      final servers = await loader();
      if (servers.isNotEmpty) updateIceServers(servers);
    } catch (_) {
      // Keep the existing/default STUN servers when config fetch fails.
    }
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
      await refreshIceServers();
      await _initPeerConnection(targetUserId, callId);
      await _captureLocalMedia(isVideo: isVideo);
      _sessionController.add(_session);

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
      await refreshIceServers();
      await _initPeerConnection(session.remoteUserId, session.callId);
      await _captureLocalMedia(isVideo: session.isVideo);
      _sessionController.add(_session);

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
    await _flushPendingRemoteCandidates();
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
    _pendingOfferSdp = null;
    _ws.sendCallReject(
      targetUserId: session.remoteUserId,
      callId: session.callId,
    );
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
    _micMuted = muted;
    final tracks = _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[];
    for (final track in tracks) {
      track.enabled = !muted;
      unawaited(Helper.setMicrophoneMute(muted, track).catchError((_) {}));
    }
  }

  void setCameraEnabled(bool enabled) {
    _cameraEnabled = enabled;
    _localStream?.getVideoTracks().forEach((t) => t.enabled = enabled);
  }

  Future<List<CallAudioOutput>> getAudioOutputs() async {
    if (!kIsWeb &&
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS &&
        defaultTargetPlatform != TargetPlatform.windows) {
      return const [];
    }
    try {
      final outputs = await Helper.audiooutputs;
      if (outputs.isNotEmpty) {
        final detected = outputs.where((d) => d.deviceId.isNotEmpty).map((d) {
          final label = _labelForAudioOutput(d.label);
          final deviceId = !kIsWeb &&
                  (defaultTargetPlatform == TargetPlatform.android ||
                      defaultTargetPlatform == TargetPlatform.iOS)
              ? _mobileAudioOutputId(label, d.deviceId)
              : d.deviceId;
          return CallAudioOutput(deviceId: deviceId, label: label);
        }).toList(growable: false);
        if (!kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS)) {
          return _mergeMobileAudioOutputs(detected);
        }
        return detected;
      }
    } catch (_) {}

    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      return const [
        CallAudioOutput(deviceId: 'speaker', label: 'Speaker'),
        CallAudioOutput(deviceId: 'earpiece', label: 'Earpiece'),
      ];
    }
    return const [];
  }

  Future<void> selectAudioOutput(String deviceId) async {
    try {
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        if (deviceId == 'speaker') {
          await Helper.setSpeakerphoneOn(true);
          return;
        }
        if (deviceId == 'earpiece') {
          await Helper.setSpeakerphoneOn(false);
          return;
        }
        if (deviceId == 'bluetooth') {
          await Helper.setSpeakerphoneOnButPreferBluetooth();
          return;
        }
      }
      await Helper.selectAudioOutput(deviceId);
    } catch (_) {
      // Some platforms do not expose output routing in flutter_webrtc.
    }
  }

  String _labelForAudioOutput(String raw) {
    final label = raw.trim();
    if (label.isEmpty) return 'Audio output';
    final lower = label.toLowerCase();
    if (lower.contains('bluetooth') || lower.contains('airpods')) {
      return 'Bluetooth';
    }
    if (lower.contains('speaker')) {
      return 'Speaker';
    }
    if (lower.contains('earpiece') || lower.contains('receiver')) {
      return 'Earpiece';
    }
    if (lower.contains('headset') ||
        lower.contains('headphone') ||
        lower.contains('wired') ||
        lower.contains('usb')) {
      return 'Headset';
    }
    return label;
  }

  String _mobileAudioOutputId(String label, String fallback) {
    switch (label) {
      case 'Speaker':
        return 'speaker';
      case 'Earpiece':
        return 'earpiece';
      case 'Bluetooth':
        return 'bluetooth';
      case 'Headset':
        return 'wired-headset';
      default:
        return fallback;
    }
  }

  List<CallAudioOutput> _mergeMobileAudioOutputs(
    List<CallAudioOutput> detected,
  ) {
    final byId = <String, CallAudioOutput>{
      'speaker': const CallAudioOutput(deviceId: 'speaker', label: 'Speaker'),
      'earpiece':
          const CallAudioOutput(deviceId: 'earpiece', label: 'Earpiece'),
    };
    for (final output in detected) {
      byId[output.deviceId] = output;
    }
    return byId.values.toList(growable: false);
  }

  // ---- WebSocket events ----

  void _handleWsEvent(WsEvent event) {
    switch (event.type) {
      case WsEventType.callOffer:
        handleIncomingCallPayload(event.data);

      case WsEventType.callAnswer:
        final sdp = event.data['sdp'] as String? ?? '';
        _cancelRingTimer();
        // Peer answered — enter connecting phase immediately so the 30-second
        // timeout starts ticking. setRemoteDescription is async; errors are
        // caught and trigger a clean hangup rather than leaving the call stuck.
        _enterConnecting();
        if (_pc != null && sdp.isNotEmpty) {
          _pc!
              .setRemoteDescription(RTCSessionDescription(sdp, 'answer'))
              .then((_) => _flushPendingRemoteCandidates())
              .catchError((_) => hangup());
        }

      case WsEventType.callIceCandidate:
        final callId = event.data['call_id'] as String? ?? '';
        final candidateMap = event.data['candidate'] as Map<String, dynamic>?;
        if (candidateMap != null) {
          final candidate = RTCIceCandidate(
            candidateMap['candidate'] as String?,
            candidateMap['sdpMid'] as String?,
            candidateMap['sdpMLineIndex'] as int?,
          );
          _addOrQueueRemoteCandidate(callId, candidate);
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

  bool handleIncomingCallPayload(Map<String, dynamic> data) {
    final callId = data['call_id'] as String? ?? '';
    final callerId = data['caller_id'] as String? ?? '';
    final callerName = data['caller_username'] as String?;
    final callerAvatar = data['caller_avatar'] as String?;
    final conversationId = data['conversation_id'] as String?;
    final sdp = data['sdp'] as String? ?? '';
    final isVideo = switch (data['is_video']) {
      true => true,
      'true' => true,
      _ => false,
    };

    if (callId.isEmpty || callerId.isEmpty || sdp.isEmpty) return false;
    if (_session != null || _pendingIncoming != null) {
      _ws.sendCallReject(targetUserId: callerId, callId: callId);
      return false;
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
    _pendingRemoteCandidates.clear();
    _pendingOfferSdp = sdp;
    _pendingIncoming = incoming;
    _incomingCallController.add(incoming);

    _ringTimer?.cancel();
    _ringTimer = Timer(ringTimeout, () {
      if (_session == null && _pendingIncoming == incoming) {
        _pendingIncoming = null;
        _pendingOfferSdp = null;
        _missedCallController.add(incoming);
      }
    });
    return true;
  }

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
        // Some desktop flutter_webrtc builds do not reliably promote
        // peerConnectionState to Connected even after media arrives. A remote
        // track means the call negotiated enough to leave "Connecting…".
        _markConnected();
      }
    };

    _pc!.onIceConnectionState = (state) {
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _markConnected();
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
        case RTCIceConnectionState.RTCIceConnectionStateClosed:
          _cleanup();
        default:
          break;
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

  Future<void> _addOrQueueRemoteCandidate(
    String callId,
    RTCIceCandidate candidate,
  ) async {
    final activeCallId = _session?.callId ?? _pendingIncoming?.callId;
    if (callId.isNotEmpty && activeCallId != null && callId != activeCallId) {
      return;
    }

    final pc = _pc;
    if (pc == null) {
      _pendingRemoteCandidates.add(candidate);
      return;
    }

    try {
      final remote = await pc.getRemoteDescription();
      if (remote == null) {
        _pendingRemoteCandidates.add(candidate);
        return;
      }
      await pc.addCandidate(candidate);
    } catch (_) {
      _pendingRemoteCandidates.add(candidate);
    }
  }

  Future<void> _flushPendingRemoteCandidates() async {
    final pc = _pc;
    if (pc == null || _pendingRemoteCandidates.isEmpty) return;
    final pending = List<RTCIceCandidate>.from(_pendingRemoteCandidates);
    _pendingRemoteCandidates.clear();
    for (final candidate in pending) {
      try {
        await pc.addCandidate(candidate);
      } catch (_) {
        // A stale/duplicate candidate should not strand the call setup.
      }
    }
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
    setMicMuted(_micMuted);
    setCameraEnabled(_cameraEnabled);
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
      _callEndedController.add(
        CallEndedEvent(
          conversationId: ending.conversationId!,
          answered: ending.wasConnected,
          isVideo: ending.isVideo,
          durationSecs: dur,
        ),
      );
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
    _pendingRemoteCandidates.clear();
    _session = null;
    _micMuted = false;
    _cameraEnabled = true;

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
