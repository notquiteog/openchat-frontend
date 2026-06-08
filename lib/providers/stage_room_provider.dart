import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import '../services/api_service.dart';
import '../services/secure_storage_service.dart';
import '../services/websocket_service.dart';

/// Live state of a Voice Stage Room (audio-only LiveKit room with host /
/// speaker / listener roles + a raise-hand queue). Media runs over a [Room];
/// role + membership state comes from the backend and `stage_state` WS events.
class StageRoomProvider extends ChangeNotifier {
  StageRoomProvider(this._api, this._ws, this._storage);

  final ApiService _api;
  final WebSocketService _ws;
  final SecureStorageService _storage;
  String? _selfId;

  Room? _room;
  StreamSubscription<WsEvent>? _wsSub;

  String? _conversationId;
  String _role = 'listener';
  String? _hostId;
  List<String> _speakerIds = const [];
  List<String> _raisedHands = const [];
  int _listenerCount = 0;
  bool _connecting = false;
  bool _micEnabled = false;
  String? _error;

  String? get conversationId => _conversationId;
  bool get isActive => _room != null;
  bool get connecting => _connecting;
  String get role => _role;
  bool get isHost => _role == 'host';
  bool get canSpeak => _role == 'host' || _role == 'speaker';
  String? get hostId => _hostId;
  List<String> get speakerIds => _speakerIds;
  List<String> get raisedHands => _raisedHands;
  int get listenerCount => _listenerCount;
  bool get micEnabled => _micEnabled;
  String? get error => _error;

  Future<void> join(String conversationId) async {
    if (_connecting || _room != null) return;
    _connecting = true;
    _error = null;
    notifyListeners();
    try {
      _selfId ??= await _storage.getUserID();
      final data = await _api.joinStage(conversationId);
      final url = data['url'] as String?;
      final token = data['token'] as String?;
      _role = data['role'] as String? ?? 'listener';
      _applyState(data['state'] as Map<String, dynamic>?);
      if (url == null || token == null || url.isEmpty || token.isEmpty) {
        throw Exception('Stage room is unavailable');
      }
      final room = Room(
        roomOptions: const RoomOptions(adaptiveStream: true),
      );
      _room = room;
      _conversationId = conversationId;
      await room.connect(url, token);
      if (canSpeak) {
        await room.localParticipant?.setMicrophoneEnabled(true);
        _micEnabled = true;
      }
      _wsSub = _ws.events.listen(_onWsEvent);
    } catch (e) {
      _error = e.toString();
      await _teardown();
    }
    _connecting = false;
    notifyListeners();
  }

  Future<void> leave() async {
    final convID = _conversationId;
    await _teardown();
    if (convID != null) {
      try {
        await _api.leaveStage(convID);
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> toggleMic() async {
    if (!canSpeak || _room == null) return;
    _micEnabled = !_micEnabled;
    await _room!.localParticipant?.setMicrophoneEnabled(_micEnabled);
    notifyListeners();
  }

  Future<void> raiseHand() async {
    final c = _conversationId;
    if (c != null) await _api.raiseStageHand(c);
  }

  Future<void> lowerHand() async {
    final c = _conversationId;
    if (c != null) await _api.lowerStageHand(c);
  }

  Future<void> inviteSpeaker(String userId) async {
    final c = _conversationId;
    if (c != null && isHost) await _api.inviteStageSpeaker(c, userId);
  }

  Future<void> removeSpeaker(String userId) async {
    final c = _conversationId;
    if (c != null && isHost) await _api.removeStageSpeaker(c, userId);
  }

  void _onWsEvent(WsEvent event) {
    if (event.type != WsEventType.stageState) return;
    if (event.data['conversation_id'] != _conversationId) return;
    _applyState(event.data);
    // A promotion/demotion may have changed our publish rights — re-sync mic.
    final wasSpeaker = canSpeak;
    final newRole = _roleFromState();
    if (newRole != _role) {
      _role = newRole;
      unawaited(_syncPublish(wasSpeaker));
    }
    notifyListeners();
  }

  String _roleFromState() {
    final selfId = _selfId;
    if (selfId == null) return _role;
    if (_hostId == selfId) return 'host';
    if (_speakerIds.contains(selfId)) return 'speaker';
    return 'listener';
  }

  Future<void> _syncPublish(bool wasSpeaker) async {
    final room = _room;
    if (room == null) return;
    if (canSpeak && !wasSpeaker) {
      // Promoted: the server must also re-issue a publish token; re-join cleanly.
      final c = _conversationId;
      if (c != null) {
        try {
          final data = await _api.joinStage(c);
          final token = data['token'] as String?;
          final url = data['url'] as String?;
          if (token != null && url != null) {
            await room.disconnect();
            await room.connect(url, token);
            await room.localParticipant?.setMicrophoneEnabled(true);
            _micEnabled = true;
          }
        } catch (_) {}
      }
    } else if (!canSpeak && wasSpeaker) {
      await room.localParticipant?.setMicrophoneEnabled(false);
      _micEnabled = false;
    }
  }

  void _applyState(Map<String, dynamic>? state) {
    if (state == null) return;
    _hostId = state['host_id'] as String?;
    _speakerIds = (state['speaker_ids'] as List? ?? const [])
        .map((e) => e.toString())
        .toList();
    _raisedHands = (state['raised_hands'] as List? ?? const [])
        .map((e) => e.toString())
        .toList();
    _listenerCount = (state['listener_count'] as num? ?? 0).toInt();
  }

  Future<void> _teardown() async {
    await _wsSub?.cancel();
    _wsSub = null;
    try {
      await _room?.disconnect();
    } catch (_) {}
    _room = null;
    _conversationId = null;
    _role = 'listener';
    _hostId = null;
    _speakerIds = const [];
    _raisedHands = const [];
    _listenerCount = 0;
    _micEnabled = false;
  }

  @override
  void dispose() {
    unawaited(_teardown());
    super.dispose();
  }
}
