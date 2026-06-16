import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/conversation.dart';
import '../../models/moderation_report.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';
import 'admin_audit_log_screen.dart';
import 'channel_members_screen.dart';

/// What changed to a channel/group's lifecycle while the moderation screen was
/// open, handed back to the channel screen so it can reflect the new state.
enum ChannelModerationResult { archived, unarchived, deleted }

/// Owner/admin-side moderation for a channel or group, redesigned as an iOS-26
/// "liquid glass" grouped settings screen.
///
/// The caller's own permissions are passed in (the channel screen already knows
/// them) rather than re-derived from the member list — so this screen never
/// downloads the membership just to render. Member management itself lives in a
/// dedicated searchable, paginated [ChannelMembersScreen] reached from the
/// "Members & roles" row, which is what makes muting / banning / promoting a
/// specific person tractable in a channel with thousands of members. The bounded
/// surfaces (open reports, currently-muted members) stay inline here.
///
/// Channel lifecycle — archive / unarchive / delete — also lives here now,
/// reached from the shield rather than a separate menu.
class ModerationScreen extends StatefulWidget {
  final Conversation conversation;
  final bool canManageModeration;
  final bool canManageRoles;
  final bool canManageSettings;

  /// Owner / system admin: may archive, unarchive, and delete the channel.
  final bool canManageLifecycle;
  final bool isArchived;

  const ModerationScreen({
    super.key,
    required this.conversation,
    required this.canManageModeration,
    required this.canManageRoles,
    required this.canManageSettings,
    this.canManageLifecycle = false,
    this.isArchived = false,
  });

  @override
  State<ModerationScreen> createState() => _ModerationScreenState();
}

class _ModerationScreenState extends State<ModerationScreen> {
  late bool _ownerOnly;
  late bool _ringAll;
  late int _newMemberCooldownSeconds;
  late bool _blockLinks;
  late bool _blockMedia;
  late int _mentionLimit;
  late bool _archived;

  List<Map<String, dynamic>> _mutes = [];
  List<ModerationReport> _reports = [];
  int _memberCount = 0;
  bool _loading = true;
  bool _savingAntiSpam = false;

  /// The lifecycle change to report back to the channel screen on pop.
  ChannelModerationResult? _pendingResult;

  Conversation get _conv => widget.conversation;
  bool get _canMod => widget.canManageModeration;
  bool get _canRoles => widget.canManageRoles;
  bool get _canManageMembers => _canMod || (_canRoles && _conv.isChannel);

  @override
  void initState() {
    super.initState();
    _ownerOnly = _conv.ownerOnlyPost;
    _ringAll = _conv.ringAllOnCallStart;
    _newMemberCooldownSeconds = _conv.newMemberCooldownSeconds;
    _blockLinks = _conv.antiSpamBlockLinks;
    _blockMedia = _conv.antiSpamBlockMedia;
    _mentionLimit = _conv.antiSpamMentionLimit;
    _archived = widget.isArchived;
    _load();
  }

