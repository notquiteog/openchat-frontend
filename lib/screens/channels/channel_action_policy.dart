import '../../models/conversation.dart';

enum ChannelTopBarAction {
  moderation,
  settings,
  subscribe,
  unsubscribe,
  archive,
  autoDelete,
  encryption,
  delete,
}

enum ChannelModerationAction { openModeration, archive, unarchive, delete }

enum ChannelSettingsAction {
  appearance,
  sharedContent,
  analytics,
  scheduledPosts,
  edit,
  inviteLinks,
  background,
  autoDelete,
  encryption,
  deleteOwnMessages,
  subscriptionPlan,
}

class ChannelActionPlacement {
  final List<ChannelTopBarAction> topBar;
  final List<ChannelModerationAction> moderationMenu;
  final List<ChannelSettingsAction> settingsMenu;

  const ChannelActionPlacement({
    required this.topBar,
    required this.moderationMenu,
    required this.settingsMenu,
  });
}

class ChannelActionPolicy {
  const ChannelActionPolicy._();

  static ChannelActionPlacement actionsFor({
    required Conversation channel,
    required bool isAdmin,
    required bool isPremium,
    required bool canManageLifecycle,
    required bool isSubscribed,
    bool? canOpenModeration,
    bool? canManageInfo,
    bool? canManageInvites,
    bool? canManageSettings,
    bool? canManageEncryption,
    bool? canViewAnalytics,
  }) {
    final isArchived = channel.isArchived;
    final opensModeration = canOpenModeration ?? isAdmin;
    final managesInfo = canManageInfo ?? isAdmin;
    final managesInvites = canManageInvites ?? isAdmin;
    final managesSettings = canManageSettings ?? isAdmin;
    final managesEncryption = canManageEncryption ?? isAdmin;
    final viewsAnalytics = canViewAnalytics ?? isAdmin;
    final topBar = <ChannelTopBarAction>[];
    final moderation = <ChannelModerationAction>[];
    final settings = <ChannelSettingsAction>[];

    if (opensModeration || canManageLifecycle) {
      topBar.add(ChannelTopBarAction.moderation);
      if (opensModeration) {
        moderation.add(ChannelModerationAction.openModeration);
      }
      if (canManageLifecycle && !isArchived) {
        moderation.add(ChannelModerationAction.archive);
      }
      if (canManageLifecycle && isArchived) {
        moderation.addAll([
          ChannelModerationAction.unarchive,
          ChannelModerationAction.delete,
        ]);
      }
    }

    final hasAdminSettings =
        managesInfo ||
        managesInvites ||
        managesSettings ||
        managesEncryption ||
        viewsAnalytics;
    if (isSubscribed || hasAdminSettings) {
      topBar.add(ChannelTopBarAction.settings);
      settings.add(ChannelSettingsAction.appearance);
      settings.add(ChannelSettingsAction.sharedContent);
      if (viewsAnalytics) {
        settings.add(ChannelSettingsAction.analytics);
      }
      settings.add(ChannelSettingsAction.scheduledPosts);
      settings.add(ChannelSettingsAction.deleteOwnMessages);
    }

    if (managesInfo) {
      settings.add(ChannelSettingsAction.edit);
      settings.add(ChannelSettingsAction.subscriptionPlan);
    }
    if (managesInvites) {
      settings.add(ChannelSettingsAction.inviteLinks);
    }
    if (managesInfo) {
      if (isPremium) settings.add(ChannelSettingsAction.background);
    }
    if (managesSettings) {
      settings.add(ChannelSettingsAction.autoDelete);
    }
    if (managesEncryption) {
      settings.add(ChannelSettingsAction.encryption);
    }

    if (!canManageLifecycle) {
      topBar.add(
        isSubscribed
            ? ChannelTopBarAction.unsubscribe
            : ChannelTopBarAction.subscribe,
      );
    }

    return ChannelActionPlacement(
      topBar: topBar,
      moderationMenu: moderation,
      settingsMenu: settings,
    );
  }
}
