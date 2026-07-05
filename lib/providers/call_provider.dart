import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/call_audio.dart';
import '../services/call_foreground_service.dart';
import '../services/call_history_service.dart';
import '../services/call_quality_policy.dart';
import '../services/call_media_permissions.dart';
import '../services/call_service.dart';
import '../services/network_service.dart';
import '../services/notification_service.dart';
import '../services/sfu_call_controller.dart';
import 'settings_provider.dart';

/// Exposed to the UI; wraps CallService and notifies listeners on state changes.
class CallProvider extends ChangeNotifier {
  static const double minimizedCallBarHeight = 48;

  final CallService _callService;
  final CallAudioController _audio;
  final CallForegroundController _foreground;
  final CallMediaPermissionGate _mediaPermissionGate;
  final CallHistoryService? _callHistory;
  final SettingsProvider? _settings;
  final NetworkService? _network;
  final DateTime Function() _now;
  // The most recent active (outgoing or accepted) session, retained so the
  // call-history record on end can attribute peer + direction (CallEndedEvent
  // alone doesn't carry them).
  CallSession? _historySession;
  Timer? _durationTicker;
  bool _isCallMinimized = false;
  bool _micMuted = false;
  bool _cameraEnabled = true;
  bool _usingFrontCamera = true;
  List<CallAudioOutput> _audioOutputs = const [];
  String? _selectedAudioOutputId;
  CallState? _lastSessionState;
  // Voice→video flip detection (remote upgrades must not claim our camera
  // is on — see the session listener).
  String? _lastSessionCallId;
  bool _lastSessionIsVideo = false;
  String? _activeCallNotificationSessionId;
  CallState? _activeCallNotificationState;
  bool? _activeCallNotificationMuted;
  bool? _activeCallNotificationVideo;
  bool _disposed = false;

  static final bool _isDesktopPlatform =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

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
    // Desktop shows the call in its own window, so an OS notification for an
    // active call is redundant. It's also harmful on Linux: the
    // flutter_local_notifications + window_manager.isFocused() calls run on the
    // GTK platform thread and stall the whole UI on every answer and every mute
    // toggle (the "freeze then recover" symptom). Skip it entirely off mobile.
    if (_isDesktopPlatform) return;
    final s = session;
    if (s == null ||
        s.state == CallState.ended ||
        !_callService.hasLocalMedia) {
      if (_activeCallNotificationSessionId != null) {
        _activeCallNotificationSessionId = null;
        _activeCallNotificationState = null;
        _activeCallNotificationMuted = null;
        _activeCallNotificationVideo = null;
        unawaited(_foreground.stop());
        unawaited(NotificationService.cancelActiveCall());
      }
      return;
    }

    final shouldRefresh =
        _activeCallNotificationSessionId != s.callId ||
        _activeCallNotificationState != s.state ||
        _activeCallNotificationMuted != _micMuted ||
        // A mid-call video upgrade must restart the Android foreground
        // service so it runs with the camera service type.
        _activeCallNotificationVideo != s.isVideo;
    if (!shouldRefresh) return;
    _activeCallNotificationSessionId = s.callId;
    _activeCallNotificationState = s.state;
    _activeCallNotificationMuted = _micMuted;
    _activeCallNotificationVideo = s.isVideo;
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
  RTCVideoRenderer? get localRenderer => _callService.localRenderer;
  Map<String, RTCVideoRenderer> get remoteRenderers =>
      _callService.remoteRenderers;
  bool get isScreenSharing => _callService.isScreenSharing;
  bool get canScreenShare => _callService.canScreenShare;
  bool get isCallMinimized => _isCallMinimized;
  bool get isMicMuted => _micMuted;
  bool get isCameraEnabled => _cameraEnabled;
  bool get isFrontCamera => _usingFrontCamera;
  List<CallAudioOutput> get audioOutputs => _audioOutputs;
  String? get selectedAudioOutputId => _selectedAudioOutputId;

  /// Extra pixels that every screen's safe-area/AppBar must add at the top
  /// when the call bar is visible, so it never overlaps screen chrome.
  double get minimizedContentTopInset =>
      _isCallMinimized ? minimizedCallBarHeight + 8.0 : 0.0;

  StreamSubscription? _sessionSub;
  StreamSubscription? _incomingSub;
  StreamSubscription? _missedSub;
  StreamSubscription? _cancelledSub;
  StreamSubscription? _endedSub;
  StreamSubscription<CallForegroundAction>? _foregroundActionSub;

