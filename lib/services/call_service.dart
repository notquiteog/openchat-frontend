import 'dart:async';
import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import '../config/api_config.dart';
import '../services/api_service.dart';
import '../services/call_platform_controls.dart';
import '../services/call_signal_codec.dart';
import '../services/websocket_service.dart';

enum CallState {
  idle,
  ringing,
  calling,
  connecting,
  connected,
  ended,
}

class CallSession {
  final String callId;
  final String remoteUserId;
  final String? remoteUsername;
  final String? remoteAvatarUrl;
  final String? conversationId;
  final List<String> participantUserIds;
  final bool isVideo;
  final bool isIncoming;
  CallState state;

  bool wasConnected = false;
  DateTime? connectedAt;

  CallSession({
    required this.callId,
    required this.remoteUserId,
    this.remoteUsername,
    this.remoteAvatarUrl,
    this.conversationId,
    List<String> participantUserIds = const [],
    required this.isVideo,
    required this.isIncoming,
    this.state = CallState.ringing,
  }) : participantUserIds = List.unmodifiable(participantUserIds);

  bool get isGroupCall => participantUserIds.length > 1;
}

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

class _PeerState {
  final String userId;
  final RTCPeerConnection pc;
  final RTCVideoRenderer renderer;
  MediaStream? remoteStream;
  bool remoteDescriptionSet = false;
  final List<RTCIceCandidate> pendingCandidates = [];

  _PeerState({required this.userId, required this.pc, required this.renderer});
}

/// Returns getUserMedia constraints for testing.
Map<String, dynamic> buildCallMediaConstraintsForTesting({
  required bool isVideo,
  bool usingFrontCamera = true,
}) {
  return {
    'audio': {
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
    },
    'video': isVideo
        ? {
            'facingMode': usingFrontCamera ? 'user' : 'environment',
            'width': {'ideal': 1280},
            'height': {'ideal': 720},
            'frameRate': {'ideal': 30},
          }
        : false,
  };
}

String? _stringField(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Extracts an SDP string without trimming. libwebrtc's parser rejects a
/// message that doesn't end in a line terminator, so the trailing CRLF must be
/// preserved (unlike display fields, which `_stringField` trims).
String? _sdpField(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is! String || value.trim().isEmpty) return null;
  return value;
}

/// Guarantees the SDP ends with a line terminator. `setRemoteDescription`
/// fails with "Invalid type or sdp" if the final line isn't newline-terminated,
/// which happens when an upstream trim() or server normalization strips it.
String _ensureSdpTerminator(String sdp) => sdp.endsWith('\n') ? sdp : '$sdp\r\n';

String _candType(String candidate) {
  final i = candidate.indexOf('typ ');
  if (i < 0) return '?';
  final rest = candidate.substring(i + 4);
  final end = rest.indexOf(' ');
  return end < 0 ? rest : rest.substring(0, end);
}

/// P2P WebRTC call service. Handles signaling via the existing WebSocket and
/// peer-to-peer media negotiation with coturn for NAT traversal.
class CallService {
  final WebSocketService _ws;
  final CallSignalCodec _signalCodec;
  final ApiService _api;
  final CallPlatformControls _platformControls;

  // P2P state — one entry per remote participant.
  final Map<String, _PeerState> _peers = {};
  MediaStream? _localStream;
  MediaStream? _screenStream;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  bool _localRendererInitialized = false;
  List<IceServer> _iceServers = const [];

  // Pending incoming call awaiting user accept/reject.
  CallSession? _pendingIncoming;
  String? _pendingRemoteSdp; // SDP offer from incoming call_offer
  // ICE candidates that trickle in during ringing, before the callee answers
  // and builds its peer connection. Flushed into the peer on accept; without
  // this buffer they are dropped and ICE has no remote candidates to check.
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  // Active call state.
  CallSession? _session;
  bool _usingFrontCamera = true;
  bool _isScreenSharing = false;
  String? _selectedAudioOutputId;

  final _sessionController = StreamController<CallSession?>.broadcast();
  final _incomingCallController = StreamController<CallSession>.broadcast();
  final _missedCallController = StreamController<CallSession>.broadcast();
  final _callEndedController = StreamController<CallEndedEvent>.broadcast();

  Stream<CallSession?> get sessionStream => _sessionController.stream;
  Stream<CallSession> get incomingCalls => _incomingCallController.stream;
  Stream<CallSession> get missedCalls => _missedCallController.stream;
  Stream<CallEndedEvent> get callEnded => _callEndedController.stream;

