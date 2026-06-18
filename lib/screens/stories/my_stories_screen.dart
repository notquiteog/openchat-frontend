import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_config.dart';
import '../../models/story.dart';
import '../../models/story_viewer.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/custom_emoji_image.dart';
import '../../widgets/glass.dart';
import '../../widgets/story_manage_sheet.dart';
import 'story_viewer_screen.dart';

/// "My Stories" hub — the single place to see and manage your own stories.
///
/// Posts are grouped into stories (a "story" is a reel of posts sharing a
/// group), shown active vs archived/expired with aggregate view/reaction
/// totals. Each story expands to its individual posts, and "Who viewed" pulls
/// the per-story viewer list (merged across the story's posts) with each
/// viewer's reaction — so stories, posts, viewers, and reactions all live here.
/// Channel stories the user posted get their own section.
class MyStoriesScreen extends StatefulWidget {
  const MyStoriesScreen({super.key});

  @override
  State<MyStoriesScreen> createState() => _MyStoriesScreenState();
}

class _MyStoriesScreenState extends State<MyStoriesScreen> {
  bool _loading = true;
  Object? _error;
  List<Story> _personal = const [];
  List<Story> _channel = const [];

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
      final userId = context.read<AuthProvider>().currentUser?.id;
      // archive=true returns the full set (active + archived + expired) for the
      // user; split personal vs channel client-side.
      final all = await context.read<ApiService>().getStories(
        archive: true,
        userId: userId,
      );
      if (!mounted) return;
      setState(() {
        _personal = all.where((s) => s.conversationId == null).toList();
        _channel = all.where((s) => s.conversationId != null).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// A post is archived when explicitly archived or expired — except a pinned
  /// post, which survives expiry and stays active.
  bool _isArchivedOrExpired(Story s) =>
      s.archivedAt != null ||
      (!s.pinned && s.expiresAt.isBefore(DateTime.now()));

  /// A whole story is archived only when every one of its posts is.
  bool _isGroupArchived(List<Story> g) => g.every(_isArchivedOrExpired);

  /// Collapses posts into stories by group, posts oldest-first within a story,
  /// stories most-recent-first.
  List<List<Story>> _group(List<Story> stories) {
    final byKey = <String, List<Story>>{};
    final order = <String>[];
    for (final s in stories) {
      byKey
          .putIfAbsent(s.groupKey, () {
            order.add(s.groupKey);
            return <Story>[];
          })
          .add(s);
    }
    final groups = [
      for (final k in order)
        byKey[k]!..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
    ];
    groups.sort((a, b) => b.last.createdAt.compareTo(a.last.createdAt));
    return groups;
  }

  Future<void> _openViewer(List<Story> reel, int index) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => StoryViewerScreen(stories: reel, initialIndex: index),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _manage(Story story) async {
    final outcome = await showStoryManageSheet(context, story);
    if (outcome.result != StoryManageResult.unchanged && mounted) _load();
  }

  /// Loads who viewed a story — merged across all its posts — with each
  /// viewer's reaction, and shows them in a sheet.
  Future<void> _showGroupViewers(List<Story> group) async {
    final api = context.read<ApiService>();
    List<StoryViewer> merged;
    try {
      final lists = await Future.wait(
        group.map((s) => api.getStoryViewers(s.id)),
      );
      final byUser = <String, StoryViewer>{};
      for (final list in lists) {
        for (final v in list) {
          final existing = byUser[v.userId];
          if (existing == null) {
            byUser[v.userId] = v;
          } else {
            byUser[v.userId] = StoryViewer(
              userId: v.userId,
              username: v.username.isNotEmpty ? v.username : existing.username,
              displayName: v.displayName ?? existing.displayName,
              avatarUrl: v.avatarUrl ?? existing.avatarUrl,
              reaction: v.reaction ?? existing.reaction,
              viewedAt: v.viewedAt.isAfter(existing.viewedAt)
                  ? v.viewedAt
                  : existing.viewedAt,
            );
          }
        }
      }
      merged = byUser.values.toList()
        ..sort((a, b) => b.viewedAt.compareTo(a.viewedAt));
    } catch (_) {
      if (mounted) {
        showAppToast(context, 'Could not load viewers', isError: true);
      }
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GlassSheetGrabber(),
            const GlassSheetHeader(
              icon: Icons.visibility_outlined,
              title: 'Viewers',
              subtitle: 'People who viewed this story',
            ),
            if (merged.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 8, 18, 24),
                child: Text('No views yet'),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [for (final v in merged) _ViewerTile(viewer: v)],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  int get _totalViews =>
      [..._personal, ..._channel].fold(0, (sum, s) => sum + s.viewCount);
  int get _totalReactions =>
      [..._personal, ..._channel].fold(0, (sum, s) => sum + s.reactionCount);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GlassAppBar(title: const Text('My stories')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: GlassProgressIndicator.circular());
    }
    if (_error != null) {
      return _CenteredMessage(
        icon: Icons.error_outline_rounded,
        text: 'Could not load your stories.',
        actionLabel: 'Retry',
        onAction: _load,
      );
    }
    if (_personal.isEmpty && _channel.isEmpty) {
      return const _CenteredMessage(
        icon: Icons.auto_stories_outlined,
        text: "You haven't posted any stories yet.",
      );
    }

    final personalGroups = _group(_personal);
    final active = personalGroups.where((g) => !_isGroupArchived(g)).toList();
    final archived = personalGroups.where(_isGroupArchived).toList();
    final channelGroups = _group(_channel);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
        children: [
          _AggregateHeader(views: _totalViews, reactions: _totalReactions),
          if (active.isNotEmpty) ...[
            const _SectionLabel('Active'),
            for (final g in active) _storyCard(g),
          ],
          if (archived.isNotEmpty) ...[
            const _SectionLabel('Archived & expired'),
            for (final g in archived) _storyCard(g),
          ],
          if (channelGroups.isNotEmpty) ...[
            const _SectionLabel('Channel stories'),
            for (final g in channelGroups) _storyCard(g),
          ],
        ],
      ),
    );
  }

