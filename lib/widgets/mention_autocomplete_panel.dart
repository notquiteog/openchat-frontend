import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/api_config.dart';
import '../models/bot_command.dart';
import '../models/conversation.dart';
import '../utils/mention_utils.dart';
import 'glass.dart';

class MentionAutocompletePanel extends StatelessWidget {
  final List<ConversationMember> members;
  final ValueChanged<ConversationMember> onSelected;
  final List<SpecialMention> specialMentions;
  final ValueChanged<SpecialMention>? onSpecialSelected;

  const MentionAutocompletePanel({
    super.key,
    required this.members,
    required this.onSelected,
    this.specialMentions = const [],
    this.onSpecialSelected,
  });

  @override
  Widget build(BuildContext context) {
    final total = specialMentions.length + members.length;
    if (total == 0) return const SizedBox.shrink();
    final height = math.min(218.0, 10.0 + total * 52.0);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - value)),
          child: child,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
        child: GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 24),
          allowElevation: true,
          glowIntensity: 0.05,
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: SizedBox(
            height: height,
            child: ListView.separated(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              itemCount: total,
              separatorBuilder: (_, _) => const SizedBox(height: 2),
              itemBuilder: (context, index) {
                if (index < specialMentions.length) {
                  final special = specialMentions[index];
                  return _SpecialMentionTile(
                    special: special,
                    onTap: () => onSpecialSelected?.call(special),
                  );
                }
                final member = members[index - specialMentions.length];
                return _MentionSuggestionTile(
                  member: member,
                  onTap: () => onSelected(member),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// `/command` autocomplete panel for bot DMs (#31) — same glass styling as
/// [MentionAutocompletePanel], listing command + description rows.
class CommandAutocompletePanel extends StatelessWidget {
  final List<BotCommand> commands;
  final ValueChanged<BotCommand> onSelected;

  const CommandAutocompletePanel({
    super.key,
    required this.commands,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (commands.isEmpty) return const SizedBox.shrink();
    final height = math.min(218.0, 10.0 + commands.length * 52.0);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - value)),
          child: child,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
        child: GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 24),
          allowElevation: true,
          glowIntensity: 0.05,
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: SizedBox(
            height: height,
            child: ListView.separated(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              itemCount: commands.length,
              separatorBuilder: (_, _) => const SizedBox(height: 2),
              itemBuilder: (context, index) => _CommandSuggestionTile(
                command: commands[index],
                onTap: () => onSelected(commands[index]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bot inline-mode results panel (Telegram `@bot <query>`) — same glass styling
/// as [CommandAutocompletePanel]. Shows a compact "Searching…" state while the
/// bot answers, an empty state when it returns nothing, and one glass row per
/// result (title, description, optional network thumbnail).
class InlineResultsPanel extends StatelessWidget {
  final List<Map<String, dynamic>> results;
  final ValueChanged<Map<String, dynamic>> onPick;
  final bool loading;

  const InlineResultsPanel({
    super.key,
    required this.results,
    required this.onPick,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasResults = results.isNotEmpty;
    final height = hasResults
        ? math.min(218.0, 10.0 + results.length * 52.0)
        : 56.0;

    Widget body;
    if (hasResults) {
      body = ListView.separated(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        itemCount: results.length,
        separatorBuilder: (_, _) => const SizedBox(height: 2),
        itemBuilder: (context, index) => _InlineResultTile(
          result: results[index],
          onTap: () => onPick(results[index]),
        ),
      );
    } else {
      body = Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading) ...[
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 10),
            ],
            Text(
              loading ? 'Searching…' : 'No results',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      );
    }

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - value)),
          child: child,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
        child: GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 24),
          allowElevation: true,
          glowIntensity: 0.05,
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: SizedBox(height: height, child: body),
        ),
      ),
    );
  }
}

class _InlineResultTile extends StatelessWidget {
  final Map<String, dynamic> result;
  final VoidCallback onTap;

  const _InlineResultTile({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = (result['title'] as String?)?.trim();
    final description = (result['description'] as String?)?.trim();
    final thumbnailUrl = (result['thumbnail_url'] as String?)?.trim();

    Widget leading;
    if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) {
      leading = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: CachedNetworkImage(
          imageUrl: ApiConfig.resolveMedia(thumbnailUrl),
          width: 32,
          height: 32,
          fit: BoxFit.cover,
          placeholder: (_, _) => Container(
            width: 32,
            height: 32,
            color: scheme.surfaceContainerHighest,
          ),
          errorWidget: (_, _, _) => Container(
            width: 32,
            height: 32,
            color: scheme.surfaceContainerHighest,
            child: Icon(
              Icons.image_not_supported_outlined,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    } else {
      leading = CircleAvatar(
        radius: 16,
        backgroundColor: scheme.primary.withValues(alpha: 0.18),
        child: Icon(Icons.article_outlined, size: 18, color: scheme.primary),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.18),
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    (title == null || title.isEmpty) ? 'Result' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (description != null && description.isNotEmpty)
                    Text(
                      description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommandSuggestionTile extends StatelessWidget {
  final BotCommand command;
  final VoidCallback onTap;

  const _CommandSuggestionTile({required this.command, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.18),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: scheme.primary.withValues(alpha: 0.18),
              child: Icon(
                Icons.terminal_rounded,
                size: 18,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '/${command.command}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (command.description.isNotEmpty)
                    Text(
                      command.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpecialMentionTile extends StatelessWidget {
  final SpecialMention special;
  final VoidCallback onTap;

  const _SpecialMentionTile({required this.special, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: scheme.primary.withValues(alpha: 0.10),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: scheme.primary.withValues(alpha: 0.18),
              child: Icon(
                Icons.campaign_rounded,
                size: 18,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    special.label,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    special.description,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MentionSuggestionTile extends StatelessWidget {
  final ConversationMember member;
  final VoidCallback onTap;

  const _MentionSuggestionTile({required this.member, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final user = member.user;
    final username = user?.username ?? 'unknown';
    final avatarUrl = user?.avatarUrl;
    final role = user?.isBot == true
        ? 'Bot'
        : member.isAdmin
        ? 'Admin'
        : member.isModerator
        ? 'Moderator'
        : null;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.18),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: scheme.surfaceContainerHighest,
              backgroundImage: avatarUrl != null
                  ? CachedNetworkImageProvider(
                      ApiConfig.resolveMedia(avatarUrl),
                    )
                  : null,
              child: avatarUrl == null
                  ? Text(
                      username.isEmpty ? '?' : username[0].toUpperCase(),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurfaceVariant,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '@$username',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (role != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  role,
                  style: TextStyle(
                    color: scheme.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
