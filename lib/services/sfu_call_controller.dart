import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';

import 'api_service.dart';
import 'call_platform_controls.dart';
import 'websocket_service.dart';

/// Drives a premium "Call with SFU" group call via a LiveKit [Room].
///
/// Deliberately self-contained and independent of the P2P CallService /
/// CallProvider: a group call can run on either backend, chosen by the user.
/// 1:1 calls never use this. Registered app-wide so a call survives navigating
/// away from the call screen (enabling "leave/join an active call any time").
class SfuCallController extends ChangeNotifier {
  SfuCallController(this._api, this._ws);

  final ApiService _api;
  final WebSocketService _ws;

  Room? _room;
  EventsListener<RoomEvent>? _listener;
  Timer? _heartbeat;
  final CallPlatformControls _platformControls = const CallPlatformControls();
  bool _usingFrontCamera = true;
  String? _conversationId;
  String? _title;
  bool _isVideo = false;
  bool _connecting = false;
  bool _sawRemote = false;
  bool _mediaE2EE = false;
  String? _error;

  Room? get room => _room;
  bool get isActive => _room != null || _connecting;
  bool get isConnecting => _connecting;
  bool get isConnected => _room?.connectionState == ConnectionState.connected;
  String? get conversationId => _conversationId;
  String? get title => _title;
  bool get isVideo => _isVideo;

  /// True when this room's media frames are end-to-end encrypted (every
  /// participant joined with the shared frame key; the SFU routes ciphertext).
  bool get isMediaE2EE => _mediaE2EE;
  String? get error => _error;

  bool get isMicEnabled =>
      _room?.localParticipant?.isMicrophoneEnabled() ?? false;
  bool get isCameraEnabled =>
      _room?.localParticipant?.isCameraEnabled() ?? false;
  bool get isScreenSharing =>
      _room?.localParticipant?.isScreenShareEnabled() ?? false;
  bool get isFrontCamera => _usingFrontCamera;

  /// Local participant first, then remotes — the render order for the grid.
  List<Participant> get participants {
    final r = _room;
    if (r == null) return const [];
    return [
      if (r.localParticipant != null) r.localParticipant!,
      ...r.remoteParticipants.values,
    ];
  }

  /// Fetch a join token from the backend (premium/group/member-gated) and
  /// connect to the LiveKit room named after the conversation.
  ///
  /// With [e2eeKeyB64] set, every media frame is additionally encrypted with
  /// that shared key (AES-GCM frame cryptor) before it reaches the SFU — the
  /// server routes ciphertext it cannot decrypt. All participants must join
  /// with the same key (distributed via sealed call signals); a client
  /// joining without it renders the others' tracks as noise, never plaintext.
  Future<void> join({
    required String conversationId,
    required String title,
    required bool isVideo,
    String? e2eeKeyB64,
  }) async {
    if (isActive) return;
    _conversationId = conversationId;
    _title = title;
    _isVideo = isVideo;
    _connecting = true;
    _sawRemote = false;
    _mediaE2EE = false;
    _error = null;
    notifyListeners();

    try {
      final data = await _api.getLiveKitToken(conversationId);
      final url = data['url'] as String?;
      final token = data['token'] as String?;
      if (url == null || url.isEmpty || token == null || token.isEmpty) {
        throw Exception('SFU is not available');
      }

      E2EEOptions? e2ee;
      if (e2eeKeyB64 != null && e2eeKeyB64.isNotEmpty) {
        e2ee = await E2EEOptions.sharedKey(e2eeKeyB64);
        _mediaE2EE = true;
      }
      final room = Room(
        roomOptions: RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          e2eeOptions: e2ee,
        ),
      );
      final listener = room.createListener();
      _room = room;
      _listener = listener;
      _bind(room, listener);

      await room.connect(url, token);
      await room.localParticipant?.setMicrophoneEnabled(true);
      if (isVideo) {
        await room.localParticipant?.setCameraEnabled(true);
      }
      // Announce presence so other members see a join banner, then re-announce
      // periodically as a heartbeat (the server ends the call when it stops).
      _ws.sendGroupCallJoin(conversationId);
      _startHeartbeat();
    } catch (e) {
      _error = e.toString();
      await _teardown();
      _connecting = false;
      notifyListeners();
      rethrow;
    }

