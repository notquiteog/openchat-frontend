import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_config.dart';
import '../../models/conversation.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/admin_permissions_sheet.dart';
import '../../widgets/glass.dart';

/// The scalable member roster behind "Members & roles" in moderation.
///
/// A 1000-member channel can't be moderated from a flat dump of every member:
/// this screen pages the membership in from the server one search-driven page
/// at a time ([ApiService.searchConversationMembers]) with infinite scroll, so
/// the client never holds the whole list. Each row opens an action sheet with
/// only the actions the caller is allowed to take — edit role/permissions, mute
/// for a duration, or ban — so promoting, muting, and banning a specific person
/// is a search-and-tap regardless of channel size.
class ChannelMembersScreen extends StatefulWidget {
  final Conversation conversation;
  final bool canManageRoles;
  final bool canManageModeration;

  /// User IDs currently muted, seeded from the moderation screen so rows can
  /// show muted state and offer Unmute immediately. Kept in sync locally as the
  /// caller mutes/unmutes from here.
  final Set<String> initiallyMutedUserIds;

  const ChannelMembersScreen({
    super.key,
    required this.conversation,
    required this.canManageRoles,
    required this.canManageModeration,
    this.initiallyMutedUserIds = const {},
  });

  @override
  State<ChannelMembersScreen> createState() => _ChannelMembersScreenState();
}

class _ChannelMembersScreenState extends State<ChannelMembersScreen> {
  static const _pageSize = 40;

  final _scrollCtrl = ScrollController();
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  String _query = '';
  final List<ConversationMember> _members = [];
  late Set<String> _mutedIds;
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

  Conversation get _conversation => widget.conversation;
  bool get _isChannel => _conversation.isChannel;
  bool get _hasMore => _members.length < _total;

