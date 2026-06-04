import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/call_audio.dart';
import '../services/call_foreground_service.dart';
import '../services/call_service.dart';
import '../services/notification_service.dart';

/// Exposed to the UI; wraps CallService and notifies listeners on state changes.
class CallProvider extends ChangeNotifier {
  static const double minimizedCallBarHeight = 48;

  final CallService _callService;
  final CallAudioController _audio;
  final CallForegroundController _foreground;
  final DateTime Function() _now;
  Timer? _durationTicker;
  bool _isCallMinimized = false;
  bool _micMuted = false;
  bool _cameraEnabled = true;
  List<CallAudioOutput> _audioOutputs = const [];
  String? _selectedAudioOutputId;
  CallState? _lastSessionState;
  String? _activeCallNotificationSessionId;
  CallState? _activeCallNotificationState;
  bool? _activeCallNotificationMuted;
  bool _disposed = false;

  /// Plays/stops the ringing/connecting tones to match the current call.
  void _syncAudio() {
    if (_incomingCall != null) {
      unawaited(_audio.update(incoming: true));
    } else {
      final s = session;
      final audioState =
          s?.isIncoming == true &&
              (s?.state == CallState.calling || s?.state == CallState.ringing)
          ? CallState.connecting
          : s?.state;
      unawaited(_audio.update(state: audioState));
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

  void _syncActiveCallNotification() {
    final s = session;
    if (s == null || s.state == CallState.ended) {
      if (_activeCallNotificationSessionId != null) {
        _activeCallNotificationSessionId = null;
        _activeCallNotificationState = null;
        _activeCallNotificationMuted = null;
        unawaited(_foreground.stop());
        unawaited(NotificationService.cancelActiveCall());
      }
      return;
    }

    final shouldRefresh =
        _activeCallNotificationSessionId != s.callId ||
        _activeCallNotificationState != s.state ||
        _activeCallNotificationMuted != _micMuted;
    if (!shouldRefresh) return;
    _activeCallNotificationSessionId = s.callId;
    _activeCallNotificationState = s.state;
    _activeCallNotificationMuted = _micMuted;
    final name = s.remoteUsername != null ? '@${s.remoteUsername}' : 'OpenChat';
    final kind = s.isVideo ? 'Video call' : 'Voice call';
    final connectedAtMillis = s.connectedAt?.millisecondsSinceEpoch;
    final notificationBody = s.state == CallState.connected
        ? 'Call in progress'
        : callStatusText;
    unawaited(
      _foreground.start(
        title: '$kind with $name',
        body: notificationBody,
        isVideo: s.isVideo,
        muted: _micMuted,
        connectedAtMillis: connectedAtMillis,
      ),
    );
    unawaited(
      (() async {
        final granted = await NotificationService.requestPermission();
        if (!granted) return;
        await NotificationService.showActiveCall(
          title: '$kind with $name',
          body: notificationBody,
          muted: _micMuted,
          connectedAtMillis: connectedAtMillis,
        );
      })(),
    );
  }

  CallSession? get session => _callService.currentSession;
  MediaStream? get localStream => _callService.currentLocalStream;
  MediaStream? get remoteStream => _callService.currentRemoteStream;
  bool get isCallMinimized => _isCallMinimized;
  bool get isMicMuted => _micMuted;
  bool get isCameraEnabled => _cameraEnabled;
  List<CallAudioOutput> get audioOutputs => _audioOutputs;
  String? get selectedAudioOutputId => _selectedAudioOutputId;
  /// Extra pixels that every screen's safe-area/AppBar must add at the top
  /// when the call bar is visible, so it never overlaps screen chrome.
  double get minimizedContentTopInset =>
      _isCallMinimized ? minimizedCallBarHeight + 8.0 : 0.0;

  StreamSubscription? _sessionSub;
  StreamSubscription? _incomingSub;
  StreamSubscription? _missedSub;
  StreamSubscription? _endedSub;
  StreamSubscription<CallForegroundAction>? _foregroundActionSub;

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
    CallForegroundController? foreground,
    DateTime Function()? now,
  }) : _audio = audio ?? CallAudio(),
       _foreground = foreground ?? const CallForegroundService(),
       _now = now ?? DateTime.now {
    CallForegroundService.init();
    _foregroundActionSub = CallForegroundService.actions.listen(
      _handleForegroundAction,
    );
    _sessionSub = _callService.sessionStream.listen((_) {
      final s = session;
      if (s == null || s.state == CallState.ended) {
        _incomingCall = null;
        _pendingOfferSdp = null;
        unawaited(NotificationService.cancelIncomingCall());
        if (_micMuted) {
          try {
            _callService.setMicMuted(false);
          } catch (_) {}
        }
        if (!_cameraEnabled) {
          try {
            _callService.setCameraEnabled(true);
          } catch (_) {}
        }
        _isCallMinimized = false;
        _micMuted = false;
        _cameraEnabled = true;
      }
      if (s?.state == CallState.connected &&
          _lastSessionState != CallState.connected) {
        _incomingCall = null;
        _pendingOfferSdp = null;
        unawaited(NotificationService.cancelIncomingCall());
        unawaited(refreshAudioOutputs());
      }
      _syncAudio();
      _syncDurationTicker();
      _syncActiveCallNotification();
      _lastSessionState = s?.state;
      notifyListeners();
    });
    _incomingSub = _callService.incomingCalls.listen(_onIncomingCall);
    _missedSub = _callService.missedCalls.listen(_onMissedCall);
    _endedSub = _callService.callEnded.listen(_onCallEnded);
    NotificationService.setActiveCallHandlers(
      onEnd: hangup,
      onToggleMute: () => setMicMuted(!_micMuted),
    );
    NotificationService.setIncomingCallHandlers(
      onAnswer: () => unawaited(acceptIncomingCall()),
      onDismiss: dismissIncomingCall,
      onDecline: rejectIncomingCall,
    );
  }