  // Pending incoming call waiting for user accept/reject
  CallSession? _incomingCall;
  CallSession? get incomingCall => _incomingCall;
  // Guards acceptIncomingCall against the UI-tap + notification-answer race.
  bool _accepting = false;

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
    CallMediaPermissionGate? mediaPermissionGate,
    CallHistoryService? callHistory,
    SettingsProvider? settings,
    NetworkService? network,
    DateTime Function()? now,
  }) : _audio = audio ?? CallAudio(),
       _foreground = foreground ?? const CallForegroundService(),
       _mediaPermissionGate = mediaPermissionGate ?? ensureCallMediaPermissions,
       // ignore: prefer_initializing_formals
       _callHistory = callHistory,
       _settings = settings,
       _network = network,
       _now = now ?? DateTime.now {
    if (settings != null && network != null) {
      _callService.setQualityPolicyResolver(_resolvedQualityPolicy);
    }
    CallForegroundService.init();
    _foregroundActionSub = CallForegroundService.actions.listen(
      _handleForegroundAction,
    );
    _sessionSub = _callService.sessionStream.listen((_) {
      final s = session;
      if (s != null && s.state != CallState.ended) {
        _historySession = s;
      }
      // Mid-call voice→video flip on the SAME call. If we initiated it,
      // upgradeToVideo() acquired a camera track before this emission and
      // the control stays on; a REMOTE upgrade must never present our
      // camera as on — the peer's video shows, ours stays off until the
      // user presses the camera button themselves.
      if (s != null &&
          s.isVideo &&
          s.callId == _lastSessionCallId &&
          !_lastSessionIsVideo &&
          !_callService.hasLocalVideo) {
        _cameraEnabled = false;
      }
      _lastSessionCallId = s?.callId;
      _lastSessionIsVideo = s?.isVideo ?? false;
      if (s == null || s.state == CallState.ended) {
        _incomingCall = null;
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
        _usingFrontCamera = true;
      }
      if (s?.state == CallState.connected &&
          _lastSessionState != CallState.connected) {
        _incomingCall = null;
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
    _cancelledSub = _callService.cancelledCalls.listen(_onCancelledCall);
    _endedSub = _callService.callEnded.listen(_onCallEnded);
    NotificationService.setActiveCallHandlers(
      onEnd: hangup,
      onToggleMute: () => setMicMuted(!_micMuted),
    );
    NotificationService.setIncomingCallHandlers(
      onAnswer: () => unawaited(_answerIncomingCallFromNotification()),
      onDismiss: dismissIncomingCall,
      onDecline: rejectIncomingCall,
    );
  }

  CallQualityPolicy _resolvedQualityPolicy() {
    final settings = _settings;
    final network = _network;
    if (settings == null || network == null) {
      return const CallQualityPolicy.normal();
    }
    final net = network.current;
    final forceAudioOnly = settings.voiceOnlyForNetwork(net);
    if (settings.dataSaverActive(net)) {
      return CallQualityPolicy.dataSaver(forceAudioOnly: forceAudioOnly);
    }
    return CallQualityPolicy.normal(forceAudioOnly: forceAudioOnly);
  }

  Future<void> _answerIncomingCallFromNotification() async {
    try {
      await acceptIncomingCall();
    } catch (error) {
      debugPrint('Could not answer incoming call: $error');
    }
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
    // Only an OUTGOING ending posts the DM call event (app.dart consumes
    // lastEndedCall) — if both sides posted it, every call would show twice.
    // History below is recorded for both directions.
    if (!ev.isIncoming) _lastEndedCall = ev;
    final hs = _historySession;
    if (hs != null) {
      _recordHistory(
        id: hs.callId,
        conversationId: ev.conversationId,
        peerUserId: hs.remoteUserId,
        peerUsername: hs.remoteUsername,
        isVideo: ev.isVideo,
        direction: hs.isIncoming
            ? CallDirection.incoming
            : CallDirection.outgoing,
        outcome: ev.answered
            ? CallOutcomeKind.answered
            : CallOutcomeKind.missed,
        startedAt: _now().subtract(Duration(seconds: ev.durationSecs)),
        durationSecs: ev.durationSecs,
      );
      _historySession = null;
    }
    notifyListeners();
  }

  /// Records a finished SFU group call (join→leave) in the device call log.
  /// Wired to [SfuCallController.onCallEnded] at the composition root —
  /// mirrors how P2P history lands via [_onCallEnded]. Joining an SFU room is
  /// an explicit user action, so it's logged as an answered outgoing call.
  void recordSfuCallEnded(SfuCallEnd end) {
    _recordHistory(
      id: end.historyId,
      conversationId: end.conversationId,
      peerUserId: null,
      peerUsername: end.title,
      isVideo: end.isVideo,
      direction: CallDirection.outgoing,
      outcome: CallOutcomeKind.answered,
      startedAt: end.joinedAt,
      durationSecs: end.durationSecs,
      sfu: true,
    );
  }

  void _recordHistory({
    required String id,
    String? conversationId,
    String? peerUserId,
    String? peerUsername,
    required bool isVideo,
    required CallDirection direction,
    required CallOutcomeKind outcome,
    required DateTime startedAt,
    int durationSecs = 0,
    bool sfu = false,
  }) {
    final svc = _callHistory;
    if (svc == null) return;
    unawaited(
      svc.record(
        CallHistoryEntry(
          id: id,
          conversationId: conversationId,
          peerUserId: peerUserId,
          peerUsername: peerUsername,
          isVideo: isVideo,
          direction: direction,
          outcome: outcome,
          startedAt: startedAt,
          sfu: sfu,
          durationSecs: durationSecs,
        ),
      ),
    );
  }

  /// Called by the app once it has recorded the ended call as a DM event.
  void clearEndedCall() => _lastEndedCall = null;

  void _onIncomingCall(CallSession incoming) {
    if (incoming.state == CallState.ended) return;
    _incomingCall = incoming;
    final kind = incoming.isVideo ? 'video' : 'voice';
    final from = incoming.remoteUsername != null
        ? ' from @${incoming.remoteUsername}'
        : '';
    unawaited(
      NotificationService.showIncomingCall(
        body: 'Incoming $kind call$from',
        conversationId: incoming.conversationId,
      ),
    );
    _syncAudio();
    notifyListeners();
  }

  void _onCancelledCall(CallSession cancelled) {
    // Answered/declined on another device — dismiss the ringing UI and its
    // notification without recording a missed call.
    if (_incomingCall?.callId == cancelled.callId) {
      _incomingCall = null;
    }
    unawaited(NotificationService.cancelIncomingCall());
    _syncAudio();
    notifyListeners();
  }

  void _onMissedCall(CallSession missed) {
    // Dismiss the ringing UI and surface the miss via an OS notification (where
    // supported) plus an in-app banner driven off [lastMissedCall].
    _incomingCall = null;
    _lastMissedCall = missed;
    _recordHistory(
      id: missed.callId,
      conversationId: missed.conversationId,
      peerUserId: missed.remoteUserId,
      peerUsername: missed.remoteUsername,
      isVideo: missed.isVideo,
      direction: CallDirection.incoming,
      outcome: CallOutcomeKind.missed,
      startedAt: _now(),
    );
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
    required String conversationId,
    required bool isVideo,
    List<String> additionalUserIds = const [],
  }) async {
    final effectiveVideo = isVideo && !_resolvedQualityPolicy().forceAudioOnly;
    await _mediaPermissionGate(isVideo: effectiveVideo);
    await _callService.startCall(
      targetUserId: targetUserId,
      targetUsername: targetUsername,
      conversationId: conversationId,
      isVideo: effectiveVideo,
      additionalUserIds: additionalUserIds,
    );
    notifyListeners();
  }

  // ---- Incoming ----

  Future<void> acceptIncomingCall() async {
    final incoming = _incomingCall;
    // Re-entry guard: the in-app "Accept" tap and the OS-notification "Answer"
    // action can both fire nearly simultaneously. Without this both would pass
    // the null check, both await the permission gate, and both build a peer for
    // the same call. _accepting is set synchronously so the second caller bails.
    if (incoming == null || _accepting) return;
    _accepting = true;
    try {
      final effectiveVideo =
          incoming.isVideo && !_resolvedQualityPolicy().forceAudioOnly;
      await _mediaPermissionGate(isVideo: effectiveVideo);
      incoming.isVideo = effectiveVideo;

      _incomingCall = null;
      unawaited(NotificationService.cancelIncomingCall());
      _syncAudio();
      notifyListeners();

      await _callService.acceptIncomingCall(incoming);
      notifyListeners();
    } finally {
      _accepting = false;
    }
  }

  void rejectIncomingCall() {
    final incoming = _incomingCall;
    if (incoming == null) return;
    _incomingCall = null;
    _recordHistory(
      id: incoming.callId,
      conversationId: incoming.conversationId,
      peerUserId: incoming.remoteUserId,
      peerUsername: incoming.remoteUsername,
      isVideo: incoming.isVideo,
      direction: CallDirection.incoming,
      outcome: CallOutcomeKind.declined,
      startedAt: _now(),
    );
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

  Future<void> startScreenShare() async {
    await _callService.startScreenShare();
    notifyListeners();
  }

  Future<void> stopScreenShare() async {
    try {
      await _callService.stopScreenShare();
    } catch (_) {}
    notifyListeners();
  }

  void hangup() {
    try {
      _callService.hangup();
    } catch (_) {}
    _incomingCall = null;
    _activeCallNotificationSessionId = null;
    _activeCallNotificationState = null;
    _activeCallNotificationMuted = null;
    unawaited(_foreground.stop());
    unawaited(NotificationService.cancelActiveCall());
    unawaited(NotificationService.cancelIncomingCall());
    // Explicitly stop audio first so the player halts even if _syncAudio's
    // _enqueue(null) is delayed or silently swallowed by the platform.
    unawaited(_audio.stop());
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
    if (enabled && session?.isVideo == true && !_callService.hasLocalVideo) {
      // First camera-on after a REMOTE video upgrade: there is no local
      // camera track to un-mute — acquiring one is the same flow as
      // upgrading (permission gate, getUserMedia, renegotiation offer).
      // _cameraEnabled flips on in upgradeToVideo() once that succeeds.
      unawaited(upgradeToVideo());
      return;
    }
    _cameraEnabled = enabled;
    try {
      _callService.setCameraEnabled(enabled);
    } catch (_) {}
    notifyListeners();
  }

  /// Whether the connected 1:1 voice call can be upgraded to video.
  bool get canUpgradeToVideo =>
      session?.isVideo == false && _callService.canUpgradeToVideo;

  /// Whether the connected mesh group call can move to the SFU. The premium
  /// gate is checked by the UI (and enforced server-side by the LiveKit
  /// token endpoint).
  bool get canEscalateToSfu =>
      session?.isGroupCall == true && session?.state == CallState.connected;

  /// Mesh calls that moved to the SFU — the app root joins the LiveKit room.
  Stream<EscalatedCall> get escalatedCalls => _callService.escalatedCalls;

  Future<void> escalateToSfu() => _callService.escalateToSfu();

  /// Whether the connected GROUP call can take an "Add people" invite. v1 is
  /// group-only — a 1:1 call stays false (escalation is deferred, see TODO #11).
  bool get canAddParticipant =>
      session?.isGroupCall == true && session?.state == CallState.connected;

  /// Dial an existing conversation member into the active group call. Errors are
  /// logged (the UI fires this unawaited and shows a "Ringing…" toast).
  Future<void> addParticipant(String userId) async {
    try {
      await _callService.addParticipant(userId: userId);
    } catch (e) {
      debugPrint('CallProvider.addParticipant failed: $e');
    }
  }

  // SFU media E2EE keys (see CallService for the distribution model).
  String? sfuKeyFor(String conversationId) =>
      _callService.sfuKeyFor(conversationId);
  String createSfuKey(String conversationId) =>
      _callService.createSfuKey(conversationId);
  Future<void> distributeSfuKey(
    String conversationId,
    Iterable<String> targetIds,
  ) => _callService.distributeSfuKey(conversationId, targetIds);
  Future<String?> requestSfuKey(
    String conversationId, {
    required List<String> fromUserIds,
  }) => _callService.requestSfuKey(conversationId, fromUserIds: fromUserIds);

  /// Turns the camera on mid-call (upgrading a voice call to video). Asks for
  /// camera permission first — the voice call never requested it.
  Future<void> upgradeToVideo() async {
    try {
      await _mediaPermissionGate(isVideo: true);
      await _callService.upgradeToVideo();
      _cameraEnabled = true;
    } catch (error) {
      debugPrint('CallProvider: video upgrade failed: $error');
    }
    _syncActiveCallNotification();
    notifyListeners();
  }

  Future<void> switchCamera() async {
    try {
      _usingFrontCamera = await _callService.switchCamera();
      _cameraEnabled = true;
    } catch (_) {}
    notifyListeners();
  }

  Future<bool> handleIncomingCallPush(Map<String, dynamic> data) async {
    final handled = await _callService.handleIncomingCallPushPayload(data);
    if (!handled) return false;
    notifyListeners();
    return true;
  }

  bool get isInCall => session != null && session!.state != CallState.ended;
  bool get isReconnecting => session?.reconnecting ?? false;

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
    if (s.reconnecting) return 'Reconnecting…';
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
    _cancelledSub?.cancel();
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