  Future<void> _load() async {
    final api = context.read<ApiService>();
    try {
      final mutes = _canMod ? await api.listMutes(_conv.id) : <dynamic>[];
      final reports = _canMod
          ? await api.listModerationReports(_conv.id, channel: _conv.isChannel)
          : <ModerationReport>[];
      // One cheap count instead of pulling the whole membership.
      var memberCount = _memberCount;
      if (_canManageMembers) {
        final page = await api.searchConversationMembers(_conv.id, limit: 1);
        memberCount = page.total;
      }
      if (!mounted) return;
      setState(() {
        _mutes = mutes.cast<Map<String, dynamic>>();
        _reports = reports;
        _memberCount = memberCount;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showAppToast(context, 'Failed to load: $e', isError: true);
    }
  }

  // ---- Toggles & anti-spam --------------------------------------------------

  Future<void> _toggleOwnerOnly(bool value) async {
    final api = context.read<ApiService>();
    setState(() => _ownerOnly = value);
    try {
      await api.setOwnerOnlyPost(_conv.id, value);
    } catch (e) {
      if (!mounted) return;
      setState(() => _ownerOnly = !value);
      showAppToast(context, 'Failed: $e', isError: true);
    }
  }

  Future<void> _toggleRingAll(bool value) async {
    final api = context.read<ApiService>();
    setState(() => _ringAll = value);
    try {
      await api.setRingAllOnCall(_conv.id, value);
    } catch (e) {
      if (!mounted) return;
      setState(() => _ringAll = !value);
      showAppToast(context, 'Failed: $e', isError: true);
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
        _conv.id,
        channel: _conv.isChannel,
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
      showAppToast(context, 'Failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _savingAntiSpam = false);
    }
  }

  // ---- Reports & mutes ------------------------------------------------------

  Future<void> _showReportActions(ModerationReport report) async {
    await showGlassActionSheet<void>(
      context: context,
      title: _reportTitle(report),
      actions: [
        GlassActionSheetAction(
          icon: const Icon(Icons.check_circle_outline),
          label: 'Resolve',
          onPressed: () => _resolveReport(report, 'resolved'),
        ),
        GlassActionSheetAction(
          icon: const Icon(Icons.cancel_outlined),
          label: 'Dismiss',
          style: GlassActionSheetStyle.destructive,
          onPressed: () => _resolveReport(report, 'dismissed'),
        ),
      ],
    );
  }

  Future<void> _resolveReport(ModerationReport report, String status) async {
    try {
      await context.read<ApiService>().resolveModerationReport(
        _conv.id,
        report.id,
        channel: _conv.isChannel,
        status: status,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, 'Failed: $e', isError: true);
    }
  }

  Future<void> _unmute(String userID) async {
    try {
      await context.read<ApiService>().unmuteUser(
        convID: _conv.id,
        userID: userID,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, 'Failed to unmute: $e', isError: true);
    }
  }

  Future<void> _openMembers() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChannelMembersScreen(
          conversation: _conv,
          canManageRoles: _canRoles,
          canManageModeration: _canMod,
          initiallyMutedUserIds: _mutes
              .map((m) => m['user_id'] as String)
              .toSet(),
        ),
      ),
    );
    // Mutes / roles / member count may have changed in there.
    if (mounted) await _load();
  }

