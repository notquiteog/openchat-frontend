import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/admin_audit_event.dart';
import '../../models/conversation.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/admin_permissions_sheet.dart';
import '../../widgets/glass.dart';

/// Owner-side moderation for a channel or group. Two controls:
///
///   1. Broadcast toggle — flips `owner_only_post`. When on, only admins can
///      post; everyone else gets `OWNER_ONLY_POST` back from the server.
///   2. Muted members list — admins can silence a specific member with an
///      optional duration. Muted members get `MUTED` back.
///
/// All actions hit the same endpoints whether you opened them from a channel
/// or a group, since the server treats both uniformly.
class ModerationScreen extends StatefulWidget {
  final Conversation conversation;
  const ModerationScreen({super.key, required this.conversation});

  @override
  State<ModerationScreen> createState() => _ModerationScreenState();
}

class _ModerationScreenState extends State<ModerationScreen> {
  late bool _ownerOnly;
  List<Map<String, dynamic>> _mutes = [];
  List<ConversationMember> _members = [];
  bool _canManageModeration = false;
  bool _canManageRoles = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _ownerOnly = widget.conversation.ownerOnlyPost;
    _load();
  }

  Future<void> _load() async {
    final api = context.read<ApiService>();
    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    try {
      final members = await api.getConversationMembers(widget.conversation.id);
      final me = members.where((m) => m.userId == currentUserId).firstOrNull;
      final canManageModeration =
          me?.hasPermission(AdminPermission.manageModeration) ?? false;
      final canManageRoles =
          me?.hasPermission(AdminPermission.manageRoles) ?? false;
      final mutes = canManageModeration
          ? await api.listMutes(widget.conversation.id)
          : <dynamic>[];
      if (!mounted) return;
      setState(() {
        _mutes = mutes.cast<Map<String, dynamic>>();
        _members = members;
        _canManageModeration = canManageModeration;
        _canManageRoles = canManageRoles;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load: $e')));
    }
  }

  Future<void> _toggleOwnerOnly(bool value) async {
    final api = context.read<ApiService>();
    setState(() => _ownerOnly = value);
    try {
      await api.setOwnerOnlyPost(widget.conversation.id, value);
    } catch (e) {
      if (!mounted) return;
      setState(() => _ownerOnly = !value);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _muteMember(ConversationMember m) async {
    final api = context.read<ApiService>();
    final dur = await showDialog<int?>(
      context: context,
      builder: (ctx) => GlassSimpleDialog(
        title: Text('Mute @${m.user?.username ?? "user"}?'),
        children: [
          for (final opt in const [
            (0, 'Indefinitely'),
            (60, '1 hour'),
            (60 * 24, '1 day'),
            (60 * 24 * 7, '1 week'),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, opt.$1),
              child: Text(opt.$2),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (dur == null) return;
    try {
      await api.muteUser(
        convID: widget.conversation.id,
        userID: m.userId,
        durationMinutes: dur,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to mute: $e')));
    }
  }

  Future<void> _unmute(String userID) async {
    final api = context.read<ApiService>();
    try {
      await api.unmuteUser(convID: widget.conversation.id, userID: userID);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to unmute: $e')));
    }
  }

  Future<void> _editPermissions(ConversationMember m) async {
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    final username = m.user?.username ?? m.userId;
    await showAdminPermissionsSheet(
      context: context,
      member: m,
      onSave: (role, permissions) async {
        await api.setChannelMemberRole(
          widget.conversation.id,
          m.userId,
          role.apiValue,
          adminPermissions: permissions,
        );
        await _load();
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(content: Text('@$username permissions updated')),
        );
      },
    );
  }

  Future<void> _showAuditHistory() async {
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final events = await api.listAdminAuditEvents(
        widget.conversation.id,
        channel: widget.conversation.isChannel,
      );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _AuditHistorySheet(events: events),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to load history: $e')),
      );
    }
  }

  Future<void> _ban(ConversationMember m) async {
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text('Ban @${m.user?.username ?? "user"}?'),
        content: const Text(
          'They will be removed from the channel and blocked from rejoining '
          'until you unban them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ban'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.banChannelUser(widget.conversation.id, m.userId);
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed to ban: $e')));
    }
  }

  String _roleLabel(MemberRole role) => switch (role) {
    MemberRole.admin => 'Admin',
    MemberRole.moderator => 'Moderator',
    MemberRole.member => 'Member',
  };

  @override
  Widget build(BuildContext context) {
    final mutedIDs = _mutes.map((m) => m['user_id'] as String).toSet();
    final mutableMembers = _canManageModeration
        ? _members
              .where((m) => !m.isAdmin && !mutedIDs.contains(m.userId))
              .toList()
        : <ConversationMember>[];
    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    // Role/ban management applies to channels only (the endpoints are channel-
    // scoped); exclude yourself from the actionable list.
    final manageableMembers =
        widget.conversation.isChannel &&
            (_canManageRoles || _canManageModeration)
        ? _members.where((m) => m.userId != currentUserId).toList()
        : <ConversationMember>[];

    return Scaffold(
      appBar: const GlassAppBar(title: Text('Moderation')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                if (_canManageModeration || _canManageRoles)
                  ListTile(
                    leading: const Icon(Icons.history_rounded),
                    title: const Text('Audit history'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: _showAuditHistory,
                  ),
                if (_canManageModeration)
                  SwitchListTile(
                    secondary: const Icon(Icons.campaign_outlined),
                    title: const Text('Admins-only posting'),
                    subtitle: const Text(
                      'When on, regular members can\'t send messages.',
                    ),
                    value: _ownerOnly,
                    onChanged: _toggleOwnerOnly,
                  ),
                if (_canManageModeration) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'Muted members (${_mutes.length})',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (_mutes.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        'No one is muted.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  for (final mute in _mutes)
                    ListTile(
                      leading: const Icon(Icons.volume_off_outlined),
                      title: Text(_displayNameFor(mute['user_id'] as String)),
                      subtitle: Text(_muteSubtitle(mute)),
                      trailing: TextButton(
                        onPressed: () => _unmute(mute['user_id'] as String),
                        child: const Text('Unmute'),
                      ),
                    ),
                  const Divider(),
                  if (mutableMembers.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'Mute a member',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    for (final m in mutableMembers)
                      ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: Text('@${m.user?.username ?? "user"}'),
                        trailing: const Icon(Icons.volume_off),
                        onTap: () => _muteMember(m),
                      ),
                  ],
                ],
                if (manageableMembers.isNotEmpty) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'Members & roles',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  for (final m in manageableMembers)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text('@${m.user?.username ?? "user"}'),
                      subtitle: Text(_roleLabel(m.role)),
                      trailing: IconButton(
                        icon: const Icon(Icons.more_vert),
                        onPressed: () => _showMemberMenu(context, m),
                      ),
                    ),
                ],
              ],
            ),
    );
  }

  void _showMemberMenu(BuildContext context, ConversationMember m) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            if (_canManageRoles)
              _ModTile(
                icon: Icons.admin_panel_settings_outlined,
                label: 'Permissions',
                onTap: () {
                  Navigator.pop(context);
                  _editPermissions(m);
                },
              ),
            if (_canManageModeration)
              _ModTile(
                icon: Icons.block_rounded,
                label: 'Ban',
                color: Colors.red,
                onTap: () {
                  Navigator.pop(context);
                  _ban(m);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _displayNameFor(String userID) {
    final m = _members.firstWhere(
      (m) => m.userId == userID,
      orElse: () => ConversationMember(
        conversationId: widget.conversation.id,
        userId: userID,
        role: MemberRole.member,
        joinedAt: DateTime.now(),
      ),
    );
    return '@${m.user?.username ?? userID.substring(0, 8)}';
  }

  String _muteSubtitle(Map<String, dynamic> mute) {
    final until = mute['muted_until'] as String?;
    final reason = mute['reason'] as String?;
    final parts = <String>[];
    parts.add(
      until == null
          ? 'Indefinitely'
          : 'Until ${DateTime.parse(until).toLocal().toString().split(".").first}',
    );
    if (reason != null && reason.isNotEmpty) parts.add('· $reason');
    return parts.join(' ');
  }
}

class _ModTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _ModTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? scheme.primary;
    return ClipRRect(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tint.withValues(alpha: 0.12),
                  ),
                  child: Icon(icon, size: 18, color: tint),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AuditHistorySheet extends StatelessWidget {
  final List<AdminAuditEvent> events;

  const _AuditHistorySheet({required this.events});

  @override
  Widget build(BuildContext context) {
    return GlassBottomSheetFrame(
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 680),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                child: Row(
                  children: [
                    const Icon(Icons.history_rounded),
                    const SizedBox(width: 10),
                    Text(
                      'Audit history',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              if (events.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 28, 20, 36),
                  child: Text('No admin events yet.'),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: events.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) =>
                        _AuditHistoryTile(event: events[index]),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuditHistoryTile extends StatelessWidget {
  final AdminAuditEvent event;

  const _AuditHistoryTile({required this.event});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(_auditIcon(event.action), color: scheme.primary),
      title: Text(_auditTitle(event)),
      subtitle: Text(_auditSubtitle(event)),
      isThreeLine: true,
    );
  }
}

IconData _auditIcon(String action) => switch (action) {
  'member_role_updated' => Icons.admin_panel_settings_outlined,
  'member_muted' || 'member_unmuted' => Icons.volume_off_outlined,
  'member_banned' || 'member_unbanned' => Icons.block_rounded,
  'message_deleted' || 'messages_deleted' => Icons.delete_sweep_outlined,
  'channel_post_pinned' || 'channel_post_unpinned' => Icons.push_pin_outlined,
  'invite_link_created' || 'invite_link_revoked' => Icons.link_rounded,
  'join_request_approved' ||
  'join_request_rejected' => Icons.how_to_reg_outlined,
  'encryption_updated' => Icons.lock_outline_rounded,
  'slow_mode_updated' || 'message_ttl_updated' => Icons.timer_outlined,
  'topic_created' ||
  'topic_updated' ||
  'topics_enabled_updated' => Icons.forum_outlined,
  'owner_only_post_updated' => Icons.campaign_outlined,
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
  'encryption_updated' => 'Updated encryption',
  'join_approval_updated' => 'Updated join approval',
  'topics_enabled_updated' => 'Updated topics',
  'topic_created' => 'Created topic',
  'topic_updated' => 'Updated topic',
  'admin_anonymity_updated' => 'Updated ${event.targetLabel}',
  'join_request_approved' => 'Approved ${event.targetLabel}',
  'join_request_rejected' => 'Rejected ${event.targetLabel}',
  'owner_only_post_updated' => 'Updated posting mode',
  _ => event.action.replaceAll('_', ' '),
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
      return role is String ? role : null;
    case 'messages_deleted':
      final scope = metadata['scope'];
      final count = metadata['count'];
      if (scope is String && count is int) return '$scope · $count';
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
      final enabled = metadata['enabled'] ?? metadata['required'];
      return enabled is bool ? (enabled ? 'On' : 'Off') : null;
    default:
      return null;
  }
}
