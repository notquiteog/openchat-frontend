import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/api_service.dart';
import '../services/websocket_service.dart';

class GroupCallInfo {
  const GroupCallInfo({required this.active, required this.participantIds});
  final bool active;
  final List<String> participantIds;
}

/// Tracks which group conversations currently have a live SFU call so the chat
/// screen can show a "Join" banner. Fed by `group_call_state` WS broadcasts and
/// a REST refresh when a chat opens.
class GroupCallPresenceProvider extends ChangeNotifier {
  GroupCallPresenceProvider(this._ws, this._api) {
    _sub = _ws.events.listen(_onEvent);
  }

  final WebSocketService _ws;
  final ApiService _api;
  StreamSubscription<WsEvent>? _sub;
  final Map<String, GroupCallInfo> _byConversation = {};

  GroupCallInfo? infoFor(String conversationId) =>
      _byConversation[conversationId];

  void _onEvent(WsEvent event) {
    if (event.type != WsEventType.groupCallState) return;
    final convID = event.data['conversation_id'] as String?;
    if (convID == null) return;
    _apply(convID, event.data);
    notifyListeners();
  }

  void _apply(String conversationId, Map<String, dynamic> data) {
    final active = data['active'] == true;
    final ids = ((data['participant_ids'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    if (active && ids.isNotEmpty) {
      _byConversation[conversationId] = GroupCallInfo(
        active: true,
        participantIds: ids,
      );
    } else {
      _byConversation.remove(conversationId);
    }
  }

  /// Fetch current state when opening a chat so the banner shows without waiting
  /// for the next broadcast.
  Future<void> refresh(String conversationId) async {
    try {
      final data = await _api.getActiveCall(conversationId);
      _apply(conversationId, data);
      notifyListeners();
    } catch (_) {}
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
