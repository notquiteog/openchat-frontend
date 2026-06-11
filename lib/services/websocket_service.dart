import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config/api_config.dart';
import '../services/proxy_service.dart';
import '../services/secure_storage_service.dart';

enum WsEventType {
  newMessage,
  typing,
  readReceipt,
  memberJoined,
  memberLeft,
  userOnline,
  userOffline,
  messageDeleted,
  messageEdited,
  messageReaction,
  // Anonymous tip aggregates changed for a message (carries the full list).
  messageTipped,
  pollUpdated,
  paymentRequestUpdated,
  // User-scoped on-chain deposit confirmation progress (owner only).
  depositProgress,
  conversationDeleted,
  conversationUpdated,
  // WebRTC call signaling
  callOffer,
  callAnswer,
  callIceCandidate,
  callHangup,
  callReject,
  callRinging,
  // Server-generated: this user answered/declined on another device.
  callCancel,
  // A mesh-call participant asked everyone to move to the SFU.
  callEscalate,
  // SFU media frame-key exchange (key rides inside encrypted_signal only).
  callE2EEKey,
  callE2EEKeyRequest,
  groupCallJoin,
  groupCallLeave,
  groupCallState,
  stageState,
  gameUpdated,
  // A pending join request, delivered only to members who can approve it.
  joinRequest,
  // A PGP-signed remote-wipe command for one of this account's sessions.
  deviceWipe,
  // Social recovery: a contact you guard opened a ceremony / a guardian
  // submitted a share to your ceremony.
  recoveryRequest,
  recoveryShare,
  // Server: the replay buffer can't bridge our last_seq — do a full refetch.
  resyncRequired,
  // Server: one broadcast conversation's replay window couldn't bridge our
  // conv_seq — refetch just that conversation (data carries conversation_id).
  convResyncRequired,
  error,
  unknown,
}

class WsEvent {
  final WsEventType type;
  final Map<String, dynamic> data;

  /// Per-user monotonic sequence number for durable events (0 = ephemeral).
  /// Used for reconnect resume and duplicate dropping only — live delivery
  /// may be out of order across server instances.
  final int seq;

  /// Broadcast-conversation stream id + per-conversation sequence number.
  /// Set only on events from conversations the server promoted to broadcast
  /// fanout; such events never carry (or consume) a per-user [seq]. Unlike
  /// [seq], cseq IS a real per-conversation ordering signal — a gap in it
  /// means a missed event worth a targeted refetch.
  final String? cid;
  final int cseq;

  WsEvent({
    required this.type,
    required this.data,
    this.seq = 0,
    this.cid,
    this.cseq = 0,
  });
}

enum WsConnectionStatus { disconnected, connecting, connected }

class WebSocketService extends ChangeNotifier {
  final SecureStorageService _storage;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  bool _connecting = false;
  bool _shouldReconnect = false;
  bool _disposed = false;
  int _connectSerial = 0;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  WsConnectionStatus _status = WsConnectionStatus.disconnected;
  DateTime? _lastConnectedAt;
  DateTime? _lastEventAt;
  final List<Map<String, dynamic>> _pendingSends = [];

  static const int _maxPendingSends = 40;
  static const Duration _connectTimeout = Duration(seconds: 10);
  static const String _lastSeqPrefsKey = 'ws_last_seq';
  static const int _dedupeWindow = 256;

  // Sequence-number resume state. lastSeq is the highest durable-event seq
  // seen; on reconnect the server replays everything after it (or sends
  // resync_required when its buffer can't bridge the gap).
  int _lastSeq = 0;
  bool _lastSeqLoaded = false;
  final Queue<int> _recentSeqOrder = Queue<int>();
  final Set<int> _recentSeqs = <int>{};

  // Broadcast-conversation resume state: highest cseq per conversation plus a
  // small per-conversation dedup window, mirroring the per-user machinery.
  // These never touch _lastSeq — broadcast events don't consume user seqs.
  static const String _convSeqsPrefsKey = 'ws_conv_seqs';
  static const int _convDedupeWindow = 128;
  final Map<String, int> _convSeqs = {};
  final Map<String, Set<int>> _recentConvSeqs = {};
  final Map<String, Queue<int>> _recentConvSeqOrder = {};
  final math.Random _reconnectJitter = math.Random();

