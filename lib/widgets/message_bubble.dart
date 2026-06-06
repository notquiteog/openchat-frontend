import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../config/api_config.dart';
import '../models/link_preview.dart';
import '../models/message.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../services/api_service.dart';
import '../services/attachment_service.dart';
import '../services/link_preview_service.dart';
import '../utils/link_preview_utils.dart';
import '../utils/mention_utils.dart';
import 'glass.dart';
import 'location_map_preview.dart';
import 'message_image_layout.dart';

class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final bool showAvatar;
  final VoidCallback? onTap;
  final GestureTapUpCallback? onTapUp;
  final VoidCallback? onLongPress;
  final VoidCallback? onAvatarTap;
  final ValueChanged<String>? onReactionTap;
  final Message? replyPreview;
  final VoidCallback? onReplyTap;
  final bool isLiveLocationSharing;
  final VoidCallback? onCancelLiveLocation;
  final bool readByOthers;
  // The current user's own bubble can be previewed locally while the published
  // sender bubble color remains authoritative for incoming messages.
  final Color? meBubbleColor;
  final double bubbleRadius;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    this.showAvatar = false,
    this.onTap,
    this.onTapUp,
    this.onLongPress,
    this.onAvatarTap,
    this.onReactionTap,
    this.replyPreview,
    this.onReplyTap,
    this.isLiveLocationSharing = false,
    this.onCancelLiveLocation,
    this.readByOthers = false,
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
        onTap: onTap,
        onLongPress: onLongPress,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: isMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe && showAvatar) ...[
            GestureDetector(
              onTap: onAvatarTap,
              child: CircleAvatar(
                radius: 14,
                backgroundImage: message.sender?.avatarUrl != null
                    ? CachedNetworkImageProvider(
                        ApiConfig.resolveMedia(message.sender!.avatarUrl!),
                      )
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
            child: Column(
              crossAxisAlignment: isMe
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message.effectiveReplyTo != null)
                  _ReplyContextPreview(
                    message: replyPreview,
                    isMe: isMe,
                    onTap: onReplyTap,
                  ),
                GestureDetector(
                  onTap: onTap,
                  onTapUp: onTapUp,
                  onLongPress: onLongPress,
                  child: _buildBubble(context),
                ),
                if (isMe && readByOthers)
                  const Padding(
                    padding: EdgeInsets.only(top: 3, right: 4),
                    child: _ReadReceiptLabel(),
                  ),
              ],
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

    if (message.type == MessageType.poll && message.poll != null) {
      return _PollBubble(
        message: message,
        isMe: isMe,
        bubbleColor: bubbleColor,
        textColor: textColor,
        radii: radii,
      );
    }

    if (message.type == MessageType.invoice ||
        message.type == MessageType.paymentRequest ||
        message.type == MessageType.paymentTransfer) {
      final payment = _PaymentEnvelope.tryParse(message);
      if (payment != null) {
        return _PaymentBubble(
          key: ValueKey('payment-${message.id}-${payment.kind}-${payment.id}'),
          message: message,
          isMe: isMe,
          payment: payment,
          bubbleColor: bubbleColor,
          textColor: textColor,
          radii: radii,
        );
      }
    }

    if (message.decryptionFailed) {
      return _BubbleShell(
        color: bubbleColor,
        radii: radii,
        child: _DecryptionError(textColor: textColor),
      );
    }

    if (message.type == MessageType.location && message.location != null) {
      return _LocationBubble(
        message: message,
        isMe: isMe,
        location: message.location!,
        bubbleColor: bubbleColor,
        textColor: textColor,
        radii: radii,
        onReactionTap: onReactionTap,
        isSharing: isLiveLocationSharing,
        onCancelSharing: onCancelLiveLocation,
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

    if (message is PendingMessage &&
        content.hasAttachment &&
        (message.attachmentId?.startsWith('pending-attachment-') ?? false)) {
      return _PendingAttachmentBubble(
        message: message as PendingMessage,
        content: content,
        bubbleColor: bubbleColor,
        textColor: textColor,
        radii: radii,
      );
    }

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
        MessageType.voice || MessageType.audio => _VoiceBubble(
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
      onReactionTap: onReactionTap,
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

class _ReadReceiptLabel extends StatelessWidget {
  const _ReadReceiptLabel();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.done_all_rounded, size: 13, color: color),
        const SizedBox(width: 3),
        Text(
          'Read',
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _PendingAttachmentBubble extends StatelessWidget {
  final PendingMessage message;
  final MessageContent content;
  final Color bubbleColor;
  final Color textColor;
  final BorderRadius radii;

  const _PendingAttachmentBubble({
    required this.message,
    required this.content,
    required this.bubbleColor,
    required this.textColor,
    required this.radii,
  });

  @override
  Widget build(BuildContext context) {
    final icon = switch (message.type) {
      MessageType.image => Icons.image_outlined,
      MessageType.video => Icons.play_circle_outline_rounded,
      MessageType.voice || MessageType.audio => Icons.graphic_eq_rounded,
      _ => Icons.insert_drive_file_outlined,
    };
    final status = switch (message.status) {
      PendingMessageStatus.sending => 'Sending',
      PendingMessageStatus.queued => 'Queued for upload',
      PendingMessageStatus.failed => 'Waiting to retry',
    };
    return _BubbleShell(
      color: bubbleColor,
      radii: radii,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: textColor, size: 28),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      content.fileName ?? 'Attachment',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      status,
                      style: TextStyle(
                        color: textColor.withValues(alpha: 0.72),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (content.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                content.text,
                style: TextStyle(color: textColor, fontSize: 14),
              ),
            ),
          ],
          const SizedBox(height: 6),
          _Timestamp(message: message, textColor: textColor),
        ],
      ),
    );
  }
}

// ── Call event chip ─────────────────────────────────────────────────────────

class _CallEventChip extends StatelessWidget {
  final CallEventInfo event;
  final DateTime time;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _CallEventChip({
    required this.event,
    required this.time,
    this.onTap,
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
        onTap: onTap,
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
                  fontSize: 12,
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                timeago.format(time, locale: 'en_short'),
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReplyContextPreview extends StatelessWidget {
  final Message? message;
  final bool isMe;
  final VoidCallback? onTap;

  const _ReplyContextPreview({
    required this.message,
    required this.isMe,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sender = message?.sender?.username;
    final title = sender == null ? 'Reply' : '@$sender';
    final preview = message == null
        ? 'Tap to load original'
        : message!.listPreview;
    final accent = isMe ? scheme.primary : scheme.secondary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.68,
        ),
        margin: const EdgeInsets.only(bottom: 3, left: 2, right: 2),
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.70),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: 0.24), width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 3,
              height: 28,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: 0.68),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
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

// ── Shell ─────────────────────────────────────────────────────────────────────

class _BubbleShell extends StatelessWidget {
  final Color color;
  final BorderRadius radii;
  final Widget child;
  final double? maxWidth;

  const _BubbleShell({
    required this.color,
    required this.radii,
    required this.child,
    this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Content layer: a solid, standard-material bubble with no backdrop blur.
    // Keeping bubbles off the Liquid Glass layer protects text legibility and
    // stops overlapping refractions from muddying the stream (and drops one
    // BackdropFilter per message). A soft ambient shadow lifts it off the canvas.
    return Container(
      constraints: BoxConstraints(
        maxWidth: maxWidth ?? MediaQuery.of(context).size.width * 0.75,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: radii,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.32 : 0.07),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: child,
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
  final ValueChanged<String>? onReactionTap;

  const _TextBubble({
    required this.message,
    required this.isMe,
    required this.bubbleColor,
    required this.textColor,
    required this.radii,
    this.onReactionTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    var linkPreviewsEnabled = true;
    var strictPrivacyMode = false;
    try {
      final settings = context.watch<SettingsProvider>();
      linkPreviewsEnabled = settings.linkPreviewsEnabled;
      strictPrivacyMode = settings.strictPrivacyMode;
    } on ProviderNotFoundException {
      linkPreviewsEnabled = true;
      strictPrivacyMode = false;
    }
    final embeddedPreview = message.content!.linkPreview;
    final previewUrl = linkPreviewsEnabled
        ? embeddedPreview?.url ?? firstLinkPreviewUrl(message.content!.text)
        : null;

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
          Text.rich(
            TextSpan(
              children: _formatMessageContent(
                context,
                message.content!,
                textColor,
                isMe ? textColor : cs.primary,
                strictPrivacyMode,
              ),
            ),
            style: TextStyle(color: textColor, fontSize: 15, height: 1.25),
          ),
          if (previewUrl != null) ...[
            const SizedBox(height: 8),
            _LinkPreviewCard(
              url: previewUrl,
              initialPreview: embeddedPreview,
              isMe: isMe,
              textColor: textColor,
            ),
          ],
          if (message.reactions.isNotEmpty) ...[
            const SizedBox(height: 6),
            _ReactionChips(
              reactions: message.reactions,
              textColor: textColor,
              onReactionTap: onReactionTap,
            ),
          ],
          const SizedBox(height: 2),
          _Timestamp(message: message, textColor: textColor),
        ],
      ),
    );
  }
}

class _LinkPreviewCard extends StatefulWidget {
  final String url;
  final LinkPreview? initialPreview;
  final bool isMe;
  final Color textColor;

  const _LinkPreviewCard({
    required this.url,
    this.initialPreview,
    required this.isMe,
    required this.textColor,
  });

  @override
  State<_LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<_LinkPreviewCard> {
  Future<LinkPreview?>? _future;
  late final LinkPreviewService _service;

  @override
  void initState() {
    super.initState();
    _service = LinkPreviewService();
    _future = widget.initialPreview != null
        ? Future<LinkPreview?>.value(widget.initialPreview)
        : _load();
  }

  @override
  void didUpdateWidget(covariant _LinkPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.initialPreview != widget.initialPreview) {
      _future = widget.initialPreview != null
          ? Future<LinkPreview?>.value(widget.initialPreview)
          : _load();
    }
  }

  @override
  void dispose() {
    _service.close();
    super.dispose();
  }

  Future<LinkPreview?> _load() async {
    try {
      return await _service.fetch(widget.url);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LinkPreview?>(
      future: _future,
      builder: (context, snapshot) {
        final preview = snapshot.data;
        if (preview == null) return const SizedBox.shrink();
        final title = preview.title.trim();
        final description = preview.description.trim();
        final host = preview.siteName.trim().isNotEmpty
            ? preview.siteName
            : preview.displayHost;
        if (title.isEmpty && description.isEmpty && host.isEmpty) {
          return const SizedBox.shrink();
        }
        return _LinkPreviewBody(
          host: host,
          title: title,
          description: description,
          isMe: widget.isMe,
          textColor: widget.textColor,
        );
      },
    );
  }
}

class _LinkPreviewBody extends StatelessWidget {
  final String host;
  final String title;
  final String description;
  final bool isMe;
  final Color textColor;

  const _LinkPreviewBody({
    required this.host,
    required this.title,
    required this.description,
    required this.isMe,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = isMe ? Colors.white : scheme.primary;
    final borderColor = accent.withValues(alpha: isMe ? 0.38 : 0.24);
    final fill = isMe
        ? Colors.white.withValues(alpha: 0.10)
        : scheme.surface.withValues(alpha: 0.34);
    return Container(
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 280),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.link_rounded, size: 18, color: accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (host.isNotEmpty)
                  Text(
                    host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.72),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                if (title.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        height: 1.18,
                      ),
                    ),
                  ),
                if (description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: textColor.withValues(alpha: 0.72),
                        fontSize: 12,
                        height: 1.18,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LocationBubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final MessageLocation location;
  final Color bubbleColor;
  final Color textColor;
  final BorderRadius radii;
  final ValueChanged<String>? onReactionTap;
  final bool isSharing;
  final VoidCallback? onCancelSharing;

  const _LocationBubble({
    required this.message,
    required this.isMe,
    required this.location,
    required this.bubbleColor,
    required this.textColor,
    required this.radii,
    this.onReactionTap,
    this.isSharing = false,
    this.onCancelSharing,
  });

  @override
  Widget build(BuildContext context) {
    final previewText = location.previewLabel.replaceFirst('📍 ', '');
    final status = location.isLive
        ? location.isActive
              ? 'Live${location.remainingLabel}'
              : 'Live location (ended)'
        : previewText;
    final accuracyText = location.accuracy != null
        ? 'Accuracy ±${location.accuracy!.toStringAsFixed(0)}m'
        : null;
    final layout = MessageImageLayout.forViewport(MediaQuery.of(context).size);
    final mapWidth = math.max(1.0, layout.maxBubbleWidth - 24);
    final mapHeight = math.min(layout.maxImageHeight, mapWidth * 0.75);

    return _BubbleShell(
      color: bubbleColor,
      radii: radii,
      maxWidth: layout.maxBubbleWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMe && message.sender != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '@${message.sender!.username}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: mapWidth,
              height: mapHeight,
              child: LocationMapPreview(location: location),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status,
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  previewText,
                  style: TextStyle(
                    color: textColor.withValues(alpha: 0.8),
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (accuracyText != null)
                  Text(
                    accuracyText,
                    style: TextStyle(
                      fontSize: 11,
                      color: textColor.withValues(alpha: 0.7),
                    ),
                  ),
                if (isSharing && location.isLive && location.isActive) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GlassButtonWidget.icon(
                      onPressed: onCancelSharing,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      icon: const Icon(Icons.location_off_outlined, size: 16),
                      label: const Text('Stop sharing'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          if (message.reactions.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: _ReactionChips(
                reactions: message.reactions,
                textColor: textColor,
                onReactionTap: onReactionTap,
              ),
            ),
          ],
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 2),
            child: _Timestamp(message: message, textColor: textColor),
          ),
        ],
      ),
    );
  }
}

List<InlineSpan> _formatMessageContent(
  BuildContext context,
  MessageContent content,
  Color color,
  Color mentionColor,
  bool strictPrivacyMode,
) {
  if (content.entities.isEmpty) {
    return _formatMessageText(
      context,
      content.text,
      color,
      mentionColor,
      strictPrivacyMode,
    );
  }
  final spans = <InlineSpan>[];
  final entities = normalizeRenderableEntities(content);
  var cursor = 0;
  for (final entity in entities) {
    if (entity.offset > cursor) {
      spans.addAll(
        _formatMessageText(
          context,
          content.text.substring(cursor, entity.offset),
          color,
          mentionColor,
          strictPrivacyMode,
        ),
      );
    }
    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: _InlineCustomEmoji(entity: entity),
      ),
    );
    cursor = entity.offset + entity.length;
  }
  if (cursor < content.text.length) {
    spans.addAll(
      _formatMessageText(
        context,
        content.text.substring(cursor),
        color,
        mentionColor,
        strictPrivacyMode,
      ),
    );
  }
  return spans;
}

List<CustomEmojiEntity> normalizeRenderableEntities(MessageContent content) {
  final out = <CustomEmojiEntity>[];
  final entities = [...content.entities]
    ..sort((a, b) => a.offset.compareTo(b.offset));
  for (final entity in entities) {
    if (entity.offset < 0 || entity.length <= 0) continue;
    final end = entity.offset + entity.length;
    if (end > content.text.length) continue;
    if (content.text.substring(entity.offset, end) != entity.emoji) continue;
    if (out.any((e) => entity.offset < e.offset + e.length && end > e.offset)) {
      continue;
    }
    out.add(entity);
  }
  return out;
}

List<InlineSpan> _formatMessageText(
  BuildContext context,
  String text,
  Color color,
  Color mentionColor,
  bool strictPrivacyMode,
) {
  final spans = <InlineSpan>[];
  var i = 0;
  while (i < text.length) {
    final markers = <String, int>{
      '**': text.indexOf('**', i),
      '__': text.indexOf('__', i),
      '`': text.indexOf('`', i),
      '||': text.indexOf('||', i),
    }..removeWhere((_, value) => value < 0);
    if (markers.isEmpty) {
      spans.addAll(
        _formatPlainTextDecorations(
          context,
          text.substring(i),
          mentionColor,
          strictPrivacyMode,
        ),
      );
      break;
    }
    final next = markers.entries.reduce((a, b) => a.value <= b.value ? a : b);
    if (next.value > i) {
      spans.addAll(
        _formatPlainTextDecorations(
          context,
          text.substring(i, next.value),
          mentionColor,
          strictPrivacyMode,
        ),
      );
    }
    final marker = next.key;
    final start = next.value + marker.length;
    final end = text.indexOf(marker, start);
    if (end < 0) {
      spans.addAll(
        _formatPlainTextDecorations(
          context,
          text.substring(next.value),
          mentionColor,
          strictPrivacyMode,
        ),
      );
      break;
    }
    final inner = text.substring(start, end);
    switch (marker) {
      case '**':
        spans.add(
          TextSpan(
            text: inner,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      case '__':
        spans.add(
          TextSpan(
            text: inner,
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      case '`':
        spans.add(
          TextSpan(
            text: inner,
            style: TextStyle(
              fontFamily: 'monospace',
              backgroundColor: color.withValues(alpha: 0.16),
            ),
          ),
        );
      case '||':
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _SpoilerText(text: inner, color: color),
          ),
        );
    }
    i = end + marker.length;
  }
  return spans;
}

List<InlineSpan> _formatPlainTextDecorations(
  BuildContext context,
  String text,
  Color mentionColor,
  bool strictPrivacyMode,
) {
  final links = linkTextMatches(text);
  if (links.isEmpty) return _formatPlainTextMentions(text, mentionColor);
  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final link in links) {
    if (link.start > cursor) {
      spans.addAll(
        _formatPlainTextMentions(
          text.substring(cursor, link.start),
          mentionColor,
        ),
      );
    }
    final label = text.substring(link.start, link.end);
    spans.add(
      TextSpan(
        text: label,
        style: TextStyle(
          color: mentionColor,
          fontWeight: FontWeight.w700,
          decoration: TextDecoration.underline,
          decorationColor: mentionColor.withValues(alpha: 0.75),
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () =>
              _openMessageLink(context, link.url, strictPrivacyMode),
      ),
    );
    cursor = link.end;
  }
  if (cursor < text.length) {
    spans.addAll(
      _formatPlainTextMentions(text.substring(cursor), mentionColor),
    );
  }
  return spans;
}

List<InlineSpan> _formatPlainTextMentions(String text, Color mentionColor) {
  final ranges = findMentionRanges(text);
  if (ranges.isEmpty) return [TextSpan(text: text)];
  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final range in ranges) {
    if (range.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, range.start)));
    }
    spans.add(
      TextSpan(
        text: text.substring(range.start, range.end),
        style: TextStyle(
          color: mentionColor,
          fontWeight: FontWeight.w800,
          decoration: TextDecoration.underline,
          decorationColor: mentionColor.withValues(alpha: 0.70),
        ),
      ),
    );
    cursor = range.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return spans;
}

Future<void> _openMessageLink(
  BuildContext context,
  String url,
  bool strictPrivacyMode,
) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  if (strictPrivacyMode) {
    final allowed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => GlassAlertDialog(
        title: const Text('Open link?'),
        content: Text(
          'Opening this link can reveal your IP address, browser details, and that you viewed it.\n\n$url',
        ),
        actions: [
          GlassButtonWidget(
            onPressed: () => Navigator.pop(dialogContext, false),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: const Text('Cancel'),
          ),
          GlassButtonWidget(
            onPressed: () => Navigator.pop(dialogContext, true),
            color: Theme.of(dialogContext).colorScheme.primary,
            foregroundColor: Theme.of(dialogContext).colorScheme.onPrimary,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    if (allowed != true) return;
  }
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!opened) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('Could not open link')),
    );
  }
}