  @override
  void initState() {
    super.initState();
    _mutedIds = {...widget.initiallyMutedUserIds};
    _scrollCtrl.addListener(_onScroll);
    _loadFirstPage();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 480) {
      _loadMore();
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (value.trim() == _query) return;
      _query = value.trim();
      _loadFirstPage();
    });
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await context.read<ApiService>().searchConversationMembers(
        _conversation.id,
        query: _query,
        limit: _pageSize,
        offset: 0,
      );
      if (!mounted) return;
      setState(() {
        _members
          ..clear()
          ..addAll(page.members);
        _total = page.total;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final page = await context.read<ApiService>().searchConversationMembers(
        _conversation.id,
        query: _query,
        limit: _pageSize,
        offset: _members.length,
      );
      if (!mounted) return;
      setState(() {
        // Guard against dupes if membership shifted between pages.
        final seen = _members.map((m) => m.userId).toSet();
        _members.addAll(page.members.where((m) => !seen.contains(m.userId)));
        _total = page.total;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      showAppToast(context, 'Failed to load more: $e', isError: true);
    }
  }

  // ---- Per-member actions ---------------------------------------------------

  bool _isSelf(ConversationMember m) =>
      m.userId == context.read<AuthProvider>().currentUser?.id;

  bool _isOwner(ConversationMember m) => m.userId == _conversation.createdBy;

  bool _canEditRole(ConversationMember m) =>
      widget.canManageRoles && _isChannel && !_isSelf(m);

  bool _canMute(ConversationMember m) =>
      widget.canManageModeration &&
      !_isSelf(m) &&
      !m.isAdmin &&
      !_mutedIds.contains(m.userId);

  bool _canUnmute(ConversationMember m) =>
      widget.canManageModeration && _mutedIds.contains(m.userId);

  bool _canBan(ConversationMember m) =>
      widget.canManageModeration && _isChannel && !_isSelf(m) && !_isOwner(m);

  bool _hasActions(ConversationMember m) =>
      _canEditRole(m) || _canMute(m) || _canUnmute(m) || _canBan(m);

  void _showMemberActions(ConversationMember m) {
    final username = m.user?.username ?? 'user';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GlassSheetGrabber(),
            GlassSheetHeader(
              icon: Icons.manage_accounts_outlined,
              title: '@$username',
              subtitle: _roleLabel(m.role),
              onClose: () => Navigator.pop(sheetCtx),
            ),
            const SizedBox(height: 4),
            GlassMenuSection(
              entries: [
                if (_canEditRole(m))
                  GlassMenuEntry(
                    icon: Icons.admin_panel_settings_outlined,
                    label: 'Role & permissions',
                    showChevron: true,
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      _editPermissions(m);
                    },
                  ),
                if (_canMute(m))
                  GlassMenuEntry(
                    icon: Icons.volume_off_outlined,
                    label: 'Mute…',
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      _muteMember(m);
                    },
                  ),
                if (_canUnmute(m))
                  GlassMenuEntry(
                    icon: Icons.volume_up_outlined,
                    label: 'Unmute',
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      _unmuteMember(m);
                    },
                  ),
              ],
            ),
            if (_canBan(m)) ...[
              const SizedBox(height: 10),
              GlassMenuSection(
                entries: [
                  GlassMenuEntry(
                    icon: Icons.block_rounded,
                    label: 'Ban from channel',
                    color: Theme.of(context).colorScheme.error,
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      _banMember(m);
                    },
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _editPermissions(ConversationMember m) async {
    final api = context.read<ApiService>();
    final username = m.user?.username ?? m.userId;
    await showAdminPermissionsSheet(
      context: context,
      member: m,
      onSave: (role, permissions) async {
        await api.setChannelMemberRole(
          _conversation.id,
          m.userId,
          role.apiValue,
          adminPermissions: permissions,
        );
        if (!mounted) return;
        showAppToast(context, '@$username updated');
        // Role/permissions affect ordering and badges — refresh the page.
        await _loadFirstPage();
      },
    );
  }

  Future<void> _muteMember(ConversationMember m) async {
    final api = context.read<ApiService>();
    final username = m.user?.username ?? 'user';
    await showGlassActionSheet<void>(
      context: context,
      title: 'Mute @$username',
      actions: [
        for (final opt in const [
          (0, 'Indefinitely'),
          (60, 'For 1 hour'),
          (60 * 24, 'For 1 day'),
          (60 * 24 * 7, 'For 1 week'),
        ])
          GlassActionSheetAction(
            label: opt.$2,
            onPressed: () async {
              try {
                await api.muteUser(
                  convID: _conversation.id,
                  userID: m.userId,
                  durationMinutes: opt.$1,
                );
                if (!mounted) return;
                setState(() => _mutedIds.add(m.userId));
                showAppToast(context, '@$username muted');
              } catch (e) {
                if (mounted) {
                  showAppToast(context, 'Failed to mute: $e', isError: true);
                }
              }
            },
          ),
      ],
    );
  }

  Future<void> _unmuteMember(ConversationMember m) async {
    final api = context.read<ApiService>();
    final username = m.user?.username ?? 'user';
    try {
      await api.unmuteUser(convID: _conversation.id, userID: m.userId);
      if (!mounted) return;
      setState(() => _mutedIds.remove(m.userId));
      showAppToast(context, '@$username unmuted');
    } catch (e) {
      if (mounted) showAppToast(context, 'Failed to unmute: $e', isError: true);
    }
  }

  Future<void> _banMember(ConversationMember m) async {
    final api = context.read<ApiService>();
    final username = m.user?.username ?? 'user';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text('Ban @$username?'),
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
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ban'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.banChannelUser(_conversation.id, m.userId);
      if (!mounted) return;
      setState(() {
        _members.removeWhere((x) => x.userId == m.userId);
        _mutedIds.remove(m.userId);
        if (_total > 0) _total -= 1;
      });
      showAppToast(context, '@$username banned');
    } catch (e) {
      if (mounted) showAppToast(context, 'Failed to ban: $e', isError: true);
    }
  }

  String _roleLabel(MemberRole role) => switch (role) {
    MemberRole.admin => 'Admin',
    MemberRole.moderator => 'Moderator',
    MemberRole.member => 'Member',
  };

  // ---- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return GlassScreenScaffold(
      title: const Text('Members & roles'),
      body: Column(
        children: [
          SizedBox(height: topInset + 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: GlassSearchBar(
              controller: _searchCtrl,
              placeholder: 'Search members',
              onChanged: _onSearchChanged,
            ),
          ),
          _CountStrip(
            loading: _loading,
            shown: _members.length,
            total: _total,
            searching: _query.isNotEmpty,
          ),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(child: GlassProgressIndicator.circular());
    }
    if (_error != null) {
      return _EmptyState(
        icon: Icons.error_outline_rounded,
        title: 'Couldn\'t load members',
        subtitle: '$_error',
      );
    }
    if (_members.isEmpty) {
      return _EmptyState(
        icon: _query.isEmpty ? Icons.group_outlined : Icons.search_off_rounded,
        title: _query.isEmpty ? 'No members yet' : 'No matches',
        subtitle: _query.isEmpty ? null : 'No members match “$_query”.',
      );
    }
    return ListView.builder(
      controller: _scrollCtrl,
      padding: EdgeInsets.fromLTRB(
        12,
        4,
        12,
        MediaQuery.paddingOf(context).bottom + 24,
      ),
      itemCount: _members.length + 1,
      itemBuilder: (context, index) {
        if (index == _members.length) {
          return _ListFooter(loadingMore: _loadingMore, hasMore: _hasMore);
        }
        return _memberTile(_members[index]);
      },
    );
  }

  Widget _memberTile(ConversationMember m) {
    final scheme = Theme.of(context).colorScheme;
    final username = m.user?.username ?? m.userId.substring(0, 8);
    final display = m.user?.profileDisplayName?.trim();
    final muted = _mutedIds.contains(m.userId);
    final actionable = _hasActions(m);
    return GlassListTile(
      leading: _Avatar(member: m),
      title: Row(
        children: [
          Flexible(
            child: Text(
              '@$username',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ),
          if (_isOwner(m)) ...[
            const SizedBox(width: 6),
            _RolePill(label: 'Owner', color: scheme.primary),
          ] else if (m.isAdmin) ...[
            const SizedBox(width: 6),
            _RolePill(label: 'Admin', color: scheme.primary),
          ] else if (m.isModerator) ...[
            const SizedBox(width: 6),
            _RolePill(label: 'Mod', color: scheme.tertiary),
          ],
        ],
      ),
      subtitle: muted || (display != null && display.isNotEmpty)
          ? Row(
              children: [
                if (muted) ...[
                  Icon(Icons.volume_off_rounded, size: 13, color: scheme.error),
                  const SizedBox(width: 4),
                  Text(
                    'Muted',
                    style: TextStyle(
                      color: scheme.error,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (display != null && display.isNotEmpty)
                    const Text('  ·  ', style: TextStyle(fontSize: 12.5)),
                ],
                if (display != null && display.isNotEmpty)
                  Flexible(
                    child: Text(
                      display,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
              ],
            )
          : null,
      trailing: actionable
          ? Icon(
              Icons.more_horiz_rounded,
              color: scheme.onSurface.withValues(alpha: 0.55),
            )
          : null,
      onTap: actionable ? () => _showMemberActions(m) : null,
    );
  }
}

class _CountStrip extends StatelessWidget {
  final bool loading;
  final int shown;
  final int total;
  final bool searching;

  const _CountStrip({
    required this.loading,
    required this.shown,
    required this.total,
    required this.searching,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final String text;
    if (loading) {
      text = 'Loading…';
    } else if (searching) {
      text = total == 1 ? '1 match' : '$total matches';
    } else if (total == 0) {
      text = 'No members';
    } else if (shown < total) {
      text = 'Showing $shown of $total members';
    } else {
      text = total == 1 ? '1 member' : '$total members';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: scheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

class _ListFooter extends StatelessWidget {
  final bool loadingMore;
  final bool hasMore;

  const _ListFooter({required this.loadingMore, required this.hasMore});

  @override
  Widget build(BuildContext context) {
    if (!hasMore && !loadingMore) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: GlassProgressIndicator.circular(),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final ConversationMember member;
  const _Avatar({required this.member});

  @override
  Widget build(BuildContext context) {
    final url = member.user?.avatarUrl;
    return CircleAvatar(
      radius: 20,
      backgroundImage: url != null
          ? CachedNetworkImageProvider(ApiConfig.resolveMedia(url))
          : null,
      child: url == null
          ? Text(
              member.user?.avatarInitial ?? '?',
              style: const TextStyle(fontWeight: FontWeight.w700),
            )
          : null,
    );
  }
}

class _RolePill extends StatelessWidget {
  final String label;
  final Color color;
  const _RolePill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22), width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  const _EmptyState({required this.icon, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 44,
              color: scheme.onSurface.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