  void _handleForegroundAction(CallForegroundAction action) {
    if (_disposed || !isInCall) return;
    switch (action) {
      case CallForegroundAction.toggleMute:
        setMicMuted(!_micMuted);
        return;
      case CallForegroundAction.end:
        hangup();
        return;
    }
  }

  void _onCallEnded(CallEndedEvent ev) {
    _lastEndedCall = ev;
    notifyListeners();
  }

  /// Called by the app once it has recorded the ended call as a DM event.
  void clearEndedCall() => _lastEndedCall = null;

  void _onIncomingCall(CallSession incoming) {
    if (incoming.state == CallState.ended) return;
    _incomingCall = incoming;
    _pendingOfferSdp = _callService.pendingOfferSdp;
    final kind = incoming.isVideo ? 'video' : 'voice';
    final from = incoming.remoteUsername != null
        ? ' from @${incoming.remoteUsername}'
        : '';
    unawaited(
      NotificationService.showIncomingCall(body: 'Incoming $kind call$from'),
    );
    _syncAudio();
    notifyListeners();
  }

  void _onMissedCall(CallSession missed) {
    // Dismiss the ringing UI and surface the miss via an OS notification (where
    // supported) plus an in-app banner driven off [lastMissedCall].
    _incomingCall = null;
    _lastMissedCall = missed;
    final kind = missed.isVideo ? 'video' : 'voice';
    final from = missed.remoteUsername != null
        ? ' from @${missed.remoteUsername}'
        : '';
    unawaited(NotificationService.cancelIncomingCall());
    unawaited(
      NotificationService.showMissedCall(body: 'Missed $kind call$from'),
    );
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
    _pendingOfferSdp = null;
    unawaited(NotificationService.cancelIncomingCall());
    _syncAudio();
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
    _pendingOfferSdp = null;
    _callService.rejectCall(incoming);
    unawaited(NotificationService.cancelIncomingCall());
    _syncAudio();
    notifyListeners();
  }

  /// Hide the incoming-call UI (and silence the ringtone) without rejecting —
  /// the call keeps ringing until it's answered, the caller hangs up, or it
  /// times out into a missed call.
  void dismissIncomingCall() {
    _incomingCall = null;
    unawaited(NotificationService.cancelIncomingCall());
    _syncAudio();
    notifyListeners();
  }

  // ---- Controls ----

  void hangup() {
    try {
      _callService.hangup();
    } catch (_) {}
    _incomingCall = null;
    _pendingOfferSdp = null;
    _activeCallNotificationSessionId = null;
    _activeCallNotificationState = null;
    _activeCallNotificationMuted = null;
    unawaited(_foreground.stop());
    unawaited(NotificationService.cancelActiveCall());
    unawaited(NotificationService.cancelIncomingCall());
    _syncAudio();
    notifyListeners();
  }

  void setMicMuted(bool muted) {
    if (_micMuted == muted) return;
    _micMuted = muted;
    try {
      _callService.setMicMuted(muted);
    } catch (_) {}
    _syncActiveCallNotification();
    notifyListeners();
  }

  void setCameraEnabled(bool enabled) {
    if (_cameraEnabled == enabled) return;
    _cameraEnabled = enabled;
    try {
      _callService.setCameraEnabled(enabled);
    } catch (_) {}
    notifyListeners();
  }

  bool handleIncomingCallPush(Map<String, dynamic> data) {
    final handled = _callService.handleIncomingCallPayload(data);
    if (!handled) return false;
    notifyListeners();
    return true;
  }

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

  void refreshActiveCallNotification() {
    _activeCallNotificationSessionId = null;
    _activeCallNotificationState = null;
    _activeCallNotificationMuted = null;
    _syncActiveCallNotification();
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
    _foregroundActionSub?.cancel();
    _durationTicker?.cancel();
    NotificationService.setActiveCallHandlers();
    NotificationService.setIncomingCallHandlers();
    unawaited(_foreground.stop());
    unawaited(NotificationService.cancelActiveCall());
    _audio.dispose();
    super.dispose();
  }
}