class _InlineCustomEmoji extends StatefulWidget {
  final CustomEmojiEntity entity;

  const _InlineCustomEmoji({required this.entity});

  @override
  State<_InlineCustomEmoji> createState() => _InlineCustomEmojiState();
}

class _InlineCustomEmojiState extends State<_InlineCustomEmoji> {
  String? _fileUrl;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _fileUrl = widget.entity.fileUrl;
    if (_fileUrl == null || _fileUrl!.isEmpty) {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant _InlineCustomEmoji oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entity.customEmojiId != widget.entity.customEmojiId ||
        oldWidget.entity.fileUrl != widget.entity.fileUrl) {
      _fileUrl = widget.entity.fileUrl;
      if (_fileUrl == null || _fileUrl!.isEmpty) {
        _load();
      }
    }
  }

  Future<void> _load() async {
    if (_loading || widget.entity.customEmojiId.isEmpty) return;
    _loading = true;
    try {
      final data = await context.read<ApiService>().getCustomEmoji(
        widget.entity.customEmojiId,
      );
      if (!mounted) return;
      setState(() => _fileUrl = data['file_url'] as String?);
    } catch (_) {
      if (mounted) setState(() => _fileUrl = null);
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileUrl = _fileUrl;
    if (fileUrl == null || fileUrl.isEmpty) {
      return Text(widget.entity.emoji, style: const TextStyle(fontSize: 20));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: CachedNetworkImage(
        imageUrl: ApiConfig.resolveMedia(fileUrl),
        width: 22,
        height: 22,
        fit: BoxFit.contain,
        errorWidget: (_, _, _) =>
            Text(widget.entity.emoji, style: const TextStyle(fontSize: 20)),
      ),
    );
  }
}

