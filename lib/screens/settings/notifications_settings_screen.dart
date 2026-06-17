import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/background_ws_service.dart';
import '../../services/desktop_autostart_service.dart';
import '../../services/notification_service.dart';
import '../../services/push_notification_service.dart';
import '../../services/secure_storage_service.dart';
import '../../widgets/glass.dart';
import 'settings_widgets.dart';

/// Notifications: how and when OpenChat alerts you. Delivery channel
/// (Firebase push, background WebSocket, desktop autostart), pause + quiet
/// hours, and what shows in a notification. The full network/metadata route
/// status lives read-only in Privacy & Security.
class NotificationsSettingsScreen extends StatefulWidget {
  const NotificationsSettingsScreen({super.key});

  @override
  State<NotificationsSettingsScreen> createState() =>
      _NotificationsSettingsScreenState();
}

class _NotificationsSettingsScreenState
    extends State<NotificationsSettingsScreen> {
  Future<void> _setPushEnabled(bool value, SettingsProvider settings) async {
    final messenger = ScaffoldMessenger.of(context);
    final api = context.read<ApiService>();

    if (value) {
      // Show privacy warning before enabling.
      var confirmed = false;
      await GlassDialog.show<void>(
        context: context,
        title: 'Privacy notice',
        message:
            'Push notifications route metadata (sender, device ID) '
            'through Google Firebase servers. No message content is sent.\n\n'
            'For full metadata privacy, use Background WebSocket instead.',
        actions: [
          GlassDialogAction(
            label: 'Cancel',
            onPressed: () => Navigator.pop(context),
          ),
          GlassDialogAction(
            label: 'Enable',
            isPrimary: true,
            onPressed: () {
              confirmed = true;
              Navigator.pop(context);
            },
          ),
        ],
      );
      if (!confirmed || !mounted) return;

      // Disable WebSocket background before enabling push — only one
      // notification channel should be active at a time.
      if (settings.wsBackgroundEnabled) {
        await BackgroundWsService.stop();
        await settings.setWsBackgroundEnabled(false);
      }

      final result = await PushNotificationService.initDetailed(api: api);
      if (!mounted) return;
      if (!result.success) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              PushNotificationService.messageForInitFailure(
                result.failure ?? PushNotificationInitFailure.unsupported,
              ),
            ),
          ),
        );
        return;
      }
    } else {
      await PushNotificationService.disable(api: api);
    }

    await settings.setPushNotificationsEnabled(value);
  }

  Future<void> _setWsBackground(bool value, SettingsProvider settings) async {
    final messenger = ScaffoldMessenger.of(context);
    if (value) {
      // Show battery warning before enabling.
      var confirmed = false;
      await GlassDialog.show<void>(
        context: context,
        title: 'Battery notice',
        message:
            'Background WebSocket keeps a live connection even when the '
            'app is closed, providing real-time notifications without '
            'Firebase.',
        actions: [
          GlassDialogAction(
            label: 'Cancel',
            onPressed: () => Navigator.pop(context),
          ),
          GlassDialogAction(
            label: 'Enable',
            isPrimary: true,
            onPressed: () {
              confirmed = true;
              Navigator.pop(context);
            },
          ),
        ],
      );
      if (!confirmed || !mounted) return;

      // Disable Firebase push before enabling WebSocket — only one
      // notification channel should be active at a time.
      if (settings.pushNotificationsEnabled) {
        final api = context.read<ApiService>();
        await PushNotificationService.disable(api: api);
        await settings.setPushNotificationsEnabled(false);
      }

      // Request local-notification permission. On iOS this shows the system
      // prompt; on Android 13+ it requests POST_NOTIFICATIONS at runtime.
      // firebase_messaging is NOT involved here, so we must ask ourselves.
      if (!mounted) return;
      final permitted = await NotificationService.requestPermission();
      if (!mounted) return;
      if (!permitted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Notification permission is required for background notifications.',
            ),
          ),
        );
        return;
      }

      final storage = context.read<SecureStorageService>();
      final token = await storage.getAccessToken() ?? '';
      final started = await BackgroundWsService.start(
        accessToken: token,
        visibility: NotificationContentVisibility(
          showSender: settings.notificationShowSender,
          showPreview: settings.notificationShowPreview,
        ),
        conversationNotificationPreferences:
            settings.conversationNotificationPreferences,
        notificationsPausedUntilMs: settings.notificationPauseUntilMs,
        globalQuietStartMinute: settings.globalQuietHoursStartMinute,
        globalQuietEndMinute: settings.globalQuietHoursEndMinute,
        pauseAllowsCalls: settings.pauseAllowsCalls,
      );
      if (!mounted) return;
      if (!started) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Background WebSocket could not start. Try again.'),
          ),
        );
        return;
      }
    } else {
      await BackgroundWsService.stop();
    }

    await settings.setWsBackgroundEnabled(value);
  }

  Future<void> _setLaunchAtLogin(bool value, SettingsProvider settings) async {
    if (!DesktopAutostartService.available) {
      showAppToast(
        context,
        DesktopAutostartService.sandboxed
            ? 'Autostart is unavailable in this sandboxed package'
            : 'Autostart is unavailable on this platform',
        isError: true,
      );
      return;
    }

    if (value) {
      await DesktopAutostartService.setup();
      await DesktopAutostartService.enable();
      final enabled = await DesktopAutostartService.isEnabled();
      if (!mounted) return;
      if (!enabled) {
        showAppToast(
          context,
          'Could not register launch at login',
          isError: true,
        );
        return;
      }
    } else {
      await DesktopAutostartService.disable();
      final enabled = await DesktopAutostartService.isEnabled();
      if (!mounted) return;
      if (enabled) {
        showAppToast(
          context,
          'Could not remove launch at login',
          isError: true,
        );
        return;
      }
    }

    await settings.setLaunchAtLogin(value);
    if (mounted) {
      showAppToast(
        context,
        value ? 'Launch at login enabled' : 'Launch at login disabled',
      );
    }
  }

  Future<void> _showPauseNotificationsSheet(SettingsProvider settings) async {
    String? choice;
    await showGlassActionSheet<void>(
      context: context,
      title: 'Pause notifications',
      actions: [
        GlassActionSheetAction(
          label: 'For 1 hour',
          onPressed: () => choice = '1h',
        ),
        GlassActionSheetAction(
          label: 'For 8 hours',
          onPressed: () => choice = '8h',
        ),
        GlassActionSheetAction(
          label: 'Until tomorrow',
          onPressed: () => choice = 'tomorrow',
        ),
        GlassActionSheetAction(
          label: 'Until I turn it back on',
          onPressed: () => choice = 'indefinite',
        ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case '1h':
        await settings.pauseNotificationsFor(const Duration(hours: 1));
        break;
      case '8h':
        await settings.pauseNotificationsFor(const Duration(hours: 8));
        break;
      case 'tomorrow':
        await settings.pauseNotificationsUntil(_nextLocalTomorrowMorning());
        break;
      case 'indefinite':
        await settings.pauseNotificationsIndefinitely();
        break;
    }
  }

  DateTime _nextLocalTomorrowMorning() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + 1, 8);
  }

  Future<void> _setGlobalQuietHoursEnabled(
    bool enabled,
    SettingsProvider settings,
  ) {
    if (!enabled) return settings.clearGlobalQuietHours();
    return settings.setGlobalQuietHours(
      startMinute: settings.globalQuietHoursStartMinute ?? 22 * 60,
      endMinute: settings.globalQuietHoursEndMinute ?? 7 * 60,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    final delivery = <Widget>[
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS))
        SettingsSwitchTile(
          icon: Icons.notifications_outlined,
          title: 'Push Notifications',
          subtitle: 'Via Firebase when the app is closed',
          value: settings.pushNotificationsEnabled,
          onChanged: (v) => _setPushEnabled(v, settings),
        ),
      // Hidden on iOS: the OS kills persistent background sockets, so
      // BackgroundWsService.start() always refuses there and the toggle could
      // never turn on — push is the iOS channel.
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS)
        SettingsSwitchTile(
          icon: Icons.wifi_tethering,
          title: 'Background WebSocket',
          subtitle: 'Live connection for real-time notifications',
          value: settings.wsBackgroundEnabled,
          onChanged: (v) => _setWsBackground(v, settings),
        ),
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.linux ||
              defaultTargetPlatform == TargetPlatform.macOS))
        SettingsSwitchTile(
          icon: Icons.power_settings_new_rounded,
          title: 'Start OpenChat at login',
          subtitle: DesktopAutostartService.sandboxed
              ? 'Not available in this sandboxed package'
              : 'Launch minimized to tray on sign-in',
          value: settings.launchAtLogin,
          enabled: DesktopAutostartService.available,
          onChanged: (v) => _setLaunchAtLogin(v, settings),
        ),
    ];

    return SettingsScaffold(
      title: 'Notifications',
      children: [
        if (delivery.isNotEmpty) ...[
          const SettingsSectionHeader('Delivery'),
          SettingsGroup(children: delivery),
          const SizedBox(height: 20),
        ],

        const SettingsSectionHeader('When'),
        SettingsGroup(
          children: [
            SettingsTile(
              icon: Icons.notifications_paused_outlined,
              title: 'Pause notifications',
              subtitle: settings.pauseStatusLabel,
              trailing: settings.hasManualNotificationPause
                  ? TextButton.icon(
                      key: const ValueKey(
                        'settings-resume-notifications-button',
                      ),
                      icon: const Icon(Icons.notifications_active_outlined),
                      label: const Text('Resume'),
                      onPressed: settings.resumeNotifications,
                    )
                  : null,
              onTap: () => _showPauseNotificationsSheet(settings),
            ),
            _GlobalQuietHoursControls(
              settings: settings,
              onToggle: (enabled) =>
                  _setGlobalQuietHoursEnabled(enabled, settings),
              onChanged: (start, end) => settings.setGlobalQuietHours(
                startMinute: start,
                endMinute: end,
              ),
            ),
            SettingsSwitchTile(
              icon: Icons.call_outlined,
              title: 'Allow calls while paused',
              subtitle: 'Incoming calls can still ring during pause',
              value: settings.pauseAllowsCalls,
              onChanged: settings.setPauseAllowsCalls,
            ),
          ],
        ),
        const SizedBox(height: 20),

        const SettingsSectionHeader('Content'),
        SettingsGroup(
          children: [
            SettingsSwitchTile(
              icon: Icons.person_outline,
              title: 'Show sender',
              subtitle: 'Reveal who or which group a message is from',
              value: settings.notificationShowSender,
              onChanged: settings.setNotificationShowSender,
            ),
            SettingsSwitchTile(
              icon: Icons.notes_outlined,
              title: 'Show message preview',
              subtitle: 'Reveal a snippet of the message text',
              value: settings.notificationShowPreview,
              onChanged: settings.setNotificationShowPreview,
            ),
          ],
        ),
      ],
    );
  }
}

