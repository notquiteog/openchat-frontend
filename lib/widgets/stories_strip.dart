import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/api_config.dart';
import '../models/story.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../screens/stories/create_story_screen.dart';
import '../screens/stories/my_stories_screen.dart';
import '../screens/stories/story_viewer_screen.dart';
import 'story_manage_sheet.dart';

/// A compact, Instagram-style row of story circles shown at the top of the
/// chats list. The avatars are deliberately small (much smaller than the iOS
/// Messages pinned row) so they read as a secondary "updates" affordance rather
/// than dominating the inbox.
const double _kAvatar = 46;
const double _kRing = 56;
const double _kGap =
    51; // diameter of the bg "gap" circle between ring + avatar
const double _kTile = 64;
const double _kStripHeight = 96;

/// The classic Instagram story gradient — signals an unseen story at a glance.
const List<Color> _kStoryGradient = [
  Color(0xFFFEDA77),
  Color(0xFFF58529),
  Color(0xFFDD2A7B),
  Color(0xFF8134AF),
  Color(0xFF515BD4),
];

class StoriesStrip extends StatefulWidget {
  const StoriesStrip({super.key});

  @override
  State<StoriesStrip> createState() => _StoriesStripState();
}

class _StoriesStripState extends State<StoriesStrip> {
  late Future<List<Story>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Story>> _load() => context.read<ApiService>().getStories();

  void _refresh() {
    if (!mounted) return;
    setState(() => _future = _load());
  }

  Future<void> _createStory() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const CreateStoryScreen()),
    );
    if (created == true) _refresh();
  }

  Future<void> _openStories(List<Story> stories, int index) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            StoryViewerScreen(stories: stories, initialIndex: index),
      ),
    );
    _refresh();
  }

  /// Long-press on the "Your story" tile opens the My Stories management hub.
  Future<void> _openMyStories() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MyStoriesScreen()),
    );
    _refresh();
  }

  /// Long-press on one of your own story tiles offers pin/archive/delete.
  Future<void> _manageStory(Story story) async {
    final outcome = await showStoryManageSheet(context, story);
    if (outcome.result != StoryManageResult.unchanged) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = context.watch<AuthProvider>().currentUser?.id ?? '';
    return SizedBox(
      height: _kStripHeight,
      child: FutureBuilder<List<Story>>(
        future: _future,
        builder: (context, snap) {
          final stories = snap.data ?? const <Story>[];
          return ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            itemCount: stories.length + 1,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              if (index == 0) {
                return _StoryAddTile(
                  onTap: _createStory,
                  onLongPress: _openMyStories,
                );
              }
              final storyIndex = index - 1;
              final story = stories[storyIndex];
              final isOwn =
                  story.userId == currentUserId && story.conversationId == null;
              return _StoryTile(
                story: story,
                currentUserId: currentUserId,
                onTap: () => _openStories(stories, storyIndex),
                onLongPress: isOwn ? () => _manageStory(story) : null,
              );
            },
          );
        },
      ),
    );
  }
}

/// Shared circular avatar layer used by both the add tile and story tiles.
class _StoryAvatar extends StatelessWidget {
  final String? avatarUrl;
  final String fallback;

  const _StoryAvatar({this.avatarUrl, required this.fallback});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipOval(
      child: Container(
        width: _kAvatar,
        height: _kAvatar,
        color: scheme.surfaceContainerHighest,
        child: avatarUrl != null
            ? CachedNetworkImage(
                imageUrl: ApiConfig.resolveMedia(avatarUrl!),
                fit: BoxFit.cover,
              )
            : Center(
                child: Text(
                  fallback.isNotEmpty ? fallback[0].toUpperCase() : '?',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
      ),
    );
  }
}

class _StoryAddTile extends StatelessWidget {
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _StoryAddTile({required this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final user = context.watch<AuthProvider>().currentUser;
    return SizedBox(
      width: _kTile,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _kRing,
              height: _kRing,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  // Faint hairline ring so the add tile aligns with story tiles.
                  Container(
                    width: _kRing,
                    height: _kRing,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: scheme.onSurface.withValues(alpha: 0.12),
                        width: 1,
                      ),
                    ),
                  ),
                  _StoryAvatar(
                    avatarUrl: user?.avatarUrl,
                    fallback: user?.avatarInitial ?? '?',
                  ),
                  // "+" badge, Instagram-style.
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 19,
                      height: 19,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.primary,
                        border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 2,
                        ),
                      ),
                      child: const Icon(
                        Icons.add,
                        color: Colors.white,
                        size: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Your story',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.6),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StoryTile extends StatelessWidget {
  final Story story;
  final String currentUserId;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _StoryTile({
    required this.story,
    required this.currentUserId,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final avatar = story.displayAvatar(currentUserId);
    final title = story.displayTitle(currentUserId);
    final unread = !story.viewerHasViewed && story.userId != currentUserId;

    return SizedBox(
      width: _kTile,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _kRing,
              height: _kRing,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Outer ring: Instagram gradient when unseen, hairline once viewed.
                  Container(
                    width: _kRing,
                    height: _kRing,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: unread
                          ? const LinearGradient(
                              begin: Alignment.topRight,
                              end: Alignment.bottomLeft,
                              colors: _kStoryGradient,
                            )
                          : null,
                      border: unread
                          ? null
                          : Border.all(
                              color: scheme.onSurface.withValues(alpha: 0.12),
                              width: 1,
                            ),
                    ),
                  ),
                  // Background gap circle (separates the ring from the avatar).
                  Container(
                    width: _kGap,
                    height: _kGap,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: bg,
                    ),
                  ),
                  _StoryAvatar(avatarUrl: avatar, fallback: title),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
                color: unread
                    ? scheme.onSurface.withValues(alpha: 0.9)
                    : scheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
