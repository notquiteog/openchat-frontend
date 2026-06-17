import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/story.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';
import '../../widgets/story_manage_sheet.dart';
import 'story_viewer_screen.dart';

/// "My Stories" hub — the missing place to *see and manage* your own stories.
///
/// Story viewing + per-viewer reactions already exist inside the viewer; this
/// screen adds the management surface the app was missing: every active and
/// archived/expired personal story with its view and reaction counts, aggregate
/// totals, and long-press / overflow access to pin/archive/delete. Tapping a
/// row opens the viewer, where the author can already see exactly who viewed and
/// how they reacted.
class MyStoriesScreen extends StatefulWidget {
  const MyStoriesScreen({super.key});

  @override
  State<MyStoriesScreen> createState() => _MyStoriesScreenState();
}

class _MyStoriesScreenState extends State<MyStoriesScreen> {
  bool _loading = true;
  Object? _error;
  List<Story> _active = const [];
  List<Story> _archived = const [];

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
      // user; partition client-side. Personal stories only (no conversation).
      final all = await context.read<ApiService>().getStories(
        archive: true,
        userId: userId,
      );
      final mine = all.where((s) => s.conversationId == null).toList();
      if (!mounted) return;
      setState(() {
        _active = mine.where((s) => !_isArchivedOrExpired(s)).toList();
        _archived = mine.where(_isArchivedOrExpired).toList();
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

  /// A story falls into the Archived section when explicitly archived or once it
  /// has expired — except a pinned story, which survives expiry and stays active.
  bool _isArchivedOrExpired(Story s) =>
      s.archivedAt != null ||
      (!s.pinned && s.expiresAt.isBefore(DateTime.now()));

  Future<void> _openViewer(List<Story> list, int index) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => StoryViewerScreen(stories: list, initialIndex: index),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _manage(Story story) async {
    final outcome = await showStoryManageSheet(context, story);
    if (outcome.result != StoryManageResult.unchanged && mounted) _load();
  }

  int get _totalViews =>
      [..._active, ..._archived].fold(0, (sum, s) => sum + s.viewCount);
  int get _totalReactions =>
      [..._active, ..._archived].fold(0, (sum, s) => sum + s.reactionCount);

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
    if (_active.isEmpty && _archived.isEmpty) {
      return const _CenteredMessage(
        icon: Icons.auto_stories_outlined,
        text: "You haven't posted any stories yet.",
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
        children: [
          _AggregateHeader(views: _totalViews, reactions: _totalReactions),
          if (_active.isNotEmpty) ...[
            const _SectionLabel('Active'),
            for (var i = 0; i < _active.length; i++)
              _StoryRow(
                story: _active[i],
                onTap: () => _openViewer(_active, i),
                onManage: () => _manage(_active[i]),
              ),
          ],
          if (_archived.isNotEmpty) ...[
            const _SectionLabel('Archived & expired'),
            for (var i = 0; i < _archived.length; i++)
              _StoryRow(
                story: _archived[i],
                onTap: () => _openViewer(_archived, i),
                onManage: () => _manage(_archived[i]),
              ),
          ],
        ],
      ),
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

class _StoryRow extends StatelessWidget {
  final Story story;
  final VoidCallback onTap;
  final VoidCallback onManage;

  const _StoryRow({
    required this.story,
    required this.onTap,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = story.isVideo
        ? Icons.videocam_outlined
        : story.isText
        ? Icons.text_fields_rounded
        : Icons.image_outlined;
    final caption = story.caption.trim();
    final title = caption.isNotEmpty
        ? caption
        : story.isVideo
        ? 'Video story'
        : story.isText
        ? 'Text story'
        : 'Photo story';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onManage,
      child: GlassListTile(
        leading: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: scheme.onSurfaceVariant, size: 22),
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Row(
          children: [
            Icon(
              Icons.visibility_outlined,
              size: 13,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text('${story.viewCount}'),
            const SizedBox(width: 12),
            Icon(
              Icons.favorite_border_rounded,
              size: 13,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text('${story.reactionCount}'),
            if (story.pinned) ...[
              const SizedBox(width: 12),
              Icon(Icons.push_pin, size: 13, color: scheme.onSurfaceVariant),
            ],
          ],
        ),
        trailing: GlassCircleIconButton(
          key: const Key('story-row-manage'),
          tooltip: 'Manage',
          size: 36,
          glowIntensity: 0.04,
          onPressed: onManage,
          icon: const Icon(Icons.more_vert_rounded, size: 18),
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
