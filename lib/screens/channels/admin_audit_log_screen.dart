import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/admin_audit_event.dart';
import '../../models/conversation.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';

enum _AuditFilter {
  all('All', Icons.history_rounded),
  members('Members', Icons.group_outlined),
  moderation('Moderation', Icons.shield_outlined),
  messages('Messages', Icons.chat_bubble_outline_rounded),
  settings('Settings', Icons.tune_rounded),
  invites('Invites', Icons.link_rounded);

  final String label;
  final IconData icon;

  const _AuditFilter(this.label, this.icon);
}

class AdminAuditLogScreen extends StatefulWidget {
  final Conversation conversation;

  const AdminAuditLogScreen({super.key, required this.conversation});

  @override
  State<AdminAuditLogScreen> createState() => _AdminAuditLogScreenState();
}

class _AdminAuditLogScreenState extends State<AdminAuditLogScreen> {
  List<AdminAuditEvent> _events = const [];
  _AuditFilter _filter = _AuditFilter.all;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final api = context.read<ApiService>();
      final events = await api.listAdminAuditEvents(
        widget.conversation.id,
        channel: widget.conversation.isChannel,
        limit: 200,
      );
      if (!mounted) return;
      setState(() {
        _events = events;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showAppToast(context, 'Failed to load audit log: $e', isError: true);
    }
  }

