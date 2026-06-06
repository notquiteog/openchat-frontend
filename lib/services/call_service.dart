import 'dart:async';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show Helper, MediaDeviceInfo;
import 'package:livekit_client/livekit_client.dart';
import 'package:uuid/uuid.dart';
import '../services/api_service.dart';
import '../services/call_platform_controls.dart';
import '../services/call_signal_codec.dart';
import '../services/websocket_service.dart';

export 'package:livekit_client/livekit_client.dart'
    show
        Room,
        LocalParticipant,
        RemoteParticipant,
        LocalVideoTrack,
        RemoteVideoTrack,
        LocalAudioTrack,
        RemoteAudioTrack,
        Participant,
        Track,
        TrackPublication,
        VideoTrack,
        VideoTrackRenderer,
        VideoViewFit,
        VideoViewMirrorMode,
        CameraPosition,
        CameraCaptureOptions,
        AudioCaptureOptions;

enum CallState {
  idle,
  ringing, // incoming awaiting accept / outgoing peer is ringing
  calling, // outgoing offer sent, not yet acknowledged
  connecting, // answered; joining LiveKit room
  connected, // media is flowing
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

/// Emitted by [CallService] when an outgoing call ends, so the caller's client
/// can record a deletable event in the DM. Only the caller emits these.
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

@visibleForTesting
List<Map<String, dynamic>> buildCallMediaCaptureAttemptsForTesting({
  required bool isVideo,
  required bool isMobile,
  required bool isWeb,
  required bool isDesktop,
  List<MediaDeviceInfo> videoInputs = const [],
}) {
  // Only used for tests — LiveKit manages actual capture internally.
  if (!isVideo) {
    return const [
      {'audio': true, 'video': false},
    ];
  }
  return const [
    {
      'audio': true,
      'video': {'width': 640, 'height': 480, 'frameRate': 30},
    },
  ];
}

String? _stringField(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Manages a call session via the LiveKit SFU. Handles invitation signaling
/// through the WebSocket service while delegating all media to LiveKit.
class CallService {
  final WebSocketService _ws;
  final CallSignalCodec _signalCodec;
  final ApiService _api;
  final CallPlatformControls _platformControls;

  Room? _room;
  EventsListener<RoomEvent>? _roomListener;
  CallSession? _session;
  bool _micMuted = false;
  bool _cameraEnabled = true;
  bool _usingFrontCamera = true;
  String? _selectedAudioOutputId;
  String? _pendingRoomName;

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

  CallSession? _pendingIncoming;

  CallSession? get currentSession => _session;
  Room? get room => _room;
  bool get hasLocalMedia => _room?.localParticipant != null;
  bool get usingFrontCamera => _usingFrontCamera;

  StreamSubscription<WsEvent>? _wsSub;

  CallService(
    this._ws,
    this._api, {
    CallSignalCodec? signalCodec,
    CallPlatformControls? platformControls,
  }) : _signalCodec = signalCodec ?? const PlainCallSignalCodec(),
       _platformControls = platformControls ?? const CallPlatformControls() {
    _wsSub = _ws.events.listen(_handleWsEvent);
  }

  // ---- Outgoing call ----

  Future<void> startCall({
    required String targetUserId,
    String? targetUsername,
    required String conversationId,
    required bool isVideo,
    List<String> additionalUserIds = const [],
  }) async {
    if (_session != null) return;

    final callId = const Uuid().v4();
    final roomName = 'call_$callId';
    final recipientIds = <String>[
      targetUserId,
      ...additionalUserIds,
    ].where((id) => id.trim().isNotEmpty).toSet().toList(growable: false);
    if (recipientIds.isEmpty) {
      throw ArgumentError('targetUserId is required');
    }

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
      final tokenResult = await _api.getLiveKitToken(
        roomName: roomName,
        conversationId: conversationId,
      );
      await _connectToRoom(
        url: tokenResult.url,
        token: tokenResult.token,
        isVideo: isVideo,
      );
      _sessionController.add(_session);

      for (final userId in recipientIds) {
        final offerData = await _signalCodec.encode(
          CallSignalPayload(
            kind: 'offer',
            targetUserId: userId,
            callId: callId,
            conversationId: conversationId,
            isVideo: isVideo,
            roomName: roomName,
            participantUserIds: recipientIds,
          ),
        );
        _ws.sendCallOfferPayload(offerData);
      }

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
    _session = session..state = CallState.connecting;
    _sessionController.add(_session);

    final roomName = _pendingRoomName;
    if (roomName == null) {
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
      final tokenResult = await _api.getLiveKitToken(
        roomName: roomName,
        conversationId: conversationId,
      );
      await _connectToRoom(
        url: tokenResult.url,
        token: tokenResult.token,
        isVideo: session.isVideo,
      );
      _sessionController.add(_session);

      _ws.sendCallRinging(
        targetUserId: session.remoteUserId,
        conversationId: session.conversationId ?? '',
        callId: session.callId,
      );
    } catch (_) {
      _cleanup(emitEndedEvent: false);
      rethrow;
    }
  }

  void rejectCall(CallSession session) {
    _cancelRingTimer();
    _pendingIncoming = null;
    _pendingRoomName = null;
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

  // ---- Media controls ----

  void setMicMuted(bool muted) {
    _micMuted = muted;
    unawaited(_room?.localParticipant?.setMicrophoneEnabled(!muted));
    unawaited(_platformControls.setMicrophoneMuted(muted));
  }

  void setCameraEnabled(bool enabled) {
    _cameraEnabled = enabled;
    unawaited(_room?.localParticipant?.setCameraEnabled(enabled));
  }

  Future<bool> switchCamera() async {
    final pub = _room?.localParticipant?.videoTrackPublications.firstOrNull;
    final track = pub?.track;
    if (track == null) return _usingFrontCamera;
    final newPos = _usingFrontCamera
        ? CameraPosition.back
        : CameraPosition.front;
    await track.setCameraPosition(newPos);
    _usingFrontCamera = !_usingFrontCamera;
    if (!_cameraEnabled) {
      unawaited(_room?.localParticipant?.setCameraEnabled(true));
      _cameraEnabled = true;
    }
    return _usingFrontCamera;
  }

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

    // iOS
    try {
      await Helper.ensureAudioSession();
    } catch (_) {}
    switch (deviceId) {
      case 'speaker':
        try {
          await Helper.setSpeakerphoneOn(true);
        } catch (_) {}
        return;
      case 'bluetooth':
        try {
          await Helper.setSpeakerphoneOnButPreferBluetooth();
        } catch (_) {}
        return;
      case 'earpiece':
      case 'wired-headset':
        try {
          await Helper.setSpeakerphoneOn(false);
        } catch (_) {}
        return;
    }
    try {
      await Helper.setSpeakerphoneOn(false);
    } catch (_) {}
  }

  // ---- WebSocket events ----

  void _handleWsEvent(WsEvent event) {
    switch (event.type) {
      case WsEventType.callOffer:
        unawaited(_handleCallOffer(event.data));

      case WsEventType.callAnswer:
        // With LiveKit the callee joining the room acts as the "answer".
        // We still handle the ringing acknowledgement here.
        final s = _session;
        if (s != null &&
            (s.state == CallState.calling || s.state == CallState.ringing)) {
          s.state = CallState.connecting;
          _sessionController.add(s);
        }

      case WsEventType.callHangup:
        if (_session == null && _pendingIncoming != null) {
          final missed = _pendingIncoming!;
          _pendingIncoming = null;
          _pendingRoomName = null;
          _missedCallController.add(missed);
        } else if (_session?.isGroupCall == true &&
            _session?.state == CallState.connected) {
          _sessionController.add(_session);
        } else {
          _cleanup();
        }

      case WsEventType.callReject:
        final s = _session;
        if (s == null && _pendingIncoming != null) {
          final missed = _pendingIncoming!;
          _pendingIncoming = null;
          _pendingRoomName = null;
          _missedCallController.add(missed);
        } else if (s != null && !s.isGroupCall) {
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
    final roomName = _stringField(data, 'room_name');
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
    _pendingRoomName = roomName;
    _pendingIncoming = incoming;
    _incomingCallController.add(incoming);

    _ringTimer?.cancel();
    _ringTimer = Timer(ringTimeout, () {
      if (_session == null && _pendingIncoming == incoming) {
        _pendingIncoming = null;
        _pendingRoomName = null;
        _missedCallController.add(incoming);
      }
    });
    return true;
  }

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
    if (ids.isEmpty && callerId.trim().isNotEmpty) {
      ids.add(callerId.trim());
    }
    return ids.toList(growable: false);
  }

  bool handleIncomingCallPayload(Map<String, dynamic> data) =>
      _handleIncomingCallPayload(data);

  Future<bool> handleIncomingCallPushPayload(Map<String, dynamic> data) async {
    final decoded = await _decodeCallSignal(data);
    if (decoded == null) return false;
    return _handleIncomingCallPayload(decoded);
  }

  // ---- Room connection ----

  Future<void> _connectToRoom({
    required String url,
    required String token,
    required bool isVideo,
  }) async {
    final room = Room(
      roomOptions: RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultCameraCaptureOptions: CameraCaptureOptions(
          cameraPosition: _usingFrontCamera
              ? CameraPosition.front
              : CameraPosition.back,
        ),
        defaultAudioCaptureOptions: const AudioCaptureOptions(
          noiseSuppression: true,
          echoCancellation: true,
        ),
      ),
    );
    _room = room;

    final listener = room.createListener();
    _roomListener = listener;

    listener
      ..on<RoomDisconnectedEvent>((_) => _cleanup())
      ..on<ParticipantConnectedEvent>((_) {
        _markConnected();
        _sessionController.add(_session);
      })
      ..on<ParticipantDisconnectedEvent>((_) {
        if ((room.remoteParticipants).isEmpty) {
          _cleanup();
        } else {
          _sessionController.add(_session);
        }
      })
      ..on<TrackSubscribedEvent>((_) {
        _markConnected();
        _sessionController.add(_session);
      })
      ..on<TrackUnsubscribedEvent>((_) {
        _sessionController.add(_session);
      })
      ..on<TrackMutedEvent>((_) => _sessionController.add(_session))
      ..on<TrackUnmutedEvent>((_) => _sessionController.add(_session));

    await room.connect(url, token);

    // Publish tracks after connecting.
    await room.localParticipant?.setMicrophoneEnabled(!_micMuted);
    if (isVideo) {
      await room.localParticipant?.setCameraEnabled(_cameraEnabled);
    }

    if (room.remoteParticipants.isNotEmpty) {
      _markConnected();
      _sessionController.add(_session);
    }

    if (_session?.state != CallState.connected) {
      // Re-arm connect timeout: if no remote participant joins within 30s
      // (unanswered call), hang up.
      _connectTimer?.cancel();
      _connectTimer = Timer(connectTimeout, () {
        final cur = _session;
        if (cur != null && cur.state != CallState.connected) {
          hangup();
        }
      });
    }
  }

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
      final selectedOutputId = _selectedAudioOutputId;
      if (selectedOutputId != null) {
        unawaited(_selectMobileAudioOutput(selectedOutputId));
      }
    }
  }

  // ---- Cleanup ----

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

    unawaited(_roomListener?.dispose());
    _roomListener = null;
    unawaited(_room?.disconnect());
    unawaited(_room?.dispose());
    _room = null;
    _pendingRoomName = null;
    _session = null;
    _micMuted = false;
    _cameraEnabled = true;
    _usingFrontCamera = true;
    unawaited(_platformControls.clearAudioOutput());

    _sessionController.add(null);
    _isCleaningUp = false;
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
  }

  // ---- Audio helpers ----

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
