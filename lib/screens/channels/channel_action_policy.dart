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
  giftSubscription,
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

    // The shield opens the moderation hub. It surfaces whenever the caller can
    // do anything channel-admin: moderate, manage the lifecycle, or manage the
    // channel's settings / encryption / analytics (those four now live inside
    // the hub rather than the gear menu).
    final managesChannel = managesInfo || managesEncryption || viewsAnalytics;
    if (opensModeration || canManageLifecycle || managesChannel) {
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
      settings.add(ChannelSettingsAction.sharedContent);
      settings.add(ChannelSettingsAction.scheduledPosts);
      settings.add(ChannelSettingsAction.deleteOwnMessages);
      // Whether the channel actually sells subscriptions is only known after
      // a plans fetch — the handler explains itself when there is no plan.
      settings.add(ChannelSettingsAction.giftSubscription);
    }

    // Analytics, channel settings (edit), subscription price, and encryption
    // mode were relocated from this gear menu into the moderation hub — see
    // ModerationScreen's "Channel" section. They stay gated by the same
    // permissions (info / encryption / analytics) there.
    if (managesInvites) {
      settings.add(ChannelSettingsAction.inviteLinks);
    }
    if (managesInfo && isPremium) {
      settings.add(ChannelSettingsAction.background);
    }
    if (managesSettings) {
      settings.add(ChannelSettingsAction.autoDelete);
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
