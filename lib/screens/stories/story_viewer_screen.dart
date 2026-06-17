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
import '../../models/story_viewer.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/attachment_service.dart';
import '../../services/secure_storage_service.dart';
import '../../utils/story_background.dart';
import '../../widgets/custom_emoji_image.dart';
import '../../widgets/glass.dart';
import '../../widgets/reaction_emoji_picker.dart';
import '../../widgets/story_manage_sheet.dart';

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
            await context
                .read<SecureStorageService>()
                .getPrivateKeyIfUnlocked() ??
            '';
        if (privateKey.isEmpty) {
          throw StateError('PGP key locked');
        }
        final raw = await PgpService.decrypt(
          encryptedArmor: _story.encryptedPayload!,
          privateKeyArmored: privateKey,
        );
        final meta = jsonDecode(raw);
        if (meta is! Map<String, dynamic> || meta['openchat_story_meta'] != 1) {
          throw StateError('bad story meta');
        }
        _stories[_index] = _story.withDecryptedMeta(meta);
      }

      if (_story.isText) {
        await api.viewStory(_story.id);
        if (!mounted) return;
        setState(() => _state = _StoryLoadState.done);
        return;
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

  /// Toggle a reaction (unicode or `custom:<id>`): tapping your current
  /// reaction clears it, otherwise it replaces it. Records recents.
  Future<void> _react(String key) async {
    final api = context.read<ApiService>();
    final settings = context.read<SettingsProvider>();
    final current = _story.viewerReaction;
    try {
      final Story updated;
      if (current == key) {
        updated = await api.deleteStoryReaction(_story.id);
      } else {
        settings.pushRecentReaction(key);
        updated = await api.reactToStory(_story.id, key);
      }
      if (!mounted) return;
      setState(() => _stories[_index] = updated);
    } catch (_) {}
  }

  /// Opens the full reaction picker (any system emoji or custom-emoji pack).
  Future<void> _openReactionPicker() async {
    final key = await showReactionEmojiPicker(context);
    if (key == null || !mounted) return;
    await _react(key);
  }

  /// Author-only: pin/archive/delete the current story. Applies the result to
  /// the in-memory list so the change is reflected without leaving the viewer.
  Future<void> _manage() async {
    final outcome = await showStoryManageSheet(context, _story);
    if (!mounted) return;
    switch (outcome.result) {
      case StoryManageResult.updated:
        final updated = outcome.story;
        if (updated != null) setState(() => _stories[_index] = updated);
      case StoryManageResult.deleted:
        _stories.removeAt(_index);
        if (_stories.isEmpty) {
          Navigator.pop(context);
          return;
        }
        setState(() => _index = _index.clamp(0, _stories.length - 1));
        _loadCurrent();
      case StoryManageResult.unchanged:
        break;
    }
  }

  Future<void> _showViewers() async {
    List<StoryViewer> viewers;
    try {
      viewers = await context.read<ApiService>().getStoryViewers(_story.id);
    } catch (e) {
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
            if (viewers.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 8, 18, 24),
                child: Text('No views yet'),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [for (final viewer in viewers) _viewerTile(viewer)],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _viewerTile(StoryViewer viewer) {
    final username = viewer.username.trim();
    final display = viewer.displayName?.trim();
    final title = display != null && display.isNotEmpty
        ? display
        : username.isNotEmpty
        ? '@$username'
        : 'Unknown viewer';
    final avatar = viewer.avatarUrl;
    return GlassListTile(
      leading: CircleAvatar(
        backgroundImage: avatar != null && avatar.isNotEmpty
            ? NetworkImage(ApiConfig.resolveMedia(avatar))
            : null,
        child: avatar == null || avatar.isEmpty
            ? Text(username.isNotEmpty ? username[0].toUpperCase() : '?')
            : null,
      ),
      title: Text(title),
      subtitle: username.isNotEmpty ? Text('@$username') : null,
      trailing: viewer.reaction == null
          ? null
          : ReactionGlyph(viewer.reaction!, size: 24),
    );
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
    final recentKeys = context.watch<SettingsProvider>().quickReactions();
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
                onShowViewers: _showViewers,
                onManage: _manage,
                onClose: () => Navigator.pop(context),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: _StoryFooter(
                story: _story,
                currentUserId: currentUserId,
                recentKeys: recentKeys,
                onReact: _react,
                onMore: _openReactionPicker,
              ),
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
      _StoryLoadState.done when _story.isText => _TextStoryMedia(story: _story),
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

class _TextStoryMedia extends StatelessWidget {
  final Story story;

  const _TextStoryMedia({required this.story});

  @override
  Widget build(BuildContext context) {
    final text = story.caption.trim();
    return DecoratedBox(
      decoration: storyBackgroundDecoration(story.background),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 96, 28, 150),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 36,
              fontWeight: FontWeight.w800,
              height: 1.12,
              shadows: [
                Shadow(
                  blurRadius: 18,
                  color: Colors.black38,
                  offset: Offset(0, 2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
  final VoidCallback onShowViewers;
  final VoidCallback? onManage;
  final VoidCallback onClose;

  const _StoryHeader({
    required this.story,
    required this.currentUserId,
    required this.index,
    required this.total,
    required this.onShowViewers,
    this.onManage,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = story.displayAvatar(currentUserId);
    final isAuthor =
        story.conversationId == null && story.userId == currentUserId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: List.generate(total, (i) {
            return Expanded(
              child: Container(
                height: 2.5,
                margin: EdgeInsets.only(right: i == total - 1 ? 0 : 4),
                decoration: BoxDecoration(
                  color: i <= index ? Colors.white : Colors.white30,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 12),
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
                  shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                ),
              ),
            ),
            // Views counter (author sees how many viewed). Sits left of the
            // close button so the two never overlap.
            if (story.viewCount > 0) ...[
              GestureDetector(
                key: const Key('story-view-count-badge'),
                behavior: HitTestBehavior.opaque,
                onTap: isAuthor ? onShowViewers : () {},
                child: GlassContainer(
                  shape: const LiquidRoundedSuperellipse(borderRadius: 999),
                  allowElevation: true,
                  glowIntensity: 0.06,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.visibility_outlined,
                          color: Colors.white,
                          size: 14,
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
              ),
              const SizedBox(width: 8),
            ],
            if (isAuthor && onManage != null) ...[
              GlassCircleIconButton(
                key: const Key('story-manage-button'),
                tooltip: 'Manage story',
                size: 38,
                glowIntensity: 0.04,
                onPressed: onManage,
                icon: const Icon(
                  Icons.more_vert_rounded,
                  size: 20,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 8),
            ],
            GlassCircleIconButton(
              tooltip: 'Close',
              size: 38,
              glowIntensity: 0.04,
              onPressed: onClose,
              icon: const Icon(
                Icons.close_rounded,
                size: 20,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StoryFooter extends StatefulWidget {
  final Story story;
  final String currentUserId;

  /// Recent reaction keys (unicode or `custom:<id>`) for the quick bar.
  final List<String> recentKeys;
  final ValueChanged<String> onReact;
  final VoidCallback onMore;

  const _StoryFooter({
    required this.story,
    required this.currentUserId,
    required this.recentKeys,
    required this.onReact,
    required this.onMore,
  });

  @override
  State<_StoryFooter> createState() => _StoryFooterState();
}

class _StoryFooterState extends State<_StoryFooter> {
  final _replyCtrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _replyCtrl.dispose();
    super.dispose();
  }

  bool get _canReply =>
      widget.story.conversationId == null &&
      widget.story.userId != widget.currentUserId;

  Future<void> _sendReply() async {
    final text = _replyCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final chat = context.read<ChatProvider>();
      final dm = await chat.openDM(widget.story.userId);
      final prefix = widget.story.caption.trim().isEmpty
          ? 'Replying to your story'
          : 'Replying to your story: ${widget.story.caption.trim()}';
      final sent = await chat.sendMessage(
        convID: dm.id,
        plaintext: '$prefix\n\n$text',
      );
      if (!mounted) return;
      if (sent) {
        _replyCtrl.clear();
        showAppToast(context, 'Reply sent');
      } else {
        showAppToast(context, 'Could not send reply', isError: true);
      }
    } catch (_) {
      if (mounted) showAppToast(context, 'Could not send reply', isError: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // If the viewer reacted with something outside the recent set, surface it
    // first so the selection stays visible.
    final story = widget.story;
    final current = story.viewerReaction;
    final keys = <String>[
      if (current != null && !widget.recentKeys.contains(current)) current,
      ...widget.recentKeys,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (story.caption.isNotEmpty && !story.isText) ...[
          GlassContainer(
            shape: const LiquidRoundedSuperellipse(borderRadius: 22),
            allowElevation: true,
            glowIntensity: 0.06,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                story.caption,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 999),
          allowElevation: true,
          glowIntensity: 0.06,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final key in keys)
                _StoryReactButton(
                  selected: story.viewerReaction == key,
                  onTap: () => widget.onReact(key),
                  child: ReactionGlyph(key, size: 26),
                ),
              Container(
                width: 1,
                height: 26,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                color: Colors.white24,
              ),
              _StoryReactButton(
                selected: false,
                onTap: widget.onMore,
                child: const Icon(
                  Icons.add_rounded,
                  size: 24,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
        if (_canReply) ...[
          const SizedBox(height: 10),
          _StoryReplyBar(
            controller: _replyCtrl,
            sending: _sending,
            onSend: _sendReply,
          ),
        ],
      ],
    );
  }
}

class _StoryReplyBar extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  const _StoryReplyBar({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      shape: const LiquidRoundedSuperellipse(borderRadius: 999),
      allowElevation: true,
      glowIntensity: 0.06,
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: !sending,
              minLines: 1,
              maxLines: 2,
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.white,
              decoration: const InputDecoration(
                hintText: 'Reply to story...',
                hintStyle: TextStyle(color: Colors.white54),
                border: InputBorder.none,
                isDense: true,
              ),
              onSubmitted: (_) => onSend(),
            ),
          ),
          GlassCircleIconButton(
            onPressed: sending ? null : onSend,
            tooltip: 'Send reply',
            size: 38,
            glowIntensity: 0.04,
            icon: sending
                ? const GlassProgressIndicator.circular(
                    size: 18,
                    strokeWidth: 2,
                    color: Colors.white,
                  )
                : const Icon(Icons.send_rounded, color: Colors.white, size: 18),
          ),
        ],
      ),
    );
  }
}

class _StoryReactButton extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  const _StoryReactButton({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // Real iOS-26 press physics (anchored squish + glow, Reduce-Motion safe).
    // The chips are siblings inside the reaction-bar glass pill, so use a low
    // stretch and a transparent style to avoid double-drawing glass; the
    // selected state keeps its own white circle inside the child.
    return GlassButton.custom(
      onTap: onTap,
      style: GlassButtonStyle.transparent,
      shape: const LiquidOval(),
      stretch: 0.15,
      width: 38,
      height: 38,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? Colors.white24 : Colors.transparent,
        ),
        child: SizedBox(
          width: 38,
          height: 38,
          child: Center(child: child),
        ),
      ),
    );
  }
}
