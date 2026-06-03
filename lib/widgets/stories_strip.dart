import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/api_config.dart';
import '../models/story.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../screens/stories/create_story_screen.dart';
import '../screens/stories/story_viewer_screen.dart';

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

  @override
  Widget build(BuildContext context) {
    final currentUserId = context.watch<AuthProvider>().currentUser?.id ?? '';
    return SizedBox(
      height: 108,
      child: FutureBuilder<List<Story>>(
        future: _future,
        builder: (context, snap) {
          final stories = snap.data ?? const <Story>[];
          return ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            itemCount: stories.length + 1,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              if (index == 0) {
                return _StoryAddTile(onTap: _createStory);
              }
              final storyIndex = index - 1;
              final story = stories[storyIndex];
              return _StoryTile(
                story: story,
                currentUserId: currentUserId,
                onTap: () => _openStories(stories, storyIndex),
              );
            },
          );
        },
      ),
    );
  }
}

class _StoryAddTile extends StatelessWidget {
  final VoidCallback onTap;

  const _StoryAddTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 72,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                // Avatar circle with glass border
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.20),
                      width: 0.7,
                    ),
                  ),
                  child: Icon(
                    Icons.person_outline_rounded,
                    color: scheme.onSurfaceVariant,
                    size: 26,
                  ),
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primary,
                      border: Border.all(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.38),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Icon(Icons.add, color: Colors.white, size: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Your story',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.65),
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

  const _StoryTile({
    required this.story,
    required this.currentUserId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final avatar = story.displayAvatar(currentUserId);
    final title = story.displayTitle(currentUserId);
    final unread = !story.viewerHasViewed && story.userId != currentUserId;

    return SizedBox(
      width: 72,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                // Gradient ring for unread; glass hairline for viewed
                if (unread)
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: SweepGradient(
                        colors: [
                          scheme.primary,
                          scheme.tertiary,
                          const Color(0xFF00D4FF),
                          scheme.primary,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.35),
                          blurRadius: 12,
                          spreadRadius: -2,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                  )
                else
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(
                          alpha: isDark ? 0.14 : 0.30,
                        ),
                        width: 1,
                      ),
                    ),
                  ),
                // Avatar inside a white-bordered circle
                ClipOval(
                  child: Container(
                    width: 56,
                    height: 56,
                    color: scheme.surfaceContainerHighest,
                    child: avatar != null
                        ? CachedNetworkImage(
                            imageUrl: ApiConfig.resolveMedia(avatar),
                            fit: BoxFit.cover,
                          )
                        : Center(
                            child: Text(
                              title.isNotEmpty ? title[0].toUpperCase() : '?',
                              style: const TextStyle(fontSize: 20),
                            ),
                          ),
                  ),
                ),
              ],
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
                    ? scheme.onSurface.withValues(alpha: 0.90)
                    : scheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
