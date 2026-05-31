import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/conversation.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';

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
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _ownerOnly = widget.conversation.ownerOnlyPost;
    _load();
  }

  Future<void> _load() async {
    final api = context.read<ApiService>();
    try {
      final mutes = await api.listMutes(widget.conversation.id);
      final members = await api.getConversationMembers(widget.conversation.id);
      if (!mounted) return;
      setState(() {
        _mutes = mutes.cast<Map<String, dynamic>>();
        _members = members;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to load: $e')));
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _muteMember(ConversationMember m) async {
    final api = context.read<ApiService>();
    final dur = await showDialog<int?>(
      context: context,
      builder: (ctx) => SimpleDialog(
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to mute: $e')));
    }
  }

  Future<void> _unmute(String userID) async {
    final api = context.read<ApiService>();
    try {
      await api.unmuteUser(convID: widget.conversation.id, userID: userID);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to unmute: $e')));
    }
  }

  Future<void> _setRole(ConversationMember m, MemberRole role) async {
    final api = context.read<ApiService>();
    final roleStr = switch (role) {
      MemberRole.admin => 'admin',
      MemberRole.moderator => 'moderator',
      MemberRole.member => 'member',
    };
    try {
      await api.setChannelMemberRole(widget.conversation.id, m.userId, roleStr);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to set role: $e')));
    }
  }

  Future<void> _ban(ConversationMember m) async {
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Ban @${m.user?.username ?? "user"}?'),
        content: const Text(
            'They will be removed from the channel and blocked from rejoining '
            'until you unban them.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
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
    final mutableMembers =
        _members.where((m) => !m.isAdmin && !mutedIDs.contains(m.userId)).toList();
    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    // Role/ban management applies to channels only (the endpoints are channel-
    // scoped); exclude yourself from the actionable list.
    final manageableMembers = widget.conversation.isChannel
        ? _members.where((m) => m.userId != currentUserId).toList()
        : <ConversationMember>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Moderation')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.campaign_outlined),
                  title: const Text('Admins-only posting'),
                  subtitle: const Text(
                      'When on, regular members can\'t send messages — '
                      'only admins of this chat can.'),
                  value: _ownerOnly,
                  onChanged: _toggleOwnerOnly,
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('Muted members (${_mutes.length})',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                if (_mutes.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text('No one is muted.',
                        style: TextStyle(color: Colors.grey)),
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
                    child: Text('Mute a member',
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final m in mutableMembers)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text('@${m.user?.username ?? "user"}'),
                      trailing: const Icon(Icons.volume_off),
                      onTap: () => _muteMember(m),
                    ),
                ],
                if (manageableMembers.isNotEmpty) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text('Members & roles',
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final m in manageableMembers)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text('@${m.user?.username ?? "user"}'),
                      subtitle: Text(_roleLabel(m.role)),
                      trailing: PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert),
                        onSelected: (v) {
                          switch (v) {
                            case 'admin':
                              _setRole(m, MemberRole.admin);
                            case 'moderator':
                              _setRole(m, MemberRole.moderator);
                            case 'member':
                              _setRole(m, MemberRole.member);
                            case 'ban':
                              _ban(m);
                          }
                        },
                        itemBuilder: (_) => [
                          if (m.role != MemberRole.admin)
                            const PopupMenuItem(
                                value: 'admin', child: Text('Make admin')),
                          if (m.role != MemberRole.moderator)
                            const PopupMenuItem(
                                value: 'moderator', child: Text('Make moderator')),
                          if (m.role != MemberRole.member)
                            const PopupMenuItem(
                                value: 'member', child: Text('Make member')),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: 'ban',
                            child: Text('Ban', style: TextStyle(color: Colors.red)),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
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
    parts.add(until == null ? 'Indefinitely' : 'Until ${DateTime.parse(until).toLocal().toString().split(".").first}');
    if (reason != null && reason.isNotEmpty) parts.add('· $reason');
    return parts.join(' ');
  }
}
