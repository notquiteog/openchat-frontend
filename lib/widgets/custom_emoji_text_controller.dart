import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/api_config.dart';
import '../models/message.dart';
import '../services/api_service.dart';
import '../utils/custom_emoji_payload.dart';

class CustomEmojiTextEditingController extends TextEditingController {
  List<CustomEmojiEntity> _customEmojiEntities = const [];

  void setCustomEmojiEntities(List<CustomEmojiEntity> entities) {
    _customEmojiEntities = List<CustomEmojiEntity>.unmodifiable(entities);
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final entities = normalizeCustomEmojiEntities(text, _customEmojiEntities);
    if (entities.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final baseStyle = style ?? DefaultTextStyle.of(context).style;
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final entity in entities) {
      if (entity.offset > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, entity.offset)));
      }
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _ComposerCustomEmoji(entity: entity, style: baseStyle),
        ),
      );
      if (entity.length > 1) {
        spans.add(
          TextSpan(
            text: List.filled(entity.length - 1, '\u200b').join(),
            style: baseStyle.copyWith(
              color: Colors.transparent,
              fontSize: 0.01,
              height: 0.01,
            ),
          ),
        );
      }
      cursor = entity.offset + entity.length;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return TextSpan(style: baseStyle, children: spans);
  }
}

class _ComposerCustomEmoji extends StatefulWidget {
  final CustomEmojiEntity entity;
  final TextStyle style;

  const _ComposerCustomEmoji({required this.entity, required this.style});

  @override
  State<_ComposerCustomEmoji> createState() => _ComposerCustomEmojiState();
}

class _ComposerCustomEmojiState extends State<_ComposerCustomEmoji> {
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
  void didUpdateWidget(covariant _ComposerCustomEmoji oldWidget) {
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
    final fontSize = widget.style.fontSize ?? 16;
    final size = (fontSize * 1.35).clamp(18.0, 28.0).toDouble();
    final fileUrl = _fileUrl;
    if (fileUrl == null || fileUrl.isEmpty) {
      return Text(widget.entity.emoji, style: widget.style);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: CachedNetworkImage(
        imageUrl: ApiConfig.resolveMedia(fileUrl),
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorWidget: (_, _, _) =>
            Text(widget.entity.emoji, style: widget.style),
      ),
    );
  }
}
