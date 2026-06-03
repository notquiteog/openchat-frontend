import 'dart:async';
import 'dart:convert';
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

class WebSocketService {
  final SecureStorageService _storage;
  WebSocketChannel? _channel;
  bool _connecting = false;
  Timer? _reconnectTimer;

  final _eventStream = StreamController<WsEvent>.broadcast();
  Stream<WsEvent> get events => _eventStream.stream;

  WebSocketService(this._storage);

  Future<void> connect() async {
    if (_channel != null || _connecting) return;
    _connecting = true;

    final token = await _storage.getAccessToken();
    if (token == null) {
      _connecting = false;
      return;
    }

    try {
      _channel = WebSocketChannel.connect(
        Uri.parse('${ApiConfig.wsUrl}?token=$token'),
      );
      _channel!.stream.listen(_onMessage, onError: _onError, onDone: _onDone);
      _connecting = false;
    } catch (_) {
      _connecting = false;
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    try {
      for (final line in raw.split('\n')) {
        if (line.trim().isEmpty) continue;
        final json = jsonDecode(line) as Map<String, dynamic>;
        final type = _parseType(json['type'] as String?);
        final data = (json['data'] as Map<String, dynamic>?) ?? {};
        _eventStream.add(WsEvent(type: type, data: data));
      }
    } catch (_) {}
  }

  void _onError(Object _) => _scheduleReconnect();
  void _onDone() {
    _channel = null;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), connect);
  }

  // ---- Send helpers ----

  void sendTyping(String conversationID) {
    _send({
      'type': 'typing',
      'data': {'conversation_id': conversationID},
    });
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
        if (conversationId != null) 'conversation_id': conversationId,
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

  void _send(Map<String, dynamic> payload) {
    try {
      _channel?.sink.add(jsonEncode(payload));
    } catch (_) {}
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    disconnect();
    _eventStream.close();
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
