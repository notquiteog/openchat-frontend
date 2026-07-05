import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/conversation.dart';
import '../models/conversation_invite.dart';
import '../providers/chat_provider.dart';
import '../services/api_service.dart';
import 'glass.dart';

Future<void> showConversationInviteLinksSheet(
  BuildContext context, {
  required Conversation conversation,
  required bool channel,
  ValueChanged<bool>? onJoinApprovalChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ConversationInviteLinksSheet(
      conversation: conversation,
      channel: channel,
      onJoinApprovalChanged: onJoinApprovalChanged,
    ),
  );
}

class ConversationInviteLinksSheet extends StatefulWidget {
  final Conversation conversation;
  final bool channel;
  final ValueChanged<bool>? onJoinApprovalChanged;

  const ConversationInviteLinksSheet({
    super.key,
    required this.conversation,
    required this.channel,
    this.onJoinApprovalChanged,
  });

  @override
  State<ConversationInviteLinksSheet> createState() =>
      _ConversationInviteLinksSheetState();
}

class _ConversationInviteLinksSheetState
    extends State<ConversationInviteLinksSheet> {
  var _links = <ConversationInviteLink>[];
  var _requests = <ConversationJoinRequest>[];
  late bool _approvalRequired;
  int _expiresInSeconds = 0;
  int _usageLimit = 0;
  bool _loading = true;
  bool _busy = false;

  StreamSubscription<Map<String, dynamic>>? _joinRequestSub;

  @override
  void initState() {
    super.initState();
    _approvalRequired = widget.conversation.joinApprovalRequired;
    _load();
    // Live-refresh the pending list when a request arrives while the sheet is
    // open. Guarded: tests (and exotic embeddings) may pump this sheet without
    // a ChatProvider above it.
    try {
      _joinRequestSub = context.read<ChatProvider>().joinRequests.listen((
        data,
      ) {
        if (data['conversation_id'] == widget.conversation.id) {
          _reloadRequests();
        }
      });
    } on ProviderNotFoundException {
      // No live updates without a provider — manual refresh still works.
    }
  }

  @override
  void dispose() {
    _joinRequestSub?.cancel();
    super.dispose();
  }

  Future<void> _reloadRequests() async {
    try {
      final api = context.read<ApiService>();
      final requests = await api.listJoinRequests(
        widget.conversation.id,
        channel: widget.channel,
      );
      if (!mounted) return;
      setState(() => _requests = requests);
    } catch (_) {
      // Transient failure: keep the current list; the next event or manual
      // reload reconciles.
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final api = context.read<ApiService>();
      final results = await Future.wait([
        api.listConversationInviteLinks(
          widget.conversation.id,
          channel: widget.channel,
        ),
        api.listJoinRequests(widget.conversation.id, channel: widget.channel),
      ]);
      if (!mounted) return;
      setState(() {
        _links = results[0] as List<ConversationInviteLink>;
        _requests = results[1] as List<ConversationJoinRequest>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showSnack('Invite settings failed: $e');
    }
  }

  Future<void> _setApprovalRequired(bool required) async {
    final previous = _approvalRequired;
    setState(() {
      _approvalRequired = required;
      _busy = true;
    });
    try {
      final api = context.read<ApiService>();
      await api.setJoinApproval(
        widget.conversation.id,
        required,
        channel: widget.channel,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      widget.onJoinApprovalChanged?.call(required);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _approvalRequired = previous;
        _busy = false;
      });
      _showSnack('Approval update failed: $e');
      _load();
    }
  }

  Future<void> _createLink({required bool rotate}) async {
    setState(() => _busy = true);
    try {
      final link = await context
          .read<ApiService>()
          .createConversationInviteLink(
            widget.conversation.id,
            channel: widget.channel,
            approvalRequired: _approvalRequired,
            revokeExisting: rotate,
            expiresInSeconds: _expiresInSeconds,
            usageLimit: _usageLimit == 0 ? null : _usageLimit,
          );
      if (!mounted) return;
      setState(() {
        _links = rotate ? [link] : [link, ..._links];
        _busy = false;
      });
      _showSnack(rotate ? 'Invite links reset' : 'Invite link created');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showSnack('Invite link failed: $e');
    }
  }

  Future<void> _copyLink(ConversationInviteLink link) async {
    await Clipboard.setData(ClipboardData(text: link.inviteUri));
    if (!mounted) return;
    _showSnack('Invite link copied');
  }

  Future<void> _revokeLink(ConversationInviteLink link) async {
    setState(() => _busy = true);
    try {
      await context.read<ApiService>().revokeConversationInviteLink(
        widget.conversation.id,
        link.id,
        channel: widget.channel,
      );
      if (!mounted) return;
      setState(() {
        _links = _links.where((item) => item.id != link.id).toList();
        _busy = false;
      });
      _showSnack('Invite link revoked');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showSnack('Revoke failed: $e');
    }
  }

  Future<void> _reviewRequest(
    ConversationJoinRequest request, {
    required bool approve,
  }) async {
    setState(() => _busy = true);
    try {
      final api = context.read<ApiService>();
      if (approve) {
        await api.approveJoinRequest(
          widget.conversation.id,
          request.userId,
          channel: widget.channel,
        );
      } else {
        await api.rejectJoinRequest(
          widget.conversation.id,
          request.userId,
          channel: widget.channel,
        );
      }
      if (!mounted) return;
      setState(() {
        _requests = _requests
            .where((item) => item.userId != request.userId)
            .toList();
        _busy = false;
      });
      _showSnack(approve ? 'Request approved' : 'Request declined');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showSnack('Request review failed: $e');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title =
        widget.conversation.name ?? (widget.channel ? 'Channel' : 'Group');
    return GlassBottomSheetFrame(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: 0.14),
                ),
                child: Icon(Icons.link_rounded, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Invite links',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: GlassProgressIndicator.circular()),
            )
          else ...[
            _ApprovalSection(
              value: _approvalRequired,
              busy: _busy,
              onChanged: _setApprovalRequired,
            ),
            const SizedBox(height: 12),
            _CreateSection(
              busy: _busy,
              hasLinks: _links.isNotEmpty,
              onCreate: () => _createLink(rotate: false),
              onReset: () => _createLink(rotate: true),
              expiresInSeconds: _expiresInSeconds,
              usageLimit: _usageLimit,
              onExpiresChanged: (value) =>
                  setState(() => _expiresInSeconds = value),
              onUsageLimitChanged: (value) =>
                  setState(() => _usageLimit = value),
            ),
            const SizedBox(height: 12),
            if (_links.isEmpty)
              const _EmptyLinksSection()
            else
              for (final link in _links) ...[
                _LinkSection(
                  link: link,
                  busy: _busy,
                  onCopy: () => _copyLink(link),
                  onRevoke: () => _revokeLink(link),
                ),
                if (link != _links.last) const SizedBox(height: 12),
              ],
            const SizedBox(height: 12),
            _RequestsSection(
              requests: _requests,
              busy: _busy,
              onApprove: (request) => _reviewRequest(request, approve: true),
              onReject: (request) => _reviewRequest(request, approve: false),
            ),
          ],
        ],
      ),
    );
  }
}

