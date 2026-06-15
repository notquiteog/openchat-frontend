import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart'
    show
        debugPrint,
        defaultTargetPlatform,
        kIsWeb,
        visibleForTesting,
        TargetPlatform;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import '../config/api_config.dart';
import '../services/api_service.dart';
import '../services/call_platform_controls.dart';
import '../services/call_quality_policy.dart';
import '../services/call_signal_codec.dart';
import '../services/secure_storage_service.dart';
import '../services/websocket_service.dart';

enum CallState { idle, ringing, calling, connecting, connected, ended }

/// Whether a decoded incoming call signal came out of a sealed envelope.
/// `encryption_mode` is authoritative: the privacy codec emits it only after
/// successfully decrypting an `encrypted_signal`, and both codecs strip it
/// from plain passthrough payloads so a sender can't spoof the E2EE chip.
bool sealedCallPayload(Map<String, dynamic> decoded) =>
    (decoded['encryption_mode']?.toString().trim() ?? '').isNotEmpty;

class CallSession {
  final String callId;
  final String remoteUserId;
  final String? remoteUsername;
  final String? remoteAvatarUrl;
  final String? conversationId;
  final List<String> participantUserIds;

  /// Mutable: a connected voice call can be upgraded to video mid-call
  /// (either side turning on their camera flips this on both ends).
  bool isVideo;
  final bool isIncoming;
  CallState state;

  /// Whether this call's signaling is sealed (PGP/MLS conversation): media is
  /// always peer-encrypted by DTLS-SRTP, but only sealed signaling makes the
  /// handshake fingerprints tamper-proof against the server — the bar for
  /// showing the "End-to-end encrypted" chip. Mutable because the outgoing
  /// path learns it from an async conversation lookup just after dialing.
  bool sealed;

  bool wasConnected = false;
  bool reconnecting = false;
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
    this.sealed = false,
    this.state = CallState.ringing,
  }) : participantUserIds = List.unmodifiable(participantUserIds);

  bool get isGroupCall => participantUserIds.length > 1;
}

class CallEndedEvent {
  final String conversationId;
  final bool answered;
  final bool isVideo;
  final int durationSecs;

  /// Direction of the ended call. Incoming endings are recorded in the local
  /// call history but must NOT post a DM call event — the caller's side owns
  /// that (otherwise both sides would write a duplicate event).
  final bool isIncoming;

  const CallEndedEvent({
    required this.conversationId,
    required this.answered,
    required this.isVideo,
    required this.durationSecs,
    this.isIncoming = false,
  });
}

/// A mesh call that moved to the SFU — the listener joins the LiveKit room
/// for [conversationId] and shows the SFU call UI.
class EscalatedCall {
  final String conversationId;
  final bool isVideo;

  /// Media frame-encryption key for the LiveKit room (base64), distributed
  /// inside the sealed escalate signal. Null in plaintext conversations —
  /// the SFU then sees media the same way it did before escalation existed.
  final String? e2eeKeyB64;