  Future<void> _showAuditHistory() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AdminAuditLogScreen(conversation: _conv),
      ),
    );
  }

  // ---- Lifecycle (archive / unarchive / delete) -----------------------------

  Future<void> _archive() async {
    final api = context.read<ApiService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Archive channel?'),
        content: Text(
          'Archive ${_conv.name ?? 'this channel'}? Subscribers will no longer '
          'be able to post or receive new messages until you unarchive it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.archiveChannel(_conv.id);
      if (!mounted) return;
      setState(() {
        _archived = true;
        _pendingResult = ChannelModerationResult.archived;
      });
      showAppToast(context, 'Channel archived');
    } catch (e) {
      if (mounted) {
        showAppToast(context, 'Failed to archive: $e', isError: true);
      }
    }
  }

  Future<void> _unarchive() async {
    final api = context.read<ApiService>();
    try {
      await api.unarchiveChannel(_conv.id);
      if (!mounted) return;
      setState(() {
        _archived = false;
        _pendingResult = ChannelModerationResult.unarchived;
      });
      showAppToast(context, 'Channel unarchived');
    } catch (e) {
      if (mounted) {
        showAppToast(context, 'Failed to unarchive: $e', isError: true);
      }
    }
  }

  Future<void> _delete() async {
    final api = context.read<ApiService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Delete channel?'),
        content: Text(
          'Permanently delete ${_conv.name ?? 'this channel'} and all its posts '
          'for everyone. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.deleteConversation(_conv.id);
      if (!mounted) return;
      Navigator.pop(context, ChannelModerationResult.deleted);
    } catch (e) {
      if (mounted) showAppToast(context, 'Failed to delete: $e', isError: true);
    }
  }

  // ---- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope<ChannelModerationResult>(
      // We intercept the pop so the lifecycle change (if any) rides back to the
      // channel screen on either the app-bar button or a system/swipe back.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.pop(context, _pendingResult);
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: GlassAppBar(
          title: const Text('Moderation'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.pop(context, _pendingResult),
          ),
        ),
        body: _loading
            ? const Center(child: GlassProgressIndicator.circular())
            : ListView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
                  16,
                  MediaQuery.paddingOf(context).bottom + 32,
                ),
                children: [
                  _ModHero(
                    conversation: _conv,
                    memberCount: _memberCount,
                    showMemberCount: _canManageMembers,
                    archived: _archived,
                  ),
                  if (_archived) ...[
                    const SizedBox(height: 14),
                    _ArchivedBanner(),
                  ],

                  // People ------------------------------------------------
                  if (_canManageMembers) ...[
                    const SizedBox(height: 20),
                    _SectionHeader(_conv.isChannel ? 'People' : 'Members'),
                    _Card([
                      GlassListTile(
                        showDivider: false,
                        leading: _LeadingIcon(
                          Icons.groups_rounded,
                          color: scheme.primary,
                        ),
                        title: Text(
                          _canRoles && _conv.isChannel
                              ? 'Members & roles'
                              : 'Members',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(_membersSubtitle()),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _openMembers,
                      ),
                    ]),
                  ],

                  // Posting -----------------------------------------------
                  if (_canMod ||
                      (widget.canManageSettings && _conv.isGroup)) ...[
                    const SizedBox(height: 20),
                    _SectionHeader('Posting'),
                    _Card([
                      if (_canMod)
                        GlassListTile(
                          showDivider:
                              widget.canManageSettings && _conv.isGroup,
                          leading: _LeadingIcon(
                            Icons.campaign_outlined,
                            color: scheme.primary,
                          ),
                          title: const Text(
                            'Admins-only posting',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: const Text(
                            'When on, regular members can\'t send messages.',
                          ),
                          trailing: GlassSwitch(
                            value: _ownerOnly,
                            onChanged: _toggleOwnerOnly,
                            activeColor: scheme.primary,
                            enableHaptics: true,
                          ),
                          onTap: () => _toggleOwnerOnly(!_ownerOnly),
                        ),
                      if (widget.canManageSettings && _conv.isGroup)
                        GlassListTile(
                          showDivider: false,
                          leading: _LeadingIcon(
                            Icons.notifications_active_outlined,
                            color: scheme.primary,
                          ),
                          title: const Text(
                            'Ring everyone on call start',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: const Text(
                            'Starting a group call rings every member like an '
                            'incoming call, not just a banner.',
                          ),
                          trailing: GlassSwitch(
                            value: _ringAll,
                            onChanged: _toggleRingAll,
                            activeColor: scheme.primary,
                            enableHaptics: true,
                          ),
                          onTap: () => _toggleRingAll(!_ringAll),
                        ),
                    ]),
                  ],

                  // Anti-spam ---------------------------------------------
                  if (_canMod) ...[
                    const SizedBox(height: 20),
                    _SectionHeader('Anti-spam'),
                    _Card([
                      GlassListTile(
                        leading: _LeadingIcon(
                          Icons.hourglass_bottom_rounded,
                          color: scheme.primary,
                        ),
                        title: const Text('New-member cooldown'),
                        subtitle: const Text(
                          'How long new members must wait before posting.',
                        ),
                        trailing: GlassPicker(
                          value: _optionLabel(
                            _cooldownOptions,
                            _newMemberCooldownSeconds,
                          ),
                          width: 112,
                          height: 38,
                          textStyle: TextStyle(
                            fontSize: 15,
                            color: scheme.onSurface,
                          ),
                          onTap: _savingAntiSpam
                              ? null
                              : () => _pickAntiSpamOption(
                                  title: 'New-member cooldown',
                                  options: _cooldownOptions,
                                  onSelected: (v) => _saveAntiSpamControls(
                                    newMemberCooldownSeconds: v,
                                  ),
                                ),
                        ),
                      ),
                      GlassListTile(
                        leading: _LeadingIcon(
                          Icons.perm_media_outlined,
                          color: scheme.primary,
                        ),
                        title: const Text(
                          'Block media',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        trailing: GlassSwitch(
                          value: _blockMedia,
                          onChanged: (v) {
                            if (!_savingAntiSpam) {
                              _saveAntiSpamControls(blockMedia: v);
                            }
                          },
                          activeColor: scheme.primary,
                          enableHaptics: true,
                        ),
                        onTap: _savingAntiSpam
                            ? null
                            : () => _saveAntiSpamControls(
                                blockMedia: !_blockMedia,
                              ),
                      ),
                      GlassListTile(
                        leading: _LeadingIcon(
                          Icons.link_off_rounded,
                          color: scheme.primary,
                        ),
                        title: const Text(
                          'Block links',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        trailing: GlassSwitch(
                          value: _blockLinks,
                          onChanged: (v) {
                            if (!_savingAntiSpam) {
                              _saveAntiSpamControls(blockLinks: v);
                            }
                          },
                          activeColor: scheme.primary,
                          enableHaptics: true,
                        ),
                        onTap: _savingAntiSpam
                            ? null
                            : () => _saveAntiSpamControls(
                                blockLinks: !_blockLinks,
                              ),
                      ),
                      GlassListTile(
                        showDivider: false,
                        leading: _LeadingIcon(
                          Icons.alternate_email_rounded,
                          color: scheme.primary,
                        ),
                        title: const Text('Mention limit'),
                        subtitle: const Text(
                          'Max @mentions allowed in a single message.',
                        ),
                        trailing: GlassPicker(
                          value: _optionLabel(
                            _mentionLimitOptions,
                            _mentionLimit,
                          ),
                          width: 92,
                          height: 38,
                          textStyle: TextStyle(
                            fontSize: 15,
                            color: scheme.onSurface,
                          ),
                          onTap: _savingAntiSpam
                              ? null
                              : () => _pickAntiSpamOption(
                                  title: 'Mention limit',
                                  options: _mentionLimitOptions,
                                  onSelected: (v) =>
                                      _saveAntiSpamControls(mentionLimit: v),
                                ),
                        ),
                      ),
                    ]),
                  ],

                  // Reports -----------------------------------------------
                  if (_canMod) ...[
                    const SizedBox(height: 20),
                    _SectionHeader('Reports (${_reports.length})'),
                    _Card([
                      if (_reports.isEmpty)
                        const _EmptyRow(
                          icon: Icons.verified_outlined,
                          text: 'No open reports',
                        )
                      else
                        for (var i = 0; i < _reports.length; i++)
                          GlassListTile(
                            showDivider: i != _reports.length - 1,
                            leading: _LeadingIcon(
                              Icons.report_problem_outlined,
                              color: scheme.error,
                            ),
                            title: Text(_reportTitle(_reports[i])),
                            subtitle: Text(_reportSubtitle(_reports[i])),
                            trailing: IconButton(
                              icon: const Icon(Icons.more_horiz_rounded),
                              onPressed: () => _showReportActions(_reports[i]),
                            ),
                            onTap: () => _showReportActions(_reports[i]),
                          ),
                    ]),
                  ],

                  // Muted -------------------------------------------------
                  if (_canMod) ...[
                    const SizedBox(height: 20),
                    _SectionHeader('Muted members (${_mutes.length})'),
                    _Card([
                      if (_mutes.isEmpty)
                        const _EmptyRow(
                          icon: Icons.volume_up_outlined,
                          text: 'No one is muted',
                        )
                      else
                        for (var i = 0; i < _mutes.length; i++)
                          GlassListTile(
                            showDivider: i != _mutes.length - 1,
                            leading: _LeadingIcon(
                              Icons.volume_off_rounded,
                              color: scheme.error,
                            ),
                            title: Text(_muteName(_mutes[i])),
                            subtitle: Text(_muteSubtitle(_mutes[i])),
                            trailing: TextButton(
                              onPressed: () =>
                                  _unmute(_mutes[i]['user_id'] as String),
                              child: const Text('Unmute'),
                            ),
                          ),
                    ]),
                  ],

                  // Audit log ---------------------------------------------
                  if (_canMod || _canRoles) ...[
                    const SizedBox(height: 20),
                    _SectionHeader('Records'),
                    _Card([
                      GlassListTile(
                        showDivider: false,
                        leading: _LeadingIcon(
                          Icons.history_rounded,
                          color: scheme.primary,
                        ),
                        title: const Text('Audit log'),
                        subtitle: const Text(
                          'Every admin action, newest first.',
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _showAuditHistory,
                      ),
                    ]),
                  ],

                  // Lifecycle ---------------------------------------------
                  if (widget.canManageLifecycle) ...[
                    const SizedBox(height: 20),
                    _SectionHeader('Channel'),
                    _Card([
                      if (!_archived)
                        GlassListTile(
                          showDivider: false,
                          leading: _LeadingIcon(
                            Icons.archive_outlined,
                            color: Colors.orange,
                          ),
                          title: const Text(
                            'Archive channel',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: const Text('Make read-only for everyone.'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: _archive,
                        )
                      else ...[
                        GlassListTile(
                          leading: _LeadingIcon(
                            Icons.unarchive_outlined,
                            color: scheme.primary,
                          ),
                          title: const Text(
                            'Unarchive channel',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: const Text('Let members post again.'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: _unarchive,
                        ),
                        GlassListTile(
                          showDivider: false,
                          leading: _LeadingIcon(
                            Icons.delete_outline_rounded,
                            color: scheme.error,
                          ),
                          title: Text(
                            'Delete channel',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: scheme.error,
                            ),
                          ),
                          subtitle: const Text('Permanent — cannot be undone.'),
                          trailing: Icon(
                            Icons.chevron_right_rounded,
                            color: scheme.error,
                          ),
                          onTap: _delete,
                        ),
                      ],
                    ]),
                  ],
                ],
              ),
      ),
    );
  }

  String _membersSubtitle() {
    final count = _memberCount == 1 ? '1 member' : '$_memberCount members';
    if (_canRoles && _conv.isChannel) {
      return '$count · search to mute, ban or set roles';
    }
    return '$count · search to mute or remove';
  }

  // ---- Formatting helpers ---------------------------------------------------

  String _muteName(Map<String, dynamic> mute) {
    final username = mute['username'] as String?;
    if (username != null && username.isNotEmpty) return '@$username';
    final display = mute['display_name'] as String?;
    if (display != null && display.isNotEmpty) return display;
    final id = mute['user_id'] as String? ?? '';
    return id.length >= 8 ? id.substring(0, 8) : id;
  }

  String _muteSubtitle(Map<String, dynamic> mute) {
    final until = mute['muted_until'] as String?;
    final reason = mute['reason'] as String?;
    final parts = <String>[
      until == null
          ? 'Muted indefinitely'
          : 'Until ${DateTime.parse(until).toLocal().toString().split(".").first}',
    ];
    if (reason != null && reason.isNotEmpty) parts.add(reason);
    return parts.join(' · ');
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
    if (report.reason.trim().isNotEmpty) parts.add(report.reason.trim());
    return parts.join(' · ');
  }

  String _formatLocal(DateTime value) =>
      value.toLocal().toString().split('.').first;
}

// ── Presentational pieces ────────────────────────────────────────────────────

class _ModHero extends StatelessWidget {
  final Conversation conversation;
  final int memberCount;
  final bool showMemberCount;
  final bool archived;

  const _ModHero({
    required this.conversation,
    required this.memberCount,
    required this.showMemberCount,
    required this.archived,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitleParts = <String>[
      conversation.isChannel ? 'Channel' : 'Group',
      if (showMemberCount)
        memberCount == 1 ? '1 member' : '$memberCount members',
      if (archived) 'Archived',
    ];
    return GlassCard(
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: 0.14),
              border: Border.all(
                color: scheme.primary.withValues(alpha: 0.20),
                width: 0.5,
              ),
            ),
            child: Icon(Icons.shield_rounded, color: scheme.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conversation.name ?? 'Moderation',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitleParts.join(' · '),
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.6),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ArchivedBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Colors.orange.withValues(alpha: 0.30),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.archive_rounded, color: Colors.orange, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'This channel is archived and read-only. Unarchive it below to let '
              'members post again.',
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: 0.8),
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final List<Widget> children;
  const _Card(this.children);

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(children: children),
    );
  }
}

class _LeadingIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _LeadingIcon(this.icon, {required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.13),
        border: Border.all(color: color.withValues(alpha: 0.10), width: 0.5),
      ),
      child: Icon(icon, size: 19, color: color),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.5);
    return GlassListTile(
      showDivider: false,
      leading: _LeadingIcon(icon, color: muted),
      title: Text(text, style: TextStyle(color: muted)),
    );
  }
}
