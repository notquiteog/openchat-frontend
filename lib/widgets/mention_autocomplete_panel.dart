import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/api_config.dart';
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
              child: Icon(Icons.campaign_rounded,
                  size: 18, color: scheme.primary),
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
