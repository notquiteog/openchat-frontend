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
      height: 104,
      child: FutureBuilder<List<Story>>(
        future: _future,
        builder: (context, snap) {
          final stories = snap.data ?? const <Story>[];
          return ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            itemCount: stories.length + 1,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
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
    return SizedBox(
      width: 72,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.person_outline),
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: CircleAvatar(
                    radius: 11,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    child: const Icon(Icons.add, color: Colors.white, size: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Your story',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12),
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
    final avatar = story.displayAvatar(currentUserId);
    final title = story.displayTitle(currentUserId);
    final unread = !story.viewerHasViewed && story.userId != currentUserId;
    final ringColor = unread
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).dividerColor;
    return SizedBox(
      width: 72,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: ringColor, width: unread ? 3 : 1),
              ),
              child: CircleAvatar(
                radius: 26,
                backgroundImage: avatar != null
                    ? CachedNetworkImageProvider(ApiConfig.resolveMedia(avatar))
                    : null,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
                child: avatar == null
                    ? Text(title.isNotEmpty ? title[0].toUpperCase() : '?')
                    : null,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