class _SpoilerText extends StatefulWidget {
  final String text;
  final Color color;

  const _SpoilerText({required this.text, required this.color});

  @override
  State<_SpoilerText> createState() => _SpoilerTextState();
}

class _SpoilerTextState extends State<_SpoilerText> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _revealed = !_revealed),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        decoration: BoxDecoration(
          color: _revealed
              ? widget.color.withValues(alpha: 0.08)
              : widget.color.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          widget.text,
          style: TextStyle(
            color: _revealed ? widget.color : Colors.transparent,
            fontSize: 15,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}

class _ReactionChips extends StatelessWidget {
  final List<MessageReactionSummary> reactions;
  final Color textColor;
  final ValueChanged<String>? onReactionTap;

  const _ReactionChips({
    required this.reactions,
    required this.textColor,
    this.onReactionTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final reaction in reactions) ...[
          Builder(
            builder: (context) {
              final selected = reaction.reactedByMe;
              final color = selected ? scheme.primary : textColor;
              final chip = AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primary.withValues(alpha: 0.20)
                      : textColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected
                        ? scheme.primary.withValues(alpha: 0.72)
                        : textColor.withValues(alpha: 0.16),
                  ),
                ),
                child: Text(
                  '${reaction.emoji} ${reaction.count}',
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                  ),
                ),
              );
              if (onReactionTap == null) return chip;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onReactionTap!(reaction.emoji),
                child: chip,
              );
            },
          ),
        ],
      ],
    );
  }
}