  Widget _storyCard(List<Story> group) => _StoryGroupCard(
    group: group,
    onOpen: (index) => _openViewer(group, index),
    // Story-level manage acts on the most recent post in the reel.
    onManage: () => _manage(group.last),
    onViewers: () => _showGroupViewers(group),
  );
}

/// One story (a reel of posts) with its aggregate stats, a manage action, an
/// expandable list of its posts, and a "who viewed" shortcut.
class _StoryGroupCard extends StatelessWidget {
  final List<Story> group;
  final ValueChanged<int> onOpen;
  final VoidCallback onManage;
  final VoidCallback onViewers;

  const _StoryGroupCard({
    required this.group,
    required this.onOpen,
    required this.onManage,
    required this.onViewers,
  });

  int get _views => group.fold(0, (s, e) => s + e.viewCount);
  int get _reactions => group.fold(0, (s, e) => s + e.reactionCount);
  bool get _pinned => group.any((s) => s.pinned);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rep = group.last;
    final caption = rep.caption.trim();
    final title = caption.isNotEmpty
        ? caption
        : group.length > 1
        ? '${group.length} posts'
        : _kindLabel(rep);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassContainer(
        shape: const LiquidRoundedSuperellipse(borderRadius: 20),
        allowElevation: true,
        glowIntensity: 0.05,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _PostThumb(story: rep),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onOpen(0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            if (group.length > 1) ...[
                              Icon(
                                Icons.collections_outlined,
                                size: 13,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Text('${group.length}'),
                              const SizedBox(width: 12),
                            ],
                            Icon(
                              Icons.visibility_outlined,
                              size: 13,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text('$_views'),
                            const SizedBox(width: 12),
                            Icon(
                              Icons.favorite_border_rounded,
                              size: 13,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text('$_reactions'),
                            if (_pinned) ...[
                              const SizedBox(width: 12),
                              Icon(
                                Icons.push_pin,
                                size: 13,
                                color: scheme.onSurfaceVariant,
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                GlassCircleIconButton(
                  key: const Key('story-row-manage'),
                  tooltip: 'Manage',
                  size: 36,
                  glowIntensity: 0.04,
                  onPressed: onManage,
                  icon: const Icon(Icons.more_vert_rounded, size: 18),
                ),
              ],
            ),
            // The individual posts, so the author can jump to any one of them.
            if (group.length > 1) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 56,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: group.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => GestureDetector(
                    onTap: () => onOpen(i),
                    child: _PostThumb(story: group[i], size: 56),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onViewers,
                icon: const Icon(Icons.visibility_outlined, size: 16),
                label: const Text('Who viewed'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _kindLabel(Story s) => s.isVideo
      ? 'Video story'
      : s.isText
      ? 'Text story'
      : 'Photo story';
}

class _PostThumb extends StatelessWidget {
  final Story story;
  final double size;

  const _PostThumb({required this.story, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = story.isVideo
        ? Icons.videocam_outlined
        : story.isText
        ? Icons.text_fields_rounded
        : Icons.image_outlined;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: scheme.onSurfaceVariant, size: size * 0.5),
    );
  }
}

class _ViewerTile extends StatelessWidget {
  final StoryViewer viewer;

  const _ViewerTile({required this.viewer});

  @override
  Widget build(BuildContext context) {
    final display = viewer.displayName?.trim();
    final username = viewer.username.trim();
    final title = display != null && display.isNotEmpty
        ? display
        : username.isNotEmpty
        ? '@$username'
        : 'Unknown viewer';
    final avatar = viewer.avatarUrl;
    final reaction = viewer.reaction;
    return GlassListTile(
      leading: CircleAvatar(
        backgroundImage: avatar != null && avatar.isNotEmpty
            ? NetworkImage(ApiConfig.resolveMedia(avatar))
            : null,
        child: avatar == null || avatar.isEmpty
            ? Text(title.isNotEmpty ? title[0].toUpperCase() : '?')
            : null,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: reaction == null || reaction.isEmpty
          ? null
          : ReactionGlyph(reaction, size: 24),
    );
  }
}

class _AggregateHeader extends StatelessWidget {
  final int views;
  final int reactions;

  const _AggregateHeader({required this.views, required this.reactions});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: _StatCard(
              icon: Icons.visibility_outlined,
              value: views,
              label: 'views',
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatCard(
              icon: Icons.favorite_border_rounded,
              value: reactions,
              label: 'reactions',
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final int value;
  final String label;

  const _StatCard({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassContainer(
      shape: const LiquidRoundedSuperellipse(borderRadius: 20),
      allowElevation: true,
      glowIntensity: 0.05,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Text(
              '$value $label',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 18, 6, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _CenteredMessage({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(text, textAlign: TextAlign.center),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            GlassButtonWidget(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}
