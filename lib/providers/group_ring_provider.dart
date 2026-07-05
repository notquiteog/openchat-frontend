import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/websocket_service.dart';

/// One active "ring everyone" group call (#9).
class GroupCallRing {
  const GroupCallRing({required this.conversationId, this.initiatorId});

  final String conversationId;
  final String? initiatorId;
}

/// Tracks ring-all group calls (#9). When a conversation opts in, the first
/// join of a group call makes the server fan a `group_call_ring` to every
/// member; this holds the current ring so the root overlay can ring + offer
/// "Join". Cleared on `group_call_ring_cancel`, when the call goes inactive, on
/// a timeout, or when the user joins/dismisses.
///
/// State only — the overlay owns the ringtone so it plays exactly while the
/// ring card is actually on screen (not when suppressed because the user is
/// already in a call).
class GroupRingProvider extends ChangeNotifier {
  GroupRingProvider(this._ws) {
    _sub = _ws.events.listen(_onEvent);
  }

  final WebSocketService _ws;
  StreamSubscription<WsEvent>? _sub;
  Timer? _timeout;
  GroupCallRing? _active;
  String? _selfId;

  /// How long a ring keeps ringing before giving up if nothing cancels it.
  static const Duration ringTimeout = Duration(seconds: 45);

  GroupCallRing? get active => _active;

  /// The local user id, so a ring echoed for the user's own call is ignored
  /// (the server already excludes the initiator; belt-and-suspenders).
  set selfId(String? id) => _selfId = id;

  void _onEvent(WsEvent event) {
    switch (event.type) {
      case WsEventType.groupCallRing:
        final convID = event.data['conversation_id'] as String?;
        if (convID == null || convID.isEmpty) return;
        final initiator = event.data['initiator_id'] as String?;
        if (initiator != null && _selfId != null && initiator == _selfId) {
          return;
        }
        _ring(GroupCallRing(conversationId: convID, initiatorId: initiator));
        break;
      case WsEventType.groupCallRingCancel:
        _clear(event.data['conversation_id'] as String?);
        break;
      case WsEventType.groupCallState:
        // The call ended (or never had participants) — stop ringing for it.
        if (event.data['active'] != true) {
          _clear(event.data['conversation_id'] as String?);
        }
        break;
      default:
        break;
    }
  }

  void _ring(GroupCallRing ring) {
    // Already ringing for this conversation: a duplicate group_call_ring must
    // NOT reset the timeout, or repeated events would extend the ring forever.
    if (_active?.conversationId == ring.conversationId) return;
    _timeout?.cancel();
    _timeout = Timer(ringTimeout, () => _clear(ring.conversationId));
    _active = ring;
    notifyListeners();
  }

  void _clear(String? convID) {
    if (convID == null || _active?.conversationId != convID) return;
    _timeout?.cancel();
    _timeout = null;
    _active = null;
    notifyListeners();
  }

  /// Dismiss the current ring (the user joined or declined it).
  void dismiss() {
    if (_active == null) return;
    _timeout?.cancel();
    _timeout = null;
    _active = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timeout?.cancel();
    super.dispose();
  }
}
