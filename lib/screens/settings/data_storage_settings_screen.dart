import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/chat_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/glass.dart';
import 'on_device_ai_screen.dart';
import 'outbox_screen.dart';
import 'settings_widgets.dart';

/// Data & storage: media auto-download policy, link-preview fetching, on-device
/// AI model storage, and the offline outbox.
class DataStorageSettingsScreen extends StatelessWidget {
  const DataStorageSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final pendingOutboxCount = context.watch<ChatProvider>().pendingOutboxCount;
    final scheme = Theme.of(context).colorScheme;

    return SettingsScaffold(
      title: 'Data & Storage',
      children: [
        const SettingsSectionHeader('Auto-download media'),
        SettingsGroup(
          children: [
            SettingsSwitchTile(
              icon: Icons.wifi_rounded,
              title: 'On Wi-Fi',
              subtitle: 'Automatically download photos & videos on Wi-Fi',
              value: settings.autoDownloadWifi,
              onChanged: settings.setAutoDownloadWifi,
            ),
            SettingsSwitchTile(
              icon: Icons.signal_cellular_alt_rounded,
              title: 'On mobile data',
              subtitle: 'Roaming can\'t be detected separately',
              value: settings.autoDownloadMobile,
              onChanged: settings.setAutoDownloadMobile,
            ),
            SettingsTile(
              icon: Icons.straighten_rounded,
              title: 'Size limit',
              subtitle: settings.autoDownloadMaxMb == 0
                  ? 'No limit'
                  : 'Skip files over ${settings.autoDownloadMaxMb} MB',
              trailing: GlassPicker(
                value: settings.autoDownloadMaxMb == 0
                    ? 'No limit'
                    : '${settings.autoDownloadMaxMb} MB',
                width: 112,
                height: 38,
                textStyle: TextStyle(fontSize: 15, color: scheme.onSurface),
                onTap: () => showGlassActionSheet<void>(
                  context: context,
                  title: 'Size limit',
                  actions: [
                    for (final mb in const [0, 1, 5, 10, 25, 50])
                      GlassActionSheetAction(
                        label: mb == 0 ? 'No limit' : '$mb MB',
                        onPressed: () => settings.setAutoDownloadMaxMb(mb),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        const SettingsSectionHeader('Media'),
        SettingsGroup(
          children: [
            SettingsSwitchTile(
              icon: Icons.link_rounded,
              title: 'Link Previews',
              subtitle: settings.strictPrivacyMode
                  ? 'Disabled while Strict Privacy is on'
                  : 'Fetch metadata through the OpenChat proxy',
              value: settings.linkPreviewsEnabled,
              onChanged: (value) {
                if (settings.strictPrivacyMode && value) {
                  showAppToast(
                    context,
                    'Turn off Strict Privacy before enabling link previews',
                    isError: true,
                  );
                  return;
                }
                settings.setLinkPreviewsEnabled(value);
              },
            ),
          ],
        ),
        const SizedBox(height: 20),

        const SettingsSectionHeader('Storage & tools'),
        SettingsGroup(
          children: [
            if (!kIsWeb)
              SettingsTile(
                icon: Icons.psychology_outlined,
                title: 'On-device intelligence',
                subtitle: 'Transcription, translation, and sticker AI models',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const OnDeviceAiScreen(),
                  ),
                ),
              ),
            SettingsTile(
              icon: Icons.outbox_outlined,
              title: 'Outbox',
              subtitle: 'Messages waiting to send',
              trailing: pendingOutboxCount > 0
                  ? SettingsCountBadge(count: pendingOutboxCount)
                  : null,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const OutboxScreen()),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