class _ApprovalSection extends StatelessWidget {
  final bool value;
  final bool busy;
  final ValueChanged<bool> onChanged;

  const _ApprovalSection({
    required this.value,
    required this.busy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _InvitePanel(
      child: Row(
        children: [
          Icon(
            value ? Icons.verified_user_outlined : Icons.group_add_outlined,
            color: scheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Approve new members',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                Text(
                  value ? 'Required' : 'Anyone with the link',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          AbsorbPointer(
            absorbing: busy,
            child: Opacity(
              opacity: busy ? 0.5 : 1.0,
              child: GlassSwitch(value: value, onChanged: onChanged),
            ),
          ),
        ],
      ),
    );
  }
}

class _CreateSection extends StatelessWidget {
  final bool busy;
  final bool hasLinks;
  final VoidCallback onCreate;
  final VoidCallback onReset;
  final int expiresInSeconds;
  final int usageLimit;
  final ValueChanged<int> onExpiresChanged;
  final ValueChanged<int> onUsageLimitChanged;

  const _CreateSection({
    required this.busy,
    required this.hasLinks,
    required this.onCreate,
    required this.onReset,
    required this.expiresInSeconds,
    required this.usageLimit,
    required this.onExpiresChanged,
    required this.onUsageLimitChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _InvitePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.add_link_rounded, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Create invite link',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _InviteDropdown<int>(
                  label: 'Expires',
                  value: expiresInSeconds,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Never')),
                    DropdownMenuItem(value: 3600, child: Text('1 hour')),
                    DropdownMenuItem(value: 86400, child: Text('1 day')),
                    DropdownMenuItem(value: 604800, child: Text('7 days')),
                    DropdownMenuItem(value: 2592000, child: Text('30 days')),
                  ],
                  onChanged: busy ? null : onExpiresChanged,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _InviteDropdown<int>(
                  label: 'Uses',
                  value: usageLimit,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('No cap')),
                    DropdownMenuItem(value: 1, child: Text('1')),
                    DropdownMenuItem(value: 10, child: Text('10')),
                    DropdownMenuItem(value: 25, child: Text('25')),
                    DropdownMenuItem(value: 100, child: Text('100')),
                  ],
                  onChanged: busy ? null : onUsageLimitChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              GlassButtonWidget.icon(
                onPressed: busy ? null : onCreate,
                icon: const Icon(Icons.add_link_rounded),
                label: const Text('Create'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              if (hasLinks)
                GlassButtonWidget.icon(
                  onPressed: busy ? null : onReset,
                  icon: const Icon(Icons.autorenew_rounded),
                  label: const Text('Reset links'),
                  foregroundColor: scheme.error,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
            ],
          ),
          if (hasLinks) ...[
            const SizedBox(height: 8),
            Text(
              'Reset revokes all links and creates one fresh link.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyLinksSection extends StatelessWidget {
  const _EmptyLinksSection();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _InvitePanel(
      child: Row(
        children: [
          Icon(Icons.link_off_rounded, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'No active invite links — create one above.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkSection extends StatelessWidget {
  final ConversationInviteLink link;
  final bool busy;
  final VoidCallback onCopy;
  final VoidCallback onRevoke;

  const _LinkSection({
    required this.link,
    required this.busy,
    required this.onCopy,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final linkAvailable = !link.isExpired && !link.isUsageLimitReached;
    return _InvitePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.ios_share_rounded, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  link.approvalRequired ? 'Invite (approval)' : 'Invite link',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: scheme.surface.withValues(alpha: 0.26),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.28),
              ),
            ),
            child: Text(
              link.inviteUri,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 10),
          _InviteStats(link: link),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              GlassButtonWidget.icon(
                onPressed: busy || !linkAvailable ? null : onCopy,
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copy'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              GlassButtonWidget.icon(
                onPressed: busy ? null : onRevoke,
                icon: const Icon(Icons.link_off_rounded),
                label: const Text('Revoke'),
                foregroundColor: scheme.error,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InviteStats extends StatelessWidget {
  final ConversationInviteLink link;

  const _InviteStats({required this.link});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w700,
    );
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      children: [
        _StatText(text: 'Views ${link.previewCount}', style: style),
        _StatText(text: 'Joins ${link.joinCount}', style: style),
        _StatText(text: 'Requests ${link.joinRequestCount}', style: style),
        _StatText(text: _usageLabel(link), style: style),
        _StatText(text: _expiryLabel(link), style: style),
      ],
    );
  }

  String _usageLabel(ConversationInviteLink link) {
    if (link.usageLimit == null) return 'Uses ${link.usageCount}';
    return 'Uses ${link.usageCount}/${link.usageLimit}';
  }

  String _expiryLabel(ConversationInviteLink link) {
    final expiresAt = link.expiresAt;
    if (expiresAt == null) return 'Never expires';
    final local = expiresAt.toLocal().toString().split('.').first;
    return link.isExpired ? 'Expired $local' : 'Expires $local';
  }
}

class _StatText extends StatelessWidget {
  final String text;
  final TextStyle? style;

  const _StatText({required this.text, this.style});

  @override
  Widget build(BuildContext context) => Text(text, style: style);
}

class _InviteDropdown<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T>? onChanged;

  const _InviteDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          isExpanded: true,
          iconEnabledColor: scheme.primary,
          items: items,
          onChanged: onChanged == null
              ? null
              : (value) {
                  if (value != null) onChanged!(value);
                },
        ),
      ),
    );
  }
}

class _RequestsSection extends StatelessWidget {
  final List<ConversationJoinRequest> requests;
  final bool busy;
  final ValueChanged<ConversationJoinRequest> onApprove;
  final ValueChanged<ConversationJoinRequest> onReject;

  const _RequestsSection({
    required this.requests,
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _InvitePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.how_to_reg_outlined, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Join requests',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              if (requests.isNotEmpty)
                Text(
                  '${requests.length}',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (requests.isEmpty)
            Text(
              'No pending requests',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            )
          else
            for (final request in requests) ...[
              _JoinRequestTile(
                request: request,
                busy: busy,
                onApprove: () => onApprove(request),
                onReject: () => onReject(request),
              ),
              if (request != requests.last)
                Divider(color: scheme.outlineVariant.withValues(alpha: 0.24)),
            ],
        ],
      ),
    );
  }
}

class _JoinRequestTile extends StatelessWidget {
  final ConversationJoinRequest request;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _JoinRequestTile({
    required this.request,
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final username = request.user?.username;
    final label = username != null
        ? '@$username'
        : _shortUserId(request.userId);
    final avatarText = label.replaceFirst('@', '');
    final avatarInitial = avatarText.isEmpty
        ? '?'
        : avatarText.substring(0, 1).toUpperCase();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: scheme.primary.withValues(alpha: 0.14),
            child: Text(
              avatarInitial,
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            tooltip: 'Decline',
            icon: Icon(Icons.close_rounded, color: scheme.error),
            onPressed: busy ? null : onReject,
          ),
          IconButton(
            tooltip: 'Approve',
            icon: Icon(Icons.check_rounded, color: scheme.primary),
            onPressed: busy ? null : onApprove,
          ),
        ],
      ),
    );
  }

  String _shortUserId(String value) =>
      value.length <= 8 ? value : value.substring(0, 8);
}

class _InvitePanel extends StatelessWidget {
  final Widget child;

  const _InvitePanel({required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: scheme.surface.withValues(alpha: 0.18),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.24),
        ),
      ),
      child: child,
    );
  }
}
