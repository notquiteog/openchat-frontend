import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/settings_provider.dart';
import '../../widgets/glass.dart';
import 'settings_widgets.dart';

/// Calls: data-saver policy and voice-only behaviour on mobile networks.
/// (IP-hiding "Always relay calls" lives in Privacy & Security.)
class CallsSettingsScreen extends StatefulWidget {
  const CallsSettingsScreen({super.key});

  @override
  State<CallsSettingsScreen> createState() => _CallsSettingsScreenState();
}

class _CallsSettingsScreenState extends State<CallsSettingsScreen> {
  String _callDataSaverLabel(CallDataSaverMode mode) => switch (mode) {
    CallDataSaverMode.off => 'Off',
    CallDataSaverMode.on => 'On',
    CallDataSaverMode.auto => 'Auto',
  };

  Future<void> _pickCallDataSaverMode(SettingsProvider settings) async {
    CallDataSaverMode? choice;
    await showGlassActionSheet<void>(
      context: context,
      title: 'Data saver',
      actions: [
        for (final mode in CallDataSaverMode.values)
          GlassActionSheetAction(
            icon: settings.callDataSaverMode == mode
                ? const Icon(Icons.check_rounded)
                : null,
            label: switch (mode) {
              CallDataSaverMode.off => 'Off',
              CallDataSaverMode.on => 'On',
              CallDataSaverMode.auto => 'Auto on mobile data',
            },
            onPressed: () => choice = mode,
          ),
      ],
    );
    if (!mounted || choice == null) return;
    await settings.setCallDataSaverMode(choice!);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final scheme = Theme.of(context).colorScheme;

    return SettingsScaffold(
      title: 'Calls',
      children: [
        const SettingsSectionHeader('Calls'),
        SettingsGroup(
          children: [
            SettingsTile(
              icon: Icons.speed_outlined,
              title: 'Data saver',
              subtitle: switch (settings.callDataSaverMode) {
                CallDataSaverMode.off => 'Use full call quality',
                CallDataSaverMode.on => 'Cap outgoing video quality',
                CallDataSaverMode.auto => 'Cap outgoing video on mobile data',
              },
              trailing: GlassPicker(
                value: _callDataSaverLabel(settings.callDataSaverMode),
                width: 96,
                height: 38,
                textStyle: TextStyle(fontSize: 15, color: scheme.onSurface),
                onTap: () => _pickCallDataSaverMode(settings),
              ),
              onTap: () => _pickCallDataSaverMode(settings),
            ),
            SettingsSwitchTile(
              icon: Icons.voice_chat_outlined,
              title: 'Voice only on mobile data',
              subtitle: 'Start and answer calls without camera capture',
              value: settings.callVoiceOnlyOnMobile,
              onChanged: settings.setCallVoiceOnlyOnMobile,
            ),
          ],
        ),
      ],
    );
  }
}