  const EscalatedCall({
    required this.conversationId,
    required this.isVideo,
    this.e2eeKeyB64,
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
  CallQualityPolicy policy = const CallQualityPolicy.normal(),
}) => _buildCallMediaConstraints(
  audio: true,
  isVideo: isVideo,
  usingFrontCamera: usingFrontCamera,
  includeFacingMode: true,
  policy: policy,
);

Map<String, dynamic> _buildCallMediaConstraints({
  required bool audio,
  required bool isVideo,
  required bool usingFrontCamera,
  required bool includeFacingMode,
  required CallQualityPolicy policy,
}) {
  final width = policy.dataSaver ? 640 : 1280;
  final height = policy.dataSaver ? 360 : 720;
  final frameRate = policy.dataSaver ? policy.maxFramerate : 30;
  return {
    'audio': audio
        ? {
            'echoCancellation': true,
            'noiseSuppression': true,
            'autoGainControl': true,
          }
        : false,
    'video': isVideo
        ? {
            if (includeFacingMode)
              'facingMode': usingFrontCamera ? 'user' : 'environment',
            'width': {'ideal': width},
            'height': {'ideal': height},
            'frameRate': {'ideal': frameRate},
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
String _ensureSdpTerminator(String sdp) =>
    sdp.endsWith('\n') ? sdp : '$sdp\r\n';

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
  CallQualityPolicy Function() _qualityPolicyResolver = () =>
      const CallQualityPolicy.normal();

  final _sessionController = StreamController<CallSession?>.broadcast();
  final _incomingCallController = StreamController<CallSession>.broadcast();
  final _missedCallController = StreamController<CallSession>.broadcast();
  final _cancelledCallController = StreamController<CallSession>.broadcast();
  final _callEndedController = StreamController<CallEndedEvent>.broadcast();

  Stream<CallSession?> get sessionStream => _sessionController.stream;
  Stream<CallSession> get incomingCalls => _incomingCallController.stream;
  Stream<CallSession> get missedCalls => _missedCallController.stream;

  /// Incoming calls that were answered or declined on another device — the
  /// ringing UI should dismiss silently (no missed-call entry).
  Stream<CallSession> get cancelledCalls => _cancelledCallController.stream;
  Stream<CallEndedEvent> get callEnded => _callEndedController.stream;

  final _escalatedCallController = StreamController<EscalatedCall>.broadcast();

  /// Mesh calls that escalated to the SFU (locally or by a peer's request).
  /// The mesh session is already torn down when this fires; the listener is
  /// responsible for joining the LiveKit room.
  Stream<EscalatedCall> get escalatedCalls => _escalatedCallController.stream;

  /// SFU media frame keys by conversation id (base64, 32 random bytes each).
  /// One key per active group call; a new call start overwrites the old key.
  /// Holding a key implies nothing beyond conversation membership — exactly
  /// the authorization the server's relay and LiveKit token endpoint enforce.
  final Map<String, String> _sfuKeys = {};
  static const _sfuKeyCacheCap = 32;

  /// Joiners waiting for a peer to answer a key request, by conversation id.
  final Map<String, Completer<String>> _sfuKeyWaiters = {};

  static const ringTimeout = Duration(seconds: 30);
  static const connectTimeout = Duration(seconds: 30);

  /// Sealed offers older than this are treated as replays and never ring.
  /// Generous enough to absorb modest clock skew between devices plus
  /// delivery delay; a captured offer re-sent by a malicious or buggy server
  /// later than this is rejected at ingest.
  static const sealedOfferMaxAge = Duration(minutes: 2);

  // Two independent ring timers: the outgoing dial timeout and the pending
  // incoming missed-call timeout can overlap (dialing out while another call
  // rings in) — sharing one Timer field made one cancel the other.
  Timer? _ringTimer; // outgoing: give up dialing after [ringTimeout]
  Timer?
  _incomingRingTimer; // pending incoming: missed call after [ringTimeout]
  Timer? _connectTimer;

  /// Local user id, used to normalize incoming participant lists (the
  /// caller's recipient list contains US, never the caller). Prefetched from
  /// storage at construction and re-checked before each offer is ingested.
  String? _selfUserId;

  /// Call ids that ended on this device recently. A late renegotiation offer
  /// (e.g. the peer's ICE restart racing our hangup) reuses the old call id;
  /// without this it would ring as a brand-new call and turn into a false
  /// missed call. Call ids are UUIDs, so a legit new call never collides.
  final Set<String> _recentlyEndedCallIds = <String>{};
  static const _recentlyEndedCap = 8;

  StreamSubscription<WsEvent>? _wsSub;

  CallSession? get currentSession => _session;

  /// Test seams: the real session/pending state is only reachable through
  /// live WebRTC negotiation, which unit tests can't run.
  @visibleForTesting
  set debugSession(CallSession? session) => _session = session;
  @visibleForTesting
  set debugPendingIncoming(CallSession? pending) => _pendingIncoming = pending;
  @visibleForTesting
  CallSession? get debugPendingIncoming => _pendingIncoming;
  @visibleForTesting
  void debugHandleWsEvent(WsEvent event) => _handleWsEvent(event);
  @visibleForTesting
  set debugSelfUserId(String? userId) => _selfUserId = userId;
  @visibleForTesting
  void debugStartOutgoingRingTimer() => _startRingTimer();

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

  final SecureStorageService? _storage;

  CallService(
    this._ws,
    this._api, {
    CallSignalCodec? signalCodec,
    CallPlatformControls? platformControls,
    SecureStorageService? storage,
    CallQualityPolicy Function()? qualityPolicy,
  }) : _signalCodec = signalCodec ?? const PlainCallSignalCodec(),
       _platformControls = platformControls ?? const CallPlatformControls(),
       // ignore: prefer_initializing_formals
       _storage = storage {
    if (qualityPolicy != null) _qualityPolicyResolver = qualityPolicy;
    _wsSub = _ws.events.listen(_handleWsEvent);
    unawaited(_ensureSelfUserId());
  }

  void setQualityPolicyResolver(CallQualityPolicy Function() resolver) {
    _qualityPolicyResolver = resolver;
  }

  CallQualityPolicy _policy() {
    try {
      return _qualityPolicyResolver();
    } catch (_) {
      return const CallQualityPolicy.normal();
    }
  }

  Future<void> _ensureSelfUserId() async {
    if (_selfUserId != null && _selfUserId!.trim().isNotEmpty) return;
    final storage = _storage;
    if (storage == null) return;
    try {
      _selfUserId = await storage.getUserID();
    } catch (_) {}
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

    // Learn whether this conversation seals its signaling AFTER the session
    // exists (the `_session != null` re-entry guard must not race the async
    // lookup); the UI's E2EE chip appears as soon as the answer lands.
    unawaited(
      _signalCodec.isConversationEncrypted(conversationId).then((sealed) {
        final s = _session;
        if (sealed && s != null && s.callId == callId) {
          s.sealed = true;
          _sessionController.add(s);
        }
      }),
    );

    try {
      await _initLocalRenderer();
      _iceServers = await _api.getIceServers();
      debugPrint(
        'CallService: ICE servers loaded: ${_iceServers.length} -> ${_iceServers.map((s) => s.url).toList()}',
      );
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
    final peerState = _PeerState(userId: userId, pc: pc, renderer: renderer);
    _peers[userId] = peerState;

    _setupPcCallbacks(pc, peerState, userId, callId, conversationId);

    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await pc.addTrack(track, stream);
      }
    }
    await _applySenderCaps(pc);

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
    debugPrint(
      'CallService: acceptIncomingCall start (callId=${session.callId})',
    );
    _cancelIncomingRingTimer();
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
      debugPrint(
        'CallService: ICE servers loaded: ${_iceServers.length} -> ${_iceServers.map((s) => s.url).toList()}',
      );
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
        debugPrint(
          'CallService: flushing ${_pendingRemoteCandidates.length} buffered remote ICE candidate(s)',
        );
        peerState.pendingCandidates.addAll(_pendingRemoteCandidates);
        _pendingRemoteCandidates.clear();
      }

      _setupPcCallbacks(
        pc,
        peerState,
        session.remoteUserId,
        session.callId,
        conversationId,
      );

      final stream = _localStream;
      if (stream != null) {
        for (final track in stream.getTracks()) {
          await pc.addTrack(track, stream);
        }
      }
      await _applySenderCaps(pc);

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
      debugPrint(
        'CallService: answer sent for ${session.callId}, awaiting connection',
      );
      // (call_ringing is sent when the offer first arrives, not here — by
      // answer time the caller is already past the ringing state.)
      _startConnectTimer();
    } catch (e, st) {
      debugPrint('CallService.acceptIncomingCall failed: $e\n$st');
      _cleanup(emitEndedEvent: false);
      rethrow;
    }
  }