  static const ringTimeout = Duration(seconds: 30);
  static const connectTimeout = Duration(seconds: 30);
  Timer? _ringTimer;
  Timer? _connectTimer;

  StreamSubscription<WsEvent>? _wsSub;

  CallSession? get currentSession => _session;
  bool get hasLocalMedia => _localStream != null;
  bool get usingFrontCamera => _usingFrontCamera;
  bool get isScreenSharing => _isScreenSharing;
  bool get canScreenShare => _supportsScreenShare;

  /// Local video renderer — valid while a call with video is active.
  RTCVideoRenderer? get localRenderer =>
      _localRendererInitialized ? _localRenderer : null;

  /// Remote video renderers keyed by the remote participant's user ID.
  Map<String, RTCVideoRenderer> get remoteRenderers => {
    for (final e in _peers.entries) e.key: e.value.renderer,
  };

  CallService(
    this._ws,
    this._api, {
    CallSignalCodec? signalCodec,
    CallPlatformControls? platformControls,
  }) : _signalCodec = signalCodec ?? const PlainCallSignalCodec(),
       _platformControls = platformControls ?? const CallPlatformControls() {
    _wsSub = _ws.events.listen(_handleWsEvent);
  }

  // ── Outgoing call ───────────────────────────────────────────────────────────

  Future<void> startCall({
    required String targetUserId,
    String? targetUsername,
    required String conversationId,
    required bool isVideo,
    List<String> additionalUserIds = const [],
  }) async {
    if (_session != null) return;

    final callId = const Uuid().v4();
    final recipientIds = <String>[
      targetUserId,
      ...additionalUserIds,
    ].where((id) => id.trim().isNotEmpty).toSet().toList(growable: false);
    if (recipientIds.isEmpty) throw ArgumentError('targetUserId is required');

    _session = CallSession(
      callId: callId,
      remoteUserId: targetUserId,
      remoteUsername: targetUsername,
      conversationId: conversationId,
      participantUserIds: recipientIds,
      isVideo: isVideo,
      isIncoming: false,
      state: CallState.calling,
    );
    _sessionController.add(_session);

    try {
      await _initLocalRenderer();
      _iceServers = await _api.getIceServers();
      debugPrint('CallService: ICE servers loaded: ${_iceServers.length} -> ${_iceServers.map((s) => s.url).toList()}');
      _localStream = await _getUserMedia(isVideo: isVideo);
      _localRenderer.srcObject = _localStream;
      _sessionController.add(_session);

      for (final userId in recipientIds) {
        await _createOutgoingPeer(
          userId: userId,
          callId: callId,
          conversationId: conversationId,
          isVideo: isVideo,
        );
      }

      _startRingTimer();
    } catch (e, st) {
      debugPrint('CallService.startCall failed: $e\n$st');
      _cleanup(emitEndedEvent: false);
      rethrow;
    }
  }