class _PaymentEnvelope {
  final String kind;
  final String id;
  final String? payerId;
  final String? fromUserId;
  final String? toUserId;
  final String title;
  final String note;
  final String provider;
  final double amount;
  final String status;

  const _PaymentEnvelope({
    required this.kind,
    required this.id,
    this.payerId,
    this.fromUserId,
    this.toUserId,
    required this.title,
    required this.note,
    required this.provider,
    required this.amount,
    required this.status,
  });

  bool get isRequest => kind == 'payment_request';
  bool get isTransfer => kind == 'payment_transfer';
  String get providerLabel => provider.toUpperCase();
  String get amountLabel =>
      '${amount.toStringAsFixed(provider == 'btc' ? 8 : 12)} $providerLabel';

  static _PaymentEnvelope? tryParse(Message message) {
    try {
      final raw = _paymentPayload(message);
      if (raw is! Map<String, dynamic>) return null;
      final request = _asMap(raw['request']);
      final transfer = _asMap(raw['transfer']);
      final invoice = _asMap(raw['invoice']);
      if (transfer != null) {
        return _PaymentEnvelope(
          kind: 'payment_transfer',
          id: transfer['id'] as String? ?? '',
          fromUserId: transfer['from_user_id'] as String?,
          toUserId: transfer['to_user_id'] as String?,
          title: 'Payment sent',
          note: transfer['note'] as String? ?? '',
          provider: transfer['provider'] as String? ?? '',
          amount: _readDouble(transfer['amount']),
          status: 'confirmed',
        );
      }
      if (request != null) {
        return _PaymentEnvelope(
          kind: 'payment_request',
          id: request['id'] as String? ?? '',
          payerId: request['payer_id'] as String?,
          title: request['title'] as String? ?? 'Payment request',
          note: request['note'] as String? ?? '',
          provider: request['provider'] as String? ?? '',
          amount: _readDouble(request['amount']),
          status: request['status'] as String? ?? 'nothing_sent',
        );
      }
      if (invoice != null) {
        return _PaymentEnvelope(
          kind: 'invoice',
          id: invoice['id'] as String? ?? '',
          title: invoice['title'] as String? ?? 'Invoice',
          note: invoice['description'] as String? ?? '',
          provider: invoice['provider'] as String? ?? '',
          amount: _readDouble(invoice['crypto_amount']),
          status: invoice['status'] as String? ?? 'nothing_sent',
        );
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static Map<String, dynamic>? _paymentPayload(Message message) {
    final artifact = message.artifact?.payloadMap;
    if (artifact != null) return artifact;
    final decrypted = message.decryptedPayload;
    if (decrypted != null && decrypted.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(decrypted);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry(key.toString(), value));
        }
      } catch (_) {}
    }
    try {
      final decoded = jsonDecode(message.encryptedPayload);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {}
    return null;
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  static double _readDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }
}

String _formatPaymentAmount(double amount, String provider) {
  final decimals = provider == 'btc' ? 8 : 12;
  return '${amount.toStringAsFixed(decimals)} ${provider.toUpperCase()}';
}

class _PaymentBubble extends StatefulWidget {
  final Message message;
  final bool isMe;
  final _PaymentEnvelope payment;
  final Color bubbleColor;
  final Color textColor;
  final BorderRadius radii;

