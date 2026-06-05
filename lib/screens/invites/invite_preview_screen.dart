import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_config.dart';
import '../../models/conversation.dart';
import '../../models/conversation_invite.dart';
import '../../providers/chat_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';
import '../channels/channel_screen.dart';
import '../chat/chat_screen.dart';

class InvitePreviewScreen extends StatefulWidget {
  final String token;

  const InvitePreviewScreen({super.key, required this.token});

  @override
  State<InvitePreviewScreen> createState() => _InvitePreviewScreenState();
}

class _InvitePreviewScreenState extends State<InvitePreviewScreen> {
  InvitePreview? _preview;
  Object? _error;
  bool _loading = true;
  bool _joining = false;
  bool _requestSent = false;
  bool _openingConversation = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview = await context.read<ApiService>().getInvite(widget.token);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _loading = false;
      });
      if (preview.member) {
        await _openConversation(preview.conversation);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _join() async {
    final preview = _preview;
    if (preview == null || _joining || _requestSent) return;
    setState(() => _joining = true);
    try {
      final result = await context.read<ApiService>().joinInvite(widget.token);
      if (!mounted) return;
      if (result.pending) {
        setState(() {
          _requestSent = true;
          _joining = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Join request sent')));
        return;
      }
      final conversation = result.conversation ?? preview.conversation;
      await _openConversation(conversation);
    } catch (e) {
      if (!mounted) return;
      setState(() => _joining = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Join failed: $e')));
    }
  }

  Future<void> _openConversation(Conversation fallback) async {
    if (_openingConversation) return;
    _openingConversation = true;
    final chat = context.read<ChatProvider>();
    try {
      await chat.refreshConversationsSilently();
    } catch (_) {}
    if (!mounted) return;
    final conversation =
        chat.conversations
            .where((item) => item.id == fallback.id)
            .firstOrNull ??
        fallback;
    final route = MaterialPageRoute<void>(
      builder: (_) => conversation.isChannel
          ? ChannelFeedScreen(channel: conversation)
          : ChatScreen(conversation: conversation),
    );
    Navigator.of(context, rootNavigator: true).pushReplacement(route);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LiquidMeshBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: GlassContainer(
                  shape: const LiquidRoundedSuperellipse(borderRadius: 34),
                  allowElevation: true,
                  glowIntensity: 0.10,
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: _loading
                        ? const _InviteLoadingView()
                        : _error != null
                        ? _InviteErrorView(error: _error!, onRetry: _load)
                        : _InviteReadyView(
                            preview: _preview!,
                            joining: _joining,
                            requestSent: _requestSent,
                            onJoin: _join,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InviteLoadingView extends StatelessWidget {
  const _InviteLoadingView();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      key: ValueKey('invite-loading'),
      height: 220,
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

class _InviteErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _InviteErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      key: const ValueKey('invite-error'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.error.withValues(alpha: 0.14),
          ),
          child: Icon(Icons.link_off_rounded, color: scheme.error, size: 30),
        ),
        const SizedBox(height: 18),
        Text(
          'Invite unavailable',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          '$error',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: GlassButtonWidget(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Close'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GlassButtonWidget.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _InviteReadyView extends StatelessWidget {
  final InvitePreview preview;
  final bool joining;
  final bool requestSent;
  final VoidCallback onJoin;

  const _InviteReadyView({
    required this.preview,
    required this.joining,
    required this.requestSent,
    required this.onJoin,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final conversation = preview.conversation;
    final requiresApproval =
        preview.invite.approvalRequired || conversation.joinApprovalRequired;
    final label =
        conversation.name ?? (conversation.isChannel ? 'Channel' : 'Group');
    final subtitle = conversation.isChannel ? 'Channel invite' : 'Group invite';
    final buttonLabel = requestSent
        ? 'Request sent'
        : requiresApproval
        ? 'Request to Join'
        : 'Join';

    return Column(
      key: const ValueKey('invite-ready'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        const SizedBox(height: 4),
        Center(child: _InviteAvatar(conversation: conversation)),
        const SizedBox(height: 18),
        Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        if ((conversation.description ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            conversation.description!.trim(),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 18),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            _InviteChip(
              icon: conversation.isChannel
                  ? Icons.campaign_outlined
                  : Icons.group_outlined,
              label: conversation.isChannel ? 'Channel' : 'Group',
            ),
            _InviteChip(
              icon: conversation.isPublic
                  ? Icons.public_rounded
                  : Icons.lock_outline_rounded,
              label: conversation.isPublic ? 'Public' : 'Private',
            ),
            _InviteChip(
              icon: requiresApproval
                  ? Icons.verified_user_outlined
                  : Icons.group_add_outlined,
              label: requiresApproval ? 'Approval required' : 'Open invite',
            ),
          ],
        ),
        const SizedBox(height: 24),
        GlassButtonWidget.icon(
          onPressed: joining || requestSent ? null : onJoin,
          icon: joining
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  requestSent
                      ? Icons.hourglass_top_rounded
                      : requiresApproval
                      ? Icons.how_to_reg_outlined
                      : Icons.login_rounded,
                ),
          label: Text(buttonLabel),
        ),
      ],
    );
  }
}

class _InviteAvatar extends StatelessWidget {
  final Conversation conversation;

  const _InviteAvatar({required this.conversation});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = conversation.avatarUrl;
    final label = conversation.name?.trim();
    final initial = label == null || label.isEmpty
        ? (conversation.isChannel ? 'C' : 'G')
        : label.substring(0, 1).toUpperCase();
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.22),
            blurRadius: 26,
            spreadRadius: -8,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipOval(
        child: avatar != null && avatar.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: ApiConfig.resolveMedia(avatar),
                fit: BoxFit.cover,
                errorWidget: (context, url, error) =>
                    _InviteInitial(initial: initial),
              )
            : _InviteInitial(initial: initial),
      ),
    );
  }
}

class _InviteInitial extends StatelessWidget {
  final String initial;

  const _InviteInitial({required this.initial});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [scheme.primary, scheme.tertiary]),
      ),
      child: Center(
        child: Text(
          initial,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 36,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _InviteChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InviteChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: scheme.surface.withValues(alpha: 0.26),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}
