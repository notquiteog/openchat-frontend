import '../models/bot_command.dart';
import '../models/conversation.dart';

class MentionRange {
  final int start;
  final int end;
  final String handle;

  const MentionRange({
    required this.start,
    required this.end,
    required this.handle,
  });
}

class ActiveMentionQuery {
  final int start;
  final int end;
  final String query;

  const ActiveMentionQuery({
    required this.start,
    required this.end,
    required this.query,
  });
}

final _mentionPattern = RegExp(r'@[A-Za-z0-9_]{3,32}');
final _wordCharPattern = RegExp(r'[A-Za-z0-9_]');

/// A broadcast mention (@everyone / @all / @admins) — not tied to one member.
class SpecialMention {
  final String handle; // 'everyone' | 'all' | 'admins'
  final String label;
  final String description;
  const SpecialMention({
    required this.handle,
    required this.label,
    required this.description,
  });
}

const List<SpecialMention> kSpecialMentions = [
  SpecialMention(
    handle: 'everyone',
    label: '@everyone',
    description: 'Notify everyone',
  ),
  SpecialMention(handle: 'all', label: '@all', description: 'Notify everyone'),
  SpecialMention(
    handle: 'admins',
    label: '@admins',
    description: 'Notify admins & moderators',
  ),
];

/// Special mentions matching the active query, when the user is allowed to use
/// them (groups/channels). Returns [] for DMs or no active query.
List<SpecialMention> specialMentionSuggestions({
  required ActiveMentionQuery? active,
  required bool allowed,
}) {
  if (active == null || !allowed) return const [];
  final q = active.query.toLowerCase();
  return kSpecialMentions
      .where((m) => q.isEmpty || m.handle.startsWith(q))
      .toList();
}

/// True if the text contains an @everyone / @all broadcast mention.
bool textMentionsBroadcast(String text) {
  return findMentionRanges(text).any((r) {
    final h = r.handle.toLowerCase();
    return h == 'everyone' || h == 'all';
  });
}

/// True if the text contains an @admins mention.
bool textMentionsAdmins(String text) =>
    findMentionRanges(text).any((r) => r.handle.toLowerCase() == 'admins');

List<MentionRange> findMentionRanges(String text) {
  final ranges = <MentionRange>[];
  for (final match in _mentionPattern.allMatches(text)) {
    final start = match.start;
    final end = match.end;
    final hasLeftBoundary =
        start == 0 || !_wordCharPattern.hasMatch(text[start - 1]);
    final hasRightBoundary =
        end == text.length || !_wordCharPattern.hasMatch(text[end]);
    if (!hasLeftBoundary || !hasRightBoundary) continue;
    ranges.add(
      MentionRange(
        start: start,
        end: end,
        handle: text.substring(start + 1, end),
      ),
    );
  }
  return ranges;
}

bool textMentionsUsername(String text, String username) {
  final normalized = username.trim().toLowerCase();
  if (normalized.isEmpty) return false;
  return findMentionRanges(
    text,
  ).any((range) => range.handle.toLowerCase() == normalized);
}

List<String> mentionedMemberIdsInText(
  String text,
  Iterable<ConversationMember> members, {
  String currentUserId = '',
}) {
  final handles = findMentionRanges(
    text,
  ).map((range) => range.handle.toLowerCase()).toSet();
  if (handles.isEmpty) return const [];

  final ids = <String>[];
  final seen = <String>{};
  for (final member in members) {
    if (member.userId == currentUserId) continue;
    final username = member.user?.username.trim().toLowerCase();
    if (username == null || username.isEmpty || !handles.contains(username)) {
      continue;
    }
    if (seen.add(member.userId)) ids.add(member.userId);
  }
  return ids;
}

ActiveMentionQuery? findActiveMentionQuery(String text, int cursorOffset) {
  if (cursorOffset < 0 || cursorOffset > text.length) return null;

  var trigger = cursorOffset - 1;
  while (trigger >= 0 && _wordCharPattern.hasMatch(text[trigger])) {
    trigger--;
  }

  if (trigger < 0 || text[trigger] != '@') return null;
  final hasLeftBoundary =
      trigger == 0 || !_wordCharPattern.hasMatch(text[trigger - 1]);
  if (!hasLeftBoundary) return null;

  var end = cursorOffset;
  while (end < text.length && _wordCharPattern.hasMatch(text[end])) {
    end++;
  }

  final query = text.substring(trigger + 1, cursorOffset);
  if (query.length > 32 || end - trigger > 33) return null;
  return ActiveMentionQuery(start: trigger, end: end, query: query);
}

// ── Bot slash-commands (#31) ─────────────────────────────────────────────────

final _whitespacePattern = RegExp(r'\s');

class ActiveCommandQuery {
  final int start;
  final int end;
  final String query;

  const ActiveCommandQuery({
    required this.start,
    required this.end,
    required this.query,
  });
}

/// Matches a leading `/command` token, active ONLY when it is the first token of
/// the composer and the cursor sits within it (Telegram only autocompletes
/// commands at message start, unlike `@` mentions which match anywhere).
ActiveCommandQuery? findActiveCommandQuery(String text, int cursorOffset) {
  if (cursorOffset < 0 || cursorOffset > text.length) return null;
  if (text.isEmpty || text[0] != '/') return null;
  var end = 1;
  while (end < text.length && !_whitespacePattern.hasMatch(text[end])) {
    end++;
  }
  // Only while the cursor is inside the leading command token.
  if (cursorOffset > end) return null;
  final query = text.substring(1, end);
  if (query.length > 32) return null;
  return ActiveCommandQuery(start: 0, end: end, query: query);
}

List<BotCommand> commandSuggestions({
  required Iterable<BotCommand> commands,
  required ActiveCommandQuery? active,
  int limit = 8,
}) {
  if (active == null) return const [];
  final q = active.query.toLowerCase();
  final list = commands.where((c) => c.command.isNotEmpty).toList();
  final filtered = q.isEmpty
      ? list
      : list.where((c) => c.command.toLowerCase().startsWith(q)).toList();
  filtered.sort((a, b) => a.command.compareTo(b.command));
  return filtered.take(limit).toList();
}

List<ConversationMember> mentionSuggestionsForMembers({
  required Iterable<ConversationMember> members,
  required ActiveMentionQuery? active,
  required String currentUserId,
  int limit = 6,
}) {
  if (active == null) return const [];

  final allMembers = members
      .where((m) => m.user != null && m.user!.username.trim().isNotEmpty)
      .toList();
  if (allMembers.isEmpty) return const [];

  var candidates = allMembers.where((m) => m.userId != currentUserId).toList();
  if (candidates.isEmpty) candidates = allMembers;

  final query = active.query.toLowerCase();
  if (query.isNotEmpty) {
    candidates = candidates
        .where((m) => m.user!.username.toLowerCase().contains(query))
        .toList();
  }

  candidates.sort((a, b) {
    final left = a.user!.username.toLowerCase();
    final right = b.user!.username.toLowerCase();
    final leftScore = query.isNotEmpty && left.startsWith(query) ? 0 : 1;
    final rightScore = query.isNotEmpty && right.startsWith(query) ? 0 : 1;
    if (leftScore != rightScore) return leftScore.compareTo(rightScore);
    return left.compareTo(right);
  });

  return candidates.take(limit).toList();
}
