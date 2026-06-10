import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/conversation.dart';
import '../../models/moderation_report.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/admin_permissions_sheet.dart';
import '../../widgets/glass.dart';
import 'admin_audit_log_screen.dart';

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
  late int _newMemberCooldownSeconds;
  late bool _blockLinks;
  late bool _blockMedia;
  late int _mentionLimit;
  List<Map<String, dynamic>> _mutes = [];
  List<ModerationReport> _reports = [];
  List<ConversationMember> _members = [];
  bool _canManageModeration = false;
  bool _canManageRoles = false;
  bool _loading = true;
  bool _savingAntiSpam = false;

  @override
  void initState() {
    super.initState();
    _ownerOnly = widget.conversation.ownerOnlyPost;
    _newMemberCooldownSeconds = widget.conversation.newMemberCooldownSeconds;
    _blockLinks = widget.conversation.antiSpamBlockLinks;
    _blockMedia = widget.conversation.antiSpamBlockMedia;
    _mentionLimit = widget.conversation.antiSpamMentionLimit;
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
      final reports = canManageModeration
          ? await api.listModerationReports(
              widget.conversation.id,
              channel: widget.conversation.isChannel,
            )
          : <ModerationReport>[];
      if (!mounted) return;
      setState(() {
        _mutes = mutes.cast<Map<String, dynamic>>();
        _reports = reports;
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

  static const _cooldownOptions = <(int, String)>[
    (0, 'Off'),
    (60, '1 min'),
    (300, '5 min'),
    (3600, '1 hour'),
    (86400, '1 day'),
  ];

  static const _mentionLimitOptions = <(int, String)>[
    (0, 'Off'),
    (1, '1'),
    (3, '3'),
    (5, '5'),
    (10, '10'),
    (25, '25'),
  ];

  String _optionLabel(List<(int, String)> options, int value) {
    for (final opt in options) {
      if (opt.$1 == value) return opt.$2;
    }
    return '$value';
  }

  Future<void> _pickAntiSpamOption({
    required String title,
    required List<(int, String)> options,
    required ValueChanged<int> onSelected,
  }) {
    return showGlassActionSheet<void>(
      context: context,
      title: title,
      actions: [
        for (final opt in options)
          GlassActionSheetAction(
            label: opt.$2,
            onPressed: () => onSelected(opt.$1),
          ),
      ],
    );
  }

  Future<void> _saveAntiSpamControls({
    int? newMemberCooldownSeconds,
    bool? blockLinks,
    bool? blockMedia,
    int? mentionLimit,
  }) async {
    final previousCooldown = _newMemberCooldownSeconds;
    final previousBlockLinks = _blockLinks;
    final previousBlockMedia = _blockMedia;
    final previousMentionLimit = _mentionLimit;
    setState(() {
      _newMemberCooldownSeconds =
          newMemberCooldownSeconds ?? _newMemberCooldownSeconds;
      _blockLinks = blockLinks ?? _blockLinks;
      _blockMedia = blockMedia ?? _blockMedia;
      _mentionLimit = mentionLimit ?? _mentionLimit;
      _savingAntiSpam = true;
    });
    try {
      await context.read<ApiService>().setAntiSpamControls(
        widget.conversation.id,
        channel: widget.conversation.isChannel,
        newMemberCooldownSeconds: _newMemberCooldownSeconds,
        blockLinks: _blockLinks,
        blockMedia: _blockMedia,
        mentionLimit: _mentionLimit,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _newMemberCooldownSeconds = previousCooldown;
        _blockLinks = previousBlockLinks;
        _blockMedia = previousBlockMedia;
        _mentionLimit = previousMentionLimit;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed: $e')));
    } finally {
      if (mounted) {
        setState(() => _savingAntiSpam = false);
      }
    }
  }

  Future<void> _showReportActions(ModerationReport report) async {
    await showGlassActionSheet<void>(
      context: context,
      actions: [
        GlassActionSheetAction(
          icon: const Icon(Icons.check_circle_outline),
          label: 'Resolve',
          onPressed: () {
            _resolveReport(report, 'resolved');
          },
        ),
        GlassActionSheetAction(
          icon: const Icon(Icons.cancel_outlined),
          label: 'Dismiss',
          style: GlassActionSheetStyle.destructive,
          onPressed: () {
            _resolveReport(report, 'dismissed');
          },
        ),
      ],
    );
  }

  Future<void> _resolveReport(ModerationReport report, String status) async {
    try {
      await context.read<ApiService>().resolveModerationReport(
        widget.conversation.id,
        report.id,
        channel: widget.conversation.isChannel,
        status: status,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
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
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AdminAuditLogScreen(conversation: widget.conversation),
      ),
    );
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
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Moderation')),
      body: _loading
          ? const Center(child: GlassProgressIndicator.circular())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                0,
                MediaQuery.paddingOf(context).top + kToolbarHeight,
                0,
                MediaQuery.paddingOf(context).bottom + 16,
              ),
              children: [
                if (_canManageModeration || _canManageRoles)
                  GlassListTile(
                    leading: const Icon(Icons.history_rounded),
                    title: const Text('Audit log'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: _showAuditHistory,
                  ),
                if (_canManageModeration)
                  GlassListTile(
                    leading: const Icon(Icons.campaign_outlined),
                    title: const Text('Admins-only posting',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                      'When on, regular members can\'t send messages.',
                    ),
                    trailing: GlassSwitch(
                      value: _ownerOnly,
                      onChanged: _toggleOwnerOnly,
                      activeColor: Theme.of(context).colorScheme.primary,
                      enableHaptics: true,
                    ),
                    onTap: () => _toggleOwnerOnly(!_ownerOnly),
                  ),
                if (_canManageModeration) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'Anti-spam controls',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  GlassListTile(
                    leading: const Icon(Icons.hourglass_bottom_rounded),
                    title: const Text('New-user cooldown'),
                    trailing: GlassPicker(
                      value: _optionLabel(
                        _cooldownOptions,
                        _newMemberCooldownSeconds,
                      ),
                      width: 112,
                      height: 38,
                      textStyle: TextStyle(
                        fontSize: 15,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      onTap: _savingAntiSpam
                          ? null
                          : () => _pickAntiSpamOption(
                              title: 'New-user cooldown',
                              options: _cooldownOptions,
                              onSelected: (value) => _saveAntiSpamControls(
                                newMemberCooldownSeconds: value,
                              ),
                            ),
                    ),
                  ),
                  GlassListTile(
                    leading: const Icon(Icons.perm_media_outlined),
                    title: const Text('Block media',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    trailing: GlassSwitch(
                      value: _blockMedia,
                      onChanged: (value) {
                        if (!_savingAntiSpam) _saveAntiSpamControls(blockMedia: value);
                      },
                      activeColor: Theme.of(context).colorScheme.primary,
                      enableHaptics: true,
                    ),
                    onTap: _savingAntiSpam
                        ? null
                        : () => _saveAntiSpamControls(blockMedia: !_blockMedia),
                  ),
                  GlassListTile(
                    leading: const Icon(Icons.link_off_rounded),
                    title: const Text('Block links',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    trailing: GlassSwitch(
                      value: _blockLinks,
                      onChanged: (value) {
                        if (!_savingAntiSpam) _saveAntiSpamControls(blockLinks: value);
                      },
                      activeColor: Theme.of(context).colorScheme.primary,
                      enableHaptics: true,
                    ),
                    onTap: _savingAntiSpam
                        ? null
                        : () => _saveAntiSpamControls(blockLinks: !_blockLinks),
                  ),
                  GlassListTile(
                    leading: const Icon(Icons.alternate_email_rounded),
                    title: const Text('Mention limit'),
                    trailing: GlassPicker(
                      value: _optionLabel(_mentionLimitOptions, _mentionLimit),
                      width: 92,
                      height: 38,
                      textStyle: TextStyle(
                        fontSize: 15,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      onTap: _savingAntiSpam
                          ? null
                          : () => _pickAntiSpamOption(
                              title: 'Mention limit',
                              options: _mentionLimitOptions,
                              onSelected: (value) =>
                                  _saveAntiSpamControls(mentionLimit: value),
                            ),
                    ),
                  ),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'Reports (${_reports.length})',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (_reports.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        'No open reports.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  for (final report in _reports)
                    GlassListTile(
                      leading: const Icon(Icons.report_problem_outlined),
                      title: Text(_reportTitle(report)),
                      subtitle: Text(_reportSubtitle(report)),
                      trailing: IconButton(
                        icon: const Icon(Icons.more_vert),
                        onPressed: () => _showReportActions(report),
                      ),
                    ),
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
                    GlassListTile(
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
                      GlassListTile(
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
                    GlassListTile(
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

  String _reportTitle(ModerationReport report) {
    final reported = report.reportedUsername;
    if (reported != null && reported.isNotEmpty) return '@$reported';
    final id = report.reportedUserId;
    return id == null ? 'Reported message' : id.substring(0, 8);
  }

  String _reportSubtitle(ModerationReport report) {
    final reporter = report.reporterUsername;
    final parts = <String>[
      reporter == null || reporter.isEmpty ? 'Report' : 'By @$reporter',
      _formatLocal(report.createdAt),
    ];
    if (report.reason.trim().isNotEmpty) {
      parts.add(report.reason.trim());
    }
    return parts.join(' · ');
  }

  String _formatLocal(DateTime value) =>
      value.toLocal().toString().split('.').first;
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
    return GlassListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: tint.withValues(alpha: 0.12),
        ),
        child: Icon(icon, size: 18, color: tint),
      ),
      title: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
          color: color,
        ),
      ),
      onTap: onTap,
    );
  }
}