class _GlobalQuietHoursControls extends StatelessWidget {
  final SettingsProvider settings;
  final ValueChanged<bool> onToggle;
  final void Function(int startMinute, int endMinute) onChanged;

  const _GlobalQuietHoursControls({
    required this.settings,
    required this.onToggle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final enabled =
        settings.globalQuietHoursStartMinute != null &&
        settings.globalQuietHoursEndMinute != null;
    final start = settings.globalQuietHoursStartMinute ?? 22 * 60;
    final end = settings.globalQuietHoursEndMinute ?? 7 * 60;
    return Column(
      children: [
        SettingsSwitchTile(
          icon: Icons.bedtime_outlined,
          title: 'Global quiet hours',
          subtitle: enabled
              ? '${SettingsProvider.formatNotificationMinute(start)}-${SettingsProvider.formatNotificationMinute(end)}'
              : 'Off',
          value: enabled,
          onChanged: onToggle,
        ),
        if (enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Row(
              children: [
                Expanded(
                  child: _GlobalQuietHourPicker(
                    label: 'From',
                    value: start,
                    onChanged: (value) => onChanged(value, end),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _GlobalQuietHourPicker(
                    label: 'To',
                    value: end,
                    onChanged: (value) => onChanged(start, value),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _GlobalQuietHourPicker extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  const _GlobalQuietHourPicker({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 5),
          child: Text(label, style: Theme.of(context).textTheme.labelMedium),
        ),
        GlassPicker(
          value: SettingsProvider.formatNotificationMinute(value),
          height: 40,
          textStyle: TextStyle(fontSize: 15, color: scheme.onSurface),
          onTap: () => showGlassActionSheet<void>(
            context: context,
            title: '$label hour',
            actions: [
              for (var hour = 0; hour < 24; hour++)
                GlassActionSheetAction(
                  label: '${hour.toString().padLeft(2, '0')}:00',
                  onPressed: () => onChanged(hour * 60),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
