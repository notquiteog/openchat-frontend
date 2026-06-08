import '../models/conversation.dart';
import '../providers/settings_provider.dart';

enum SmartInboxFilter {
  all,
  unread,
  mentions,
  dms,
  groups,
  channels,
  bots,
  archived,
}

SmartInboxFilter smartInboxFilterFromName(String? value) {
  return SmartInboxFilter.values.firstWhere(
    (filter) => filter.name == value,
    orElse: () => SmartInboxFilter.all,
  );
}

List<SmartInboxFilter> availableSmartInboxFilters({
  required bool channelsOwnTab,
  required bool botsOwnTab,
  bool hasArchived = false,
}) {
  return [
    SmartInboxFilter.all,
    SmartInboxFilter.unread,
    SmartInboxFilter.mentions,
    SmartInboxFilter.dms,
    SmartInboxFilter.groups,
    if (!channelsOwnTab) SmartInboxFilter.channels,
    if (!botsOwnTab) SmartInboxFilter.bots,
    if (hasArchived) SmartInboxFilter.archived,
  ];
}

SmartInboxFilter effectiveSmartInboxFilter(
  SmartInboxFilter selected, {
  required bool channelsOwnTab,
  required bool botsOwnTab,
  bool hasArchived = false,
}) {
  final available = availableSmartInboxFilters(
    channelsOwnTab: channelsOwnTab,
    botsOwnTab: botsOwnTab,
    hasArchived: hasArchived,
  );
  return available.contains(selected) ? selected : SmartInboxFilter.all;
}

bool conversationBelongsInChatsTab(
  Conversation conversation, {
  required String currentUserId,
  required bool channelsOwnTab,
  required bool botsOwnTab,
}) {
  if (conversation.isChannel) return !channelsOwnTab;
  if (conversation.isBotDM(currentUserId)) return !botsOwnTab;
  return true;
}

bool conversationMatchesSmartInboxFilter(
  Conversation conversation, {
  required SmartInboxFilter filter,
  required String currentUserId,
  Set<String> archivedConversationIds = const {},
  Map<String, String> unreadMentionMessageIds = const {},
}) {
  final archived = archivedConversationIds.contains(conversation.id);
  if (filter == SmartInboxFilter.archived) return archived;
  if (archived) return false;

  return switch (filter) {
    SmartInboxFilter.all => true,
    SmartInboxFilter.unread => conversation.unreadCount > 0,
    SmartInboxFilter.mentions => unreadMentionMessageIds.containsKey(
      conversation.id,
    ),
    SmartInboxFilter.dms =>
      conversation.isDM && !conversation.isBotDM(currentUserId),
    SmartInboxFilter.groups => conversation.isGroup,
    SmartInboxFilter.channels => conversation.isChannel,
    SmartInboxFilter.bots => conversation.isBotDM(currentUserId),
    SmartInboxFilter.archived => false,
  };
}

String smartInboxFilterLabel(SmartInboxFilter filter) {
  return switch (filter) {
    SmartInboxFilter.all => 'All',
    SmartInboxFilter.unread => 'Unread',
    SmartInboxFilter.mentions => 'Mentions',
    SmartInboxFilter.dms => 'DMs',
    SmartInboxFilter.groups => 'Groups',
    SmartInboxFilter.channels => 'Channels',
    SmartInboxFilter.bots => 'Bots',
    SmartInboxFilter.archived => 'Archived',
  };
}

int compareConversationsForInbox(
  Conversation a,
  Conversation b, {
  required Map<String, MessageDraft> drafts,
  required Set<String> pinnedConversationIds,
}) {
  // Saved Messages (self) is always pinned to the very top.
  if (a.isSelf != b.isSelf) return a.isSelf ? -1 : 1;
  final aPinned = pinnedConversationIds.contains(a.id);
  final bPinned = pinnedConversationIds.contains(b.id);
  if (aPinned != bPinned) return aPinned ? -1 : 1;
  return conversationActivityTime(
    b,
    drafts,
  ).compareTo(conversationActivityTime(a, drafts));
}

DateTime conversationActivityTime(
  Conversation conversation,
  Map<String, MessageDraft> drafts,
) {
  final lastActivity =
      conversation.lastMessage?.createdAt ?? conversation.createdAt;
  final draft = drafts[conversation.id];
  if (draft == null || draft.updatedAt.isBefore(lastActivity)) {
    return lastActivity;
  }
  return draft.updatedAt;
}
