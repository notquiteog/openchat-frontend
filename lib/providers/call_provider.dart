import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/call_audio.dart';
import '../services/call_service.dart';
import '../services/notification_service.dart';

/// Exposed to the UI; wraps CallService and notifies listeners on state changes.
class CallProvider extends ChangeNotifier {
  final CallService _callService;
  final CallAudioController _audio;
  final DateTime Function() _now;
  Timer? _durationTicker;
  bool _isCallMinimized = false;
  List<CallAudioOutput> _audioOutputs = const [];
  String? _selectedAudioOutputId;
  CallState? _lastSessionState;
  bool _disposed = false;

  /// Plays/stops the ringing/connecting tones to match the current call.
  void _syncAudio() {
    if (_incomingCall != null) {
      unawaited(_audio.update(incoming: true));
    } else {
      unawaited(_audio.update(state: session?.state));
    }
  }

  void _syncDurationTicker() {
    _durationTicker?.cancel();
    _durationTicker = null;
    final s = session;
    if (s?.state == CallState.connected && s?.connectedAt != null) {
      _durationTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!_disposed) notifyListeners();
      });
    }
  }

  CallSession? get session => _callService.currentSession;
  MediaStream? get localStream => _callService.currentLocalStream;
  MediaStream? get remoteStream => _callService.currentRemoteStream;
  bool get isCallMinimized => _isCallMinimized;
  List<CallAudioOutput> get audioOutputs => _audioOutputs;
  String? get selectedAudioOutputId => _selectedAudioOutputId;

  StreamSubscription? _sessionSub;
  StreamSubscription? _incomingSub;
  StreamSubscription? _missedSub;
  StreamSubscription? _endedSub;

  // Pending incoming call waiting for user accept/reject
  CallSession? _incomingCall;
  String? _pendingOfferSdp;
  CallSession? get incomingCall => _incomingCall;

  // Most recent missed call, consumed by the UI to show an in-app banner.
  CallSession? _lastMissedCall;
  CallSession? get lastMissedCall => _lastMissedCall;

  // Most recent ended outgoing call, consumed by the app to write a deletable
  // event into the DM thread.
  CallEndedEvent? _lastEndedCall;
  CallEndedEvent? get lastEndedCall => _lastEndedCall;

  CallProvider(
    this._callService, {
    CallAudioController? audio,
    DateTime Function()? now,
  })  : _audio = audio ?? CallAudio(),
        _now = now ?? DateTime.now {
    _sessionSub = _callService.sessionStream.listen((_) {
      final s = session;
      if (s == null || s.state == CallState.ended) {
        _isCallMinimized = false;
      }
      if (s?.state == CallState.connected &&
          _lastSessionState != CallState.connected) {
        unawaited(refreshAudioOutputs());
      }
      _lastSessionState = s?.state;
      _syncAudio();
      _syncDurationTicker();
      notifyListeners();
    });
    _incomingSub = _callService.incomingCalls.listen(_onIncomingCall);
    _missedSub = _callService.missedCalls.listen(_onMissedCall);
    _endedSub = _callService.callEnded.listen(_onCallEnded);
  }

  void _onCallEnded(CallEndedEvent ev) {
    _lastEndedCall = ev;
    notifyListeners();
  }

  /// Called by the app once it has recorded the ended call as a DM event.
  void clearEndedCall() => _lastEndedCall = null;

  void _onIncomingCall(CallSession incoming) {
    _incomingCall = incoming;
    _pendingOfferSdp = _callService.pendingOfferSdp;
    final kind = incoming.isVideo ? 'video' : 'voice';
    final from = incoming.remoteUsername != null ? ' from @${incoming.remoteUsername}' : '';
    NotificationService.showIncomingCall(body: 'Incoming $kind call$from');
    _syncAudio();
    notifyListeners();
  }

  void _onMissedCall(CallSession missed) {
    // Dismiss the ringing UI and surface the miss via an OS notification (where
    // supported) plus an in-app banner driven off [lastMissedCall].
    _incomingCall = null;
    _lastMissedCall = missed;
    final kind = missed.isVideo ? 'video' : 'voice';
    final from =
        missed.remoteUsername != null ? ' from @${missed.remoteUsername}' : '';
    NotificationService.showMissedCall(body: 'Missed $kind call$from');
    _syncAudio();
    notifyListeners();
  }

  /// Called by the UI once it has shown the in-app banner for a missed call.
  void clearMissedCall() => _lastMissedCall = null;

  // ---- Outgoing ----

  Future<void> startCall({
    required String targetUserId,
    String? targetUsername,
    String? conversationId,
    required bool isVideo,
  }) async {
    await _callService.startCall(
      targetUserId: targetUserId,
      targetUsername: targetUsername,
      conversationId: conversationId,
      isVideo: isVideo,
    );
    notifyListeners();
  }

  // ---- Incoming ----

  Future<void> acceptIncomingCall() async {
    final incoming = _incomingCall;
    final sdp = _pendingOfferSdp;
    if (incoming == null) return;

    _incomingCall = null;
    notifyListeners();

    await _callService.acceptIncomingCall(incoming);
    if (sdp != null) {
      await _callService.answerCall(sdpOffer: sdp);
    }
    notifyListeners();
  }

  void rejectIncomingCall() {
    final incoming = _incomingCall;
    if (incoming == null) return;
    _incomingCall = null;
    _callService.rejectCall(incoming);
    _syncAudio();
    notifyListeners();
  }

  /// Hide the incoming-call UI (and silence the ringtone) without rejecting —
  /// the call keeps ringing until it's answered, the caller hangs up, or it
  /// times out into a missed call.
  void dismissIncomingCall() {
    _incomingCall = null;
    _syncAudio();
    notifyListeners();
  }

  // ---- Controls ----

  void hangup() {
    _callService.hangup();
    notifyListeners();
  }

  void setMicMuted(bool muted) => _callService.setMicMuted(muted);
  void setCameraEnabled(bool enabled) => _callService.setCameraEnabled(enabled);

  bool get isInCall => session != null && session!.state != CallState.ended;

  void setCallMinimized(bool minimized) {
    if (!isInCall) {
      _isCallMinimized = false;
      return;
    }
    if (_isCallMinimized == minimized) return;
    _isCallMinimized = minimized;
    notifyListeners();
  }

  String get callStatusText {
    final s = session;
    if (s == null) return '';
    if (s.state == CallState.connected && s.connectedAt != null) {
      final seconds = _now().difference(s.connectedAt!).inSeconds;
      return formatCallDuration(seconds);
    }
    return switch (s.state) {
      CallState.ringing => 'Ringing…',
      CallState.calling => 'Calling…',
      CallState.connecting => 'Connecting…',
      CallState.connected => 'Connected',
      CallState.ended => 'Call ended',
      CallState.idle => '',
    };
  }

  static String formatCallDuration(int seconds) {
    final total = seconds < 0 ? 0 : seconds;
    final minutes = (total ~/ 60).toString().padLeft(2, '0');
    final remainder = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$remainder';
  }

  Future<void> refreshAudioOutputs() async {
    final outputs = await _callService.getAudioOutputs();
    if (_disposed) return;
    _audioOutputs = outputs;
    if (_selectedAudioOutputId != null &&
        !_audioOutputs.any((o) => o.deviceId == _selectedAudioOutputId)) {
      _selectedAudioOutputId = null;
    }
    notifyListeners();
  }

  Future<void> selectAudioOutput(String deviceId) async {
    try {
      await _callService.selectAudioOutput(deviceId);
    } catch (_) {
      // Unsupported output switching should not break the call screen.
    }
    if (_disposed) return;
    _selectedAudioOutputId = deviceId;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionSub?.cancel();
    _incomingSub?.cancel();
    _missedSub?.cancel();
    _endedSub?.cancel();
    _durationTicker?.cancel();
    _audio.dispose();
    super.dispose();
  }
}
