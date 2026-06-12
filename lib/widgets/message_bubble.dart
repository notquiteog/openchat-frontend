import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../config/api_config.dart';
import '../models/conversation.dart';
import '../models/conversation_invite.dart';
import '../models/link_preview.dart';
import '../models/message.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../screens/invites/invite_preview_screen.dart';
import '../services/api_service.dart';
import '../services/attachment_service.dart';
import '../services/link_preview_service.dart';
import '../services/network_service.dart';
import '../services/security_service.dart';
import '../services/transcription_service.dart';
import '../utils/link_preview_utils.dart';
import '../utils/mention_utils.dart';
import '../utils/skill_game.dart';
import 'die_3d.dart';
import 'game_play_sheet.dart';
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

  /// Desktop right-click: the pointer-native way to open the message menu.
  final GestureTapUpCallback? onSecondaryTapUp;
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
  // True when this bubble belongs to a channel, so interactive cards (e.g. the
  // game card) route their API calls to the /channels surface.
  final bool isChannel;

  /// When [message] anchors a media album (consecutive same-sender images
  /// sharing a media_group_id), the full chronological run — rendered as one
  /// grouped grid instead of a lone image. See utils/message_albums.dart.
  final List<Message>? albumMessages;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    this.showAvatar = false,
    this.onTap,
    this.onTapUp,
    this.onLongPress,
    this.onSecondaryTapUp,
    this.onAvatarTap,
    this.onReactionTap,
    this.replyPreview,
    this.onReplyTap,
    this.isLiveLocationSharing = false,
    this.onCancelLiveLocation,
    this.readByOthers = false,
    this.meBubbleColor,
    this.bubbleRadius = 18,
    this.isChannel = false,
    this.albumMessages,
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
      return GestureDetector(
        onSecondaryTapUp: onSecondaryTapUp,
        child: _CallEventChip(
          event: callEvent,
          time: message.createdAt,
          onTap: onTap,
          onLongPress: onLongPress,
        ),
      );
    }
    if (message.isScreenshotNotice) {
      return _ScreenshotNoticeChip(
        sender: message.sender?.displayName,
        isMe: isMe,
      );
    }
    final dice = message.dice;
    if (dice != null) {
      return _DiceBubble(
        dice: dice,
        isMe: isMe,
        messageId: message.id,
        createdAt: message.createdAt,
      );
    }

    final gameRoundId = message.gameRoundId;
    if (gameRoundId != null) {
      return _GameBubble(
        conversationId: message.conversationId,
        roundId: gameRoundId,
        isMe: isMe,
        isChannel: isChannel,
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
                  onSecondaryTapUp: onSecondaryTapUp,
                  child: _buildBubble(context),
                ),
                if (message.tips.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: _TipChips(tips: message.tips),
                  ),
                _TranslationLine(messageId: message.id),
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

    if (message.type == MessageType.contact && content.contact != null) {
      return _ContactBubble(
        contact: content.contact!,
        bubbleColor: bubbleColor,
        textColor: textColor,
        radii: radii,
        message: message,
      );
    }

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

    if (content.hasAttachment && content.viewOnce && !isMe) {
      return _ViewOnceAttachmentGate(
        message: message,
        content: content,
        bubbleColor: bubbleColor,
        textColor: textColor,
        radii: radii,
      );
    }

    if (content.hasAttachment) {
      final album = albumMessages;
      final attachment = switch (message.type) {
        MessageType.image when album != null && album.length >= 2 =>
          _AlbumGridBubble(
            messages: album,
            anchor: message,
            bubbleColor: bubbleColor,
            textColor: textColor,
            radii: radii,
          ),
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
      if (content.hasSpoiler &&
          (message.type == MessageType.image ||
              message.type == MessageType.video)) {
        return _SpoilerGate(radii: radii, child: attachment);
      }
      // Auto-download gating: on a restricted network, hold heavy incoming media
      // behind a tap-to-download placeholder.
      if (!isMe &&
          (message.type == MessageType.image ||
              message.type == MessageType.video)) {
        return _AutoDownloadGate(
          content: content,
          bubbleColor: bubbleColor,
          textColor: textColor,
          radii: radii,
          child: attachment,
        );
      }
      return attachment;
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

/// Centered system note shown when someone screenshots view-once media.
class _ScreenshotNoticeChip extends StatelessWidget {
  final String? sender;
  final bool isMe;

  const _ScreenshotNoticeChip({required this.sender, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final who = isMe ? 'You' : (sender ?? 'Someone');
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: cs.errorContainer.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.screenshot_monitor_outlined, size: 15, color: cs.error),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '$who took a screenshot',
                style: TextStyle(
                  fontSize: 12,
                  color: cs.error,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Animated reveal of a server-rolled dice/randomiser (Batch 8.1). The emoji
/// "tumbles" through random faces before settling on the authoritative value.
class _DiceBubble extends StatefulWidget {
  final DiceContent dice;
  final bool isMe;
  final String messageId;
  final DateTime createdAt;
  const _DiceBubble({
    required this.dice,
    required this.isMe,
    required this.messageId,
    required this.createdAt,
  });

  @override
  State<_DiceBubble> createState() => _DiceBubbleState();
}

class _DiceBubbleState extends State<_DiceBubble>
    with SingleTickerProviderStateMixin {
  /// Rolls animate once per message per app run: a fresh roll tumbles, a
  /// scrollback remount (or any list rebuild) renders the settled result.
  static final Set<String> _rolledOnce = <String>{};

  late final bool _animate =
      !_rolledOnce.contains(widget.messageId) &&
      DateTime.now().difference(widget.createdAt).abs() <
          const Duration(minutes: 2);

  late final AnimationController _ctrl = AnimationController(
    duration: const Duration(milliseconds: 1600),
    vsync: this,
  );

  bool get _isDie => widget.dice.emoji == '🎲' && widget.dice.max == 6;

  @override
  void initState() {
    super.initState();
    if (_animate) {
      _rolledOnce.add(widget.messageId);
      _ctrl.forward();
    } else {
      _ctrl.value = 1.0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// The 🎲 path: a perspective cube tumbling through seeded spins, hopping
  /// twice off the ground, and easing onto the server-decided face. Pure
  /// function of t, like the glyph path.
  Widget _die3d(double t) {
    const dieSize = 54.0;
    final seed = widget.messageId.hashCode & 0x7fffffff;
    final ease = Curves.easeOutQuart.transform(t);
    final spinsX = (2 + seed % 2) * (((seed >> 5) & 1) == 0 ? 1.0 : -1.0);
    final spinsY =
        (3 + (seed >> 3) % 2) * (((seed >> 7) & 1) == 0 ? 1.0 : -1.0);
    final (targetX, targetY) = Die3D.targetRotationFor(widget.dice.value);
    // A fixed presentation tilt keeps two extra edges visible once settled —
    // composed OUTSIDE the spin so the landed face still points at the
    // viewer.
    final rotation = Matrix4.identity()
      ..rotateX(-0.30)
      ..rotateY(0.36)
      ..rotateX(targetX + spinsX * 2 * math.pi * (1 - ease))
      ..rotateY(targetY + spinsY * 2 * math.pi * (1 - ease));
    final hop = t < 1.0
        ? 24.0 * (1 - t) * math.sin(t * math.pi * 3).abs()
        : 0.0;
    final lift = hop / 24.0;
    return SizedBox(
      width: 96,
      height: 88,
      child: Stack(
        alignment: Alignment.bottomCenter,
        clipBehavior: Clip.none,
        children: [
          Positioned(
            bottom: 2,
            child: Container(
              width: dieSize * (1.0 - 0.3 * lift),
              height: 9,
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.all(
                  Radius.elliptical(27, 4.5),
                ),
                color: Colors.black.withValues(alpha: 0.28 - 0.16 * lift),
              ),
            ),
          ),
          Positioned(
            bottom: 12 + hop,
            child: Die3D(rotation: rotation, size: dieSize),
          ),
        ],
      ),
    );
  }

  /// Non-die randomisers (🎯 …) keep the 2D glyph tumble.
  Widget _emojiTumble(double t, ColorScheme scheme) {
    final rolling = t < 1.0;
    // Wobble + spin fade out as the emoji settles; a slight overshoot pop
    // lands the result.
    final wobble = rolling ? math.sin(t * math.pi * 10) * 0.35 * (1 - t) : 0.0;
    final settlePop = rolling ? 1.0 + 0.18 * (1 - t) : 1.0;
    return Transform.rotate(
      angle: wobble,
      child: Transform.scale(
        scale: settlePop,
        child: Text(
          widget.dice.emoji,
          style: const TextStyle(fontSize: 44, height: 1.1),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: widget.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(18),
        ),
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            final t = _ctrl.value;
            final rolling = t < 1.0;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isDie) _die3d(t) else _emojiTumble(t, scheme),
                const SizedBox(height: 4),
                Text(
                  rolling ? 'Rolling…' : widget.dice.label,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface.withValues(
                      alpha: rolling ? 0.55 : 0.85,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Live in-chat card for a provably-fair game round. Renders the commitment and
/// bet controls while open, the verifiable outcome + payout once revealed, and a
/// refund notice for an abandoned real-money round. State comes from
/// ChatProvider (seeded by the API + game_updated WS events).
class _GameBubble extends StatefulWidget {
  final String conversationId;
  final String roundId;
  final bool isMe;
  final bool isChannel;
  const _GameBubble({
    required this.conversationId,
    required this.roundId,
    required this.isMe,
    required this.isChannel,
  });

  @override
  State<_GameBubble> createState() => _GameBubbleState();
}

class _GameBubbleState extends State<_GameBubble> {
  bool _busy = false;
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _requested) return;
      final chat = context.read<ChatProvider>();
      if (chat.gameRound(widget.roundId) == null) {
        _requested = true;
        chat.loadGameRound(
          widget.conversationId,
          widget.roundId,
          isChannel: widget.isChannel,
        );
      }
    });
  }

  String _faceLabel(String emoji, int selection) {
    if (emoji == '🪙') return selection == 1 ? 'Heads' : 'Tails';
    return '$selection';
  }

  String _amount(Object? v) => v is num ? v.toString() : (v?.toString() ?? '0');

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chat = context.watch<ChatProvider>();
    final round = chat.gameRound(widget.roundId);
    return Align(
      alignment: widget.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
        ),
        child: round == null
            ? const SizedBox(
                height: 40,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            : _content(context, round, chat.selfId, scheme),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    Map<String, dynamic> round,
    String? selfId,
    ColorScheme scheme,
  ) {
    final emoji = round['game_type'] as String? ?? '🎲';
    final faces = (round['faces'] as num?)?.toInt() ?? 6;
    final provider = round['provider'] as String? ?? 'fun';
    final status = round['status'] as String? ?? 'open';
    final isReal = provider != 'fun';
    final stake = _amount(round['stake']);
    final bets = (round['bets'] as List?) ?? const [];
    Map<String, dynamic>? myBet;
    for (final b in bets) {
      if (b is Map && b['user_id'] == selfId) {
        myBet = Map<String, dynamic>.from(b);
        break;
      }
    }

    // Skill rounds (lobby flow, scored by timing) vs legacy chance rounds
    // (picked-face betting, random outcome). Old rounds in the history keep
    // rendering with the legacy branches below.
    final isSkill =
        status == 'lobby' ||
        status == 'playing' ||
        (status == 'revealed' && round['outcome'] == null);

    final children = <Widget>[
      Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 26)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isSkill
                      ? '${skillGameName(emoji)} — skill game'
                      : 'Provably-fair game',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                Text(
                  isReal
                      ? 'Ante $stake ${provider.toUpperCase()} · best total takes the pot'
                      : isSkill
                      ? 'No stakes · best total score wins'
                      : 'No stakes · verify the result yourself',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
    ];

    if (status == 'refunded') {
      children.add(
        Text(
          isReal
              ? 'Game cancelled or expired — all antes were refunded.'
              : 'Game cancelled or expired.',
          style: TextStyle(color: scheme.error),
        ),
      );
    } else if (status == 'lobby') {
      children.addAll(_lobbyChildren(round, selfId, myBet, bets, scheme));
    } else if (status == 'playing') {
      children.addAll(
        _playingChildren(round, selfId, myBet, bets, scheme, emoji),
      );
    } else if (isSkill) {
      children.addAll(
        _scoreboardChildren(round, selfId, bets, scheme, provider, faces),
      );
    } else if (status == 'revealed') {
      final outcome = (round['outcome'] as num?)?.toInt() ?? 0;
      children.add(
        Center(
          child: Column(
            children: [
              Text(
                '$emoji  ${_faceLabel(emoji, outcome)}',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (myBet != null) ...[
                const SizedBox(height: 4),
                Text(
                  _resultLine(myBet, provider),
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
      children.add(const SizedBox(height: 8));
      children.add(
        _commit(
          'Server seed (revealed)',
          round['server_seed'] as String? ?? '',
        ),
      );
      children.add(const SizedBox(height: 4));
      children.add(
        Text(
          'Verify: SHA-256(server seed) must equal the commitment, and the roll '
          'is HMAC-SHA256(server seed, client seed) over $faces faces.',
          style: TextStyle(
            fontSize: 10,
            color: scheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
      );
    } else {
      children.add(
        _commit('Commitment', round['server_seed_hash'] as String? ?? ''),
      );
      children.add(const SizedBox(height: 10));
      if (isReal) {
        children.add(
          Text(
            'Pot: ${bets.length} × $stake ${provider.toUpperCase()} · ${bets.length} player(s)',
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        );
        children.add(const SizedBox(height: 8));
      }
      if (myBet != null) {
        children.add(
          Text(
            'Your pick: ${_faceLabel(emoji, (myBet['selection'] as num).toInt())}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
        children.add(const SizedBox(height: 8));
      }
      // Real-money bettors can't change their ante; fun bettors can re-pick.
      if (myBet == null || !isReal) {
        children.add(const Text('Pick:'));
        children.add(const SizedBox(height: 6));
        children.add(
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var n = 1; n <= (faces <= 12 ? faces : 12); n++)
                ChoiceChip(
                  label: Text(_faceLabel(emoji, n)),
                  selected:
                      myBet != null && (myBet['selection'] as num).toInt() == n,
                  onSelected: _busy
                      ? null
                      : (_) => _run(
                          () => context.read<ChatProvider>().placeGameBet(
                            widget.conversationId,
                            widget.roundId,
                            n,
                            isChannel: widget.isChannel,
                          ),
                        ),
                ),
            ],
          ),
        );
        children.add(const SizedBox(height: 10));
      }
      children.add(
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonal(
            onPressed: _busy
                ? null
                : () => _run(
                    () => context.read<ChatProvider>().revealGame(
                      widget.conversationId,
                      widget.roundId,
                      isChannel: widget.isChannel,
                    ),
                  ),
            child: _busy
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Reveal outcome'),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  String _resultLine(Map<String, dynamic> myBet, String provider) {
    final status = myBet['status'] as String? ?? '';
    final payout = _amount(myBet['payout']);
    switch (status) {
      case 'won':
        return provider == 'fun'
            ? 'You won! 🎉'
            : 'You won $payout ${provider.toUpperCase()} 🎉';
      case 'refunded':
        return 'Refunded';
      default:
        return provider == 'fun' ? 'No win this time' : 'You lost your ante';
    }
  }

  // ── Skill-game lobby flow ─────────────────────────────────────────────────

  String _playerName(String? selfId, String userId) {
    if (userId == selfId) return 'You';
    final conv = context
        .read<ChatProvider>()
        .conversations
        .where((c) => c.id == widget.conversationId)
        .firstOrNull;
    final member = conv?.members.where((m) => m.userId == userId).firstOrNull;
    final name = member?.user?.username;
    if (name == null || name.trim().isEmpty) {
      return 'Player ${userId.length >= 4 ? userId.substring(0, 4) : userId}';
    }
    return '@$name';
  }

  Widget _playerRow(
    String? selfId,
    Map<String, dynamic> seat,
    ColorScheme scheme, {
    Widget? trailing,
  }) {
    final userId = seat['user_id']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _playerName(selfId, userId),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: userId == selfId
                    ? FontWeight.w700
                    : FontWeight.w500,
                fontSize: 13,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  List<Widget> _lobbyChildren(
    Map<String, dynamic> round,
    String? selfId,
    Map<String, dynamic>? mySeat,
    List<dynamic> seats,
    ColorScheme scheme,
  ) {
    final maxPlayers = (round['max_players'] as num?)?.toInt() ?? 8;
    final createdBy = round['created_by']?.toString();
    final iAmCreator = selfId != null && selfId == createdBy;
    final full = seats.length >= maxPlayers;
    final myReady = mySeat?['ready'] == true;

    return [
      Text(
        'Waiting for players — ${seats.length}/$maxPlayers joined',
        style: TextStyle(
          fontSize: 12,
          color: scheme.onSurface.withValues(alpha: 0.7),
        ),
      ),
      const SizedBox(height: 6),
      for (final seat in seats.whereType<Map>())
        _playerRow(
          selfId,
          Map<String, dynamic>.from(seat),
          scheme,
          trailing: seat['ready'] == true
              ? Icon(
                  Icons.check_circle_rounded,
                  size: 16,
                  color: scheme.primary,
                )
              : Icon(
                  Icons.hourglass_empty_rounded,
                  size: 14,
                  color: scheme.onSurface.withValues(alpha: 0.4),
                ),
        ),
      const SizedBox(height: 10),
      if (mySeat == null)
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _busy || full
                ? null
                : () => _run(
                    () => context.read<ChatProvider>().joinGame(
                      widget.conversationId,
                      widget.roundId,
                      isChannel: widget.isChannel,
                    ),
                  ),
            child: Text(full ? 'Lobby full' : 'Join game'),
          ),
        )
      else
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => context.read<ChatProvider>().readyGame(
                          widget.conversationId,
                          widget.roundId,
                          ready: !myReady,
                          isChannel: widget.isChannel,
                        ),
                      ),
                child: Text(myReady ? 'Unready' : 'Ready up'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => context.read<ChatProvider>().leaveGame(
                          widget.conversationId,
                          widget.roundId,
                          isChannel: widget.isChannel,
                        ),
                      ),
                child: Text(iAmCreator ? 'Cancel game' : 'Leave'),
              ),
            ),
          ],
        ),
      if (mySeat != null && seats.length < 2) ...[
        const SizedBox(height: 6),
        Text(
          'It takes at least two players to start.',
          style: TextStyle(
            fontSize: 11,
            color: scheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
      ],
    ];
  }

  Future<void> _playMyTurn() async {
    final chat = context.read<ChatProvider>();
    setState(() => _busy = true);
    try {
      // The shared broadcast never carries my_patterns — fetch the round
      // directly so the play sheet animates the exact patterns the server
      // scores against.
      final round = await chat.fetchGameRound(
        widget.conversationId,
        widget.roundId,
        isChannel: widget.isChannel,
      );
      final patterns = GamePattern.parseList(round['my_patterns']);
      final gameType = round['game_type'] as String? ?? '🎲';
      if (patterns.isEmpty || round['status'] != 'playing') {
        throw Exception('the game is not in play');
      }
      if (!mounted) return;
      setState(() => _busy = false);
      final taps = await showGamePlaySheet(
        context,
        gameType: gameType,
        patterns: patterns,
      );
      if (taps == null || !mounted) return; // forfeited — nothing submitted
      setState(() => _busy = true);
      await chat.playGame(
        widget.conversationId,
        widget.roundId,
        taps,
        isChannel: widget.isChannel,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Widget> _playingChildren(
    Map<String, dynamic> round,
    String? selfId,
    Map<String, dynamic>? mySeat,
    List<dynamic> seats,
    ColorScheme scheme,
    String emoji,
  ) {
    final iPlayed = mySeat?['played_at'] != null;
    final pending = seats
        .whereType<Map>()
        .where((s) => s['played_at'] == null)
        .length;

    return [
      Text(
        'Game on — $pending player(s) still to play',
        style: TextStyle(
          fontSize: 12,
          color: scheme.onSurface.withValues(alpha: 0.7),
        ),
      ),
      const SizedBox(height: 6),
      for (final seat in seats.whereType<Map>())
        _playerRow(
          selfId,
          Map<String, dynamic>.from(seat),
          scheme,
          trailing: seat['played_at'] != null
              ? Text(
                  '${(seat['score'] as num?)?.toInt() ?? 0}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: scheme.primary,
                  ),
                )
              : Icon(
                  Icons.sports_esports_outlined,
                  size: 14,
                  color: scheme.onSurface.withValues(alpha: 0.4),
                ),
        ),
      const SizedBox(height: 10),
      if (mySeat != null && !iPlayed)
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            icon: Text(emoji),
            label: Text('Play your ${emoji == '🎯' ? 'throws' : 'stops'}'),
            onPressed: _busy ? null : () => unawaited(_playMyTurn()),
          ),
        )
      else if (mySeat != null)
        Text(
          'Waiting for the others to finish…',
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurface.withValues(alpha: 0.6),
          ),
        )
      else
        Text(
          'Game in progress — you can join the next one.',
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
    ];
  }

  List<Widget> _scoreboardChildren(
    Map<String, dynamic> round,
    String? selfId,
    List<dynamic> seats,
    ColorScheme scheme,
    String provider,
    int attempts,
  ) {
    final sorted = seats.whereType<Map>().toList()
      ..sort(
        (a, b) =>
            ((b['score'] as num?) ?? 0).compareTo((a['score'] as num?) ?? 0),
      );
    return [
      for (var i = 0; i < sorted.length; i++)
        _playerRow(
          selfId,
          Map<String, dynamic>.from(sorted[i]),
          scheme,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (sorted[i]['status'] == 'won') ...[
                const Text('🏆', style: TextStyle(fontSize: 13)),
                const SizedBox(width: 4),
              ],
              Text(
                '${(sorted[i]['score'] as num?)?.toInt() ?? 0}',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: sorted[i]['status'] == 'won'
                      ? scheme.primary
                      : scheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              if (provider != 'fun' && sorted[i]['status'] == 'won') ...[
                const SizedBox(width: 6),
                Text(
                  '+${_amount(sorted[i]['payout'])}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              ],
            ],
          ),
        ),
      const SizedBox(height: 8),
      _commit('Server seed (revealed)', round['server_seed'] as String? ?? ''),
      const SizedBox(height: 4),
      Text(
        'Verify: SHA-256(server seed) must equal the commitment; each player\'s '
        '$attempts marker patterns derive from it and their published taps '
        'recompute their score.',
        style: TextStyle(
          fontSize: 10,
          color: scheme.onSurface.withValues(alpha: 0.55),
        ),
      ),
    ];
  }

  Widget _commit(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: scheme.primary,
          ),
        ),
        SelectableText(
          value,
          maxLines: 2,
          style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
        ),
      ],
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
          // Tracks the bubble cap (560) so the quote never outgrows the
          // message it decorates on wide desktop panes.
          maxWidth: math.min(520.0, MediaQuery.sizeOf(context).width * 0.68),
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
        // Capped so bubbles keep a readable measure on desktop panes, where
        // 75% of the window would be a multi-thousand-pixel line.
        maxWidth:
            maxWidth ??
            math.min(560.0, MediaQuery.sizeOf(context).width * 0.75),
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
    // Honor a per-message "no link preview" flag — skips the IP-leaking fetch.
    final previewUrl =
        (linkPreviewsEnabled && !message.content!.suppressLinkPreview)
        ? embeddedPreview?.url ?? firstLinkPreviewUrl(message.content!.text)
        : null;
    // OpenChat invite links resolve via our own API (no third-party fetch), so
    // they preview regardless of the link-preview setting.
    final inviteToken = firstInviteToken(message.content!.text);

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
          if (message.content!.forwardedFrom != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.forward_rounded,
                    size: 13,
                    color: textColor.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      'Forwarded from ${message.content!.forwardedFrom}',
                      style: TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: textColor.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          _CollapsibleText(
            spans: _formatMessageContent(
              context,
              message.content!,
              textColor,
              isMe ? textColor : cs.primary,
              strictPrivacyMode,
            ),
            style: TextStyle(color: textColor, fontSize: 15, height: 1.25),
            accentColor: isMe ? textColor.withValues(alpha: 0.9) : cs.primary,
          ),
          if (inviteToken != null) ...[
            const SizedBox(height: 8),
            _InvitePreviewCard(
              token: inviteToken,
              isMe: isMe,
              textColor: textColor,
            ),
          ] else if (previewUrl != null) ...[
            const SizedBox(height: 8),
            _LinkPreviewCard(
              url: previewUrl,
              initialPreview: embeddedPreview,
              isMe: isMe,
              textColor: textColor,
            ),
          ],
          if (message.content!.replyMarkup != null) ...[
            const SizedBox(height: 8),
            _BotInlineKeyboard(
              message: message,
              markup: message.content!.replyMarkup!,
              textColor: textColor,
              strictPrivacyMode: strictPrivacyMode,
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

/// Clamps long messages to ~10 lines with a Read more / Show less toggle.
class _CollapsibleText extends StatefulWidget {
  final List<InlineSpan> spans;
  final TextStyle style;
  final Color accentColor;

  const _CollapsibleText({
    required this.spans,
    required this.style,
    required this.accentColor,
  });

  @override
  State<_CollapsibleText> createState() => _CollapsibleTextState();
}

class _CollapsibleTextState extends State<_CollapsibleText> {
  static const _collapsedMaxLines = 10;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    double scale = 1.0;
    try {
      scale = context.select<SettingsProvider, double>(
        (s) => s.messageFontScale,
      );
    } on ProviderNotFoundException {
      scale = 1.0;
    }
    final textScaler = TextScaler.linear(scale);
    final textSpan = TextSpan(children: widget.spans, style: widget.style);
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: textSpan,
          maxLines: _collapsedMaxLines,
          textScaler: textScaler,
          textDirection: Directionality.of(context),
        );
        // Inline custom emoji are WidgetSpans. A bare TextPainter throws on the
        // first placeholder unless its dimensions are supplied before layout()
        // — and a throw here would swap the whole bubble for a gray ErrorBox.
        final placeholderCount = _countPlaceholderSpans(textSpan);
        if (placeholderCount > 0) {
          painter.setPlaceholderDimensions(
            List<PlaceholderDimensions>.filled(
              placeholderCount,
              const PlaceholderDimensions(
                size: Size(24, 22),
                alignment: PlaceholderAlignment.middle,
              ),
            ),
          );
        }
        painter.layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(
              textSpan,
              style: widget.style,
              textScaler: textScaler,
              maxLines: _expanded ? null : _collapsedMaxLines,
              overflow: _expanded ? TextOverflow.clip : TextOverflow.ellipsis,
            ),
            if (overflows)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    _expanded ? 'Show less' : 'Read more',
                    style: TextStyle(
                      color: widget.accentColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Counts the placeholder (WidgetSpan) leaves in [span] so a manual
/// [TextPainter] can be given matching [PlaceholderDimensions] before layout.
int _countPlaceholderSpans(InlineSpan span) {
  var count = 0;
  span.visitChildren((InlineSpan s) {
    if (s is WidgetSpan) count += 1;
    return true;
  });
  return count;
}

class _BotInlineKeyboard extends StatelessWidget {
  final Message message;
  final BotInlineKeyboardMarkup markup;
  final Color textColor;
  final bool strictPrivacyMode;

  const _BotInlineKeyboard({
    required this.message,
    required this.markup,
    required this.textColor,
    required this.strictPrivacyMode,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in markup.rows)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var index = 0; index < row.length; index++) ...[
                  if (index > 0) const SizedBox(width: 6),
                  Flexible(
                    child: _BotInlineButton(
                      message: message,
                      button: row[index],
                      foreground: textColor,
                      background: scheme.surface.withValues(alpha: 0.18),
                      strictPrivacyMode: strictPrivacyMode,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _BotInlineButton extends StatefulWidget {
  final Message message;
  final BotInlineKeyboardButton button;
  final Color foreground;
  final Color background;
  final bool strictPrivacyMode;

  const _BotInlineButton({
    required this.message,
    required this.button,
    required this.foreground,
    required this.background,
    required this.strictPrivacyMode,
  });

  @override
  State<_BotInlineButton> createState() => _BotInlineButtonState();
}

class _BotInlineButtonState extends State<_BotInlineButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        backgroundColor: widget.background,
        foregroundColor: widget.foreground,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: _busy ? null : _activate,
      child: _busy
          ? SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: widget.foreground,
              ),
            )
          : Text(
              widget.button.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
    );
  }

  Future<void> _activate() async {
    final url = widget.button.url?.trim();
    if (url != null && url.isNotEmpty) {
      await _openMessageLink(context, url, widget.strictPrivacyMode);
      return;
    }
    final data = widget.button.callbackData?.trim();
    if (data == null || data.isEmpty) return;
    setState(() => _busy = true);
    try {
      await context.read<ApiService>().sendBotCallback(
        convID: widget.message.conversationId,
        msgID: widget.message.id,
        data: data,
      );
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('Sent to bot')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('Bot action failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

void _openInvite(BuildContext context, String token) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => InvitePreviewScreen(token: token)),
  );
}

/// Inline preview for an `openchat://invite/<token>` link: resolves the invite
/// via the first-party API (no third-party fetch, so it's safe regardless of
/// the link-preview privacy setting) and shows the group/channel name +
/// description. Tapping opens the full join screen.
class _InvitePreviewCard extends StatefulWidget {
  final String token;
  final bool isMe;
  final Color textColor;

  const _InvitePreviewCard({
    required this.token,
    required this.isMe,
    required this.textColor,
  });

  @override
  State<_InvitePreviewCard> createState() => _InvitePreviewCardState();
}

class _InvitePreviewCardState extends State<_InvitePreviewCard> {
  Future<InvitePreview?>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _load();
  }

  @override
  void didUpdateWidget(covariant _InvitePreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token != widget.token) _future = _load();
  }

  Future<InvitePreview?> _load() async {
    try {
      return await context.read<ApiService>().getInvite(widget.token);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<InvitePreview?>(
      future: _future,
      builder: (context, snapshot) {
        final preview = snapshot.data;
        if (preview == null) return const SizedBox.shrink();
        return _InvitePreviewBody(
          conversation: preview.conversation,
          isMe: widget.isMe,
          textColor: widget.textColor,
          onTap: () => _openInvite(context, widget.token),
        );
      },
    );
  }
}

class _InvitePreviewBody extends StatelessWidget {
  final Conversation conversation;
  final bool isMe;
  final Color textColor;
  final VoidCallback onTap;

  const _InvitePreviewBody({
    required this.conversation,
    required this.isMe,
    required this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = isMe ? Colors.white : scheme.primary;
    final borderColor = accent.withValues(alpha: isMe ? 0.38 : 0.24);
    final fill = isMe
        ? Colors.white.withValues(alpha: 0.10)
        : scheme.surface.withValues(alpha: 0.34);
    final name = (conversation.name?.trim().isNotEmpty ?? false)
        ? conversation.name!.trim()
        : (conversation.isChannel ? 'Channel' : 'Group');
    final kind = conversation.isChannel ? 'Channel invite' : 'Group invite';
    final description = conversation.description?.trim() ?? '';
    final avatarUrl = conversation.avatarUrl;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 200, maxWidth: 280),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 40,
                height: 40,
                child: (avatarUrl != null && avatarUrl.isNotEmpty)
                    ? CachedNetworkImage(
                        imageUrl: ApiConfig.resolveMedia(avatarUrl),
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) =>
                            _InviteAvatarFallback(accent: accent, name: name),
                      )
                    : _InviteAvatarFallback(accent: accent, name: name),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    kind,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.72),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      name,
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
      ),
    );
  }
}

class _InviteAvatarFallback extends StatelessWidget {
  final Color accent;
  final String name;

  const _InviteAvatarFallback({required this.accent, required this.name});

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name.substring(0, 1).toUpperCase() : '#';
    return Container(
      color: accent.withValues(alpha: 0.18),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: accent,
          fontWeight: FontWeight.w800,
          fontSize: 18,
        ),
      ),
    );
  }
}

List<InlineSpan> _formatPlainTextDecorations(
  BuildContext context,
  String text,
  Color mentionColor,
  bool strictPrivacyMode,
) {
  final decos = <({int start, int end, VoidCallback onTap})>[
    for (final l in linkTextMatches(text))
      (
        start: l.start,
        end: l.end,
        onTap: () => _openMessageLink(context, l.url, strictPrivacyMode),
      ),
    for (final i in inviteTextMatches(text))
      (start: i.start, end: i.end, onTap: () => _openInvite(context, i.token)),
  ]..sort((a, b) => a.start.compareTo(b.start));
  if (decos.isEmpty) return _formatPlainTextMentions(text, mentionColor);
  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final deco in decos) {
    if (deco.start < cursor) continue; // skip overlaps (shouldn't happen)
    if (deco.start > cursor) {
      spans.addAll(
        _formatPlainTextMentions(
          text.substring(cursor, deco.start),
          mentionColor,
        ),
      );
    }
    spans.add(
      TextSpan(
        text: text.substring(deco.start, deco.end),
        style: TextStyle(
          color: mentionColor,
          fontWeight: FontWeight.w700,
          decoration: TextDecoration.underline,
          decorationColor: mentionColor.withValues(alpha: 0.75),
        ),
        recognizer: TapGestureRecognizer()..onTap = deco.onTap,
      ),
    );
    cursor = deco.end;
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
  String? _packId;
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
      _packId = null;
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
      setState(() {
        _fileUrl = data['file_url'] as String?;
        _packId = data['pack_id'] as String?;
      });
    } catch (_) {
      if (mounted) setState(() => _fileUrl = null);
    } finally {
      _loading = false;
    }
  }

  /// Tap-to-add: resolve the emoji's pack and offer it as a library add,
  /// mirroring the sticker bubble's pack sheet. Works regardless of the
  /// pack's discoverability — the fetch endpoints don't gate (by design).
  Future<void> _onTap() async {
    if (widget.entity.customEmojiId.isEmpty) return;
    final api = context.read<ApiService>();
    var packId = _packId;
    if (packId == null) {
      try {
        final data = await api.getCustomEmoji(widget.entity.customEmojiId);
        packId = data['pack_id'] as String?;
        _packId = packId;
      } catch (_) {
        return;
      }
    }
    if (packId == null || !mounted) return;
    final id = packId;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CustomEmojiPackSheet(packID: id, api: api),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fileUrl = _fileUrl;
    final Widget child;
    if (fileUrl == null || fileUrl.isEmpty) {
      child = Text(widget.entity.emoji, style: const TextStyle(fontSize: 20));
    } else {
      child = Padding(
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
    // GestureDetector is layout-transparent: the WidgetSpan keeps exactly the
    // dimensions the manual TextPainter in _CollapsibleText supplies via
    // setPlaceholderDimensions, so overflow measurement stays correct.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onTap,
      child: child,
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

/// Ephemeral on-device translation shown under the original bubble. Reads
/// ChatProvider's per-session map; widget-test trees without providers just
/// render nothing (same defensive pattern as the other provider consumers).
class _TranslationLine extends StatelessWidget {
  final String messageId;

  const _TranslationLine({required this.messageId});

  @override
  Widget build(BuildContext context) {
    String? text;
    try {
      text = context.select<ChatProvider, String?>(
        (chat) => chat.translationFor(messageId),
      );
    } on ProviderNotFoundException {
      return const SizedBox.shrink();
    }
    if (text == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: const TextStyle(fontSize: 13.5)),
          const SizedBox(height: 2),
          Text(
            'Translated on-device',
            style: TextStyle(
              fontSize: 10,
              color: scheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Anonymous tip aggregates, one small chip per provider ("⚡ 0.75 BTC · 2").
/// Sits under the bubble next to the reactions row. Never shows tipper names —
/// the server doesn't reveal them. Width-capped + ellipsized so a pathological
/// total can't break the bubble column layout.
class _TipChips extends StatelessWidget {
  final List<MessageTipTotal> tips;

  const _TipChips({required this.tips});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final tip in tips)
          Container(
            constraints: const BoxConstraints(maxWidth: 180),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: scheme.tertiary.withValues(alpha: 0.35),
              ),
            ),
            child: Text(
              '⚡ ${tip.total} ${tip.provider.toUpperCase()} · ${tip.tippers}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onTertiaryContainer,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
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
                        ? const GlassProgressIndicator.circular(
                            size: 14,
                            strokeWidth: 2,
                          )
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
                        ? const GlassProgressIndicator.circular(
                            size: 14,
                            strokeWidth: 2,
                          )
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

  /// The poll as it should render: the host's message poll, overlaid with the
  /// freshest server state (some hosts — channel post lists, shared-content
  /// sheets — render message snapshots that never refresh after a vote or a
  /// poll_updated broadcast), then with the viewer's own votes restored.
  /// Refetched anonymous polls can't echo the viewer's selections by design,
  /// so without the device-local vote memory the voted bubble would un-mark.
  Poll _mergedPoll(
    List<String> localVotes,
    Poll? snapshot, {
    required bool voterAuthoritative,
  }) {
    var base = widget.message.poll!;
    if (snapshot != null && snapshot.id == base.id) {
      // Tallies and lifecycle come from the snapshot; labels stay with base —
      // E2EE polls carry their option texts in the encrypted payload, which
      // server-sourced snapshots don't have.
      final countById = {for (final o in snapshot.options) o.id: o.voterCount};
      final countByIndex = {
        for (final o in snapshot.options) o.index: o.voterCount,
      };
      base = base.copyWith(
        options: [
          for (final o in base.options)
            o.copyWith(
              voterCount:
                  countById[o.id] ?? countByIndex[o.index] ?? o.voterCount,
            ),
        ],
        totalVoterCount: snapshot.totalVoterCount,
        isClosed: base.isClosed || snapshot.isClosed,
        // Broadcasts are voter-stripped, so their empty voter list means
        // "unknown" and must not blank the base echo. A vote/retract
        // response is device-truth though — there, empty means "retracted"
        // and must win over a stale echo.
        voterOptionIds: voterAuthoritative
            ? snapshot.voterOptionIds
            : (snapshot.voterOptionIds.isNotEmpty
                  ? snapshot.voterOptionIds
                  : base.voterOptionIds),
        correctOptionIds: snapshot.correctOptionIds.isNotEmpty
            ? snapshot.correctOptionIds
            : base.correctOptionIds,
        explanation: snapshot.explanation,
      );
    }
    if (base.voterOptionIds.isNotEmpty || localVotes.isEmpty) return base;
    return base.copyWith(voterOptionIds: localVotes);
  }

  Future<void> _vote(PollOption option) async {
    final base = widget.message.poll;
    if (base == null || _voting) return;
    final chat = context.read<ChatProvider>();
    final poll = _mergedPoll(
      chat.myPollVotes(base.id),
      chat.pollSnapshot(base.id),
      voterAuthoritative: chat.isPollVoterStateAuthoritative(base.id),
    );
    if (poll.isClosed) return;
    final selected = poll.voterOptionIds.toSet();
    // Tapping a selected option retracts it; an empty result retracts the
    // whole vote (the server deletes this voter's rows).
    final List<String> next;
    if (selected.contains(option.id)) {
      next = (selected..remove(option.id)).toList();
    } else if (poll.allowsMultipleAnswers) {
      next = (selected..add(option.id)).toList();
    } else {
      next = [option.id];
    }
    setState(() => _voting = true);
    try {
      await chat.votePoll(
        convID: widget.message.conversationId,
        pollID: poll.id,
        optionIDs: next,
        isAnonymous: base.isAnonymous,
      );
    } finally {
      if (mounted) setState(() => _voting = false);
    }
  }

  static String _formatMeetingSlot(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return iso;
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day} · $hh:$mm';
  }

  Future<void> _addMeetingToCalendar(Poll poll) async {
    PollOption? best;
    for (final o in poll.options) {
      if (best == null || o.voterCount > best.voterCount) best = o;
    }
    final start = best == null ? null : DateTime.tryParse(best.text);
    if (start == null) return;
    final end = start.add(const Duration(hours: 1));
    String stamp(DateTime d) =>
        '${d.toUtc().toIso8601String().replaceAll(RegExp(r'[-:]'), '').split('.').first}Z';
    final title = poll.question.replaceFirst('📅 ', '');
    final ics =
        'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//OpenChat//Meeting//EN\r\n'
        'BEGIN:VEVENT\r\nUID:${poll.id}@openchat\r\nDTSTAMP:${stamp(DateTime.now())}\r\n'
        'DTSTART:${stamp(start)}\r\nDTEND:${stamp(end)}\r\nSUMMARY:$title\r\n'
        'END:VEVENT\r\nEND:VCALENDAR\r\n';
    try {
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'meeting_${poll.id}.ics'));
      await file.writeAsString(ics);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (_) {}
  }

  /// The device-local vote memory, watched so the bubble re-marks itself
  /// when the lazy storage load lands (myPollVotes returns a stable list
  /// instance per poll, so select's identity comparison works). Degrades to
  /// "no local votes" in provider-less trees (widget tests).
  List<String> _watchLocalVotes(BuildContext context, String pollId) {
    try {
      return context.select<ChatProvider, List<String>>(
        (chat) => chat.myPollVotes(pollId),
      );
    } on ProviderNotFoundException {
      return const [];
    }
  }

  /// The provider's freshest server poll state, watched so bubbles hosted on
  /// never-refreshed message snapshots (channel posts) repaint after votes
  /// and poll_updated broadcasts.
  Poll? _watchSnapshot(BuildContext context, String pollId) {
    try {
      return context.select<ChatProvider, Poll?>(
        (chat) => chat.pollSnapshot(pollId),
      );
    } on ProviderNotFoundException {
      return null;
    }
  }

  bool _readVoterAuthoritative(BuildContext context, String pollId) {
    try {
      // No select needed: authority only flips together with a new snapshot
      // instance, which the snapshot watcher already rebuilds on.
      return context.read<ChatProvider>().isPollVoterStateAuthoritative(pollId);
    } on ProviderNotFoundException {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pollId = widget.message.poll!.id;
    final poll = _mergedPoll(
      _watchLocalVotes(context, pollId),
      _watchSnapshot(context, pollId),
      voterAuthoritative: _readVoterAuthoritative(context, pollId),
    );
    final cs = Theme.of(context).colorScheme;
    final total = math.max(1, poll.totalVoterCount);
    // Quiz: reveal the correct answer + explanation once the user has voted
    // (or the poll closed).
    final quizRevealed =
        poll.isQuiz &&
        poll.correctOptionIds.isNotEmpty &&
        (poll.voterOptionIds.isNotEmpty || poll.isClosed);

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
          if (poll.allowsMultipleAnswers && !poll.isClosed) ...[
            const SizedBox(height: 4),
            Text(
              poll.isMeeting
                  ? 'Select all times that work'
                  : 'Select all that apply',
              style: TextStyle(
                color: widget.textColor.withValues(alpha: 0.62),
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          const SizedBox(height: 10),
          for (final option in poll.options) ...[
            _PollOptionRow(
              option: option,
              percent: option.voterCount / total,
              selected: poll.isSelected(option.id),
              enabled:
                  !poll.isClosed &&
                  !_voting &&
                  !(poll.isQuiz && poll.voterOptionIds.isNotEmpty) &&
                  // No revoting = the vote is final: no moving, no retracting.
                  (poll.allowsRevoting || poll.voterOptionIds.isEmpty),
              textColor: widget.textColor,
              quizReveal: quizRevealed,
              isCorrect: poll.isCorrectOption(option.index),
              labelOverride: poll.isMeeting
                  ? _formatMeetingSlot(option.text)
                  : null,
              onTap: () => _vote(option),
            ),
            const SizedBox(height: 6),
          ],
          // Only meaningful once someone has picked a slot (the export uses
          // the best-voted option). Foreground must follow the bubble's text
          // color — the default primary-colored TextButton is invisible on
          // the sender's own primary-colored bubble.
          if (poll.isMeeting && poll.options.any((o) => o.voterCount > 0))
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: widget.textColor),
                icon: const Icon(Icons.event_available, size: 16),
                label: const Text('Add to calendar'),
                onPressed: () => _addMeetingToCalendar(poll),
              ),
            ),
          if (quizRevealed &&
              poll.explanation != null &&
              poll.explanation!.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: widget.textColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.lightbulb_outline_rounded,
                    size: 16,
                    color: widget.textColor.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      poll.explanation!,
                      style: TextStyle(
                        color: widget.textColor.withValues(alpha: 0.85),
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
          ],
          Row(
            children: [
              Text(
                poll.isClosed
                    ? 'Closed'
                    : poll.isQuiz
                    ? 'Quiz · ${poll.totalVoterCount} answered'
                    : '${poll.totalVoterCount} votes',
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
  final bool quizReveal;
  final bool isCorrect;
  final String? labelOverride;
  final VoidCallback onTap;

  const _PollOptionRow({
    required this.option,
    required this.percent,
    required this.selected,
    required this.enabled,
    required this.textColor,
    this.quizReveal = false,
    this.isCorrect = false,
    this.labelOverride,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const correctColor = Color(0xFF2E9E5B);
    const wrongColor = Color(0xFFD05050);
    Color fill;
    Color border;
    IconData icon;
    Color iconColor;
    if (quizReveal && isCorrect) {
      fill = correctColor.withValues(alpha: 0.22);
      border = correctColor.withValues(alpha: 0.6);
      icon = Icons.check_circle;
      iconColor = correctColor;
    } else if (quizReveal && selected && !isCorrect) {
      fill = wrongColor.withValues(alpha: 0.22);
      border = wrongColor.withValues(alpha: 0.6);
      icon = Icons.cancel;
      iconColor = wrongColor;
    } else {
      fill = textColor.withValues(alpha: selected ? 0.24 : 0.14);
      border = textColor.withValues(alpha: selected ? 0.42 : 0.16);
      icon = selected ? Icons.check_circle : Icons.radio_button_unchecked;
      iconColor = textColor.withValues(alpha: selected ? 0.95 : 0.7);
    }
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
                  Icon(icon, size: 18, color: iconColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      labelOverride ?? option.text,
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

/// Blurs media until tapped (tap-to-reveal spoiler). Reveal is ephemeral — it
/// re-blurs when the bubble is rebuilt (e.g. scrolled out of view and back).
class _SpoilerGate extends StatefulWidget {
  final Widget child;
  final BorderRadius radii;
  const _SpoilerGate({required this.child, required this.radii});

  @override
  State<_SpoilerGate> createState() => _SpoilerGateState();
}

class _SpoilerGateState extends State<_SpoilerGate> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    if (_revealed) return widget.child;
    return GestureDetector(
      onTap: () => setState(() => _revealed = true),
      child: Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(
            borderRadius: widget.radii,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: widget.child,
            ),
          ),
          Positioned.fill(
            child: ClipRRect(
              borderRadius: widget.radii,
              child: Container(color: Colors.black.withValues(alpha: 0.18)),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.visibility_off_outlined,
                  size: 16,
                  color: Colors.white,
                ),
                SizedBox(width: 6),
                Text(
                  'Spoiler',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
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

/// Holds heavy incoming media behind a tap-to-download placeholder when the
/// user's auto-download policy disallows it on the current network (Batch 5.3).
class _AutoDownloadGate extends StatefulWidget {
  final MessageContent content;
  final Color bubbleColor;
  final Color textColor;
  final BorderRadius radii;
  final Widget child;

  const _AutoDownloadGate({
    required this.content,
    required this.bubbleColor,
    required this.textColor,
    required this.radii,
    required this.child,
  });

  @override
  State<_AutoDownloadGate> createState() => _AutoDownloadGateState();
}

class _AutoDownloadGateState extends State<_AutoDownloadGate> {
  bool _userRequested = false;

  @override
  Widget build(BuildContext context) {
    if (_userRequested) return widget.child;
    bool allowed;
    try {
      final net = context.watch<NetworkService>().current;
      final settings = context.watch<SettingsProvider>();
      allowed = settings.allowAutoDownload(
        net,
        sizeBytes: widget.content.fileSize,
      );
    } on ProviderNotFoundException {
      // No providers (e.g. widget tests) — don't gate.
      return widget.child;
    }
    if (allowed) return widget.child;

    final size = widget.content.fileSize;
    final sizeLabel = size != null && size > 0
        ? ' (${size < 1024 * 1024 ? '${(size / 1024).toStringAsFixed(0)} KB' : '${(size / (1024 * 1024)).toStringAsFixed(1)} MB'})'
        : '';
    return GestureDetector(
      onTap: () => setState(() => _userRequested = true),
      child: _BubbleShell(
        color: widget.bubbleColor,
        radii: widget.radii,
        child: SizedBox(
          width: math.min(MediaQuery.of(context).size.width * 0.6, 300),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_rounded, color: widget.textColor, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tap to download$sizeLabel',
                      style: TextStyle(
                        color: widget.textColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Auto-download is off for this network',
                      style: TextStyle(
                        color: widget.textColor.withValues(alpha: 0.66),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ViewOnceAttachmentGate extends StatefulWidget {
  final Message message;
  final MessageContent content;
  final Color bubbleColor;
  final Color textColor;
  final BorderRadius radii;

  const _ViewOnceAttachmentGate({
    required this.message,
    required this.content,
    required this.bubbleColor,
    required this.textColor,
    required this.radii,
  });

  @override
  State<_ViewOnceAttachmentGate> createState() =>
      _ViewOnceAttachmentGateState();
}

class _ViewOnceAttachmentGateState extends State<_ViewOnceAttachmentGate> {
  bool _revealed = false;
  VoidCallback? _releaseSecure;
  StreamSubscription<void>? _shotSub;

  @override
  void dispose() {
    _releaseSecure?.call();
    unawaited(SecurityService.instance.stopScreenshotDetection());
    _shotSub?.cancel();
    super.dispose();
  }

  // While the decrypted view-once media is on screen: force screenshot blocking
  // and, on platforms that report it, notify the conversation if a screenshot is
  // captured anyway.
  Future<void> _armScreenProtection() async {
    _releaseSecure = await SecurityService.instance.pushForceSecure();
    if (!mounted) {
      _releaseSecure?.call();
      _releaseSecure = null;
      return;
    }
    final convID = widget.message.conversationId;
    _shotSub = SecurityService.instance.screenshots.listen((_) {
      if (mounted) {
        unawaited(
          context.read<ChatProvider>().postScreenshotNotice(convID: convID),
        );
      }
    });
    await SecurityService.instance.startScreenshotDetection();
  }

  @override
  Widget build(BuildContext context) {
    final viewed = context.watch<SettingsProvider>().hasViewedOnceMedia(
      widget.message.id,
    );
    if (viewed && !_revealed) return _placeholder(expired: true);
    if (!_revealed) return _placeholder(expired: false);
    return switch (widget.message.type) {
      MessageType.image => _ImageBubble(
        message: widget.message,
        content: widget.content,
        bubbleColor: widget.bubbleColor,
        textColor: widget.textColor,
        radii: widget.radii,
      ),
      MessageType.video => _VideoBubble(
        message: widget.message,
        content: widget.content,
        bubbleColor: widget.bubbleColor,
        textColor: widget.textColor,
        radii: widget.radii,
      ),
      MessageType.voice || MessageType.audio => _VoiceBubble(
        message: widget.message,
        content: widget.content,
        bubbleColor: widget.bubbleColor,
        textColor: widget.textColor,
        radii: widget.radii,
      ),
      _ => _FileBubble(
        message: widget.message,
        content: widget.content,
        bubbleColor: widget.bubbleColor,
        textColor: widget.textColor,
        radii: widget.radii,
      ),
    };
  }

  Widget _placeholder({required bool expired}) {
    final icon = expired ? Icons.visibility_off_outlined : Icons.lock_clock;
    final title = expired ? 'View-once media opened' : 'View once media';
    final subtitle = expired
        ? 'This attachment is hidden on this device'
        : 'Tap to decrypt and reveal locally';
    return GestureDetector(
      onTap: expired ? null : () => unawaited(_open()),
      child: _BubbleShell(
        color: widget.bubbleColor,
        radii: widget.radii,
        child: SizedBox(
          width: math.min(MediaQuery.of(context).size.width * 0.64, 320),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: widget.textColor, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: widget.textColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: widget.textColor.withValues(alpha: 0.66),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _Timestamp(
                      message: widget.message,
                      textColor: widget.textColor,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open() async {
    if (_revealed) return;
    setState(() => _revealed = true);
    unawaited(_armScreenProtection());
    await context.read<SettingsProvider>().markViewOnceMediaViewed(
      widget.message.id,
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

// ── Album grid bubble ─────────────────────────────────────────────────────────

/// Telegram-style grouped media: 2 → side-by-side, 3 → one tall + two
/// stacked, 4+ → a 2×2 grid with a "+N" veil on the last tile. The anchor
/// (newest member) carries the caption, timestamp, and reactions for the
/// whole group.
class _AlbumGridBubble extends StatelessWidget {
  final List<Message> messages;
  final Message anchor;
  final Color bubbleColor;
  final Color textColor;
  final BorderRadius radii;

  const _AlbumGridBubble({
    required this.messages,
    required this.anchor,
    required this.bubbleColor,
    required this.textColor,
    required this.radii,
  });

  static const double _gap = 2;

  @override
  Widget build(BuildContext context) {
    final layout = MessageImageLayout.forViewport(MediaQuery.of(context).size);
    final w = layout.maxBubbleWidth;
    final caption = anchor.content?.text ?? '';

    return ClipRRect(
      borderRadius: radii,
      child: Container(
        constraints: BoxConstraints(maxWidth: w),
        color: bubbleColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            _grid(w),
            if (caption.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Text(
                  caption,
                  style: TextStyle(color: textColor, fontSize: 14),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
              child: _Timestamp(message: anchor, textColor: textColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(Message m, double width, double height) => SizedBox(
    width: width,
    height: height,
    child: _AlbumTile(message: m),
  );

  Widget _grid(double w) {
    final half = (w - _gap) / 2;
    switch (messages.length) {
      case 2:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _tile(messages[0], half, w * 0.66),
            const SizedBox(width: _gap),
            _tile(messages[1], half, w * 0.66),
          ],
        );
      case 3:
        final h = w * 0.66;
        final cell = (h - _gap) / 2;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _tile(messages[0], half, h),
            const SizedBox(width: _gap),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _tile(messages[1], half, cell),
                const SizedBox(height: _gap),
                _tile(messages[2], half, cell),
              ],
            ),
          ],
        );
      default:
        // 4+: rows of pairs; an odd straggler gets a full-width row. Every
        // member stays visible — its own list row is collapsed to zero
        // height, so this grid is the only place it can appear.
        final rows = <Widget>[];
        for (var i = 0; i + 1 < messages.length; i += 2) {
          if (rows.isNotEmpty) rows.add(const SizedBox(height: _gap));
          rows.add(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _tile(messages[i], half, half),
                const SizedBox(width: _gap),
                _tile(messages[i + 1], half, half),
              ],
            ),
          );
        }
        if (messages.length.isOdd) {
          rows.add(const SizedBox(height: _gap));
          rows.add(_tile(messages.last, w, w * 0.55));
        }
        return Column(mainAxisSize: MainAxisSize.min, children: rows);
    }
  }
}

/// One image cell of an album: loads (and decrypts) its own attachment,
/// opens fullscreen on tap.
class _AlbumTile extends StatefulWidget {
  final Message message;

  const _AlbumTile({required this.message});

  @override
  State<_AlbumTile> createState() => _AlbumTileState();
}

class _AlbumTileState extends State<_AlbumTile> {
  _LoadState _state = _LoadState.idle;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = widget.message.content;
    if (c?.attachmentId == null) {
      setState(() => _state = _LoadState.error);
      return;
    }
    setState(() => _state = _LoadState.loading);
    try {
      final svc = AttachmentService(context.read<ApiService>());
      final bytes = c!.fileKey != null && c.fileNonce != null
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
    return switch (_state) {
      _LoadState.done => GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => Scaffold(
              backgroundColor: Colors.black,
              appBar: AppBar(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
              ),
              body: Center(
                child: InteractiveViewer(child: Image.memory(_bytes!)),
              ),
            ),
          ),
        ),
        child: Image.memory(_bytes!, fit: BoxFit.cover, gaplessPlayback: true),
      ),
      _LoadState.error => Container(
        color: Colors.black12,
        child: const Center(
          child: Icon(Icons.broken_image, color: Colors.grey, size: 20),
        ),
      ),
      _ => Container(
        color: Colors.black12,
        child: const Center(
          child: GlassProgressIndicator.circular(size: 18, strokeWidth: 2),
        ),
      ),
    };
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
  String? _transcript;
  bool _transcriptVisible = false;
  bool _transcribing = false;
  String? _transcribeStatus;

  @override
  void initState() {
    super.initState();
    _duration = _durationFromMetadata(widget.content.durationMs);
    final waveform = widget.content.waveform;
    _levels = (waveform != null && waveform.isNotEmpty)
        ? _resampleVoiceLevels(waveform, 28)
        : _voiceLevels(widget.message.id);
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

  Future<Uint8List> _audioBytes() async {
    final attachmentId = widget.content.attachmentId;
    if (attachmentId == null) throw StateError('no attachment');
    final svc = AttachmentService(context.read<ApiService>());
    if (widget.content.fileKey != null && widget.content.fileNonce != null) {
      return svc.downloadAndDecrypt(
        attachmentId: attachmentId,
        fileKeyB64: widget.content.fileKey!,
        fileNonceB64: widget.content.fileNonce!,
      );
    }
    if (!widget.message.isEncrypted) {
      return svc.downloadRaw(attachmentId: attachmentId);
    }
    throw StateError('missing attachment key');
  }

  Future<void> _onTranscribePressed() async {
    if (_transcribing) return;
    // Already transcribed this session — just toggle.
    if (_transcript != null) {
      setState(() => _transcriptVisible = !_transcriptVisible);
      return;
    }
    ChatProvider? chat;
    try {
      chat = context.read<ChatProvider>();
    } on ProviderNotFoundException {
      chat = null;
    }
    // Cached from an earlier session?
    final cached = await chat?.cachedTranscript(widget.message);
    if (!mounted) return;
    if (cached != null) {
      setState(() {
        _transcript = cached;
        _transcriptVisible = true;
      });
      return;
    }
    if (!TranscriptionService.isSupported) {
      showAppToast(
        context,
        'Transcription is not supported on this platform',
        isError: true,
      );
      return;
    }
    if (!await TranscriptionService.isModelCached()) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => GlassAlertDialog(
          title: const Text('Download speech model?'),
          content: const Text(
            'Transcription runs entirely on this device. The one-time '
            'Whisper model download is about 90 MB; manage it later under '
            'Settings → On-device intelligence.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Download'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() {
      _transcribing = true;
      _transcribeStatus = 'Preparing…';
    });
    StreamSubscription<double>? progressSub;
    try {
      progressSub = TranscriptionService.downloadProgress.listen((p) {
        if (mounted && _transcribing) {
          setState(
            () => _transcribeStatus = 'Downloading model ${(p * 100).round()}%',
          );
        }
      });
      await TranscriptionService.ensureModel();
      if (!mounted) return;
      setState(() => _transcribeStatus = 'Transcribing…');
      final bytes = await _audioBytes();
      final text = await TranscriptionService.transcribeM4a(bytes);
      if (!mounted) return;
      final result = text.isEmpty ? '(no speech detected)' : text;
      await chat?.storeTranscript(widget.message, result);
      if (!mounted) return;
      setState(() {
        _transcript = result;
        _transcriptVisible = true;
      });
    } catch (e) {
      if (mounted) showAppToast(context, e.toString(), isError: true);
    } finally {
      unawaited(progressSub?.cancel());
      if (mounted) {
        setState(() {
          _transcribing = false;
          _transcribeStatus = null;
        });
      }
    }
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
                        error
                            ? 'Tap to retry'
                            : (_transcribeStatus ?? _timeLabel),
                        style: TextStyle(
                          color: widget.textColor.withValues(alpha: 0.76),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: _onTranscribePressed,
                        child: _transcribing
                            ? GlassProgressIndicator.circular(size: 13)
                            : Icon(
                                _transcriptVisible
                                    ? Icons.subtitles_rounded
                                    : Icons.subtitles_outlined,
                                size: 16,
                                color: widget.textColor.withValues(alpha: 0.76),
                              ),
                      ),
                      const SizedBox(width: 8),
                      _Timestamp(
                        message: widget.message,
                        textColor: widget.textColor,
                      ),
                    ],
                  ),
                  if (_transcriptVisible && _transcript != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      _transcript!,
                      style: TextStyle(
                        color: widget.textColor.withValues(alpha: 0.9),
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      'Transcribed on-device',
                      style: TextStyle(
                        color: widget.textColor.withValues(alpha: 0.5),
                        fontSize: 10,
                      ),
                    ),
                  ],
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
                ? GlassProgressIndicator.circular(
                    size: 18,
                    strokeWidth: 2,
                    color: color,
                  )
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

/// Resamples a recorded amplitude waveform to [count] bars for the scrubber,
/// keeping a small floor so quiet segments stay visible.
List<double> _resampleVoiceLevels(List<double> src, int count) {
  if (src.isEmpty) return _voiceLevels('');
  return List<double>.generate(count, (i) {
    final idx = (i * src.length / count).floor().clamp(0, src.length - 1);
    return (0.12 + src[idx] * 0.88).clamp(0.0, 1.0).toDouble();
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
        _LoadState.loading => GlassProgressIndicator.circular(
          size: 40,
          strokeWidth: 2,
          color: textColor,
        ),
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

class _ContactBubble extends StatelessWidget {
  final MessageContact contact;
  final Color bubbleColor;
  final Color textColor;
  final BorderRadius radii;
  final Message message;

  const _ContactBubble({
    required this.contact,
    required this.bubbleColor,
    required this.textColor,
    required this.radii,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = contact.displayLabel;
    final fp = contact.fingerprint;
    return _BubbleShell(
      color: bubbleColor,
      radii: radii,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: textColor.withValues(alpha: 0.15),
                child: Text(
                  label.isNotEmpty ? label[0].toUpperCase() : '?',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.person_rounded,
                        size: 14,
                        color: textColor.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        label,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '@${contact.username}',
                    style: TextStyle(
                      fontSize: 12,
                      color: textColor.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (fp != null && fp.isNotEmpty) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: fp));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Fingerprint copied')),
                );
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.fingerprint_rounded,
                    size: 14,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    fp.length > 16 ? '${fp.substring(0, 16)}…' : fp,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: textColor.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 4),
          _Timestamp(message: message, textColor: textColor),
        ],
      ),
    );
  }
}

class _Timestamp extends StatelessWidget {
  final Message message;
  final Color textColor;

  const _Timestamp({required this.message, required this.textColor});

  @override
  Widget build(BuildContext context) {
    final pending = message is PendingMessage
        ? message as PendingMessage
        : null;
    // A still-queued message that a verified peer already confirmed over the
    // nearby mesh: the server copy is pending, but the human has it.
    final meshDelivered =
        pending != null &&
        pending.status != PendingMessageStatus.failed &&
        context.select<ChatProvider, bool>(
          (chat) => chat.meshDelivered(pending.id),
        );
    final receivedViaMesh = message.id.startsWith('mesh-');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pending != null)
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Icon(
              meshDelivered
                  ? Icons.bluetooth_connected_rounded
                  : switch (pending.status) {
                      PendingMessageStatus.sending => Icons.sync_rounded,
                      PendingMessageStatus.queued =>
                        Icons.cloud_upload_outlined,
                      PendingMessageStatus.failed =>
                        Icons.error_outline_rounded,
                    },
              size: 11,
              color: textColor.withValues(alpha: 0.62),
            ),
          ),
        if (receivedViaMesh)
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Icon(
              Icons.bluetooth_rounded,
              size: 11,
              color: textColor.withValues(alpha: 0.55),
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
              : meshDelivered
              ? 'delivered nearby'
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
          _AutoDeleteIndicator(message: message, color: textColor),
      ],
    );
  }
}

/// A Telegram-style shrinking-clock countdown for disappearing messages, with a
/// remaining-time label. Ticks every second under ~2 min, otherwise every 30 s.
class _AutoDeleteIndicator extends StatefulWidget {
  final Message message;
  final Color color;
  const _AutoDeleteIndicator({required this.message, required this.color});

  @override
  State<_AutoDeleteIndicator> createState() => _AutoDeleteIndicatorState();
}

class _AutoDeleteIndicatorState extends State<_AutoDeleteIndicator> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    final remaining = _remaining();
    final interval = remaining.inSeconds <= 120
        ? const Duration(seconds: 1)
        : const Duration(seconds: 30);
    _timer?.cancel();
    _timer = Timer(interval, () {
      if (mounted) setState(_schedule);
    });
  }

  Duration _remaining() {
    final expiresAt = widget.message.autoDeleteExpiresAt;
    if (expiresAt == null) return Duration.zero;
    final r = expiresAt.difference(DateTime.now());
    return r.isNegative ? Duration.zero : r;
  }

  double _fraction() {
    final total = widget.message.autoDeleteSeconds;
    if (total <= 0) return 1;
    return (_remaining().inSeconds / total).clamp(0.0, 1.0);
  }

  String _label(Duration r) {
    if (r.inSeconds <= 0) return 'expiring';
    if (r.inDays >= 1) return '${r.inDays}d';
    if (r.inHours >= 1) return '${r.inHours}h';
    if (r.inMinutes >= 1) return '${r.inMinutes}m';
    return '${r.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _remaining();
    final color = widget.color.withValues(alpha: 0.7);
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CustomPaint(
              painter: _ClockPiePainter(fraction: _fraction(), color: color),
            ),
          ),
          const SizedBox(width: 3),
          Text(_label(remaining), style: TextStyle(fontSize: 10, color: color)),
        ],
      ),
    );
  }
}

class _ClockPiePainter extends CustomPainter {
  final double fraction;
  final Color color;
  _ClockPiePainter({required this.fraction, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    canvas.drawCircle(center, radius - 0.5, ring);
    final pie = Paint()
      ..style = PaintingStyle.fill
      ..color = color;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 1.5),
      -math.pi / 2,
      2 * math.pi * fraction,
      true,
      pie,
    );
  }

  @override
  bool shouldRepaint(_ClockPiePainter old) =>
      old.fraction != fraction || old.color != color;
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
            ? const Center(
                child: GlassProgressIndicator.circular(strokeWidth: 2),
              )
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
                        ? const GlassProgressIndicator.circular(
                            size: 16,
                            strokeWidth: 2,
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

/// Bottom sheet shown when an inline custom emoji is tapped: previews the
/// emoji's pack and offers a one-tap library add. Mirrors _StickerPackSheet.
class _CustomEmojiPackSheet extends StatefulWidget {
  final String packID;
  final ApiService api;
  const _CustomEmojiPackSheet({required this.packID, required this.api});

  @override
  State<_CustomEmojiPackSheet> createState() => _CustomEmojiPackSheetState();
}

class _CustomEmojiPackSheetState extends State<_CustomEmojiPackSheet> {
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
      final pack = await widget.api.getCustomEmojiPack(widget.packID);
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
      await widget.api.addCustomEmojiPackToLibrary(widget.packID);
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Emoji pack added to your library')),
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
    final emojis = (_pack?['custom_emojis'] as List? ?? [])
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
                          _pack?['name'] as String? ?? 'Emoji Pack',
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
                        ? const GlassProgressIndicator.circular(
                            size: 16,
                            strokeWidth: 2,
                          )
                        : const Icon(Icons.add, size: 18),
                    label: const Text('Add to library'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: GlassProgressIndicator.circular())
                  : emojis.isEmpty
                  ? const Center(child: Text('No custom emoji in this pack'))
                  : GridView.builder(
                      controller: controller,
                      padding: const EdgeInsets.all(8),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 5,
                            crossAxisSpacing: 6,
                            mainAxisSpacing: 6,
                          ),
                      itemCount: emojis.length,
                      itemBuilder: (_, i) {
                        final em = emojis[i];
                        final url = em['file_url'] as String?;
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: url != null && url.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: ApiConfig.resolveMedia(url),
                                  fit: BoxFit.contain,
                                  errorWidget: (_, _, _) => Center(
                                    child: Text(em['emoji'] as String? ?? '🙂'),
                                  ),
                                )
                              : Center(
                                  child: Text(em['emoji'] as String? ?? '🙂'),
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
