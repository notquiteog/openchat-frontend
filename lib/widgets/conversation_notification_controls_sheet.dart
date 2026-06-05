import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../utils/local_conversation_preferences.dart';
import 'glass.dart';

Future<void> showConversationNotificationControlsSheet(
  BuildContext context, {
  required String conversationId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) =>
        _ConversationNotificationControlsSheet(conversationId: conversationId),
  );
}

class _ConversationNotificationControlsSheet extends StatefulWidget {
  final String conversationId;

  const _ConversationNotificationControlsSheet({required this.conversationId});

  @override
  State<_ConversationNotificationControlsSheet> createState() =>
      _ConversationNotificationControlsSheetState();
}

class _ConversationNotificationControlsSheetState
    extends State<_ConversationNotificationControlsSheet> {
  late final TextEditingController _keywordsCtrl;

  @override
  void initState() {
    super.initState();
    final preference = context
        .read<SettingsProvider>()
        .notificationPreferenceForConversation(widget.conversationId);
    _keywordsCtrl = TextEditingController(text: preference.keywords.join(', '));
  }

  @override
  void dispose() {
    _keywordsCtrl.dispose();
    super.dispose();
  }

  Future<void> _setPreference(ConversationNotificationPreference preference) {
    return context
        .read<SettingsProvider>()
        .setConversationNotificationPreference(
          widget.conversationId,
          preference,
        );
  }

  Future<void> _saveKeywords() async {
    final keywords = normalizeNotificationKeywords(
      _keywordsCtrl.text.split(','),
    );
    _keywordsCtrl.text = keywords.join(', ');
    await context.read<SettingsProvider>().setConversationNotificationKeywords(
      widget.conversationId,
      keywords,
    );
  }

  Future<void> _muteFor(Duration duration) {
    return context.read<SettingsProvider>().muteConversationUntil(
      widget.conversationId,
      DateTime.now().add(duration),
    );
  }

  Future<void> _pickMuteUntil(BuildContext context) async {
    final now = DateTime.now();
    var selected = now.add(const Duration(hours: 1));
    final mutedUntil = await showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => GlassBottomSheetFrame(
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                SizedBox(
                  height: 216,
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.dateAndTime,
                    minimumDate: now.add(const Duration(minutes: 1)),
                    initialDateTime: selected,
                    onDateTimeChanged: (value) =>
                        setSheetState(() => selected = value),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.pop(ctx, selected),
                          child: const Text('Done'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mutedUntil != null && mounted) {
      await this.context.read<SettingsProvider>().muteConversationUntil(
        widget.conversationId,
        mutedUntil,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final preference = settings.notificationPreferenceForConversation(
      widget.conversationId,
    );
    final scheme = Theme.of(context).colorScheme;
    return GlassBottomSheetFrame(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.82,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primary.withValues(alpha: 0.14),
                    ),
                    child: Icon(
                      Icons.notifications_active_outlined,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Notifications',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _NotificationTile(
                icon: Icons.notifications_active_outlined,
                label: 'All messages',
                selected:
                    preference.mode == ConversationNotificationMode.all &&
                    !preference.isMutedAt(DateTime.now()),
                onTap: () => _setPreference(
                  preference.copyWith(
                    mode: ConversationNotificationMode.all,
                    clearMutedUntil: true,
                  ),
                ),
              ),
              _NotificationTile(
                icon: Icons.notification_important_outlined,
                label: 'Mentions only',
                selected:
                    preference.mode ==
                    ConversationNotificationMode.mentionsOnly,
                onTap: () => _setPreference(
                  preference.copyWith(
                    mode: ConversationNotificationMode.mentionsOnly,
                    clearMutedUntil: true,
                  ),
                ),
              ),
              _SwitchTile(
                icon: Icons.star_outline_rounded,
                label: 'Priority',
                value: preference.priority,
                onChanged: (value) =>
                    settings.setConversationPriorityNotifications(
                      widget.conversationId,
                      value,
                    ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
                child: TextField(
                  controller: _keywordsCtrl,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _saveKeywords(),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.tag_outlined),
                    suffixIcon: IconButton(
                      tooltip: 'Save keywords',
                      icon: const Icon(Icons.check_rounded),
                      onPressed: _saveKeywords,
                    ),
                    labelText: 'Keywords',
                    hintText: 'urgent, deploy',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              _QuietHoursControls(
                preference: preference,
                onToggle: (enabled) {
                  if (enabled) {
                    settings.setConversationQuietHours(
                      widget.conversationId,
                      startMinute: preference.quietHoursStartMinute ?? 22 * 60,
                      endMinute: preference.quietHoursEndMinute ?? 7 * 60,
                    );
                    return;
                  }
                  settings.clearConversationQuietHours(widget.conversationId);
                },
                onChanged: (start, end) => settings.setConversationQuietHours(
                  widget.conversationId,
                  startMinute: start,
                  endMinute: end,
                ),
              ),
              const Divider(height: 18),
              _NotificationTile(
                icon: Icons.notifications_paused_outlined,
                label: 'Mute 1 hour',
                onTap: () => _muteFor(const Duration(hours: 1)),
              ),
              _NotificationTile(
                icon: Icons.notifications_paused_outlined,
                label: 'Mute 8 hours',
                onTap: () => _muteFor(const Duration(hours: 8)),
              ),
              _NotificationTile(
                icon: Icons.notifications_paused_outlined,
                label: 'Mute 1 day',
                onTap: () => _muteFor(const Duration(days: 1)),
              ),
              _NotificationTile(
                icon: Icons.notifications_paused_outlined,
                label: 'Mute 1 week',
                onTap: () => _muteFor(const Duration(days: 7)),
              ),
              _NotificationTile(
                icon: Icons.schedule_outlined,
                label: 'Mute until...',
                onTap: () => _pickMuteUntil(context),
              ),
              _NotificationTile(
                icon: Icons.notifications_off_outlined,
                label: 'Mute forever',
                selected: preference.mode == ConversationNotificationMode.muted,
                onTap: () =>
                    settings.setConversationMuted(widget.conversationId, true),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuietHoursControls extends StatelessWidget {
  final ConversationNotificationPreference preference;
  final ValueChanged<bool> onToggle;
  final void Function(int startMinute, int endMinute) onChanged;

  const _QuietHoursControls({
    required this.preference,
    required this.onToggle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = preference.hasQuietHours;
    final start = preference.quietHoursStartMinute ?? 22 * 60;
    final end = preference.quietHoursEndMinute ?? 7 * 60;
    return Column(
      children: [
        _SwitchTile(
          icon: Icons.bedtime_outlined,
          label: 'Quiet hours',
          value: enabled,
          onChanged: onToggle,
        ),
        if (enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: _MinuteDropdown(
                    label: 'From',
                    value: start,
                    onChanged: (value) => onChanged(value, end),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MinuteDropdown(
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

class _MinuteDropdown extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  const _MinuteDropdown({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: value,
          isDense: true,
          isExpanded: true,
          items: [
            for (var hour = 0; hour < 24; hour++)
              DropdownMenuItem(
                value: hour * 60,
                child: Text('${hour.toString().padLeft(2, '0')}:00'),
              ),
          ],
          onChanged: (value) {
            if (value != null) onChanged(value);
          },
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NotificationTile({
    required this.icon,
    required this.label,
    this.selected = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: selected ? scheme.primary : null),
      title: Text(label),
      trailing: selected
          ? Icon(Icons.check_rounded, color: scheme.primary)
          : null,
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      secondary: Icon(icon),
      title: Text(label),
      value: value,
      onChanged: onChanged,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    );
  }
}