  final _eventStream = StreamController<WsEvent>.broadcast();
  Stream<WsEvent> get events => _eventStream.stream;
  WsConnectionStatus get connectionStatus => _status;
  bool get isMonitoring => _status == WsConnectionStatus.connected;
  DateTime? get lastConnectedAt => _lastConnectedAt;
  DateTime? get lastEventAt => _lastEventAt;

  /// Highest durable-event sequence number seen for this account.
  int get lastSeq => _lastSeq;

  WebSocketService(this._storage);

  Future<void> _ensureLastSeqLoaded() async {
    if (_lastSeqLoaded) return;
    _lastSeqLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _lastSeq = math.max(_lastSeq, prefs.getInt(_lastSeqPrefsKey) ?? 0);
      final rawConvSeqs = prefs.getString(_convSeqsPrefsKey);
      if (rawConvSeqs != null && rawConvSeqs.isNotEmpty) {
        final decoded = jsonDecode(rawConvSeqs);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            final seq = (value as num?)?.toInt() ?? 0;
            final existing = _convSeqs[key.toString()] ?? 0;
            if (seq > existing) _convSeqs[key.toString()] = seq;
          });
        }
      }
    } catch (_) {}
  }

  /// Forgets the resume position (logout / account switch) — the next
  /// connect starts fresh instead of resuming another account's stream.
  Future<void> resetSequence() async {
    _lastSeq = 0;
    _recentSeqs.clear();
    _recentSeqOrder.clear();
    _convSeqs.clear();
    _recentConvSeqs.clear();
    _recentConvSeqOrder.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_lastSeqPrefsKey);
      await prefs.remove(_convSeqsPrefsKey);
    } catch (_) {}
  }

  /// True when this seq was already delivered (duplicate from a replay
  /// racing live delivery). Tracks a small recent window — live events can
  /// arrive slightly out of order across server instances, so anything not
  /// recently seen is accepted even if its seq is below lastSeq.
  bool _isDuplicateSeq(int seq) {
    if (seq <= 0) return false;
    if (_recentSeqs.contains(seq)) return true;
    _recentSeqs.add(seq);
    _recentSeqOrder.addLast(seq);
    while (_recentSeqOrder.length > _dedupeWindow) {
      _recentSeqs.remove(_recentSeqOrder.removeFirst());
    }
    if (seq > _lastSeq) {
      _lastSeq = seq;
      unawaited(_persistLastSeq());
    }
    return false;
  }

  DateTime _lastSeqPersistedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _persistLastSeq() async {
    // Throttle disk writes; the exact value only matters on the next launch,
    // and an older persisted seq just replays a few duplicate events.
    final now = DateTime.now();
    if (now.difference(_lastSeqPersistedAt) < const Duration(seconds: 2)) {
      return;
    }
    _lastSeqPersistedAt = now;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lastSeqPrefsKey, _lastSeq);
    } catch (_) {}
  }

  /// True when this (conversation, cseq) pair was already delivered. Mirrors
  /// [_isDuplicateSeq] but per conversation, and never touches [_lastSeq].
  bool _isDuplicateConvSeq(String cid, int cseq) {
    if (cseq <= 0) return false;
    final seen = _recentConvSeqs.putIfAbsent(cid, () => <int>{});
    if (seen.contains(cseq)) return true;
    final order = _recentConvSeqOrder.putIfAbsent(cid, Queue<int>.new);
    seen.add(cseq);
    order.addLast(cseq);
    while (order.length > _convDedupeWindow) {
      seen.remove(order.removeFirst());
    }
    if (cseq > (_convSeqs[cid] ?? 0)) {
      _convSeqs[cid] = cseq;
      unawaited(_persistConvSeqs());
    }
    return false;
  }

  DateTime _convSeqsPersistedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _persistConvSeqs() async {
    final now = DateTime.now();
    if (now.difference(_convSeqsPersistedAt) < const Duration(seconds: 2)) {
      return;
    }
    _convSeqsPersistedAt = now;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_convSeqsPrefsKey, jsonEncode(_convSeqs));
    } catch (_) {}
  }

  /// Highest broadcast-conversation sequence seen, keyed by conversation id.
  Map<String, int> get convSeqs => Map.unmodifiable(_convSeqs);

  Future<void> connect() async {
    if (_disposed) return;
    _shouldReconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_channel != null || _connecting) return;
    _connecting = true;
    _setStatus(WsConnectionStatus.connecting);

    final token = await _storage.getAccessToken();
    if (_disposed || !_shouldReconnect) {
      _connecting = false;
      _setStatus(WsConnectionStatus.disconnected);
      return;
    }
    if (token == null) {
      _connecting = false;
      _shouldReconnect = false;
      _setStatus(WsConnectionStatus.disconnected);
      return;
    }

    final connectSerial = ++_connectSerial;
    WebSocketChannel? channel;
    StreamSubscription<dynamic>? subscription;
    try {
      final wsUri = Uri.parse(ApiConfig.wsUrl);
      final protocols = ['openchat.v1', 'openchat.jwt.$token'];
      // Route the socket through the proxy when one is configured; otherwise use
      // the default lazy connection.
      channel =
          await ProxyService.instance.connectWebSocket(
            wsUri,
            protocols: protocols,
          ) ??
          WebSocketChannel.connect(wsUri, protocols: protocols);
      _channel = channel;
      subscription = channel.stream.listen(
        (raw) => _onMessage(raw, channel!),
        onError: (error) => _onError(error, channel!),
        onDone: () => _onDone(channel!),
      );
      _channelSub = subscription;
      await channel.ready.timeout(_connectTimeout);
      if (_disposed ||
          !_shouldReconnect ||
          _connectSerial != connectSerial ||
          !identical(_channel, channel)) {
        await channel.sink.close();
        return;
      }
      _connecting = false;
      _reconnectAttempt = 0;
      _lastConnectedAt = DateTime.now();
      _setStatus(WsConnectionStatus.connected);
      // Resume FIRST: the server replays durable events missed while offline
      // (or answers resync_required) before any queued sends go out. A fresh
      // client (lastSeq 0) skips this — its initial REST load covers it.
      await _ensureLastSeqLoaded();
      if (_lastSeq > 0) {
        final resume = <String, dynamic>{'last_seq': _lastSeq};
        // Broadcast-conversation resume positions ride along; servers that
        // don't know the field ignore it.
        if (_convSeqs.isNotEmpty) {
          resume['conv_seqs'] = Map<String, int>.from(_convSeqs);
        }
        _trySendNow({'type': 'resume', 'data': resume});
      }
      _flushPendingSends();
    } catch (_) {
      if (channel != null && identical(_channel, channel)) {
        try {
          await channel.sink.close();
        } catch (_) {}
        _channel = null;
        if (identical(_channelSub, subscription)) {
          await subscription?.cancel();
          _channelSub = null;
        }
      }
      _connecting = false;
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw, WebSocketChannel channel) {
    if (_disposed) return;
    if (!identical(_channel, channel)) return;
    if (raw is! String) return;
    _lastEventAt = DateTime.now();
    handleRawFrame(raw);
  }

  /// Parses one WebSocket frame (possibly several newline-batched events)
  /// into the event stream. Visible for tests — the network path can't run
  /// in unit tests.
  @visibleForTesting
  void handleRawFrame(String raw) {
    try {
      for (final line in raw.split('\n')) {
        if (line.trim().isEmpty) continue;
        final json = jsonDecode(line) as Map<String, dynamic>;
        final type = _parseType(json['type'] as String?);
        final data = (json['data'] as Map<String, dynamic>?) ?? {};
        // Broadcast-conversation events carry cid/cseq instead of a per-user
        // seq; they get their own per-conversation dedup window and never
        // advance _lastSeq.
        final cid = json['cid'] as String?;
        final cseq = (json['cseq'] as num?)?.toInt() ?? 0;
        if (cid != null && cid.isNotEmpty && cseq > 0) {
          if (_isDuplicateConvSeq(cid, cseq)) continue;
          if (!_eventStream.isClosed) {
            _eventStream.add(WsEvent(type: type, data: data, cid: cid, cseq: cseq));
          }
          continue;
        }
        final seq = (json['seq'] as num?)?.toInt() ?? 0;
        // Replay racing live delivery can duplicate an event; drop repeats.
        if (_isDuplicateSeq(seq)) continue;
        if (!_eventStream.isClosed) {
          _eventStream.add(WsEvent(type: type, data: data, seq: seq));
        }
      }
    } catch (_) {}
  }

  void _onError(Object _, WebSocketChannel channel) {
    if (_disposed) return;
    if (!identical(_channel, channel)) return;
    _channel = null;
    _channelSub = null;
    _connecting = false;
    _scheduleReconnect();
  }

  void _onDone(WebSocketChannel channel) {
    if (_disposed) return;
    if (!identical(_channel, channel)) return;
    _channel = null;
    _channelSub = null;
    _connecting = false;
    if (_shouldReconnect) {
      _scheduleReconnect();
    } else {
      _setStatus(WsConnectionStatus.disconnected);
    }
  }

  void _scheduleReconnect() {
    if (_disposed || !_shouldReconnect) {
      _setStatus(WsConnectionStatus.disconnected);
      return;
    }
    _setStatus(WsConnectionStatus.connecting);
    _reconnectTimer?.cancel();
    final seconds = math.min(15, 1 << math.min(_reconnectAttempt, 3));
    _reconnectAttempt += 1;
    // Jitter spreads a fleet of clients reconnecting after a server restart
    // across ~a second per step instead of a synchronized thundering herd.
    final delay = Duration(
      seconds: seconds,
      milliseconds: _reconnectJitter.nextInt(1000),
    );
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(connect());
    });
  }

  void _setStatus(WsConnectionStatus status) {
    if (_status == status) return;
    _status = status;
    if (!_disposed) notifyListeners();
  }

  void _queueSend(Map<String, dynamic> payload) {
    if (_pendingSends.length >= _maxPendingSends) {
      _pendingSends.removeAt(0);
    }
    _pendingSends.add(payload);
  }

  void _flushPendingSends() {
    if (_pendingSends.isEmpty || !isMonitoring) return;
    final pending = List<Map<String, dynamic>>.from(_pendingSends);
    _pendingSends.clear();
    for (var i = 0; i < pending.length; i += 1) {
      if (!_trySendNow(pending[i])) {
        _pendingSends.insertAll(0, pending.skip(i));
        return;
      }
    }
  }

  bool _trySendNow(Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null || !isMonitoring) return false;
    try {
      channel.sink.add(jsonEncode(payload));
      return true;
    } catch (_) {
      _channel = null;
      _channelSub?.cancel();
      _channelSub = null;
      _connecting = false;
      _scheduleReconnect();
      return false;
    }
  }

  // ---- Send helpers ----

  void sendTyping(String conversationID) {
    _send({
      'type': 'typing',
      'data': {'conversation_id': conversationID},
    }, queueIfOffline: false);
  }

  void sendCallOfferPayload(Map<String, dynamic> data) {
    _send({'type': 'call_offer', 'data': data});
  }

  void sendCallAnswer(Map<String, dynamic> data) {
    _send({'type': 'call_answer', 'data': data});
  }

  /// Announce joining (also used as a periodic heartbeat) / leaving an active
  /// group SFU call so the server can broadcast the conversation's call state.
  void sendGroupCallJoin(String conversationId) {
    _send({
      'type': 'group_call_join',
      'data': {'conversation_id': conversationId},
    });
  }

  void sendGroupCallLeave(String conversationId) {
    _send({
      'type': 'group_call_leave',
      'data': {'conversation_id': conversationId},
    }, queueIfOffline: false);
  }

  void sendCallIceCandidate({
    required String targetUserId,
    required String conversationId,
    required String callId,
    required String candidate,
    required String sdpMid,
    required int sdpMLineIndex,
  }) {
    if (conversationId.trim().isEmpty) return;
    _send({
      'type': 'call_ice_candidate',
      'data': {
        'target_user_id': targetUserId,
        'conversation_id': conversationId,
        'call_id': callId,
        'candidate': candidate,
        'sdp_mid': sdpMid,
        'sdp_mline_index': sdpMLineIndex,
      },
    }, queueIfOffline: false);
  }

  void sendCallHangup({
    required String targetUserId,
    required String conversationId,
    required String callId,
  }) {
    if (conversationId.trim().isEmpty) return;
    _send({
      'type': 'call_hangup',
      'data': {
        'target_user_id': targetUserId,
        'conversation_id': conversationId,
        'call_id': callId,
      },
    });
  }

  void sendCallReject({
    required String targetUserId,
    required String conversationId,
    required String callId,
    String? reason,
  }) {
    if (conversationId.trim().isEmpty) return;
    _send({
      'type': 'call_reject',
      'data': {
        'target_user_id': targetUserId,
        'conversation_id': conversationId,
        'call_id': callId,
        // 'busy' vs absent (= declined) lets the caller tell the two apart.
        'reason': ?reason,
      },
    });
  }

  /// Relays a mesh→SFU escalation signal to one mesh peer (encoded payload,
  /// same per-target relay as hangup).
  void sendCallEscalate(Map<String, dynamic> data) {
    _send({'type': 'call_escalate', 'data': data});
  }

  /// Relays an SFU media frame key to one conversation member. The key is
  /// inside the encoded payload's encrypted_signal — opaque to the server.
  void sendCallE2EEKey(Map<String, dynamic> data) {
    _send({'type': 'call_e2ee_key', 'data': data});
  }

  /// Asks one current call participant for the SFU media frame key (used by a
  /// joiner who wasn't online when the key was distributed).
  void sendCallE2EEKeyRequest(Map<String, dynamic> data) {
    _send({'type': 'call_e2ee_key_request', 'data': data});
  }

  void sendCallRinging({
    required String targetUserId,
    required String conversationId,
    required String callId,
  }) {
    if (conversationId.trim().isEmpty) return;
    _send({
      'type': 'call_ringing',
      'data': {
        'target_user_id': targetUserId,
        'conversation_id': conversationId,
        'call_id': callId,
      },
    });
  }

  void _send(Map<String, dynamic> payload, {bool queueIfOffline = true}) {
    if (_trySendNow(payload)) return;
    if (queueIfOffline) _queueSend(payload);
    if (_shouldReconnect) {
      unawaited(connect());
    }
  }

  void disconnect() {
    _shouldReconnect = false;
    _connecting = false;
    _connectSerial += 1;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pendingSends.clear();
    final channel = _channel;
    _channel = null;
    _channelSub?.cancel();
    _channelSub = null;
    try {
      channel?.sink.close();
    } catch (_) {}
    _setStatus(WsConnectionStatus.disconnected);
  }

  @visibleForTesting
  void debugSetConnectionStatus(WsConnectionStatus status) {
    _setStatus(status);
  }

  @override
  void dispose() {
    _disposed = true;
    disconnect();
    _eventStream.close();
    super.dispose();
  }

  WsEventType _parseType(String? type) => switch (type) {
    'new_message' => WsEventType.newMessage,
    'typing' => WsEventType.typing,
    'read_receipt' => WsEventType.readReceipt,
    'member_joined' => WsEventType.memberJoined,
    'member_left' => WsEventType.memberLeft,
    'user_online' => WsEventType.userOnline,
    'user_offline' => WsEventType.userOffline,
    'message_deleted' => WsEventType.messageDeleted,
    'message_edited' => WsEventType.messageEdited,
    'message_reaction' => WsEventType.messageReaction,
    'message_tipped' => WsEventType.messageTipped,
    'poll_updated' => WsEventType.pollUpdated,
    'payment_request_updated' => WsEventType.paymentRequestUpdated,
    'deposit_progress' => WsEventType.depositProgress,
    'conversation_deleted' => WsEventType.conversationDeleted,
    'conversation_updated' => WsEventType.conversationUpdated,
    'call_offer' => WsEventType.callOffer,
    'call_answer' => WsEventType.callAnswer,
    'call_ice_candidate' => WsEventType.callIceCandidate,
    'call_hangup' => WsEventType.callHangup,
    'call_reject' => WsEventType.callReject,
    'call_ringing' => WsEventType.callRinging,
    'call_cancel' => WsEventType.callCancel,
    'call_escalate' => WsEventType.callEscalate,
    'call_e2ee_key' => WsEventType.callE2EEKey,
    'call_e2ee_key_request' => WsEventType.callE2EEKeyRequest,
    'group_call_join' => WsEventType.groupCallJoin,
    'group_call_leave' => WsEventType.groupCallLeave,
    'group_call_state' => WsEventType.groupCallState,
    'stage_state' => WsEventType.stageState,
    'game_updated' => WsEventType.gameUpdated,
    'join_request' => WsEventType.joinRequest,
    'device_wipe' => WsEventType.deviceWipe,
    'recovery_request' => WsEventType.recoveryRequest,
    'recovery_share' => WsEventType.recoveryShare,
    'resync_required' => WsEventType.resyncRequired,
    'conv_resync_required' => WsEventType.convResyncRequired,
    'error' => WsEventType.error,
    _ => WsEventType.unknown,
  };
}
