import 'dart:io';
import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:video_player/video_player.dart';
import '../config/api_config.dart';
import '../models/message.dart';
import '../services/api_service.dart';
import '../services/attachment_service.dart';
import 'glass.dart';
import 'message_image_layout.dart';

class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final bool showAvatar;
  final VoidCallback? onLongPress;
  final VoidCallback? onAvatarTap;
  // The current user's own bubble can be previewed locally while the published
  // sender bubble color remains authoritative for incoming messages.
  final Color? meBubbleColor;
  final double bubbleRadius;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    this.showAvatar = false,
    this.onLongPress,
    this.onAvatarTap,
    this.meBubbleColor,
    this.bubbleRadius = 18,
  });

  /// Resolved background color for this bubble.
  Color _bubbleColor(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (isMe) return meBubbleColor ?? cs.primary;
    final senderBubbleColor = message.sender?.bubbleColor;
    if (senderBubbleColor != null) return Color(senderBubbleColor);
    return cs.surfaceContainerHighest;
  }

  /// Corner radii honouring the configured [bubbleRadius]; the "tail" corner
  /// stays tight for the speech-bubble look.
  BorderRadius _radii() => BorderRadius.only(
        topLeft: Radius.circular(bubbleRadius),
        topRight: Radius.circular(bubbleRadius),
        bottomLeft: Radius.circular(isMe ? bubbleRadius : 4),
        bottomRight: Radius.circular(isMe ? 4 : bubbleRadius),
      );

  @override
  Widget build(BuildContext context) {
    // Call events render as a centered, full-width chip rather than a sided
    // bubble — they're conversation metadata, not a message from either party.
    final callEvent = message.callEvent;
    if (callEvent != null) {
      return _CallEventChip(
        event: callEvent,
        time: message.createdAt,
        onLongPress: onLongPress,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment:
            isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe && showAvatar) ...[
            GestureDetector(
              onTap: onAvatarTap,
              child: CircleAvatar(
                radius: 14,
                backgroundImage: message.sender?.avatarUrl != null
                    ? CachedNetworkImageProvider(
                        ApiConfig.resolveMedia(message.sender!.avatarUrl!))
                    : null,
                child: message.sender?.avatarUrl == null
                    ? Text(
                        message.sender?.username
                                .substring(0, 1)
                                .toUpperCase() ??
                            '?',
                        style: const TextStyle(fontSize: 10),
                      )
                    : null,
              ),
            ),
            const SizedBox(width: 6),
          ] else if (!isMe)
            const SizedBox(width: 34),
          Flexible(
            child: GestureDetector(
              onLongPress: onLongPress,
              child: _buildBubble(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBubble(BuildContext context) {
    if (message.type == MessageType.sticker) {
      return _StickerBubble(stickerID: message.decryptedContent ?? '');
    }

    final bubbleColor = _bubbleColor(context);
    final textColor = _textColorFor(context);
    final radii = _radii();

    if (message.decryptionFailed) {
      return _BubbleShell(
        color: bubbleColor,
        radii: radii,
        child: _DecryptionError(textColor: textColor),
      );
    }

    if (!message.isDecrypted) {
      return _BubbleShell(
        color: bubbleColor,
        radii: radii,
        child: _buildTimestamp(context, textColor),
      );
    }

    final content = message.content!;

    if (content.hasAttachment) {
      return switch (message.type) {
        MessageType.image => _ImageBubble(
            message: message,
            content: content,
            bubbleColor: bubbleColor,
            textColor: textColor,
            radii: radii,
          ),
        MessageType.video => _VideoBubble(
            message: message,
            content: content,
            bubbleColor: bubbleColor,
            textColor: textColor,
            radii: radii,
          ),
        _ => _FileBubble(
            message: message,
            content: content,
            bubbleColor: bubbleColor,
            textColor: textColor,
            radii: radii,
          ),
      };
    }

    return _TextBubble(
      message: message,
      isMe: isMe,
      bubbleColor: bubbleColor,
      textColor: textColor,
      radii: radii,
    );
  }

  Color _textColorFor(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (isMe) {
      if (meBubbleColor == null) return Colors.white;
      // A custom bubble color needs a contrasting text color the theme's
      // onPrimary can't guarantee.
      return ThemeData.estimateBrightnessForColor(meBubbleColor!) ==
              Brightness.dark
          ? Colors.white
          : Colors.black;
    }
    final senderBubbleColor = message.sender?.bubbleColor;
    if (senderBubbleColor != null) {
      return ThemeData.estimateBrightnessForColor(Color(senderBubbleColor)) ==
              Brightness.dark
          ? Colors.white
          : Colors.black;
    }
    return cs.onSurface;
  }

  Widget _buildTimestamp(BuildContext context, Color textColor) {
    return Text(
      timeago.format(message.createdAt, locale: 'en_short'),
      style: TextStyle(fontSize: 10, color: textColor.withValues(alpha: 0.6)),
    );
  }
}

// ── Call event chip ─────────────────────────────────────────────────────────

class _CallEventChip extends StatelessWidget {
  final CallEventInfo event;
  final DateTime time;
  final VoidCallback? onLongPress;

  const _CallEventChip({
    required this.event,
    required this.time,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final missed = event.outcome == CallOutcome.missed;
    final color = missed ? cs.error : cs.onSurfaceVariant;
    final icon = event.isVideo
        ? (missed ? Icons.videocam_off : Icons.videocam)
        : (missed ? Icons.phone_missed : Icons.call);

    return Center(
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 6),
              Text(
                event.label,
                style: TextStyle(
                    fontSize: 12, color: color, fontWeight: FontWeight.w500),
              ),
              const SizedBox(width: 6),
              Text(
                timeago.format(time, locale: 'en_short'),
                style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Shell ─────────────────────────────────────────────────────────────────────

class _BubbleShell extends StatelessWidget {
  final Color color;
  final BorderRadius radii;
  final Widget child;

  const _BubbleShell({
    required this.color,
    required this.radii,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final tintOpacity =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
            ? 0.38
            : 0.34;
    return GlassSurface(
      blur: 30,
      borderRadius: radii,
      border: Border.all(
        color: Colors.white.withValues(alpha: 0.42),
        width: 0.75,
      ),
      boxShadow: [
        BoxShadow(
          color: color.withValues(alpha: 0.18),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      child: Container(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: color.withValues(alpha: tintOpacity),
          borderRadius: radii,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: child,
      ),
    );
  }
}

// ── Text bubble ───────────────────────────────────────────────────────────────

class _TextBubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final Color bubbleColor;
  final Color textColor;
  final BorderRadius radii;

  const _TextBubble({
    required this.message,
    required this.isMe,
    required this.bubbleColor,
    required this.textColor,
    required this.radii,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return _BubbleShell(
      color: bubbleColor,
      radii: radii,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMe && message.sender != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '@${message.sender!.username}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: cs.primary,
                ),
              ),
            ),
          Text(
            message.decryptedContent ?? '',
            style: TextStyle(color: textColor, fontSize: 15),
          ),
          const SizedBox(height: 2),
          _Timestamp(message: message, textColor: textColor),
        ],
      ),
    );
  }
}

// ── Image bubble ──────────────────────────────────────────────────────────────

enum _LoadState { idle, loading, done, error }

class _ImageBubble extends StatefulWidget {
  final Message message;
  final MessageContent content;
  final Color bubbleColor;
  final Color textColor;
  final BorderRadius radii;

  const _ImageBubble({
    required this.message,
    required this.content,
    required this.bubbleColor,
    required this.textColor,
    required this.radii,
  });

  @override
  State<_ImageBubble> createState() => _ImageBubbleState();
}

class _ImageBubbleState extends State<_ImageBubble> {
  _LoadState _state = _LoadState.idle;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = widget.content;
    if (c.attachmentId == null || c.fileKey == null || c.fileNonce == null) {
      setState(() => _state = _LoadState.error);
      return;
    }
    setState(() => _state = _LoadState.loading);
    try {
      final svc = AttachmentService(context.read<ApiService>());
      final bytes = await svc.downloadAndDecrypt(
        attachmentId: c.attachmentId!,
        fileKeyB64: c.fileKey!,
        fileNonceB64: c.fileNonce!,
      );
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _state = _LoadState.done;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _state = _LoadState.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textColor = widget.textColor;
    final c = widget.content;
    final layout = MessageImageLayout.forViewport(MediaQuery.of(context).size);

    return ClipRRect(
      borderRadius: widget.radii,
      child: Container(
        constraints: BoxConstraints(maxWidth: layout.maxBubbleWidth),
        color: widget.bubbleColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildImageArea(layout),
            if ((c.text).isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Text(c.text,
                    style: TextStyle(color: textColor, fontSize: 14)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
              child: _Timestamp(message: widget.message, textColor: textColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageArea(MessageImageLayout layout) {
    return switch (_state) {
      _LoadState.done => GestureDetector(
          onTap: () => _showFullscreen(context),
          child: SizedBox(
            width: layout.maxBubbleWidth,
            height: layout.reservedImageHeight,
            child: Stack(
              children: [
                Image.memory(
                  _bytes!,
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Tooltip(
                    message: MessageImageLayout.expandTooltip,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.open_in_full,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      _LoadState.loading => Container(
          height: layout.reservedImageHeight,
          color: Colors.black12,
          child: const Center(child: CircularProgressIndicator()),
        ),
      _LoadState.error => Container(
          height: layout.reservedImageHeight,
          color: Colors.black12,
          child:
              const Center(child: Icon(Icons.broken_image, color: Colors.grey)),
        ),
      _LoadState.idle => const SizedBox.shrink(),
    };
  }

  void _showFullscreen(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
              backgroundColor: Colors.black, foregroundColor: Colors.white),
          body: Center(
            child: InteractiveViewer(child: Image.memory(_bytes!)),
          ),
        ),
      ),
    );
  }
}

// ── Video bubble ──────────────────────────────────────────────────────────────

class _VideoBubble extends StatefulWidget {
  final Message message;
  final MessageContent content;
  final Color bubbleColor;
  final Color textColor;
  final BorderRadius radii;

  const _VideoBubble({
    required this.message,
    required this.content,
    required this.bubbleColor,
    required this.textColor,
    required this.radii,
  });

  @override
  State<_VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<_VideoBubble> {
  _LoadState _state = _LoadState.idle;
  VideoPlayerController? _controller;
  File? _tempFile;

  @override
  void dispose() {
    _controller?.dispose();
    _tempFile?.delete().ignore();
    super.dispose();
  }

  Future<void> _load() async {
    final c = widget.content;
    if (c.attachmentId == null || c.fileKey == null || c.fileNonce == null) {
      setState(() => _state = _LoadState.error);
      return;
    }
    setState(() => _state = _LoadState.loading);
    try {
      final svc = AttachmentService(context.read<ApiService>());
      final bytes = await svc.downloadAndDecrypt(
        attachmentId: c.attachmentId!,
        fileKeyB64: c.fileKey!,
        fileNonceB64: c.fileNonce!,
      );

      // Write decrypted bytes to a temp file for the video player.
      final dir = await getTemporaryDirectory();
      final ext = _extFromMime(c.mimeType ?? 'video/mp4');
      final file = File('${dir.path}/${c.attachmentId}.$ext');
      await file.writeAsBytes(bytes);
      _tempFile = file;

      final ctrl = VideoPlayerController.file(file);
      await ctrl.initialize();
      if (mounted) {
        setState(() {
          _controller = ctrl;
          _state = _LoadState.done;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _state = _LoadState.error);
    }
  }

  String _extFromMime(String mime) {
    if (mime.contains('mp4')) return 'mp4';
    if (mime.contains('webm')) return 'webm';
    if (mime.contains('mov') || mime.contains('quicktime')) return 'mov';
    return 'mp4';
  }

  @override
  Widget build(BuildContext context) {
    final textColor = widget.textColor;
    final maxW = MediaQuery.of(context).size.width * 0.75;

    return ClipRRect(
      borderRadius: widget.radii,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxW),
        color: widget.bubbleColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildVideoArea(),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
              child: _Timestamp(message: widget.message, textColor: textColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoArea() {
    return switch (_state) {
      _LoadState.done => _VideoPlayerWidget(controller: _controller!),
      _LoadState.loading => Container(
          height: 160,
          color: Colors.black26,
          child: const Center(child: CircularProgressIndicator()),
        ),
      _LoadState.error => Container(
          height: 100,
          color: Colors.black12,
          child:
              const Center(child: Icon(Icons.videocam_off, color: Colors.grey)),
        ),
      _LoadState.idle => GestureDetector(
          onTap: _load,
          child: Container(
            height: 160,
            color: Colors.black26,
            child: const Center(
              child: CircleAvatar(
                radius: 28,
                backgroundColor: Colors.black54,
                child: Icon(Icons.play_arrow, color: Colors.white, size: 36),
              ),
            ),
          ),
        ),
    };
  }
}

class _VideoPlayerWidget extends StatefulWidget {
  final VideoPlayerController controller;
  const _VideoPlayerWidget({required this.controller});

  @override
  State<_VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<_VideoPlayerWidget> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerUpdate);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerUpdate);
    super.dispose();
  }

  void _onControllerUpdate() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    return GestureDetector(
      onTap: () {
        ctrl.value.isPlaying ? ctrl.pause() : ctrl.play();
      },
      child: AspectRatio(
        aspectRatio: ctrl.value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(ctrl),
            if (!ctrl.value.isPlaying)
              const CircleAvatar(
                radius: 24,
                backgroundColor: Colors.black54,
                child: Icon(Icons.play_arrow, color: Colors.white, size: 30),
              ),
          ],
        ),
      ),
    );
  }
}

// ── File bubble ───────────────────────────────────────────────────────────────

class _FileBubble extends StatefulWidget {
  final Message message;
  final MessageContent content;
  final Color bubbleColor;
  final Color textColor;
  final BorderRadius radii;

  const _FileBubble({
    required this.message,
    required this.content,
    required this.bubbleColor,
    required this.textColor,
    required this.radii,
  });

  @override
  State<_FileBubble> createState() => _FileBubbleState();
}

class _FileBubbleState extends State<_FileBubble> {
  _LoadState _state = _LoadState.idle;

  Future<void> _download() async {
    final c = widget.content;
    if (c.attachmentId == null || c.fileKey == null || c.fileNonce == null) {
      return;
    }
    setState(() => _state = _LoadState.loading);
    try {
      final svc = AttachmentService(context.read<ApiService>());
      final bytes = await svc.downloadAndDecrypt(
        attachmentId: c.attachmentId!,
        fileKeyB64: c.fileKey!,
        fileNonceB64: c.fileNonce!,
      );

      final dir = await getApplicationDocumentsDirectory();
      final fileName = c.fileName ?? 'file_${c.attachmentId}';
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes);

      if (mounted) {
        setState(() => _state = _LoadState.done);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved to ${file.path}')),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _state = _LoadState.error);
    }
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final textColor = widget.textColor;
    final c = widget.content;

    return _BubbleShell(
      color: widget.bubbleColor,
      radii: widget.radii,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildIcon(textColor),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  c.fileName ?? 'File',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _formatSize(c.fileSize),
                  style: TextStyle(
                    color: textColor.withValues(alpha: 0.6),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 4),
                _Timestamp(message: widget.message, textColor: textColor),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIcon(Color textColor) {
    return GestureDetector(
      onTap: _state == _LoadState.idle || _state == _LoadState.error
          ? _download
          : null,
      child: switch (_state) {
        _LoadState.loading => SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(strokeWidth: 2, color: textColor),
          ),
        _LoadState.done => Icon(Icons.check_circle, color: textColor, size: 40),
        _LoadState.error =>
          Icon(Icons.error_outline, color: Colors.red[300], size: 40),
        _LoadState.idle =>
          Icon(Icons.download_outlined, color: textColor, size: 40),
      },
    );
  }
}

// ── Shared helpers ────────────────────────────────────────────────────────────

class _Timestamp extends StatelessWidget {
  final Message message;
  final Color textColor;

  const _Timestamp({required this.message, required this.textColor});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.decryptionFailed)
          Icon(Icons.lock, size: 10, color: textColor.withValues(alpha: 0.5)),
        Text(
          timeago.format(message.createdAt, locale: 'en_short'),
          style:
              TextStyle(fontSize: 10, color: textColor.withValues(alpha: 0.6)),
        ),
        if (message.isEdited)
          Text(
            ' · edited',
            style: TextStyle(
                fontSize: 10, color: textColor.withValues(alpha: 0.6)),
          ),
        if (message.hasAutoDelete)
          StreamBuilder<int>(
            stream: Stream.periodic(const Duration(seconds: 30), (i) => i),
            builder: (context, _) => Text(
              ' · ${_remainingAutoDelete(message)} left',
              style: TextStyle(
                  fontSize: 10, color: textColor.withValues(alpha: 0.7)),
            ),
          ),
      ],
    );
  }

  String _remainingAutoDelete(Message message) {
    final expiresAt = message.autoDeleteExpiresAt;
    if (expiresAt == null) return '';
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.inSeconds <= 0) return 'expiring';
    if (remaining.inDays >= 1) return '${remaining.inDays}d';
    if (remaining.inHours >= 1) return '${remaining.inHours}h';
    if (remaining.inMinutes >= 1) return '${remaining.inMinutes}m';
    return '${remaining.inSeconds}s';
  }
}

class _DecryptionError extends StatelessWidget {
  final Color textColor;
  const _DecryptionError({required this.textColor});

  @override
  Widget build(BuildContext context) {
    return Text(
      '🔒 Unable to decrypt',
      style: TextStyle(
          color: textColor.withValues(alpha: 0.5), fontStyle: FontStyle.italic),
    );
  }
}

class _StickerBubble extends StatefulWidget {
  final String stickerID;
  const _StickerBubble({required this.stickerID});

  @override
  State<_StickerBubble> createState() => _StickerBubbleState();
}

class _StickerBubbleState extends State<_StickerBubble> {
  Map<String, dynamic>? _sticker;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await context.read<ApiService>().getSticker(widget.stickerID);
      if (mounted) {
        setState(() {
          _sticker = s;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onTap() {
    final packId = _sticker?['pack_id'] as String?;
    if (packId == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _StickerPackSheet(
        packID: packId,
        api: context.read<ApiService>(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fileUrl = _sticker?['file_url'] as String?;
    return GestureDetector(
      onTap: _sticker != null ? _onTap : null,
      child: SizedBox(
        width: 120,
        height: 120,
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : fileUrl != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: ApiConfig.resolveMedia(fileUrl),
                      fit: BoxFit.contain,
                      placeholder: (_, __) => const Center(
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      errorWidget: (_, __, ___) => Center(
                        child: Text(
                          _sticker?['emoji'] as String? ?? '😀',
                          style: const TextStyle(fontSize: 60),
                        ),
                      ),
                    ),
                  )
                : Center(
                    child: Text(
                      _sticker?['emoji'] as String? ?? '😀',
                      style: const TextStyle(fontSize: 60),
                    ),
                  ),
      ),
    );
  }
}

class _StickerPackSheet extends StatefulWidget {
  final String packID;
  final ApiService api;
  const _StickerPackSheet({required this.packID, required this.api});

  @override
  State<_StickerPackSheet> createState() => _StickerPackSheetState();
}

class _StickerPackSheetState extends State<_StickerPackSheet> {
  Map<String, dynamic>? _pack;
  bool _loading = true;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final pack = await widget.api.getStickerPack(widget.packID);
      if (mounted) {
        setState(() {
          _pack = pack;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addToLibrary() async {
    setState(() => _adding = true);
    try {
      await widget.api.addStickerPackToLibrary(widget.packID);
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sticker pack added to your library')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _adding = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add pack: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final stickers =
        (_pack?['stickers'] as List? ?? []).cast<Map<String, dynamic>>();
    final coverUrl = _pack?['cover_url'] as String?;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.85,
      builder: (_, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                if (coverUrl != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: CachedNetworkImage(
                      imageUrl: ApiConfig.resolveMedia(coverUrl),
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _pack?['name'] as String? ?? 'Sticker Pack',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 16),
                      ),
                      if (_pack?['description'] != null)
                        Text(
                          _pack!['description'] as String,
                          style:
                              TextStyle(color: Colors.grey[600], fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: _adding ? null : _addToLibrary,
                  icon: _adding
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add, size: 18),
                  label: const Text('Add'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : stickers.isEmpty
                    ? const Center(child: Text('No stickers in this pack'))
                    : GridView.builder(
                        controller: controller,
                        padding: const EdgeInsets.all(8),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 6,
                          mainAxisSpacing: 6,
                        ),
                        itemCount: stickers.length,
                        itemBuilder: (_, i) {
                          final st = stickers[i];
                          final url = st['file_url'] as String?;
                          return ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: url != null
                                ? CachedNetworkImage(
                                    imageUrl: ApiConfig.resolveMedia(url),
                                    fit: BoxFit.contain,
                                    errorWidget: (_, __, ___) => Center(
                                      child: Text(
                                        st['emoji'] as String? ?? '😀',
                                        style: const TextStyle(fontSize: 28),
                                      ),
                                    ),
                                  )
                                : Center(
                                    child: Text(
                                      st['emoji'] as String? ?? '😀',
                                      style: const TextStyle(fontSize: 28),
                                    ),
                                  ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