  const _PaymentBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.payment,
    required this.bubbleColor,
    required this.textColor,
    required this.radii,
  });

  @override
  State<_PaymentBubble> createState() => _PaymentBubbleState();
}

class _PaymentBubbleState extends State<_PaymentBubble> {
  bool _paying = false;
  bool _declining = false;
  bool _declined = false;
  bool _loadingBalance = false;
  String? _balanceProvider;
  double? _availableBalance;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureBalanceLoaded();
  }

  @override
  void didUpdateWidget(covariant _PaymentBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.payment.id != widget.payment.id ||
        oldWidget.payment.provider != widget.payment.provider) {
      _declined = false;
      _balanceProvider = null;
      _availableBalance = null;
      _ensureBalanceLoaded();
    }
  }

  void _ensureBalanceLoaded() {
    final currentUserID = context.read<AuthProvider>().currentUser?.id;
    final payment = widget.payment;
    final shouldLoad =
        payment.isRequest &&
        !widget.isMe &&
        payment.status == 'nothing_sent' &&
        payment.id.isNotEmpty &&
        (payment.payerId == null || payment.payerId == currentUserID);
    if (!shouldLoad ||
        _loadingBalance ||
        _balanceProvider == payment.provider) {
      return;
    }
    unawaited(_loadBalance(payment.provider));
  }

  Future<void> _loadBalance(String provider) async {
    setState(() {
      _loadingBalance = true;
      _balanceProvider = provider;
    });
    try {
      final balances = await context.read<ApiService>().getPaymentBalances();
      double available = 0;
      for (final item in balances.whereType<Map<String, dynamic>>()) {
        if (item['provider'] == provider) {
          available = _PaymentEnvelope._readDouble(item['available']);
          break;
        }
      }
      if (!mounted) return;
      setState(() => _availableBalance = available);
    } catch (_) {
      if (!mounted) return;
      setState(() => _availableBalance = 0);
    } finally {
      if (mounted) setState(() => _loadingBalance = false);
    }
  }

  Future<void> _pay() async {
    if (_paying || _declining || _declined) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => GlassAlertDialog(
        title: const Text('Pay request'),
        content: Text('Send ${widget.payment.amountLabel}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Pay'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();
    setState(() => _paying = true);
    try {
      final result = await api.payPaymentRequest(widget.payment.id);
      final transfer = result['transfer'] as Map<String, dynamic>?;
      if (transfer != null) {
        await chat.sendPaymentArtifact(
          convID: widget.message.conversationId,
          kind: 'payment_transfer',
          payload: {'kind': 'payment_transfer', 'transfer': transfer},
        );
      }
      if (!mounted) return;
      await chat.loadMessages(widget.message.conversationId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  Future<void> _payExternal() async {
    if (_paying || _declining || _declined) return;
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();
    setState(() => _paying = true);
    try {
      final result = await api.payPaymentRequestExternally(
        requestID: widget.payment.id,
      );
      if (!mounted) return;
      final deposit = result['deposit'] as Map<String, dynamic>?;
      if (deposit != null) {
        await chat.sendPaymentArtifact(
          convID: widget.message.conversationId,
          kind: 'invoice',
          payload: {
            'kind': 'invoice',
            'invoice': {
              'id': deposit['id'],
              'title': 'External payment',
              'description': widget.payment.note,
              'provider': deposit['provider'],
              'crypto_amount': deposit['expected_amount'],
              'crypto_address': deposit['crypto_address'],
              'status': deposit['status'],
            },
          },
        );
        if (!mounted) return;
        _showExternalPaymentAddress(deposit);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  Future<void> _decline() async {
    if (_paying || _declining || _declined) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => GlassAlertDialog(
        title: const Text('Decline request'),
        content: Text('Decline ${widget.payment.amountLabel}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Decline'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _declining = true);
    try {
      await context.read<ApiService>().declinePaymentRequest(widget.payment.id);
      if (!mounted) return;
      setState(() => _declined = true);
      await context.read<ChatProvider>().loadMessages(
        widget.message.conversationId,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _declining = false);
    }
  }

  void _showExternalPaymentAddress(Map<String, dynamic> deposit) {
    final address = deposit['crypto_address'] as String? ?? '';
    final provider = deposit['provider'] as String? ?? '';
    final amount = deposit['expected_amount'];
    final amountText = amount == null
        ? ''
        : '\n\nSend at least ${_formatPaymentAmount(_PaymentEnvelope._readDouble(amount), provider)}.';
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => GlassAlertDialog(
        title: Text('Pay with ${provider.toUpperCase()}'),
        content: SelectableText('$address$amountText'),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: address));
              if (mounted && dialogCtx.mounted) Navigator.pop(dialogCtx);
            },
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final currentUserID = context.watch<AuthProvider>().currentUser?.id;
    final payment = widget.payment;
    final canPay =
        payment.isRequest &&
        !widget.isMe &&
        !_declined &&
        payment.status == 'nothing_sent' &&
        payment.id.isNotEmpty &&
        (payment.payerId == null || payment.payerId == currentUserID);
    final canDecline = canPay && payment.payerId == currentUserID;
    final canPayWithWallet =
        canPay &&
        _availableBalance != null &&
        _availableBalance! >= payment.amount;
    final isBusy = _paying || _declining;
    final icon = payment.isTransfer
        ? Icons.check_circle_outline
        : Icons.payments_outlined;
    final statusText = payment.isTransfer
        ? 'Confirmed'
        : _declined
        ? 'Declined'
        : payment.status == 'nothing_sent'
        ? 'Requested'
        : payment.status.replaceAll('_', ' ');

    return _BubbleShell(
      color: widget.bubbleColor,
      radii: widget.radii,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!widget.isMe && widget.message.sender != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '@${widget.message.sender!.username}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: cs.primary,
                ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: widget.textColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: widget.textColor, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      payment.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      statusText,
                      style: TextStyle(
                        color: widget.textColor.withValues(alpha: 0.68),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                payment.amountLabel,
                style: TextStyle(
                  color: widget.textColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          if (payment.note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              payment.note,
              style: TextStyle(
                color: widget.textColor.withValues(alpha: 0.78),
                fontSize: 13,
              ),
            ),
          ],
          if (canPay) ...[
            const SizedBox(height: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (canPayWithWallet)
                  GlassButtonWidget.icon(
                    onPressed: isBusy ? null : _pay,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    icon: _paying
                        ? const GlassProgressIndicator.circular(size: 14, strokeWidth: 2)
                        : const Icon(Icons.account_balance_wallet, size: 16),
                    label: const Text('App wallet'),
                  ),
                if (canPayWithWallet) const SizedBox(height: 8),
                GlassButtonWidget.icon(
                  onPressed: isBusy ? null : _payExternal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  icon: const Icon(Icons.qr_code_2, size: 16),
                  label: const Text('External'),
                ),
                if (canDecline) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: isBusy ? null : _decline,
                    icon: _declining
                        ? const GlassProgressIndicator.circular(size: 14, strokeWidth: 2)
                        : const Icon(Icons.close_rounded, size: 16),
                    label: const Text('Decline'),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: _Timestamp(
              message: widget.message,
              textColor: widget.textColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _PollBubble extends StatefulWidget {
  final Message message;
  final bool isMe;
  final Color bubbleColor;
  final Color textColor;
  final BorderRadius radii;

  const _PollBubble({
    required this.message,
    required this.isMe,
    required this.bubbleColor,
    required this.textColor,
    required this.radii,
  });

  @override
  State<_PollBubble> createState() => _PollBubbleState();
}

class _PollBubbleState extends State<_PollBubble> {
  bool _voting = false;

  Future<void> _vote(PollOption option) async {
    final poll = widget.message.poll;
    if (poll == null || poll.isClosed || _voting) return;
    final selected = poll.voterOptionIds.toSet();
    final next = poll.allowsMultipleAnswers
        ? (selected.contains(option.id)
              ? (selected..remove(option.id)).toList()
              : (selected..add(option.id)).toList())
        : [option.id];
    if (next.isEmpty) return;
    setState(() => _voting = true);
    try {
      await context.read<ChatProvider>().votePoll(
        convID: widget.message.conversationId,
        pollID: poll.id,
        optionIDs: next,
      );
    } finally {
      if (mounted) setState(() => _voting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final poll = widget.message.poll!;
    final cs = Theme.of(context).colorScheme;
    final total = math.max(1, poll.totalVoterCount);

    return _BubbleShell(
      color: widget.bubbleColor,
      radii: widget.radii,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!widget.isMe && widget.message.sender != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '@${widget.message.sender!.username}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: cs.primary,
                ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.poll_outlined, size: 18, color: widget.textColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  poll.question,
                  style: TextStyle(
                    color: widget.textColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (poll.description != null && poll.description!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              poll.description!,
              style: TextStyle(
                color: widget.textColor.withValues(alpha: 0.78),
                fontSize: 13,
              ),
            ),
          ],
          const SizedBox(height: 10),
          for (final option in poll.options) ...[
            _PollOptionRow(
              option: option,
              percent: option.voterCount / total,
              selected: poll.isSelected(option.id),
              enabled: !poll.isClosed && !_voting,
              textColor: widget.textColor,
              onTap: () => _vote(option),
            ),
            const SizedBox(height: 6),
          ],
          Row(
            children: [
              Text(
                poll.isClosed ? 'Closed' : '${poll.totalVoterCount} votes',
                style: TextStyle(
                  color: widget.textColor.withValues(alpha: 0.68),
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              _Timestamp(message: widget.message, textColor: widget.textColor),
            ],
          ),
        ],
      ),
    );
  }
}

class _PollOptionRow extends StatelessWidget {
  final PollOption option;
  final double percent;
  final bool selected;
  final bool enabled;
  final Color textColor;
  final VoidCallback onTap;

  const _PollOptionRow({
    required this.option,
    required this.percent,
    required this.selected,
    required this.enabled,
    required this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fill = textColor.withValues(alpha: selected ? 0.24 : 0.14);
    final border = textColor.withValues(alpha: selected ? 0.42 : 0.16);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: percent.clamp(0, 1),
                child: DecoratedBox(decoration: BoxDecoration(color: fill)),
              ),
            ),
            Container(
              constraints: const BoxConstraints(minHeight: 40),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: border),
              ),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: textColor.withValues(alpha: selected ? 0.95 : 0.7),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      option.text,
                      style: TextStyle(color: textColor, fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${(percent * 100).round()}%',
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.72),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
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
    if (c.attachmentId == null) {
      setState(() => _state = _LoadState.error);
      return;
    }
    setState(() => _state = _LoadState.loading);
    try {
      final svc = AttachmentService(context.read<ApiService>());
      final bytes = c.fileKey != null && c.fileNonce != null
          ? await svc.downloadAndDecrypt(
              attachmentId: c.attachmentId!,
              fileKeyB64: c.fileKey!,
              fileNonceB64: c.fileNonce!,
            )
          : !widget.message.isEncrypted
          ? await svc.downloadRaw(attachmentId: c.attachmentId!)
          : throw StateError('missing attachment key');
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
                child: Text(
                  c.text,
                  style: TextStyle(color: textColor, fontSize: 14),
                ),
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
        child: const Center(child: GlassProgressIndicator.circular()),
      ),
      _LoadState.error => Container(
        height: layout.reservedImageHeight,
        color: Colors.black12,
        child: const Center(
          child: Icon(Icons.broken_image, color: Colors.grey),
        ),
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
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
          ),
          body: Center(child: InteractiveViewer(child: Image.memory(_bytes!))),
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
    if (c.attachmentId == null) {
      setState(() => _state = _LoadState.error);
      return;
    }
    setState(() => _state = _LoadState.loading);
    try {
      final svc = AttachmentService(context.read<ApiService>());
      final bytes = c.fileKey != null && c.fileNonce != null
          ? await svc.downloadAndDecrypt(
              attachmentId: c.attachmentId!,
              fileKeyB64: c.fileKey!,
              fileNonceB64: c.fileNonce!,
            )
          : !widget.message.isEncrypted
          ? await svc.downloadRaw(attachmentId: c.attachmentId!)
          : throw StateError('missing attachment key');

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
        child: const Center(child: GlassProgressIndicator.circular()),
      ),
      _LoadState.error => Container(
        height: 100,
        color: Colors.black12,
        child: const Center(
          child: Icon(Icons.videocam_off, color: Colors.grey),
        ),
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

// ── Voice / audio bubble ─────────────────────────────────────────────────────

class _VoiceBubble extends StatefulWidget {
  final Message message;
  final MessageContent content;
  final Color bubbleColor;
  final Color textColor;
  final BorderRadius radii;

  const _VoiceBubble({
    required this.message,
    required this.content,
    required this.bubbleColor,
    required this.textColor,
    required this.radii,
  });

  @override
  State<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<_VoiceBubble> {
  _LoadState _state = _LoadState.idle;
  AudioPlayer? _player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  late final List<double> _levels;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _duration = _durationFromMetadata(widget.content.durationMs);
    _levels = _voiceLevels(widget.message.id);
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    unawaited(_player?.dispose());
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_state == _LoadState.loading) return;
    if (_state != _LoadState.done) {
      await _load();
      if (!mounted || _state != _LoadState.done) return;
    }

    final player = _player;
    if (player == null) return;
    final duration = _duration;
    if (duration != null &&
        duration > Duration.zero &&
        _position >= duration - const Duration(milliseconds: 250)) {
      await player.seek(Duration.zero);
    }
    if (player.playing) {
      await player.pause();
    } else {
      unawaited(player.play());
    }
  }

  Future<void> _seekToFraction(double fraction) async {
    if (_state != _LoadState.done) {
      await _load();
      if (!mounted || _state != _LoadState.done) return;
    }
    final duration = _duration;
    final player = _player;
    if (duration == null || duration <= Duration.zero || player == null) {
      return;
    }
    await player.seek(
      Duration(
        milliseconds: (duration.inMilliseconds * fraction.clamp(0, 1)).round(),
      ),
    );
  }

  Future<void> _load() async {
    final attachmentId = widget.content.attachmentId;
    if (attachmentId == null) {
      setState(() => _state = _LoadState.error);
      return;
    }

    setState(() => _state = _LoadState.loading);
    try {
      final svc = AttachmentService(context.read<ApiService>());
      final bytes =
          widget.content.fileKey != null && widget.content.fileNonce != null
          ? await svc.downloadAndDecrypt(
              attachmentId: attachmentId,
              fileKeyB64: widget.content.fileKey!,
              fileNonceB64: widget.content.fileNonce!,
            )
          : !widget.message.isEncrypted
          ? await svc.downloadRaw(attachmentId: attachmentId)
          : throw StateError('missing attachment key');

      final file = await _writeTempAudio(bytes);
      final player = _ensurePlayer();
      final loadedDuration = await player.setFilePath(file.path);
      if (!mounted) return;
      setState(() {
        _duration = loadedDuration ?? _duration;
        _state = _LoadState.done;
      });
    } catch (_) {
      if (mounted) setState(() => _state = _LoadState.error);
    }
  }

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;

    final player = AudioPlayer();
    _player = player;
    _subscriptions
      ..add(
        player.positionStream.listen((position) {
          if (mounted) setState(() => _position = position);
        }),
      )
      ..add(
        player.durationStream.listen((duration) {
          if (mounted && duration != null) setState(() => _duration = duration);
        }),
      )
      ..add(
        player.playerStateStream.listen((state) {
          if (!mounted) return;
          if (state.processingState == ProcessingState.completed) {
            setState(() {
              _playing = false;
              _position = _duration ?? _position;
            });
            unawaited(player.seek(Duration.zero));
            return;
          }
          setState(() => _playing = state.playing);
        }),
      );
    return player;
  }

  Future<File> _writeTempAudio(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final safeId = (widget.content.attachmentId ?? widget.message.id)
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final ext = _audioExtension(widget.content);
    final file = File(p.join(dir.path, 'openchat_voice_$safeId.$ext'));
    if (!await file.exists() || await file.length() != bytes.length) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return file;
  }

  double get _progress {
    final duration = _duration;
    if (duration == null || duration.inMilliseconds <= 0) return 0;
    return (_position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  String get _timeLabel {
    if (_position > Duration.zero && _state == _LoadState.done) {
      return _formatVoiceDuration(_position);
    }
    final duration = _duration;
    return duration == null ? '--:--' : _formatVoiceDuration(duration);
  }

  @override
  Widget build(BuildContext context) {
    final error = _state == _LoadState.error;
    final loading = _state == _LoadState.loading;
    return _BubbleShell(
      color: widget.bubbleColor,
      radii: widget.radii,
      child: SizedBox(
        width: math.min(MediaQuery.of(context).size.width * 0.64, 340),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _VoicePlayButton(
              color: widget.textColor,
              loading: loading,
              playing: _playing,
              error: error,
              onTap: _togglePlayback,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _VoiceScrubber(
                    levels: _levels,
                    progress: _progress,
                    activeColor: widget.textColor,
                    inactiveColor: widget.textColor.withValues(alpha: 0.24),
                    onSeek: _seekToFraction,
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Text(
                        error ? 'Tap to retry' : _timeLabel,
                        style: TextStyle(
                          color: widget.textColor.withValues(alpha: 0.76),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      _Timestamp(
                        message: widget.message,
                        textColor: widget.textColor,
                      ),
                    ],
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

class _VoicePlayButton extends StatelessWidget {
  final Color color;
  final bool loading;
  final bool playing;
  final bool error;
  final VoidCallback onTap;

  const _VoicePlayButton({
    required this.color,
    required this.loading,
    required this.playing,
    required this.error,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.18),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: loading ? null : onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: loading
                ? GlassProgressIndicator.circular(size: 18, strokeWidth: 2, color: color)
                : Icon(
                    error
                        ? Icons.refresh
                        : playing
                        ? Icons.pause
                        : Icons.play_arrow,
                    color: color,
                    size: 27,
                  ),
          ),
        ),
      ),
    );
  }
}

class _VoiceScrubber extends StatelessWidget {
  final List<double> levels;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;
  final ValueChanged<double> onSeek;

  const _VoiceScrubber({
    required this.levels,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    required this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        void seek(Offset localPosition) {
          final width = math.max(1.0, constraints.maxWidth);
          onSeek((localPosition.dx / width).clamp(0.0, 1.0));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => seek(details.localPosition),
          onHorizontalDragUpdate: (details) => seek(details.localPosition),
          child: SizedBox(
            height: 32,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (final (index, level) in levels.indexed) ...[
                  Expanded(
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 90),
                        height: 5 + (24 * level),
                        decoration: BoxDecoration(
                          color: (index + 1) / levels.length <= progress
                              ? activeColor
                              : inactiveColor,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                  ),
                  if (index != levels.length - 1) const SizedBox(width: 3),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

Duration? _durationFromMetadata(int? durationMs) {
  if (durationMs == null || durationMs <= 0) return null;
  return Duration(milliseconds: durationMs);
}

String _formatVoiceDuration(Duration duration) {
  final total = duration.inSeconds;
  final minutes = (total ~/ 60).toString().padLeft(2, '0');
  final seconds = (total % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

String _audioExtension(MessageContent content) {
  final nameExt = content.fileName == null
      ? ''
      : p.extension(content.fileName!).replaceFirst('.', '').toLowerCase();
  if (nameExt.isNotEmpty && nameExt.length <= 5) return nameExt;

  final mime = content.mimeType ?? '';
  if (mime.contains('mpeg')) return 'mp3';
  if (mime.contains('ogg') || mime.contains('opus')) return 'ogg';
  if (mime.contains('wav')) return 'wav';
  if (mime.contains('webm')) return 'webm';
  return 'm4a';
}

List<double> _voiceLevels(String seed) {
  var hash = seed.codeUnits.fold<int>(0x4d3c2b1a, (value, code) {
    return (value * 31 + code) & 0x7fffffff;
  });
  return List<double>.generate(28, (_) {
    hash = (hash * 1103515245 + 12345) & 0x7fffffff;
    return 0.18 + ((hash >> 8) & 0xff) / 255 * 0.82;
  });
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
    if (c.attachmentId == null) {
      return;
    }
    setState(() => _state = _LoadState.loading);
    try {
      final svc = AttachmentService(context.read<ApiService>());
      final bytes = c.fileKey != null && c.fileNonce != null
          ? await svc.downloadAndDecrypt(
              attachmentId: c.attachmentId!,
              fileKeyB64: c.fileKey!,
              fileNonceB64: c.fileNonce!,
            )
          : !widget.message.isEncrypted
          ? await svc.downloadRaw(attachmentId: c.attachmentId!)
          : throw StateError('missing attachment key');

      final dir = await getApplicationDocumentsDirectory();
      final fileName = c.fileName ?? 'file_${c.attachmentId}';
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes);

      if (mounted) {
        setState(() => _state = _LoadState.done);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Saved to ${file.path}')));
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
        _LoadState.loading => GlassProgressIndicator.circular(size: 40, strokeWidth: 2, color: textColor),
        _LoadState.done => Icon(Icons.check_circle, color: textColor, size: 40),
        _LoadState.error => Icon(
          Icons.error_outline,
          color: Colors.red[300],
          size: 40,
        ),
        _LoadState.idle => Icon(
          Icons.download_outlined,
          color: textColor,
          size: 40,
        ),
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
    final pending = message is PendingMessage
        ? message as PendingMessage
        : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pending != null)
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Icon(
              switch (pending.status) {
                PendingMessageStatus.sending => Icons.sync_rounded,
                PendingMessageStatus.queued => Icons.cloud_upload_outlined,
                PendingMessageStatus.failed => Icons.error_outline_rounded,
              },
              size: 11,
              color: textColor.withValues(alpha: 0.62),
            ),
          ),
        if (message.decryptionFailed)
          Icon(Icons.lock, size: 10, color: textColor.withValues(alpha: 0.5)),
        if (message.silent)
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Icon(
              Icons.notifications_off_outlined,
              size: 11,
              color: textColor.withValues(alpha: 0.55),
            ),
          ),
        Text(
          pending == null
              ? timeago.format(message.createdAt, locale: 'en_short')
              : switch (pending.status) {
                  PendingMessageStatus.sending => 'sending',
                  PendingMessageStatus.queued => 'queued',
                  PendingMessageStatus.failed => 'retrying',
                },
          style: TextStyle(
            fontSize: 10,
            color: textColor.withValues(alpha: 0.6),
          ),
        ),
        if (message.isEdited)
          Text(
            ' · edited',
            style: TextStyle(
              fontSize: 10,
              color: textColor.withValues(alpha: 0.6),
            ),
          ),
        if (message.hasAutoDelete)
          StreamBuilder<int>(
            stream: Stream.periodic(const Duration(seconds: 30), (i) => i),
            builder: (context, _) => Text(
              ' · ${_remainingAutoDelete(message)} left',
              style: TextStyle(
                fontSize: 10,
                color: textColor.withValues(alpha: 0.7),
              ),
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
        color: textColor.withValues(alpha: 0.5),
        fontStyle: FontStyle.italic,
      ),
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
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _StickerPackSheet(packID: packId, api: context.read<ApiService>()),
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
            ? const Center(child: GlassProgressIndicator.circular(strokeWidth: 2))
            : fileUrl != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: ApiConfig.resolveMedia(fileUrl),
                  fit: BoxFit.contain,
                  placeholder: (_, _) => const Center(
                    child: GlassProgressIndicator.circular(strokeWidth: 2),
                  ),
                  errorWidget: (_, _, _) => const Center(
                    child: Icon(Icons.broken_image_outlined, size: 44),
                  ),
                ),
              )
            : const Center(child: Icon(Icons.broken_image_outlined, size: 44)),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to add pack: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final stickers = (_pack?['stickers'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final coverUrl = _pack?['cover_url'] as String?;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.85,
      builder: (_, controller) => GlassSurface(
        blur: 56,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: Column(
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
                        errorWidget: (_, _, _) => const SizedBox.shrink(),
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
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        if (_pack?['description'] != null)
                          Text(
                            _pack!['description'] as String,
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 13,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  GlassButtonWidget.icon(
                    onPressed: _adding ? null : _addToLibrary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    icon: _adding
                        ? const GlassProgressIndicator.circular(size: 16, strokeWidth: 2)
                        : const Icon(Icons.add, size: 18),
                    label: const Text('Add'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: GlassProgressIndicator.circular())
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
                                  errorWidget: (_, _, _) => const Center(
                                    child: Icon(Icons.broken_image_outlined),
                                  ),
                                )
                              : const Center(
                                  child: Icon(Icons.broken_image_outlined),
                                ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