    _connecting = false;
    notifyListeners();
  }

  void _bind(Room room, EventsListener<RoomEvent> listener) {
    room.addListener(_onRoomChange);
    listener
      ..on<ParticipantConnectedEvent>((_) {
        _sawRemote = true;
        notifyListeners();
      })
      ..on<ParticipantDisconnectedEvent>((_) => _onParticipantLeft())
      ..on<TrackSubscribedEvent>((_) => notifyListeners())
      ..on<TrackUnsubscribedEvent>((_) => notifyListeners())
      ..on<RoomDisconnectedEvent>((_) => _onDisconnected());
  }

  void _onRoomChange() => notifyListeners();

  void _onParticipantLeft() {
    final r = _room;
    // Auto-end when everyone else has left and we're the last one standing.
    if (r != null && _sawRemote && r.remoteParticipants.isEmpty) {
      unawaited(leave());
      return;
    }
    notifyListeners();
  }

  void _onDisconnected() {
    unawaited(_teardown());
    notifyListeners();
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
      final c = _conversationId;
      if (c != null) _ws.sendGroupCallJoin(c);
    });
  }

  Future<void> toggleMic() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    await lp.setMicrophoneEnabled(!lp.isMicrophoneEnabled());
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    await lp.setCameraEnabled(!lp.isCameraEnabled());
    notifyListeners();
  }

  /// Flip the local camera front/back (mobile).
  Future<void> switchCamera() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    final pubs = lp.videoTrackPublications;
    final track = pubs.isNotEmpty ? pubs.first.track : null;
    if (track is! LocalVideoTrack) return;
    try {
      await track.setCameraPosition(
        _usingFrontCamera ? CameraPosition.back : CameraPosition.front,
      );
      _usingFrontCamera = !_usingFrontCamera;
    } catch (_) {}
    notifyListeners();
  }

  Future<void> toggleScreenShare() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    final enabling = !lp.isScreenShareEnabled();
    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    try {
      if (enabling) {
        if (isAndroid) {
          // Android 14+: a mediaProjection foreground service must be running
          // before the projection is created. Grab the consent token first so
          // LiveKit's internal getDisplayMedia reuses it, start the FGS, then
          // enable — mirrors CallService.startScreenShare() for the P2P path.
          final granted = await rtc.Helper.requestCapturePermission();
          if (!granted) return;
          final started = await _platformControls.startMediaProjection();
          if (!started) return;
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        await lp.setScreenShareEnabled(true);
      } else {
        await lp.setScreenShareEnabled(false);
        if (isAndroid) unawaited(_platformControls.stopMediaProjection());
      }
    } catch (_) {
      if (isAndroid) unawaited(_platformControls.stopMediaProjection());
    }
    notifyListeners();
  }

  Future<void> leave() async {
    await _teardown();
    notifyListeners();
  }

  Future<void> _teardown() async {
    final room = _room;
    final listener = _listener;
    final convID = _conversationId;
    _room = null;
    _listener = null;
    _conversationId = null;
    _title = null;
    _sawRemote = false;
    _mediaE2EE = false;
    _heartbeat?.cancel();
    _heartbeat = null;
    unawaited(_platformControls.stopMediaProjection());
    if (convID != null) {
      _ws.sendGroupCallLeave(convID);
    }
    room?.removeListener(_onRoomChange);
    try {
      await listener?.dispose();
    } catch (_) {}
    try {
      await room?.disconnect();
    } catch (_) {}
    try {
      await room?.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(_teardown());
    super.dispose();
  }
}
