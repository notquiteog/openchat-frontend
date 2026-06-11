import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import '../services/api_service.dart';
import '../services/secure_storage_service.dart';
import '../services/websocket_service.dart';

/// One paid, publicly-attributed super-chat on a stage. Unlike post tips
/// (anonymous aggregates), the sender's name IS the product here. [amount]
/// stays the server's decimal string — no float round-tripping.
class StageSuperchat {
  final String id;
  final String userId;
  final String name;
  final String provider;
  final String amount;
  final String message;
  final DateTime at;

  const StageSuperchat({
    required this.id,
    required this.userId,
    required this.name,
    required this.provider,
    required this.amount,
    required this.message,
    required this.at,
  });

  static StageSuperchat? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    return StageSuperchat(
      id: id,
      userId: raw['user_id']?.toString() ?? '',
      name: raw['name']?.toString() ?? '',
      provider: raw['provider']?.toString() ?? '',
      amount: raw['amount']?.toString() ?? '0',
      message: raw['message']?.toString() ?? '',
      at: DateTime.fromMillisecondsSinceEpoch(
        ((raw['at'] as num?)?.toInt() ?? 0) * 1000,
      ),
    );
  }
}

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
  Timer? _heartbeat;

  String? _conversationId;
  String _role = 'listener';
  String? _hostId;
  List<String> _speakerIds = const [];
  List<String> _raisedHands = const [];
  int _listenerCount = 0;
  bool _connecting = false;
  bool _micEnabled = false;
  String? _error;
  List<StageSuperchat> _superchats = const [];
  bool _superchatsPrimed = false;
  final Set<String> _seenSuperchatIds = {};
  // Fresh super-chats only (each id announced once) — the screen turns these
  // into transient highlight banners; [superchats] keeps the recent backlog.
  final StreamController<StageSuperchat> _superchatAnnouncements =
      StreamController.broadcast();

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
  List<StageSuperchat> get superchats => _superchats;
  Stream<StageSuperchat> get superchatAnnouncements =>
      _superchatAnnouncements.stream;

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
      // Heartbeat: re-join periodically so the server can prune crashed
      // participants (and tear down a stage whose host vanished) instead of
      // keeping the room "active" for the full key TTL.
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 60), (_) {
        final c = _conversationId;
        if (c != null && _room != null) {
          unawaited(_api.joinStage(c).catchError((_) => <String, dynamic>{}));
        }
      });
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

  /// Sends a paid super-chat to the host and applies the returned state (the
  /// broadcast also arrives over WS — _applyState dedups by entry id).
  Future<void> sendSuperchat({
    required String provider,
    required double amount,
    required String message,
  }) async {
    final c = _conversationId;
    if (c == null) throw StateError('not in a stage room');
    final data = await _api.sendStageSuperchat(
      c,
      provider: provider,
      amount: amount,
      message: message,
    );
    _applyState(data['state'] as Map<String, dynamic>?);
    notifyListeners();
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

  @visibleForTesting
  void debugApplyState(Map<String, dynamic> state) => _applyState(state);

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
    if (state.containsKey('superchats')) {
      final entries = (state['superchats'] as List? ?? const [])
          .map(StageSuperchat.fromJson)
          .whereType<StageSuperchat>()
          .toList(growable: false);
      // The first state after joining seeds the backlog silently — those
      // super-chats predate us. Later applies announce unseen ids,
      // oldest-first so banner order matches arrival order.
      for (final sc in entries.reversed) {
        if (_seenSuperchatIds.add(sc.id) && _superchatsPrimed) {
          _superchatAnnouncements.add(sc);
        }
      }
      _superchatsPrimed = true;
      _superchats = entries;
    }
  }

  Future<void> _teardown() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    await _wsSub?.cancel();
    _wsSub = null;
    final room = _room;
    _room = null;
    try {
      await room?.disconnect();
    } catch (_) {}
    // Dispose like SfuCallController does — disconnect alone leaks the native
    // room resources across repeated stage joins.
    try {
      await room?.dispose();
    } catch (_) {}
    _conversationId = null;
    _role = 'listener';
    _hostId = null;
    _speakerIds = const [];
    _raisedHands = const [];
    _listenerCount = 0;
    _micEnabled = false;
    _superchats = const [];
    _superchatsPrimed = false;
    _seenSuperchatIds.clear();
  }

  @override
  void dispose() {
    unawaited(_teardown());
    unawaited(_superchatAnnouncements.close());
    super.dispose();
  }
}
