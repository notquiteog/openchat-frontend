import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config/api_config.dart';
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
  pollUpdated,
  paymentRequestUpdated,
  conversationDeleted,
  conversationUpdated,
  // WebRTC call signaling
  callOffer,
  callAnswer,
  callIceCandidate,
  callHangup,
  callReject,
  callRinging,
  error,
  unknown,
}

class WsEvent {
  final WsEventType type;
  final Map<String, dynamic> data;
  WsEvent({required this.type, required this.data});
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

  final _eventStream = StreamController<WsEvent>.broadcast();
  Stream<WsEvent> get events => _eventStream.stream;
  WsConnectionStatus get connectionStatus => _status;
  bool get isMonitoring => _status == WsConnectionStatus.connected;
  DateTime? get lastConnectedAt => _lastConnectedAt;
  DateTime? get lastEventAt => _lastEventAt;

  WebSocketService(this._storage);

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
      channel = WebSocketChannel.connect(
        Uri.parse('${ApiConfig.wsUrl}?token=$token'),
      );
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
    try {
      for (final line in raw.split('\n')) {
        if (line.trim().isEmpty) continue;
        final json = jsonDecode(line) as Map<String, dynamic>;
        final type = _parseType(json['type'] as String?);
        final data = (json['data'] as Map<String, dynamic>?) ?? {};
        if (!_eventStream.isClosed) {
          _eventStream.add(WsEvent(type: type, data: data));
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
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
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

  void sendCallOffer({
    required String targetUserId,
    required String callId,
    required String sdp,
    required bool isVideo,
    String? conversationId,
  }) {
    _send({
      'type': 'call_offer',
      'data': {
        'target_user_id': targetUserId,
        'call_id': callId,
        'sdp': sdp,
        'is_video': isVideo,
        'conversation_id': ?conversationId,
      },
    });
  }

  void sendCallAnswer({
    required String targetUserId,
    required String callId,
    required String sdp,
  }) {
    _send({
      'type': 'call_answer',
      'data': {'target_user_id': targetUserId, 'call_id': callId, 'sdp': sdp},
    });
  }

  void sendIceCandidate({
    required String targetUserId,
    required String callId,
    required Map<String, dynamic> candidate,
  }) {
    _send({
      'type': 'call_ice_candidate',
      'data': {
        'target_user_id': targetUserId,
        'call_id': callId,
        'candidate': candidate,
      },
    });
  }

  void sendCallHangup({required String targetUserId, required String callId}) {
    _send({
      'type': 'call_hangup',
      'data': {'target_user_id': targetUserId, 'call_id': callId},
    });
  }

  void sendCallReject({required String targetUserId, required String callId}) {
    _send({
      'type': 'call_reject',
      'data': {'target_user_id': targetUserId, 'call_id': callId},
    });
  }

  void sendCallRinging({required String targetUserId, required String callId}) {
    _send({
      'type': 'call_ringing',
      'data': {'target_user_id': targetUserId, 'call_id': callId},
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
    'poll_updated' => WsEventType.pollUpdated,
    'payment_request_updated' => WsEventType.paymentRequestUpdated,
    'conversation_deleted' => WsEventType.conversationDeleted,
    'conversation_updated' => WsEventType.conversationUpdated,
    'call_offer' => WsEventType.callOffer,
    'call_answer' => WsEventType.callAnswer,
    'call_ice_candidate' => WsEventType.callIceCandidate,
    'call_hangup' => WsEventType.callHangup,
    'call_reject' => WsEventType.callReject,
    'call_ringing' => WsEventType.callRinging,
    'error' => WsEventType.error,
    _ => WsEventType.unknown,
  };
}
