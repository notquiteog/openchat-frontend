import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../../config/api_config.dart';
import '../../crypto/pgp_service.dart';
import '../../models/story.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../services/attachment_service.dart';
import '../../services/secure_storage_service.dart';
import '../../widgets/glass.dart';

enum _StoryLoadState { idle, loading, done, error }

class StoryViewerScreen extends StatefulWidget {
  final List<Story> stories;
  final int initialIndex;

  const StoryViewerScreen({
    super.key,
    required this.stories,
    this.initialIndex = 0,
  });

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> {
  late final List<Story> _stories = List<Story>.from(widget.stories);
  late int _index = _stories.isEmpty
      ? 0
      : widget.initialIndex.clamp(0, _stories.length - 1);
  _StoryLoadState _state = _StoryLoadState.idle;
  Uint8List? _bytes;
  VideoPlayerController? _video;
  File? _tempFile;
  String? _error;

  Story get _story => _stories[_index];

  @override
  void initState() {
    super.initState();
    if (_stories.isNotEmpty) _loadCurrent();
  }

  @override
  void dispose() {
    _disposeMedia();
    super.dispose();
  }

  void _disposeMedia() {
    _video?.dispose();
    _video = null;
    _tempFile?.delete().ignore();
    _tempFile = null;
    _bytes = null;
  }

  Future<void> _loadCurrent() async {
    _disposeMedia();
    setState(() {
      _state = _StoryLoadState.loading;
      _error = null;
    });
    try {
      final api = context.read<ApiService>();

      // E2E stories carry their media key/caption inside a PGP envelope
      // addressed to the audience — decrypt it before touching the media.
      if (_story.needsMetaDecryption) {
        final privateKey =
            await context.read<SecureStorageService>().getPrivateKeyIfUnlocked() ??
                '';
        if (privateKey.isEmpty) {
          throw StateError('PGP key locked');
        }
        final raw = await PgpService.decrypt(
          encryptedArmor: _story.encryptedPayload!,
          privateKeyArmored: privateKey,
        );
        final meta = jsonDecode(raw);
        if (meta is! Map<String, dynamic> ||
            meta['openchat_story_meta'] != 1) {
          throw StateError('bad story meta');
        }
        _stories[_index] = _story.withDecryptedMeta(meta);
      }

      final attachmentId = _story.attachmentId;
      if (attachmentId == null) throw StateError('missing attachment');

      await api.viewStory(_story.id);
      final svc = AttachmentService(api);
      final bytes = _story.fileKey != null && _story.fileNonce != null
          ? await svc.downloadAndDecrypt(
              attachmentId: attachmentId,
              fileKeyB64: _story.fileKey!,
              fileNonceB64: _story.fileNonce!,
            )
          : await svc.downloadRaw(attachmentId: attachmentId);

      if (_story.isVideo) {
        final dir = await getTemporaryDirectory();
        final file = File(
          '${dir.path}/story-${_story.id}.${_videoExt(_story)}',
        );
        await file.writeAsBytes(bytes, flush: true);
        final controller = VideoPlayerController.file(file);
        await controller.initialize();
        await controller.setLooping(true);
        await controller.play();
        if (!mounted) {
          await controller.dispose();
          file.delete().ignore();
          return;
        }
        setState(() {
          _tempFile = file;
          _video = controller;
          _state = _StoryLoadState.done;
        });
      } else {
        if (!mounted) return;
        setState(() {
          _bytes = bytes;
          _state = _StoryLoadState.done;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load story.';
        _state = _StoryLoadState.error;
      });
    }
  }

  String _videoExt(Story story) {
    final mime = story.mimeType ?? '';
    if (mime.contains('webm')) return 'webm';
    if (mime.contains('quicktime') || mime.contains('mov')) return 'mov';
    return 'mp4';
  }

  Future<void> _react(String emoji) async {
    try {
      final updated = await context.read<ApiService>().reactToStory(
        _story.id,
        emoji,
      );
      if (!mounted) return;
      setState(() => _stories[_index] = updated);
    } catch (_) {}
  }

  void _next() {
    if (_index >= _stories.length - 1) {
      Navigator.pop(context);
      return;
    }
    setState(() => _index += 1);
    _loadCurrent();
  }

  void _previous() {
    if (_index <= 0) return;
    setState(() => _index -= 1);
    _loadCurrent();
  }

  @override
  Widget build(BuildContext context) {
    if (_stories.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text('No stories', style: TextStyle(color: Colors.white70)),
        ),
      );
    }
    final currentUserId = context.read<AuthProvider>().currentUser?.id ?? '';
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildMedia(),
            _TapZones(onPrevious: _previous, onNext: _next),
            Positioned(
              left: 12,
              right: 12,
              top: 8,
              child: _StoryHeader(
                story: _story,
                currentUserId: currentUserId,
                index: _index,
                total: _stories.length,
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                tooltip: 'Close',
                color: Colors.white,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: _StoryFooter(story: _story, onReact: _react),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMedia() {
    return switch (_state) {
      _StoryLoadState.done when _video != null => Center(
        child: AspectRatio(
          aspectRatio: _video!.value.aspectRatio,
          child: VideoPlayer(_video!),
        ),
      ),
      _StoryLoadState.done when _bytes != null => Center(
        child: Image.memory(
          _bytes!,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
      ),
      _StoryLoadState.error => Center(
        child: Text(
          _error ?? 'Story unavailable',
          style: const TextStyle(color: Colors.white70),
        ),
      ),
      _ => Center(child: GlassProgressIndicator.circular(color: Colors.white)),
    };
  }
}

class _TapZones extends StatelessWidget {
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  const _TapZones({required this.onPrevious, required this.onNext});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onPrevious,
            child: const SizedBox.expand(),
          ),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onNext,
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}

class _StoryHeader extends StatelessWidget {
  final Story story;
  final String currentUserId;
  final int index;
  final int total;

  const _StoryHeader({
    required this.story,
    required this.currentUserId,
    required this.index,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = story.displayAvatar(currentUserId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: List.generate(total, (i) {
            return Expanded(
              child: Container(
                height: 2,
                margin: EdgeInsets.only(right: i == total - 1 ? 0 : 4),
                color: i <= index ? Colors.white : Colors.white30,
              ),
            );
          }),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundImage: avatar != null
                  ? NetworkImage(ApiConfig.resolveMedia(avatar))
                  : null,
              backgroundColor: Colors.white24,
              child: avatar == null
                  ? const Icon(Icons.person, color: Colors.white, size: 18)
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                story.displayTitle(currentUserId),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (story.viewCount > 0)
              GlassContainer(
                shape: LiquidRoundedSuperellipse(borderRadius: 999),
                allowElevation: true,
                glowIntensity: 0.06,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.visibility_outlined,
                        color: Colors.white,
                        size: 13,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${story.viewCount}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _StoryFooter extends StatelessWidget {
  final Story story;
  final ValueChanged<String> onReact;

  const _StoryFooter({required this.story, required this.onReact});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (story.caption.isNotEmpty)
          GlassContainer(
            shape: LiquidRoundedSuperellipse(borderRadius: 999),
            allowElevation: true,
            glowIntensity: 0.06,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                story.caption,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        const SizedBox(height: 10),
        GlassContainer(
          shape: LiquidRoundedSuperellipse(borderRadius: 999),
          allowElevation: true,
          glowIntensity: 0.06,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: ['❤️', '🔥', '😂', '👍', '😮', '😢'].map((emoji) {
                final selected = story.viewerReaction == emoji;
                return GestureDetector(
                  onTap: () => onReact(emoji),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: selected ? Colors.white30 : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                    child: Text(emoji, style: const TextStyle(fontSize: 26)),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }
}