  void rejectCall(CallSession session) {
    _cancelIncomingRingTimer();
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
    final self = _selfUserId?.trim() ?? '';
    return ids
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty && (self.isEmpty || id != self))
        .toSet()
        .toList(growable: false);
  }

  void hangup() {
    final session = _session;
    if (session != null) {
      // Always signal — in a connected group call the remaining peers remove
      // just our tile (see the callHangup handler); without the signal they
      // stare at a frozen frame until ICE times out.
      for (final userId in _hangupTargetIds(session)) {
        _ws.sendCallHangup(
          targetUserId: userId,
          conversationId: session.conversationId ?? '',
          callId: session.callId,
        );
      }
    }
    _cleanup();
  }

  /// Removes a single participant from a connected group call: closes their
  /// peer connection, disposes their renderer, and ends the call when they
  /// were the last remote participant.
  void _removePeer(String userId) {
    final peer = userId.isEmpty ? null : _peers.remove(userId);
    if (peer == null) {
      // Unknown sender (or relay without caller_id) — just refresh the UI.
      _sessionController.add(_session);
      return;
    }
    debugPrint('CallService: peer[$userId] left the group call');
    peer.pc.onIceCandidate = null;
    peer.pc.onTrack = null;
    peer.pc.onConnectionState = null;
    peer.pc.onIceConnectionState = null;
    peer.renderer.srcObject = null;
    unawaited(() async {
      try {
        await peer.pc.close();
      } catch (_) {}
      try {
        await peer.renderer.dispose();
      } catch (_) {}
    }());
    if (_peers.isEmpty) {
      _cleanup();
    } else {
      _sessionController.add(_session);
    }
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
        final hangupCallId = event.data['call_id']?.toString() ?? '';
        final hangupFromId = event.data['caller_id']?.toString() ?? '';
        final pending = _pendingIncoming;
        // A hangup for a *pending* incoming call must dismiss its ring even
        // while another call is active — otherwise the stale ring persists
        // forever. Requires an explicit call-id match so an active group
        // call's hangups can't be misrouted here.
        if (_session != null &&
            pending != null &&
            hangupCallId.isNotEmpty &&
            hangupCallId == pending.callId &&
            hangupCallId != _session!.callId) {
          _cancelIncomingRingTimer();
          _pendingIncoming = null;
          _pendingRemoteSdp = null;
          _pendingRemoteCandidates.clear();
          _missedCallController.add(pending);
          break;
        }
        if (_session == null && pending != null) {
          // Only the caller hanging up cancels the ring — another invitee
          // leaving a group call (or a stale call's hangup) does not.
          final matchesCall =
              hangupCallId.isEmpty || hangupCallId == pending.callId;
          final fromCaller =
              hangupFromId.isEmpty || hangupFromId == pending.remoteUserId;
          if (matchesCall && fromCaller) {
            _cancelIncomingRingTimer();
            _pendingIncoming = null;
            _pendingRemoteSdp = null;
            _pendingRemoteCandidates.clear();
            _missedCallController.add(pending);
          }
        } else if (_session != null &&
            hangupCallId.isNotEmpty &&
            hangupCallId != _session!.callId) {
          // Stale hangup from a previous call — must not end the active one
          // NOR remove a live group peer whose caller_id happens to match.
          // (Checked BEFORE the group branch for exactly that reason.)
          debugPrint(
            'CallService: hangup for stale call $hangupCallId ignored',
          );
        } else if (_session?.isGroupCall == true &&
            _session?.state == CallState.connected) {
          // One participant left a connected group call: tear down just their
          // peer (otherwise their connection and frozen tile leak until ICE
          // times out). Everyone else stays in the call.
          _removePeer(hangupFromId);
        } else {
          debugPrint('CallService: remote hangup signal -> cleanup');
          _cleanup();
        }

      case WsEventType.callReject:
        final rejectCallId = event.data['call_id']?.toString() ?? '';
        final s = _session;
        if (s == null && _pendingIncoming != null) {
          // Dismiss the ring only for a matching (or id-less) reject — a
          // stale reject from a previous call must not kill a fresh ring.
          final pending = _pendingIncoming!;
          if (rejectCallId.isEmpty || rejectCallId == pending.callId) {
            _cancelIncomingRingTimer();
            _pendingIncoming = null;
            _pendingRemoteSdp = null;
            _pendingRemoteCandidates.clear();
            _missedCallController.add(pending);
          }
        } else if (s != null &&
            rejectCallId.isNotEmpty &&
            rejectCallId != s.callId) {
          // Stale reject from a previous call — must not end the active one
          // NOR remove a live group peer whose caller_id happens to match.
          debugPrint(
            'CallService: reject for stale call $rejectCallId ignored',
          );
        } else if (s != null && s.isGroupCall) {
          // One invitee declined a group call — drop just their peer; the
          // call continues for everyone else.
          _removePeer(event.data['caller_id']?.toString() ?? '');
        } else if (s != null) {
          debugPrint('CallService: remote reject signal -> cleanup');
          _cleanup();
        }

      case WsEventType.callRinging:
        final s = _session;
        final ringingCallId = event.data['call_id']?.toString() ?? '';
        // Only an un-answered outgoing call may move to "ringing", and only
        // for its own call id — a late/stale ringing event must never touch
        // a connecting, connected, or unrelated session.
        if (s != null &&
            s.state == CallState.calling &&
            (ringingCallId.isEmpty || ringingCallId == s.callId)) {
          s.state = CallState.ringing;
          _sessionController.add(s);
        }

      case WsEventType.callEscalate:
        unawaited(_handleCallEscalate(event.data));

      case WsEventType.callE2EEKey:
        unawaited(_handleCallE2EEKey(event.data));

      case WsEventType.callE2EEKeyRequest:
        unawaited(_handleCallE2EEKeyRequest(event.data));

      case WsEventType.callCancel:
        // A call_cancel means "this call was handled on one of your devices".
        // The server distinguishes two cases by `reason`:
        //   - 'lost_race' — sent point-to-point to the LOSING connection only:
        //     this device also answered but a DIFFERENT session of ours won
        //     first-answer-wins. Tear our half-built call down silently.
        //   - 'handled' (or absent, from older servers) — fanned out to ALL of
        //     our devices, INCLUDING the one that just answered, so the others
        //     stop ringing. It must only dismiss a still-ringing pending offer;
        //     it must NEVER tear down a call THIS device answered, or the
        //     winning device would kill its own call the moment it picks up.
        final cancelId = event.data['call_id']?.toString() ?? '';
        final cancelReason = event.data['reason']?.toString() ?? '';
        final acceptedHere = _session;
        // First-answer-wins loser: this device ALSO accepted, but another
        // session of ours won and the server cancelled THIS connection
        // specifically. Tear the connecting session down silently — signaling
        // call_hangup here would carry the ACTIVE call id and destroy the
        // caller's live call with the winner. Gated on the explicit
        // 'lost_race' reason so the winner's own stop-ringing broadcast (which
        // also reaches this device) can never trigger a self-teardown.
        if (cancelReason == 'lost_race' &&
            acceptedHere != null &&
            acceptedHere.isIncoming &&
            !acceptedHere.wasConnected &&
            cancelId.isNotEmpty &&
            cancelId == acceptedHere.callId) {
          debugPrint(
            'CallService: call ${acceptedHere.callId} lost first-answer race '
            '-> silent teardown',
          );
          _cancelledCallController.add(acceptedHere);
          _cleanup(emitEndedEvent: false);
          break;
        }
        final pendingCancel = _pendingIncoming;
        // Dismiss the matching pending ring even while another call is
        // active — answering the second call on a different device must stop
        // this device's ring. With an active session an explicit, matching
        // call id is required (an empty id is too ambiguous to act on).
        if (pendingCancel != null &&
            (_session == null
                ? (cancelId.isEmpty || cancelId == pendingCancel.callId)
                : (cancelId.isNotEmpty &&
                      cancelId == pendingCancel.callId &&
                      cancelId != _session!.callId))) {
          _cancelIncomingRingTimer();
          _pendingIncoming = null;
          _pendingRemoteSdp = null;
          _pendingRemoteCandidates.clear();
          _cancelledCallController.add(pendingCancel);
        }

      default:
        break;
    }
  }

  Future<void> _handleCallOffer(Map<String, dynamic> data) async {
    final decoded = await _decodeCallSignal(data);
    if (decoded == null) return;
    // The local user id is needed to normalize the offer's participant list
    // (it contains us, never the caller); usually already prefetched.
    await _ensureSelfUserId();
    _handleIncomingCallPayload(decoded);
  }

  Future<void> _handleCallAnswer(Map<String, dynamic> data) async {
    final s = _session;
    if (s == null) return;

    final decoded = await _decodeCallSignal(data);
    if (decoded == null) return;

    // Validate the call id BEFORE touching state — a stale answer from a
    // previous call must not flip a fresh outgoing call to "connecting".
    final callId = decoded['call_id']?.toString() ?? '';
    if (callId.isNotEmpty && callId != s.callId) return;

    if (s.state == CallState.calling || s.state == CallState.ringing) {
      s.state = CallState.connecting;
      _sessionController.add(s);
      _startConnectTimer();
    }

    final sdp = decoded['sdp']?.toString() ?? '';
    if (sdp.isEmpty) return;

    // Route answer to the right peer (backend injects caller_id into relay).
    final callerId = decoded['caller_id']?.toString() ?? '';
    final peer =
        _peers[callerId] ?? _peers[s.remoteUserId] ?? _peers.values.firstOrNull;
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
        debugPrint(
          'CallService: buffered early remote ICE candidate (${_candType(candidateStr)})',
        );
      } else {
        debugPrint(
          'CallService: remote ICE candidate dropped — no peer (callerId=$callerId)',
        );
      }
      return;
    }

    if (peer.remoteDescriptionSet) {
      debugPrint(
        'CallService: remote ICE candidate (${_candType(candidateStr)}) applied',
      );
      try {
        await peer.pc.addCandidate(candidate);
      } catch (_) {}
    } else {
      debugPrint(
        'CallService: remote ICE candidate (${_candType(candidateStr)}) queued (no remote desc yet)',
      );
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

  /// Asks every mesh peer to move this group call to the SFU, then tears the
  /// local mesh down and reports the escalation for the SFU join. The server
  /// gate (LiveKit token endpoint) still enforces premium per participant —
  /// a peer who can't join simply errors out of the new room.
  ///
  /// In sealed conversations a fresh media frame key rides inside each
  /// escalate signal, so the LiveKit room starts end-to-end encrypted.
  Future<void> escalateToSfu() async {
    final s = _session;
    final convId = s?.conversationId ?? '';
    if (s == null || !s.isGroupCall || !s.wasConnected || convId.isEmpty) {
      return;
    }
    debugPrint('CallService: escalating ${s.callId} to SFU');
    String? e2eeKey;
    if (await _signalCodec.isConversationEncrypted(convId)) {
      e2eeKey = createSfuKey(convId);
    }
    for (final peer in _peers.values) {
      try {
        final data = await _signalCodec.encode(
          CallSignalPayload(
            kind: 'escalate',
            targetUserId: peer.userId,
            callId: s.callId,
            conversationId: convId,
            e2eeKey: e2eeKey,
          ),
        );
        _ws.sendCallEscalate(data);
      } catch (e) {
        debugPrint('CallService: escalate signal to ${peer.userId} failed: $e');
      }
    }
    final escalated = EscalatedCall(
      conversationId: convId,
      isVideo: s.isVideo,
      e2eeKeyB64: e2eeKey,
    );
    _cleanup(emitEndedEvent: false);
    _escalatedCallController.add(escalated);
  }

  Future<void> _handleCallEscalate(Map<String, dynamic> data) async {
    final decoded = await _decodeCallSignal(data);
    if (decoded == null) return;
    final callId = decoded['call_id']?.toString() ?? '';
    final s = _session;
    // Escalation only matters for the active mesh call; unknown or stale call
    // ids are ignored (e.g. the escalate raced our own hangup).
    if (s == null || callId.isEmpty || callId != s.callId) return;
    final convId =
        s.conversationId ?? decoded['conversation_id']?.toString() ?? '';
    if (convId.isEmpty) return;
    debugPrint('CallService: peer escalated ${s.callId} to SFU');
    final e2eeKey = decoded['e2ee_key']?.toString();
    if (e2eeKey != null && e2eeKey.isNotEmpty) {
      _storeSfuKey(convId, e2eeKey);
    }
    final escalated = EscalatedCall(
      conversationId: convId,
      isVideo: s.isVideo,
      e2eeKeyB64: (e2eeKey?.isNotEmpty ?? false) ? e2eeKey : null,
    );
    _cleanup(emitEndedEvent: false);
    _escalatedCallController.add(escalated);
  }

  // ── SFU media E2EE keys ───────────────────────────────────────────────────

  /// The cached media frame key for a conversation's active SFU call, if this
  /// client generated or received one.
  String? sfuKeyFor(String conversationId) => _sfuKeys[conversationId];

  /// Generates (and caches) a fresh 32-byte media frame key for a new SFU
  /// call in [conversationId].
  String createSfuKey(String conversationId) {
    final rng = Random.secure();
    final key = base64Encode(List<int>.generate(32, (_) => rng.nextInt(256)));
    _storeSfuKey(conversationId, key);
    return key;
  }

  void _storeSfuKey(String conversationId, String key) {
    _sfuKeys.remove(conversationId); // re-insert → most-recently-used
    _sfuKeys[conversationId] = key;
    while (_sfuKeys.length > _sfuKeyCacheCap) {
      _sfuKeys.remove(_sfuKeys.keys.first);
    }
    final waiter = _sfuKeyWaiters.remove(conversationId);
    if (waiter != null && !waiter.isCompleted) waiter.complete(key);
  }

  /// Sends the current frame key for [conversationId] to each of [targetIds]
  /// inside sealed signals. No-op in plaintext conversations — the codec's
  /// plain fallback structurally drops the key, so don't even try.
  Future<void> distributeSfuKey(
    String conversationId,
    Iterable<String> targetIds,
  ) async {
    final key = _sfuKeys[conversationId];
    if (key == null) return;
    if (!await _signalCodec.isConversationEncrypted(conversationId)) return;
    for (final target in targetIds.toSet()) {
      if (target.trim().isEmpty) continue;
      try {
        final data = await _signalCodec.encode(
          CallSignalPayload(
            kind: 'e2ee_key',
            targetUserId: target,
            callId: conversationId,
            conversationId: conversationId,
            e2eeKey: key,
          ),
        );
        _ws.sendCallE2EEKey(data);
      } catch (e) {
        debugPrint('CallService: e2ee key to $target failed: $e');
      }
    }
  }

  /// Asks up to three current participants for the active call's frame key
  /// and waits for one to answer. Returns null on timeout (no participant
  /// reachable, or none holds a key — e.g. a plaintext conversation).
  Future<String?> requestSfuKey(
    String conversationId, {
    required List<String> fromUserIds,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final cached = _sfuKeys[conversationId];
    if (cached != null) return cached;
    if (fromUserIds.isEmpty) return null;
    final waiter = _sfuKeyWaiters.putIfAbsent(conversationId, Completer.new);
    for (final target in fromUserIds.take(3)) {
      try {
        final data = await _signalCodec.encode(
          CallSignalPayload(
            kind: 'e2ee_key_request',
            targetUserId: target,
            callId: conversationId,
            conversationId: conversationId,
          ),
        );
        _ws.sendCallE2EEKeyRequest(data);
      } catch (e) {
        debugPrint('CallService: e2ee key request to $target failed: $e');
      }
    }
    try {
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      _sfuKeyWaiters.remove(conversationId);
      return null;
    }
  }

  Future<void> _handleCallE2EEKey(Map<String, dynamic> data) async {
    final decoded = await _decodeCallSignal(data);
    if (decoded == null) return;
    final convId = decoded['conversation_id']?.toString() ?? '';
    final key = decoded['e2ee_key']?.toString() ?? '';
    if (convId.isEmpty || key.isEmpty) return;
    _storeSfuKey(convId, key);
  }

  Future<void> _handleCallE2EEKeyRequest(Map<String, dynamic> data) async {
    final decoded = await _decodeCallSignal(data);
    if (decoded == null) return;
    final convId = decoded['conversation_id']?.toString() ?? '';
    final requester = decoded['caller_id']?.toString() ?? '';
    if (convId.isEmpty || requester.isEmpty) return;
    if (_sfuKeys[convId] == null) return;
    await distributeSfuKey(convId, [requester]);
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
    // Renegotiation offer that adds video to this voice call. The explicit
    // flag beats SDP sniffing; the m=video check is a fallback for peers on
    // builds that predate the flag. Whether it changes anything is decided at
    // the apply site (only a connected non-video session upgrades).
    final videoUpgrade =
        data['video_upgrade'] == true ||
        (sdp != null && sdp.contains('\nm=video'));

    if (callId.isEmpty) return false;

    // A late renegotiation offer for a call that already ended here (e.g.
    // the peer's ICE restart racing our hangup) must not ring as a new call.
    if (_recentlyEndedCallIds.contains(callId)) {
      debugPrint('CallService: offer for recently ended call $callId ignored');
      return false;
    }

    // The backend delivers each offer over BOTH the WebSocket and FCM. A
    // second copy of an offer we already know about must be ignored — busy-
    // rejecting it would tear down our own pending/active call.
    if (callId == _pendingIncoming?.callId) return false;
    final active = _session;
    if (active != null && callId == active.callId) {
      // Same call id on the active session: either a duplicate delivery of
      // the original offer, or (when connected) a renegotiation offer from
      // the peer — e.g. an ICE restart after a network change.
      if (active.state == CallState.connected &&
          sdp != null &&
          callerId.isNotEmpty) {
        unawaited(
          _applyRenegotiationOffer(
            callerId,
            sdp,
            conversationId ?? '',
            videoUpgrade: videoUpgrade,
          ),
        );
      }
      return false;
    }

    // Replay guard: a sealed offer carries the sender's created_at inside the
    // ciphertext — a server replaying a captured offer can't forge it. Note
    // plaintext offers carry no timestamp at all, so they can't be checked.
    if (_sealedOfferExpired(data)) {
      debugPrint('CallService: stale sealed offer $callId rejected (replay)');
      return false;
    }

    if (active != null || _pendingIncoming != null) {
      // Glare: both sides called each other in the same conversation at the
      // same time. Resolve deterministically — both sides compare the same
      // pair of call ids, the side whose outgoing call id sorts LOWER wins as
      // caller; the loser silently cancels its outgoing attempt and rings for
      // the winner's offer instead. (The loser's offer is ignored by the
      // winner below, so no reject is sent in either direction.)
      final glare =
          active != null &&
          !active.isIncoming &&
          !active.wasConnected &&
          (active.state == CallState.calling ||
              active.state == CallState.ringing) &&
          conversationId != null &&
          conversationId == active.conversationId;
      if (glare) {
        if (active.callId.compareTo(callId) < 0) {
          // We win — keep our outgoing call, ignore their offer.
          return false;
        }
        // We lose — drop our outgoing attempt without signaling and fall
        // through to ring for the incoming offer.
        debugPrint(
          'CallService: glare detected, yielding to remote call $callId',
        );
        _cleanup(emitEndedEvent: false);
      } else {
        // Genuinely busy with a different call.
        if (callerId.isNotEmpty) {
          _ws.sendCallReject(
            targetUserId: callerId,
            conversationId: conversationId ?? '',
            callId: callId,
            reason: 'busy',
          );
        }
        return false;
      }
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
      sealed: sealedCallPayload(data),
      state: CallState.ringing,
    );
    _pendingRemoteSdp = sdp;
    _pendingRemoteCandidates.clear();
    _pendingIncoming = incoming;
    _incomingCallController.add(incoming);

    // Tell the caller we are ringing NOW — not on accept, by which time the
    // caller has already moved to connecting and ignores the event.
    if (callerId.isNotEmpty &&
        conversationId != null &&
        conversationId.isNotEmpty) {
      _ws.sendCallRinging(
        targetUserId: callerId,
        conversationId: conversationId,
        callId: callId,
      );
    }

    _incomingRingTimer?.cancel();
    _incomingRingTimer = Timer(ringTimeout, () {
      if (_session == null && _pendingIncoming == incoming) {
        _pendingIncoming = null;
        _pendingRemoteSdp = null;
        _pendingRemoteCandidates.clear();
        _missedCallController.add(incoming);
      }
    });
    return true;
  }

  /// True when a sealed payload's `created_at` is older than
  /// [sealedOfferMaxAge]. Payloads without a (parseable) timestamp pass —
  /// older clients don't send one. Future timestamps (peer clock ahead of
  /// ours) also pass: the guard only rejects provably old offers.
  bool _sealedOfferExpired(Map<String, dynamic> data) {
    if (!sealedCallPayload(data)) return false;
    final raw = data['created_at']?.toString() ?? '';
    if (raw.isEmpty) return false;
    final createdAt = DateTime.tryParse(raw);
    if (createdAt == null) return false;
    final age = DateTime.now().toUtc().difference(createdAt.toUtc());
    return age > sealedOfferMaxAge;
  }

  bool handleIncomingCallPayload(Map<String, dynamic> data) =>
      _handleIncomingCallPayload(data);

  Future<bool> handleIncomingCallPushPayload(Map<String, dynamic> data) async {
    final decoded = await _decodeCallSignal(data);
    if (decoded == null) return false;
    await _ensureSelfUserId();
    return _handleIncomingCallPayload(decoded);
  }

  /// Participants of an incoming call from OUR perspective. The caller built
  /// `participant_user_ids` as ITS recipient list — it contains us and the
  /// other invitees but never the caller — so take {caller} ∪ received − self.
  /// Without this, hangup() signaled the recipient list as-is and the caller
  /// was never told we hung up (its PC then failed, ICE-restarted, and rang
  /// us again as a false missed call).
  List<String> _participantUserIds(Map<String, dynamic> data, String callerId) {
    final raw = data['participant_user_ids'];
    final ids = <String>{};
    if (raw is List) {
      for (final value in raw) {
        if (value is! String) continue;
        final trimmed = value.trim();
        if (trimmed.isNotEmpty) ids.add(trimmed);
      }
    }
    if (callerId.trim().isNotEmpty) {
      ids.add(callerId.trim());
    }
    final self = _selfUserId?.trim() ?? '';
    if (self.isNotEmpty) ids.remove(self);
    return ids.toList(growable: false);
  }

  // ── Peer connection factory ─────────────────────────────────────────────────

  Future<RTCPeerConnection> _createPeerConnection() async {
    final forceTurn = await (_storage?.getForceTurn() ?? Future.value(false));
    final config = <String, dynamic>{
      'iceServers': [
        if (_iceServers.isNotEmpty)
          for (final server in _iceServers) server.toRtcMap()
        else
          {'urls': 'stun:stun.l.google.com:19302'},
      ],
      // 'relay' forces all media through TURN so the peer never sees our IP.
      'iceTransportPolicy': forceTurn ? 'relay' : 'all',
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
        debugPrint(
          'CallService: local ICE candidate (${_candType(c)}) -> $userId',
        );
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
          if (_session != null && !_session!.wasConnected) {
            _cleanup();
          } else if (_session != null) {
            // Mid-call transport failure (network change) — try to recover
            // instead of leaving a zombie "connected" call with dead media.
            _attemptIceRestart(peer);
          }
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
          if (_session != null && !_session!.wasConnected) {
            _cleanup();
          } else if (_session != null) {
            _attemptIceRestart(peer);
          }
        default:
          break;
      }
    };
  }

  // ── Media controls ──────────────────────────────────────────────────────────

  void setMicMuted(bool muted) {
    final audioTrack = _localStream?.getAudioTracks().firstOrNull;
    if (audioTrack == null) return;
    // Mute through flutter_webrtc so it flows through the plugin's own audio
    // management (RTCAudioSession on iOS, AudioSwitchManager on Android) instead
    // of the app's parallel native layer, which conflicts with it (and whose
    // iOS path, AVAudioSession.setInputGain, is a no-op on most devices). Also
    // disable the track directly so no audio is sent regardless of platform.
    audioTrack.enabled = !muted;
    unawaited(Helper.setMicrophoneMute(muted, audioTrack));
  }

  void setCameraEnabled(bool enabled) {
    if (!_isScreenSharing) {
      final videoTrack = _localStream?.getVideoTracks().firstOrNull;
      if (videoTrack != null) videoTrack.enabled = enabled;
    }
  }

  Future<void> _applySenderCaps(RTCPeerConnection pc) async {
    final policy = _policy();
    if (!policy.dataSaver) return;
    try {
      final senders = await pc.senders;
      for (final sender in senders) {
        if (sender.track?.kind != 'video') continue;
        final params = sender.parameters;
        await sender.setParameters(applyVideoSenderCaps(params, policy));
      }
    } catch (e) {
      debugPrint('CallService: could not apply video sender caps: $e');
    }
  }

  /// Whether this device has acquired a camera track for the current call.
  /// False on the receiving side of a remote video upgrade until the user
  /// turns their own camera on ([setCameraEnabled] can only toggle an
  /// existing track; acquiring one goes through [upgradeToVideo]).
  bool get hasLocalVideo => _localStream?.getVideoTracks().isNotEmpty == true;

  /// Whether the connected 1:1 call can gain video right now — drives the
  /// "turn on camera" button on voice calls.
  bool get canUpgradeToVideo {
    final s = _session;
    return s != null &&
        s.wasConnected &&
        s.state == CallState.connected &&
        !s.isGroupCall &&
        _peers.length == 1;
  }

  /// Turns this device's camera on mid-call. On a voice call this upgrades
  /// the whole call to video: a camera track is acquired, added to the peer
  /// connection, and announced via a flagged renegotiation offer — the remote
  /// side auto-accepts and renders it (their own camera stays off until they
  /// press their camera button, which lands here too).
  Future<void> upgradeToVideo() async {
    final s = _session;
    final peer = _peers.values.firstOrNull;
    if (s == null || peer == null || !s.wasConnected || s.isGroupCall) return;

    // Already have a camera track (e.g. remote upgraded first, then we
    // toggled off/on, or this is an original video call): just re-enable.
    if (_localStream?.getVideoTracks().isNotEmpty == true) {
      s.isVideo = true;
      setCameraEnabled(true);
      _sessionController.add(s);
      return;
    }

    debugPrint('CallService: upgrading ${s.callId} to video');
    final cameraStream = await navigator.mediaDevices.getUserMedia(
      _buildCallMediaConstraints(
        audio: false,
        isVideo: true,
        usingFrontCamera: _usingFrontCamera,
        includeFacingMode: _isMobilePlatform,
        policy: _policy(),
      ),
    );
    final videoTrack = cameraStream.getVideoTracks().firstOrNull;
    if (videoTrack == null) {
      await _stopLocalStream(cameraStream);
      return;
    }

    final local = _localStream;
    if (local != null) {
      await local.addTrack(videoTrack);
    } else {
      _localStream = cameraStream;
    }
    await _initLocalRenderer();
    _localRenderer.srcObject = _localStream;
    for (final p in _peers.values) {
      await p.pc.addTrack(videoTrack, _localStream ?? cameraStream);
      await _applySenderCaps(p.pc);
    }

    s.isVideo = true;
    _sessionController.add(s);

    // Video calls default to speakerphone on mobile (matching video-call
    // starts); an explicit user-chosen output is respected.
    if (_isMobilePlatform && _selectedAudioOutputId == null) {
      try {
        await Helper.setSpeakerphoneOn(true);
      } catch (_) {}
    }

    try {
      final offer = await peer.pc.createOffer({'offerToReceiveVideo': 1});
      await peer.pc.setLocalDescription(offer);
      final offerData = await _signalCodec.encode(
        CallSignalPayload(
          kind: 'offer',
          targetUserId: peer.userId,
          callId: s.callId,
          conversationId: s.conversationId ?? '',
          isVideo: true,
          videoUpgrade: true,
          sdp: offer.sdp,
          participantUserIds: s.participantUserIds,
        ),
      );
      _ws.sendCallOfferPayload(offerData);
      debugPrint('CallService: video-upgrade offer sent for ${s.callId}');
    } catch (e) {
      debugPrint('CallService: video-upgrade offer failed: $e');
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
      screenStream = await navigator.mediaDevices.getDisplayMedia(
        <String, dynamic>{'video': true, 'audio': false},
      );
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
      // iOS needs a Broadcast Upload Extension target wired to flutter_webrtc
      // (App Group + RTCAppGroupIdentifier/RTCScreenSharingExtension Info.plist
      // keys). See ios/SCREENSHARE_IOS_SETUP.md. getDisplayMedia() then shows the
      // system broadcast picker; without the extension the picker is empty.
      TargetPlatform.iOS ||
      TargetPlatform.macOS ||
      TargetPlatform.linux ||
      TargetPlatform.windows => true,
      _ => false,
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
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // Route through flutter_webrtc's RTCAudioSession (Helper). The app's
      // AppDelegate AVAudioSession route gets overridden by flutter_webrtc's own
      // session management, so it never sticks; going through Helper does.
      try {
        switch (deviceId) {
          case 'speaker':
            await Helper.setSpeakerphoneOn(true);
          case 'bluetooth':
            await Helper.setSpeakerphoneOnButPreferBluetooth();
          default: // earpiece / wired-headset
            await Helper.setSpeakerphoneOn(false);
        }
      } catch (_) {}
      return;
    }

    // Android: native AudioManager routing + Helper fallback.
    await _platformControls.selectAudioOutput(
      deviceId,
      isVideo: _session?.isVideo ?? false,
    );

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
    _iceRestartTimer?.cancel();
    _iceRestartTimer = null;
    if (!s.wasConnected) {
      s.wasConnected = true;
      s.connectedAt = DateTime.now();
    }
    s.reconnecting = false;
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

  /// Cancels the OUTGOING dial timer only — the pending-incoming missed-call
  /// timer ([_incomingRingTimer]) is deliberately independent: connecting an
  /// outgoing call must not silence another caller's pending ring.
  void _cancelRingTimer() {
    _ringTimer?.cancel();
    _ringTimer = null;
  }

  void _cancelIncomingRingTimer() {
    _incomingRingTimer?.cancel();
    _incomingRingTimer = null;
  }

  /// Fails the call if it never reaches connected after answering — without
  /// this, a callee whose ICE never completes sits in "connecting" forever.
  void _startConnectTimer() {
    _connectTimer?.cancel();
    _connectTimer = Timer(connectTimeout, () {
      final s = _session;
      if (s != null && !s.wasConnected) {
        debugPrint('CallService: connect timeout -> hangup');
        hangup();
      }
    });
  }

  // ── ICE restart ─────────────────────────────────────────────────────────────

  static const _iceRestartTimeout = Duration(seconds: 12);
  Timer? _iceRestartTimer;

  /// A connected call whose transport failed (network change, NAT rebind)
  /// attempts one ICE restart before giving up. The new offer reuses the
  /// normal offer relay with the same call id; the remote side recognizes the
  /// id and treats it as a renegotiation rather than a new call.
  void _attemptIceRestart(_PeerState peer) {
    final s = _session;
    if (s == null || !s.wasConnected) return;
    if (_iceRestartTimer != null) return; // restart already in flight

    debugPrint('CallService: transport failed while connected -> ICE restart');
    _iceRestartTimer = Timer(_iceRestartTimeout, () {
      _iceRestartTimer = null;
      final current = _session;
      if (current != null && current.reconnecting) {
        debugPrint('CallService: ICE restart failed -> cleanup');
        _cleanup();
      }
    });
    s.reconnecting = true;
    _sessionController.add(s);

    unawaited(() async {
      try {
        final offer = await peer.pc.createOffer({'iceRestart': true});
        await peer.pc.setLocalDescription(offer);
        final offerData = await _signalCodec.encode(
          CallSignalPayload(
            kind: 'offer',
            targetUserId: peer.userId,
            callId: s.callId,
            conversationId: s.conversationId ?? '',
            isVideo: s.isVideo,
            sdp: offer.sdp,
            participantUserIds: s.participantUserIds,
          ),
        );
        _ws.sendCallOfferPayload(offerData);
      } catch (e) {
        debugPrint('CallService: ICE restart offer failed: $e');
      }
    }());
  }

  /// Remote side of a renegotiation: an offer arriving with the active call's
  /// id while connected is either an ICE restart or a video upgrade — apply
  /// it and answer back.
  Future<void> _applyRenegotiationOffer(
    String callerId,
    String sdp,
    String conversationId, {
    bool videoUpgrade = false,
  }) async {
    final s = _session;
    final peer = _peers[callerId] ?? _peers.values.firstOrNull;
    if (s == null || peer == null) return;
    try {
      // Simultaneous-upgrade glare: if our own renegotiation offer is still
      // in flight, the polite peer (the original callee) rolls its offer
      // back and answers the remote one; the impolite peer ignores the
      // incoming offer and waits for its own answer. Both sides want the
      // same outcome, so either resolution converges.
      final signalingState = peer.pc.signalingState;
      if (signalingState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        if (!s.isIncoming) {
          debugPrint(
            'CallService: renegotiation glare — impolite side ignoring offer',
          );
          return;
        }
        debugPrint('CallService: renegotiation glare — rolling back');
        await peer.pc.setLocalDescription(
          RTCSessionDescription('', 'rollback'),
        );
      }
      if (videoUpgrade && !s.isVideo) {
        // The peer turned their camera on: render their video immediately.
        // Our own camera stays off until the user enables it (auto-accept,
        // Telegram-style — no consent dialog).
        s.isVideo = true;
        await _initLocalRenderer();
        _sessionController.add(s);
      }
      await peer.pc.setRemoteDescription(
        RTCSessionDescription(_ensureSdpTerminator(sdp), 'offer'),
      );
      final answer = await peer.pc.createAnswer({});
      await peer.pc.setLocalDescription(answer);
      final answerData = await _signalCodec.encode(
        CallSignalPayload(
          kind: 'answer',
          targetUserId: peer.userId,
          callId: s.callId,
          conversationId: conversationId.isNotEmpty
              ? conversationId
              : (s.conversationId ?? ''),
          isVideo: s.isVideo,
          sdp: answer.sdp,
        ),
      );
      _ws.sendCallAnswer(answerData);
      debugPrint('CallService: renegotiation answer sent for ${s.callId}');
    } catch (e) {
      debugPrint('CallService: renegotiation failed: $e');
    }
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

    // facingMode selects the front/back camera and only applies on mobile. It
    // MUST be a plain string: the flutter_webrtc Android/iOS plugins read it
    // via ConstraintsMap.getString(), so the web-style {'ideal': ...} object
    // throws ClassCastException and hard-crashes on video call start.
    final constraints = _buildCallMediaConstraints(
      audio: true,
      isVideo: isVideo,
      usingFrontCamera: _usingFrontCamera,
      includeFacingMode: _isMobilePlatform,
      policy: _policy(),
    );
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
    _iceRestartTimer?.cancel();
    _iceRestartTimer = null;

    final ending = _session;
    if (ending != null) _rememberEndedCallId(ending.callId);
    // Emitted for BOTH directions: the listener records call history from it
    // (an answered incoming call must land in the log too). The DM call event
    // stays caller-side only — receivers key off [CallEndedEvent.isIncoming].
    if (emitEndedEvent && ending != null && ending.conversationId != null) {
      final dur = ending.wasConnected && ending.connectedAt != null
          ? DateTime.now().difference(ending.connectedAt!).inSeconds
          : 0;
      _callEndedController.add(
        CallEndedEvent(
          conversationId: ending.conversationId!,
          answered: ending.wasConnected,
          isVideo: ending.isVideo,
          durationSecs: dur,
          isIncoming: ending.isIncoming,
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
    unawaited(
      Future.microtask(() async {
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
      }),
    );

    _isCleaningUp = false;
  }

  void _rememberEndedCallId(String callId) {
    if (callId.isEmpty) return;
    _recentlyEndedCallIds.remove(callId); // re-insert → most recent
    _recentlyEndedCallIds.add(callId);
    while (_recentlyEndedCallIds.length > _recentlyEndedCap) {
      _recentlyEndedCallIds.remove(_recentlyEndedCallIds.first);
    }
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
    _cancelIncomingRingTimer();
    _connectTimer?.cancel();
    _wsSub?.cancel();
    _sessionController.close();
    _incomingCallController.close();
    _missedCallController.close();
    _cancelledCallController.close();
    _callEndedController.close();
    _escalatedCallController.close();
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