  List<AdminAuditEvent> get _visibleEvents {
    if (_filter == _AuditFilter.all) return _events;
    return _events
        .where((event) => _filterForAction(event.action) == _filter)
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final visibleEvents = _visibleEvents;
    return GlassScreenScaffold(
      title: const Text('Audit log'),
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _load,
        ),
      ],
      body: _loading
          ? const Center(child: GlassProgressIndicator.circular())
          : Column(
              children: [
                SizedBox(
                  height: MediaQuery.paddingOf(context).top + kToolbarHeight,
                ),
                SizedBox(
                  height: 58,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                    itemBuilder: (context, index) {
                      final filter = _AuditFilter.values[index];
                      return GlassChip(
                        icon: Icon(filter.icon),
                        iconSize: 18,
                        label: filter.label,
                        selected: filter == _filter,
                        onTap: () => setState(() => _filter = filter),
                      );
                    },
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemCount: _AuditFilter.values.length,
                  ),
                ),
                const GlassDivider(),
                Expanded(
                  child: visibleEvents.isEmpty
                      ? const _AuditEmptyState()
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: EdgeInsets.only(
                              bottom: MediaQuery.paddingOf(context).bottom + 16,
                            ),
                            itemCount: visibleEvents.length,
                            itemBuilder: (context, index) {
                              final event = visibleEvents[index];
                              return _AuditLogTile(
                                event: event,
                                isLast: index == visibleEvents.length - 1,
                                onTap: () => _showDetails(event),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  void _showDetails(AdminAuditEvent event) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AuditDetailsSheet(event: event),
    );
  }
}

class _AuditEmptyState extends StatelessWidget {
  const _AuditEmptyState();

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.4);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history_toggle_off_rounded, size: 44, color: muted),
          const SizedBox(height: 12),
          Text(
            'No audit events',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _AuditLogTile extends StatelessWidget {
  final AdminAuditEvent event;
  final bool isLast;
  final VoidCallback onTap;

  const _AuditLogTile({
    required this.event,
    required this.onTap,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filter = _filterForAction(event.action);
    final tint = _auditColor(scheme, filter);
    return GlassListTile(
      showDivider: !isLast,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: tint.withValues(alpha: 0.12),
        ),
        child: Icon(_auditIcon(event.action), color: tint, size: 20),
      ),
      title: Text(
        _auditTitle(event),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        _auditSubtitle(event),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}

class _AuditDetailsSheet extends StatelessWidget {
  final AdminAuditEvent event;

  const _AuditDetailsSheet({required this.event});

  @override
  Widget build(BuildContext context) {
    final metadataRows = event.metadata.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return GlassBottomSheetFrame(
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const GlassSheetGrabber(),
              GlassSheetHeader(
                icon: _auditIcon(event.action),
                title: _auditTitle(event),
                subtitle: _formatAuditTime(event.createdAt),
                onClose: () => Navigator.pop(context),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _AuditDetailRow(label: 'Actor', value: event.actorLabel),
                      _AuditDetailRow(
                        label: 'Target',
                        value: event.targetLabel,
                      ),
                      _AuditDetailRow(label: 'Action', value: event.action),
                      _AuditDetailRow(
                        label: 'Time',
                        value: _formatAuditTime(event.createdAt),
                      ),
                      if (metadataRows.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Metadata',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        for (final entry in metadataRows)
                          _AuditDetailRow(
                            label: _titleCase(entry.key.replaceAll('_', ' ')),
                            value: _formatMetadataValue(entry.value),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuditDetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _AuditDetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: 0.62),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

_AuditFilter _filterForAction(String action) => switch (action) {
  'member_added' ||
  'member_removed' ||
  'member_role_updated' ||
  'admin_anonymity_updated' => _AuditFilter.members,
  'member_muted' ||
  'member_unmuted' ||
  'member_banned' ||
  'member_unbanned' => _AuditFilter.moderation,
  'message_deleted' ||
  'messages_deleted' ||
  'channel_post_pinned' ||
  'channel_post_unpinned' => _AuditFilter.messages,
  'invite_link_created' ||
  'invite_link_revoked' ||
  'join_request_approved' ||
  'join_request_rejected' => _AuditFilter.invites,
  _ => _AuditFilter.settings,
};

Color _auditColor(ColorScheme scheme, _AuditFilter filter) => switch (filter) {
  _AuditFilter.members => scheme.primary,
  _AuditFilter.moderation => scheme.error,
  _AuditFilter.messages => scheme.tertiary,
  _AuditFilter.invites => scheme.secondary,
  _AuditFilter.settings || _AuditFilter.all => scheme.primary,
};

IconData _auditIcon(String action) => switch (action) {
  'member_role_updated' ||
  'admin_anonymity_updated' => Icons.admin_panel_settings_outlined,
  'member_added' => Icons.person_add_alt_1_outlined,
  'member_removed' => Icons.person_remove_outlined,
  'member_muted' || 'member_unmuted' => Icons.volume_off_outlined,
  'member_banned' || 'member_unbanned' => Icons.block_rounded,
  'message_deleted' || 'messages_deleted' => Icons.delete_sweep_outlined,
  'channel_post_pinned' || 'channel_post_unpinned' => Icons.push_pin_outlined,
  'invite_link_created' || 'invite_link_revoked' => Icons.link_rounded,
  'join_request_approved' ||
  'join_request_rejected' => Icons.how_to_reg_outlined,
  'encryption_updated' => Icons.lock_outline_rounded,
  'slow_mode_updated' || 'message_ttl_updated' => Icons.timer_outlined,
  'ring_all_on_call_start_updated' => Icons.notifications_active_outlined,
  'topic_created' ||
  'topic_updated' ||
  'topics_enabled_updated' => Icons.forum_outlined,
  'owner_only_post_updated' => Icons.campaign_outlined,
  'channel_archived' || 'channel_unarchived' => Icons.archive_outlined,
  _ => Icons.shield_outlined,
};

String _auditTitle(AdminAuditEvent event) => switch (event.action) {
  'conversation_info_updated' => 'Updated group info',
  'channel_info_updated' => 'Updated channel info',
  'background_updated' => 'Updated background',
  'member_added' => 'Added ${event.targetLabel}',
  'member_removed' => 'Removed ${event.targetLabel}',
  'member_role_updated' => 'Updated ${event.targetLabel}',
  'member_muted' => 'Muted ${event.targetLabel}',
  'member_unmuted' => 'Unmuted ${event.targetLabel}',
  'member_banned' => 'Banned ${event.targetLabel}',
  'member_unbanned' => 'Unbanned ${event.targetLabel}',
  'message_deleted' => 'Deleted a message',
  'messages_deleted' => 'Deleted messages',
  'channel_post_pinned' => 'Pinned a post',
  'channel_post_unpinned' => 'Unpinned a post',
  'invite_link_created' => 'Created invite link',
  'invite_link_revoked' => 'Revoked invite link',
  'slow_mode_updated' => 'Updated slow mode',
  'message_ttl_updated' => 'Updated disappearing messages',
  'ring_all_on_call_start_updated' => 'Updated group-call ringing',
  'encryption_updated' => 'Updated encryption',
  'join_approval_updated' => 'Updated join approval',
  'topics_enabled_updated' => 'Updated topics',
  'topic_created' => 'Created topic',
  'topic_updated' => 'Updated topic',
  'admin_anonymity_updated' => 'Updated ${event.targetLabel}',
  'join_request_approved' => 'Approved ${event.targetLabel}',
  'join_request_rejected' => 'Rejected ${event.targetLabel}',
  'owner_only_post_updated' => 'Updated posting mode',
  'channel_archived' => 'Archived channel',
  'channel_unarchived' => 'Unarchived channel',
  _ => _titleCase(event.action.replaceAll('_', ' ')),
};

String _auditSubtitle(AdminAuditEvent event) {
  final parts = <String>[event.actorLabel, _formatAuditTime(event.createdAt)];
  final detail = _auditMetadataDetail(event);
  if (detail != null) parts.add(detail);
  return parts.join(' · ');
}

String _formatAuditTime(DateTime value) {
  final local = value.toLocal();
  final date =
      '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  return '$date $time';
}

String? _auditMetadataDetail(AdminAuditEvent event) {
  final metadata = event.metadata;
  switch (event.action) {
    case 'member_role_updated':
      final role = metadata['role'];
      return role is String ? _titleCase(role) : null;
    case 'messages_deleted':
      final scope = metadata['scope'];
      final count = metadata['count'];
      if (scope is String && count is int) {
        return '${_titleCase(scope)} · $count';
      }
      return null;
    case 'member_muted':
      final minutes = metadata['duration_minutes'];
      if (minutes is int && minutes > 0) return '$minutes min';
      return 'Indefinite';
    case 'slow_mode_updated':
    case 'message_ttl_updated':
      final seconds = metadata['seconds'];
      return seconds is int ? '${seconds}s' : null;
    case 'join_approval_updated':
    case 'topics_enabled_updated':
    case 'encryption_updated':
    case 'owner_only_post_updated':
    case 'ring_all_on_call_start_updated':
      final enabled = metadata['enabled'] ?? metadata['required'];
      return enabled is bool ? (enabled ? 'On' : 'Off') : null;
    case 'channel_archived':
      return 'Archived';
    case 'channel_unarchived':
      return 'Active';
    default:
      return null;
  }
}

String _formatMetadataValue(Object? value) {
  if (value is bool) return value ? 'true' : 'false';
  if (value is List) return value.map(_formatMetadataValue).join(', ');
  if (value is Map) {
    final entries = value.entries.toList()
      ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
    return entries
        .map((entry) => '${entry.key}: ${_formatMetadataValue(entry.value)}')
        .join(', ');
  }
  return value?.toString() ?? '';
}

String _titleCase(String value) {
  return value
      .split(' ')
      .where((part) => part.isNotEmpty)
      .map((part) => part[0].toUpperCase() + part.substring(1))
      .join(' ');
}
