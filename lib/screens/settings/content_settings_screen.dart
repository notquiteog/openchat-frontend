import 'package:flutter/material.dart';

import '../bots/bot_management_screen.dart';
import '../custom_emojis/custom_emoji_pack_screen.dart';
import '../mini_apps/mini_apps_screen.dart';
import '../stickers/sticker_pack_screen.dart';
import 'settings_widgets.dart';

/// Stickers, emoji, bots, and mini apps you create and manage.
class ContentSettingsScreen extends StatelessWidget {
  const ContentSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'Stickers & Emoji',
      children: [
        const SettingsSectionHeader('Content'),
        SettingsGroup(
          children: [
            SettingsTile(
              icon: Icons.emoji_emotions_outlined,
              title: 'Sticker Packs',
              subtitle: 'Create and manage your sticker packs',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const StickerPackScreen(),
                ),
              ),
            ),
            SettingsTile(
              icon: Icons.add_reaction_outlined,
              title: 'Custom Emoji Packs',
              subtitle: 'Create and manage your custom emoji packs',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const CustomEmojiPackScreen(),
                ),
              ),
            ),
            SettingsTile(
              icon: Icons.smart_toy_outlined,
              title: 'My Bots',
              subtitle: 'Create and manage bots',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const BotManagementScreen(),
                ),
              ),
            ),
            SettingsTile(
              icon: Icons.widgets_outlined,
              title: 'Mini Apps',
              subtitle: 'Open bot-owned apps in an isolated browser',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const MiniAppsScreen()),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
