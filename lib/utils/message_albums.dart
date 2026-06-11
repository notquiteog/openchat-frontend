/// Album detection for the chat list: consecutive image messages from the
/// same sender sharing a `media_group_id` render as ONE grid bubble instead
/// of a stack of separate image bubbles.
///
/// The message list itself is untouched — every member keeps its row (the
/// non-anchor rows collapse to zero height), so reverse-index math, message
/// keys, reply jumps, and read receipts all keep working on raw indices.
library;

import '../models/message.dart';

bool _albumEligible(Message m) =>
    m.type == MessageType.image &&
    (m.effectiveMediaGroupId?.isNotEmpty ?? false);

/// The chronological run of consecutive same-sender, same-media-group image
/// messages containing [index] — or null unless the run has 2+ members.
List<Message>? albumRunAt(List<Message> messages, int index) {
  final msg = messages[index];
  if (!_albumEligible(msg)) return null;
  final groupId = msg.effectiveMediaGroupId;
  bool sameRun(Message other) =>
      _albumEligible(other) &&
      other.effectiveMediaGroupId == groupId &&
      other.senderId == msg.senderId;
  var start = index;
  while (start > 0 && sameRun(messages[start - 1])) {
    start--;
  }
  var end = index;
  while (end + 1 < messages.length && sameRun(messages[end + 1])) {
    end++;
  }
  if (end == start) return null;
  return messages.sublist(start, end + 1);
}
