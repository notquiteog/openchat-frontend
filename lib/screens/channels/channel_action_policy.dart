import '../../models/conversation.dart';

enum ChannelTopBarAction {
  moderation,
  settings,
  subscribe,
  unsubscribe,
  archive,
  autoDelete,
  encryption,
  delete
}

enum ChannelModerationAction { openModeration, archive, unarchive, delete }

enum ChannelSettingsAction {
  appearance,
  edit,
  background,
  autoDelete,
  encryption,
  deleteOwnMessages,
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
  }) {
    final isArchived = channel.isArchived;
    final topBar = <ChannelTopBarAction>[];
    final moderation = <ChannelModerationAction>[];
    final settings = <ChannelSettingsAction>[];

    if (isAdmin || canManageLifecycle) {
      topBar.add(ChannelTopBarAction.moderation);
      if (isAdmin) moderation.add(ChannelModerationAction.openModeration);
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

    if (isSubscribed || isAdmin) {
      topBar.add(ChannelTopBarAction.settings);
      settings.add(ChannelSettingsAction.appearance);
      settings.add(ChannelSettingsAction.deleteOwnMessages);
    }

    if (isAdmin) {
      settings.add(ChannelSettingsAction.edit);
      if (isPremium) settings.add(ChannelSettingsAction.background);
      settings.addAll([
        ChannelSettingsAction.autoDelete,
        ChannelSettingsAction.encryption,
      ]);
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