  Future<void> _createOutgoingPeer({
    required String userId,
    required String callId,
    required String conversationId,
    required bool isVideo,
  }) async {
    final renderer = RTCVideoRenderer();
    await renderer.initialize();

    final pc = await _createPeerConnection();
    final peerState = _PeerState(
      userId: userId,
      pc: pc,
      renderer: renderer,
    );
    _peers[userId] = peerState;

    _setupPcCallbacks(pc, peerState, userId, callId, conversationId);

    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await pc.addTrack(track, stream);
      }
    }

    final offer = await pc.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': isVideo ? 1 : 0,
    });
    await pc.setLocalDescription(offer);

    final offerData = await _signalCodec.encode(
      CallSignalPayload(
        kind: 'offer',
        targetUserId: userId,
        callId: callId,
        conversationId: conversationId,
        isVideo: isVideo,
        sdp: offer.sdp,
        participantUserIds: _session!.participantUserIds,
      ),
    );
    _ws.sendCallOfferPayload(offerData);
  }

  // ── Incoming call actions ───────────────────────────────────────────────────

  Future<void> acceptIncomingCall(CallSession session) async {
    debugPrint('CallService: acceptIncomingCall start (callId=${session.callId})');
    _cancelRingTimer();
    _pendingIncoming = null;
    _session = session..state = CallState.connecting;
    _sessionController.add(_session);

    final remoteSdp = _pendingRemoteSdp;
    if (remoteSdp == null || remoteSdp.isEmpty) {
      _cleanup(emitEndedEvent: false);
      throw Exception(
        'Your PGP key was locked when this call arrived. Unlock it in Settings, then ask the caller to try again.',
      );
    }
    final conversationId = session.conversationId;
    if (conversationId == null || conversationId.isEmpty) {
      _cleanup(emitEndedEvent: false);
      throw Exception('Call offer is missing its conversation.');
    }

    try {
      await _initLocalRenderer();
      _iceServers = await _api.getIceServers();
      debugPrint('CallService: ICE servers loaded: ${_iceServers.length} -> ${_iceServers.map((s) => s.url).toList()}');
      _localStream = await _getUserMedia(isVideo: session.isVideo);
      _localRenderer.srcObject = _localStream;

      final renderer = RTCVideoRenderer();
      await renderer.initialize();

      final pc = await _createPeerConnection();
      final peerState = _PeerState(
        userId: session.remoteUserId,
        pc: pc,
        renderer: renderer,
      );
      _peers[session.remoteUserId] = peerState;

      // Apply ICE candidates that trickled in during ringing. They're queued
      // until setRemoteDescription succeeds, then flushed with the rest below.
      if (_pendingRemoteCandidates.isNotEmpty) {
        debugPrint('CallService: flushing ${_pendingRemoteCandidates.length} buffered remote ICE candidate(s)');
        peerState.pendingCandidates.addAll(_pendingRemoteCandidates);
        _pendingRemoteCandidates.clear();
      }

      _setupPcCallbacks(pc, peerState, session.remoteUserId, session.callId, conversationId);

      final stream = _localStream;
      if (stream != null) {
        for (final track in stream.getTracks()) {
          await pc.addTrack(track, stream);
        }
      }

      await pc.setRemoteDescription(
        RTCSessionDescription(_ensureSdpTerminator(remoteSdp), 'offer'),
      );
      peerState.remoteDescriptionSet = true;

      for (final candidate in peerState.pendingCandidates) {
        try {
          await pc.addCandidate(candidate);
        } catch (_) {}
      }
      peerState.pendingCandidates.clear();

      final answer = await pc.createAnswer({});
      await pc.setLocalDescription(answer);
      _pendingRemoteSdp = null;

      final answerData = await _signalCodec.encode(
        CallSignalPayload(
          kind: 'answer',
          targetUserId: session.remoteUserId,
          callId: session.callId,
          conversationId: conversationId,
          isVideo: session.isVideo,
          sdp: answer.sdp,
        ),
      );
      _ws.sendCallAnswer(answerData);
      debugPrint('CallService: answer sent for ${session.callId}, awaiting connection');

      _ws.sendCallRinging(
        targetUserId: session.remoteUserId,
        conversationId: conversationId,
        callId: session.callId,
      );
    } catch (e, st) {
      debugPrint('CallService.acceptIncomingCall failed: $e\n$st');
      _cleanup(emitEndedEvent: false);
      rethrow;
    }
  }

  void rejectCall(CallSession session) {
    _cancelRingTimer();
    _pendingIncoming = null;
    _pendingRemoteSdp = null;
    _pendingRemoteCandidates.clear();
    _ws.sendCallReject(
      targetUserId: session.remoteUserId,
      conversationId: session.conversationId ?? '',
      callId: session.callId,
    );
  }

  List<String> _hangupTargetIds(CallSession session) {
    final ids = session.participantUserIds.isEmpty
        ? <String>[session.remoteUserId]
        : session.participantUserIds;
    return ids
        .where((id) => id.trim().isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  void hangup() {
    final session = _session;
    if (session != null) {
      final shouldSignalHangup =
          !session.isGroupCall || session.state != CallState.connected;
      if (shouldSignalHangup) {
        for (final userId in _hangupTargetIds(session)) {
          _ws.sendCallHangup(
            targetUserId: userId,
            conversationId: session.conversationId ?? '',
            callId: session.callId,
          );
        }
      }
    }
    _cleanup();
  }

  // ── WebSocket events ────────────────────────────────────────────────────────

  void _handleWsEvent(WsEvent event) {
    switch (event.type) {
      case WsEventType.callOffer:
        unawaited(_handleCallOffer(event.data));

      case WsEventType.callAnswer:
        unawaited(_handleCallAnswer(event.data));

      case WsEventType.callIceCandidate:
        unawaited(_handleIceCandidate(event.data));

      case WsEventType.callHangup:
        if (_session == null && _pendingIncoming != null) {
          final missed = _pendingIncoming!;
          _pendingIncoming = null;
          _pendingRemoteSdp = null;
          _pendingRemoteCandidates.clear();
          _missedCallController.add(missed);
        } else if (_session?.isGroupCall == true &&
            _session?.state == CallState.connected) {
          _sessionController.add(_session);
        } else {
          debugPrint('CallService: remote hangup signal -> cleanup');
          _cleanup();
        }

      case WsEventType.callReject:
        final s = _session;
        if (s == null && _pendingIncoming != null) {
          final missed = _pendingIncoming!;
          _pendingIncoming = null;
          _pendingRemoteSdp = null;
          _pendingRemoteCandidates.clear();
          _missedCallController.add(missed);
        } else if (s != null && !s.isGroupCall) {
          debugPrint('CallService: remote reject signal -> cleanup');
          _cleanup();
        }

      case WsEventType.callRinging:
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

  Future<void> _handleCallOffer(Map<String, dynamic> data) async {
    final decoded = await _decodeCallSignal(data);
    if (decoded != null) _handleIncomingCallPayload(decoded);
  }

  Future<void> _handleCallAnswer(Map<String, dynamic> data) async {
    final s = _session;
    if (s == null) return;

    if (s.state == CallState.calling || s.state == CallState.ringing) {
      s.state = CallState.connecting;
      _sessionController.add(s);
    }

    final decoded = await _decodeCallSignal(data);
    if (decoded == null) return;

    final callId = decoded['call_id']?.toString() ?? '';
    if (callId.isNotEmpty && callId != s.callId) return;

    final sdp = decoded['sdp']?.toString() ?? '';
    if (sdp.isEmpty) return;

    // Route answer to the right peer (backend injects caller_id into relay).
    final callerId = decoded['caller_id']?.toString() ?? '';
    final peer = _peers[callerId] ?? _peers[s.remoteUserId] ?? _peers.values.firstOrNull;
    if (peer == null) return;

    unawaited(_applyRemoteAnswer(peer, sdp));
  }

  Future<void> _applyRemoteAnswer(_PeerState peer, String sdp) async {
    try {
      await peer.pc.setRemoteDescription(
        RTCSessionDescription(_ensureSdpTerminator(sdp), 'answer'),
      );
      peer.remoteDescriptionSet = true;
      for (final candidate in peer.pendingCandidates) {
        try {
          await peer.pc.addCandidate(candidate);
        } catch (_) {}
      }
      peer.pendingCandidates.clear();
    } catch (e) {
      debugPrint('CallService: setRemoteDescription(answer) failed: $e');
    }
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> data) async {
    final callId = data['call_id']?.toString() ?? '';
    final activeCallId = _session?.callId ?? _pendingIncoming?.callId;
    if (callId.isNotEmpty && callId != activeCallId) return;

    final candidateStr = data['candidate']?.toString() ?? '';
    if (candidateStr.isEmpty) return;

    final sdpMid = data['sdp_mid']?.toString() ?? '0';
    final sdpMLineIndex = (data['sdp_mline_index'] as num?)?.toInt() ?? 0;
    final candidate = RTCIceCandidate(candidateStr, sdpMid, sdpMLineIndex);

    // Backend injects caller_id into the relay — use it to route to the right PC.
    final callerId = data['caller_id']?.toString() ?? '';
    final peer = _peers[callerId] ?? _peers.values.firstOrNull;
    if (peer == null) {
      // Candidate arrived before the peer connection exists — the caller
      // trickles ICE during ringing, before the callee answers. Buffer it so
      // acceptIncomingCall can apply it; dropping it leaves ICE with no remote
      // candidates and the call never connects.
      if (_pendingIncoming != null) {
        _pendingRemoteCandidates.add(candidate);
        debugPrint('CallService: buffered early remote ICE candidate (${_candType(candidateStr)})');
      } else {
        debugPrint('CallService: remote ICE candidate dropped — no peer (callerId=$callerId)');
      }
      return;
    }

    if (peer.remoteDescriptionSet) {
      debugPrint('CallService: remote ICE candidate (${_candType(candidateStr)}) applied');
      try {
        await peer.pc.addCandidate(candidate);
      } catch (_) {}
    } else {
      debugPrint('CallService: remote ICE candidate (${_candType(candidateStr)}) queued (no remote desc yet)');
      peer.pendingCandidates.add(candidate);
    }
  }

  Future<Map<String, dynamic>?> _decodeCallSignal(
    Map<String, dynamic> data,
  ) async {
    try {
      return await _signalCodec.decode(data);
    } catch (_) {
      return null;
    }
  }

  bool _handleIncomingCallPayload(Map<String, dynamic> data) {
    final callId = data['call_id'] as String? ?? '';
    final callerId = data['caller_id'] as String? ?? '';
    final callerName = _stringField(data, 'caller_username');
    final callerAvatar = _stringField(data, 'caller_avatar');
    final conversationId = data['conversation_id'] as String?;
    final sdp = _sdpField(data, 'sdp');
    final participantUserIds = _participantUserIds(data, callerId);
    final isVideo = switch (data['is_video']) {
      true => true,
      'true' => true,
      _ => false,
    };

    if (callId.isEmpty) return false;
    if (_session != null || _pendingIncoming != null) {
      if (callerId.isNotEmpty) {
        _ws.sendCallReject(
          targetUserId: callerId,
          conversationId: conversationId ?? '',
          callId: callId,
        );
      }
      return false;
    }

    final incoming = CallSession(
      callId: callId,
      remoteUserId: callerId,
      remoteUsername: callerName,
      remoteAvatarUrl: callerAvatar,
      conversationId: conversationId,
      participantUserIds: participantUserIds,
      isVideo: isVideo,
      isIncoming: true,
      state: CallState.ringing,
    );
    _pendingRemoteSdp = sdp;
    _pendingRemoteCandidates.clear();
    _pendingIncoming = incoming;
    _incomingCallController.add(incoming);

    _ringTimer?.cancel();
    _ringTimer = Timer(ringTimeout, () {
      if (_session == null && _pendingIncoming == incoming) {
        _pendingIncoming = null;
        _pendingRemoteSdp = null;
        _pendingRemoteCandidates.clear();
        _missedCallController.add(incoming);
      }
    });
    return true;
  }

  bool handleIncomingCallPayload(Map<String, dynamic> data) =>
      _handleIncomingCallPayload(data);

  Future<bool> handleIncomingCallPushPayload(Map<String, dynamic> data) async {
    final decoded = await _decodeCallSignal(data);
    if (decoded == null) return false;
    return _handleIncomingCallPayload(decoded);
  }

  List<String> _participantUserIds(
    Map<String, dynamic> data,
    String callerId,
  ) {
    final raw = data['participant_user_ids'];
    final ids = <String>{};
    if (raw is List) {
      for (final value in raw) {
        if (value is! String) continue;
        final trimmed = value.trim();
        if (trimmed.isNotEmpty) ids.add(trimmed);
      }
    }
    if (ids.isEmpty && callerId.trim().isNotEmpty) {
      ids.add(callerId.trim());
    }
    return ids.toList(growable: false);
  }

  // ── Peer connection factory ─────────────────────────────────────────────────

  Future<RTCPeerConnection> _createPeerConnection() async {
    final config = <String, dynamic>{
      'iceServers': [
        if (_iceServers.isNotEmpty)
          for (final server in _iceServers) server.toRtcMap()
        else
          {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'iceTransportPolicy': 'all',
      'sdpSemantics': 'unified-plan',
    };
    return createPeerConnection(config);
  }

  void _setupPcCallbacks(
    RTCPeerConnection pc,
    _PeerState peer,
    String userId,
    String callId,
    String conversationId,
  ) {
    pc.onIceCandidate = (RTCIceCandidate candidate) {
      final c = candidate.candidate;
      if (c != null && c.isNotEmpty) {
        debugPrint('CallService: local ICE candidate (${_candType(c)}) -> $userId');
        _ws.sendCallIceCandidate(
          targetUserId: userId,
          conversationId: conversationId,
          callId: callId,
          candidate: c,
          sdpMid: candidate.sdpMid ?? '0',
          sdpMLineIndex: candidate.sdpMLineIndex ?? 0,
        );
      }
    };

    pc.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        peer.remoteStream = event.streams.first;
        peer.renderer.srcObject = event.streams.first;
        _sessionController.add(_session);
      }
    };

    pc.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('CallService: peer[$userId] connectionState -> $state');
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _markConnected();
          _sessionController.add(_session);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          if (_session != null && !_session!.wasConnected) _cleanup();
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          if (_session != null) _cleanup();
        default:
          break;
      }
    };

    pc.onIceGatheringState = (RTCIceGatheringState state) {
      debugPrint('CallService: peer[$userId] iceGatheringState -> $state');
    };

    // Fallback: ICE connection state also indicates connectivity.
    pc.onIceConnectionState = (RTCIceConnectionState state) {
      debugPrint('CallService: peer[$userId] iceConnectionState -> $state');
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _markConnected();
          _sessionController.add(_session);
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          if (_session != null && !_session!.wasConnected) _cleanup();
        default:
          break;
      }
    };
  }

  // ── Media controls ──────────────────────────────────────────────────────────

  void setMicMuted(bool muted) {
    final audioTrack = _localStream?.getAudioTracks().firstOrNull;
    if (audioTrack != null) audioTrack.enabled = !muted;
    unawaited(_platformControls.setMicrophoneMuted(muted));
  }

  void setCameraEnabled(bool enabled) {
    if (!_isScreenSharing) {
      final videoTrack = _localStream?.getVideoTracks().firstOrNull;
      if (videoTrack != null) videoTrack.enabled = enabled;
    }
  }

  Future<bool> switchCamera() async {
    if (_isScreenSharing) return _usingFrontCamera;
    final videoTrack = _localStream?.getVideoTracks().firstOrNull;
    if (videoTrack == null) return _usingFrontCamera;
    try {
      await Helper.switchCamera(videoTrack);
      _usingFrontCamera = !_usingFrontCamera;
    } catch (_) {}
    return _usingFrontCamera;
  }

  Future<void> startScreenShare() async {
    if (_isScreenSharing || !_supportsScreenShare) return;

    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    if (isAndroid) {
      // Android 14+ hard-crashes (SecurityException) if MediaProjection.start()
      // runs without a foreground service of type mediaProjection already
      // active. flutter_webrtc 1.4.1 doesn't manage that service, so we do it:
      //   1. obtain the screen-capture consent token up front
      //      (getDisplayMedia reuses it, so this avoids a second prompt),
      //   2. start the mediaProjection foreground service,
      //   3. give it a moment to reach the foreground, then
      //   4. getDisplayMedia() finds the running service and the saved token.
      final granted = await Helper.requestCapturePermission();
      if (!granted) {
        throw Exception('Screen capture permission was denied');
      }
      final started = await _platformControls.startMediaProjection();
      if (!started) {
        throw Exception('Could not start the screen-sharing service');
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    final MediaStream screenStream;
    try {
      screenStream = await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
        'video': true,
        'audio': false,
      });
    } catch (_) {
      if (isAndroid) unawaited(_platformControls.stopMediaProjection());
      rethrow;
    }

    final screenTrack = screenStream.getVideoTracks().firstOrNull;
    if (screenTrack == null) {
      await screenStream.dispose();
      if (isAndroid) unawaited(_platformControls.stopMediaProjection());
      return;
    }

    _screenStream = screenStream;
    _isScreenSharing = true;

    for (final peer in _peers.values) {
      try {
        final senders = await peer.pc.senders;
        for (final sender in senders) {
          if (sender.track?.kind == 'video') {
            await sender.replaceTrack(screenTrack);
            break;
          }
        }
      } catch (_) {}
    }

    _localRenderer.srcObject = screenStream;
    _sessionController.add(_session);
  }

  Future<void> stopScreenShare() async {
    if (!_isScreenSharing) return;

    final cameraTrack = _localStream?.getVideoTracks().firstOrNull;

    for (final peer in _peers.values) {
      try {
        final senders = await peer.pc.senders;
        for (final sender in senders) {
          if (sender.track?.kind == 'video') {
            await sender.replaceTrack(cameraTrack);
            break;
          }
        }
      } catch (_) {}
    }

    final stream = _screenStream;
    _screenStream = null;
    _isScreenSharing = false;

    if (stream != null) {
      for (final track in stream.getTracks()) {
        try {
          await track.stop();
        } catch (_) {}
      }
      try {
        await stream.dispose();
      } catch (_) {}
    }

    unawaited(_platformControls.stopMediaProjection());

    _localRenderer.srcObject = _localStream;
    _sessionController.add(_session);
  }

  bool get _supportsScreenShare {
    if (kIsWeb) return true;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.macOS ||
      TargetPlatform.linux ||
      TargetPlatform.windows => true,
      _ => false, // iOS requires a native Broadcast Extension
    };
  }

  // ── Audio output ────────────────────────────────────────────────────────────

  Future<List<CallAudioOutput>> getAudioOutputs() async {
    if (!kIsWeb &&
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS &&
        defaultTargetPlatform != TargetPlatform.windows &&
        defaultTargetPlatform != TargetPlatform.linux) {
      return const [];
    }
    try {
      final outputs = await Helper.audiooutputs;
      if (outputs.isNotEmpty) {
        final isMobile = _isMobilePlatform;
        final detected = outputs
            .where((d) => d.deviceId.isNotEmpty)
            .map(
              (d) => CallAudioOutput(
                deviceId: isMobile
                    ? _mobileAudioOutputId(d.deviceId, d.label)
                    : d.deviceId,
                label: _labelForAudioOutput(d.label),
              ),
            )
            .toList(growable: false);
        if (isMobile) return _mergeMobileAudioOutputs(detected);
        return detected;
      }
    } catch (_) {}

    if (_isMobilePlatform) {
      return const [
        CallAudioOutput(deviceId: 'speaker', label: 'Speaker'),
        CallAudioOutput(deviceId: 'earpiece', label: 'Earpiece'),
      ];
    }
    return const [];
  }

  Future<void> selectAudioOutput(String deviceId) async {
    _selectedAudioOutputId = deviceId;
    try {
      if (_isMobilePlatform) {
        await _selectMobileAudioOutput(deviceId);
        return;
      }
      await Helper.selectAudioOutput(deviceId);
    } catch (_) {}
  }

  Future<void> _selectMobileAudioOutput(String deviceId) async {
    await _platformControls.selectAudioOutput(
      deviceId,
      isVideo: _session?.isVideo ?? false,
    );

    // iOS: AppDelegate's configureAudioSession() handles complete session setup
    // and audio routing. Do not call Helper.ensureAudioSession() or
    // Helper.setSpeakerphoneOn() — they undo the route AppDelegate just applied.
    if (defaultTargetPlatform == TargetPlatform.iOS) return;

    if (defaultTargetPlatform == TargetPlatform.android) {
      switch (deviceId) {
        case 'speaker':
          try {
            await Helper.selectAudioOutput('speaker');
          } catch (_) {
            try {
              await Helper.setSpeakerphoneOn(true);
            } catch (_) {}
          }
          return;
        case 'earpiece':
          try {
            await Helper.setSpeakerphoneOn(false);
          } catch (_) {}
          try {
            await Helper.selectAudioOutput('earpiece');
          } catch (_) {}
          return;
        case 'bluetooth':
        case 'wired-headset':
          try {
            await Helper.selectAudioOutput(deviceId);
          } catch (_) {}
          return;
      }
      try {
        await Helper.selectAudioOutput(deviceId);
      } catch (_) {}
      return;
    }

  }

  // ── Connected state ─────────────────────────────────────────────────────────

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
    if (_isMobilePlatform) {
      final outputId = _selectedAudioOutputId;
      if (outputId != null) {
        unawaited(_selectMobileAudioOutput(outputId));
      }
    }
  }

  // ── Ring / connect timers ───────────────────────────────────────────────────

  void _startRingTimer() {
    _ringTimer?.cancel();
    _ringTimer = Timer(ringTimeout, () {
      final s = _session;
      if (s != null && s.state != CallState.connected) hangup();
    });
  }

  void _cancelRingTimer() {
    _ringTimer?.cancel();
    _ringTimer = null;
  }

  // ── Local media ─────────────────────────────────────────────────────────────

  Future<void> _initLocalRenderer() async {
    if (!_localRendererInitialized) {
      await _localRenderer.initialize();
      _localRendererInitialized = true;
    }
  }

  Future<MediaStream> _getUserMedia({required bool isVideo}) async {
    // iOS requires AVAudioSession to be in playAndRecord mode before getUserMedia.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await Helper.ensureAudioSession();
      } catch (_) {}
    }

    final constraints = <String, dynamic>{
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': isVideo
          ? {
              // facingMode selects the front/back camera and only applies on
              // mobile. It MUST be a plain string: the flutter_webrtc Android/iOS
              // plugins read it via ConstraintsMap.getString(), so the web-style
              // {'ideal': ...} object throws ClassCastException (HashMap cannot be
              // cast to String) and hard-crashes the app on a video call. Desktop
              // ignores facingMode, so we omit it there entirely.
              if (_isMobilePlatform)
                'facingMode': _usingFrontCamera ? 'user' : 'environment',
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
              'frameRate': {'ideal': 30},
            }
          : false,
    };
    try {
      return await navigator.mediaDevices.getUserMedia(constraints);
    } catch (_) {
      // Fallback to minimal constraints if ideal ones fail (e.g. no camera
      // matching the preferred facingMode, or constrained device).
      return await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': isVideo,
      });
    }
  }

  // ── Cleanup ─────────────────────────────────────────────────────────────────

  bool _isCleaningUp = false;

  void _cleanup({bool emitEndedEvent = true}) {
    if (_isCleaningUp) return;
    _isCleaningUp = true;
    _cancelRingTimer();
    _connectTimer?.cancel();
    _connectTimer = null;

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

    // Clear renderer sources immediately so the UI stops rendering.
    if (_localRendererInitialized) _localRenderer.srcObject = null;
    for (final peer in _peers.values) {
      peer.renderer.srcObject = null;
    }

    _session = null;
    _pendingRemoteSdp = null;
    _pendingRemoteCandidates.clear();
    _usingFrontCamera = true;
    _isScreenSharing = false;
    unawaited(_platformControls.stopMediaProjection());
    unawaited(_platformControls.clearAudioOutput());

    _sessionController.add(null);

    // Tear down peers and the local capture after the UI has a frame to rebuild.
    final peersSnapshot = Map.of(_peers);
    _peers.clear();
    // Detach callbacks synchronously BEFORE closing. The async native teardown
    // of a closed peer connection fires onConnectionState/onIceConnectionState,
    // which call _cleanup() again. Since _isCleaningUp resets to false in this
    // same frame, that re-entrant cleanup would tear down a *subsequent* call.
    for (final peer in peersSnapshot.values) {
      peer.pc.onIceCandidate = null;
      peer.pc.onTrack = null;
      peer.pc.onConnectionState = null;
      peer.pc.onIceConnectionState = null;
    }
    final localStream = _localStream;
    final screenStream = _screenStream;
    _localStream = null;
    _screenStream = null;
    // Close the peer connections FIRST, then stop and dispose the local
    // capture — the standard teardown order (don't dispose tracks still
    // attached to an open sender).
    unawaited(Future.microtask(() async {
      for (final peer in peersSnapshot.values) {
        try {
          await peer.pc.close();
        } catch (_) {}
        try {
          await peer.renderer.dispose();
        } catch (_) {}
      }
      await _stopLocalStream(localStream);
      await _stopLocalStream(screenStream);
    }));

    _isCleaningUp = false;
  }

  Future<void> _stopLocalStream(MediaStream? stream) async {
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (_) {}
    }
    try {
      await stream.dispose();
    } catch (_) {}
  }

  void dispose() {
    _cleanup();
    _cancelRingTimer();
    _connectTimer?.cancel();
    _wsSub?.cancel();
    _sessionController.close();
    _incomingCallController.close();
    _missedCallController.close();
    _callEndedController.close();
    if (_localRendererInitialized) {
      unawaited(_localRenderer.dispose());
    }
  }

  // ── Audio helpers ───────────────────────────────────────────────────────────

  bool get _isMobilePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  String _labelForAudioOutput(String raw) {
    final label = raw.trim();
    if (label.isEmpty) return 'Audio output';
    final lower = label.toLowerCase();
    if (lower.contains('bluetooth') || lower.contains('airpods')) {
      return 'Bluetooth';
    }
    if (lower.contains('speaker')) return 'Speaker';
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

  String _mobileAudioOutputId(String deviceId, String label) {
    switch (deviceId) {
      case 'speaker':
      case 'earpiece':
      case 'bluetooth':
      case 'wired-headset':
        return deviceId;
    }
    switch (_labelForAudioOutput(label)) {
      case 'Speaker':
        return 'speaker';
      case 'Earpiece':
        return 'earpiece';
      case 'Bluetooth':
        return 'bluetooth';
      case 'Headset':
        return 'wired-headset';
      default:
        return deviceId;
    }
  }

  List<CallAudioOutput> _mergeMobileAudioOutputs(
    List<CallAudioOutput> detected,
  ) {
    final byId = <String, CallAudioOutput>{
      'speaker': const CallAudioOutput(deviceId: 'speaker', label: 'Speaker'),
      'earpiece': const CallAudioOutput(
        deviceId: 'earpiece',
        label: 'Earpiece',
      ),
    };
    for (final output in detected) {
      byId[output.deviceId] = output;
    }
    return byId.values.toList(growable: false);
  }
}
