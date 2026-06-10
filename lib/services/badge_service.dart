import 'dart:async';

import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';

/// Pure badge arithmetic: unread across [conversations], skipping archived and
/// muted ones. Top-level so it is unit-testable (ChatProvider can't be
/// constructed in tests).
int computeUnreadBadgeTotal({
  required List<Conversation> conversations,
  required Set<String> archivedIds,
  required bool Function(String convId) isMuted,
}) {
  var total = 0;
  for (final conv in conversations) {
    if (conv.unreadCount <= 0) continue;
    if (archivedIds.contains(conv.id)) continue;
    if (isMuted(conv.id)) continue;
    total += conv.unreadCount;
  }
  return total;
}

/// SharedPreferences keys shared with the FCM background isolate: the isolate
/// bumps an increment on top of the last total this service published; the
/// next foreground recompute overwrites both with the authoritative number.
const String badgeLastTotalPrefsKey = 'badge_last_total';
const String badgeBackgroundIncrementPrefsKey = 'badge_bg_increment';

/// Computes the launcher/tray unread badge from client state.
///
/// The badge is client-computed by design: push payloads carry only opaque
/// route tokens, so the server never knows (and is never told) per-user unread
/// counts. Source of truth is [ChatProvider]'s conversation list, minus muted
/// and archived conversations.
class BadgeService {
  BadgeService({
    Future<void> Function(int count)? applyPlatformBadge,
    // ignore: prefer_initializing_formals — keeps both appliers symmetric.
    Future<void> Function(bool unread, int count)? applyTrayBadge,
  }) : _applyPlatformBadge = applyPlatformBadge ?? _defaultPlatformBadge,
       // ignore: prefer_initializing_formals
       _applyTrayBadge = applyTrayBadge;

  final Future<void> Function(int count) _applyPlatformBadge;

  /// Desktop tray hook (icon swap + tooltip); injected by DesktopStartupService
  /// where a tray exists, left null elsewhere.
  Future<void> Function(bool unread, int count)? _applyTrayBadge;

  ChatProvider? _chat;
  SettingsProvider? _settings;
  Timer? _debounce;
  int? _lastPublished;
  bool _disposed = false;

  static Future<void> _defaultPlatformBadge(int count) async {
    if (kIsWeb) return;
    try {
      if (await AppBadgePlus.isSupported()) {
        await AppBadgePlus.updateBadge(count);
      }
    } catch (_) {
      // Launcher badges are best-effort (many Android launchers lack them).
    }
  }

  set trayBadgeApplier(Future<void> Function(bool unread, int count)? fn) {
    _applyTrayBadge = fn;
    _lastPublished = null; // force re-publish through the new applier
    _scheduleRecompute();
  }

  void attach(ChatProvider chat, SettingsProvider settings) {
    detach();
    _chat = chat;
    _settings = settings;
    chat.addListener(_scheduleRecompute);
    settings.addListener(_scheduleRecompute);
    _scheduleRecompute();
  }

  void detach() {
    _chat?.removeListener(_scheduleRecompute);
    _settings?.removeListener(_scheduleRecompute);
    _chat = null;
    _settings = null;
    _debounce?.cancel();
    _debounce = null;
  }

  void dispose() {
    _disposed = true;
    detach();
  }

  /// Total unread across the inbox, excluding muted and archived
  /// conversations — matching what the user would see as notification-worthy.
  int computeTotalUnread() {
    final chat = _chat;
    final settings = _settings;
    if (chat == null || settings == null) return 0;
    return computeUnreadBadgeTotal(
      conversations: chat.conversations,
      archivedIds: settings.archivedConversationIds,
      isMuted: settings.isConversationMuted,
    );
  }

  void _scheduleRecompute() {
    if (_disposed) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _debounce = null;
      unawaited(_publish());
    });
  }

  Future<void> _publish() async {
    if (_disposed) return;
    final total = computeTotalUnread();
    if (total == _lastPublished) return;
    _lastPublished = total;
    await _applyPlatformBadge(total);
    final tray = _applyTrayBadge;
    if (tray != null) {
      try {
        await tray(total > 0, total);
      } catch (_) {}
    }
    // Authoritative recompute resets the background isolate's bookkeeping.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(badgeLastTotalPrefsKey, total);
      await prefs.setInt(badgeBackgroundIncrementPrefsKey, 0);
    } catch (_) {}
  }

  /// Best-effort bump from the FCM background isolate (app terminated or
  /// backgrounded): last published total + running increment. Overwritten by
  /// the next foreground recompute.
  static Future<void> incrementFromBackground() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // The isolate may hold a stale cache of values written by the app.
      await prefs.reload();
      final base = prefs.getInt(badgeLastTotalPrefsKey) ?? 0;
      final increment = (prefs.getInt(badgeBackgroundIncrementPrefsKey) ?? 0) + 1;
      await prefs.setInt(badgeBackgroundIncrementPrefsKey, increment);
      await _defaultPlatformBadge(base + increment);
    } catch (_) {}
  }
}
