import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/api_config.dart';
import '../services/api_service.dart';

/// Process-wide cache of custom-emoji id → file URL so reaction chips, the
/// reaction bar, and the picker don't refetch the same emoji repeatedly.
class CustomEmojiUrlCache {
  CustomEmojiUrlCache._();

  static final Map<String, String?> _urls = {};
  static final Map<String, Future<String?>> _inflight = {};

  /// Seeds the cache from data already fetched elsewhere (e.g. a pack load).
  static void put(String id, String? url) => _urls[id] = url;

  /// The resolved URL if known (null also means "fetched, but has no URL").
  static String? cached(String id) => _urls[id];

  static bool isKnown(String id) => _urls.containsKey(id);

  static Future<String?> resolve(ApiService api, String id) {
    if (_urls.containsKey(id)) return Future.value(_urls[id]);
    return _inflight[id] ??= () async {
      try {
        final data = await api.getCustomEmoji(id);
        final url = data['file_url'] as String?;
        _urls[id] = url;
        return url;
      } catch (_) {
        _urls[id] = null;
        return null;
      } finally {
        _inflight.remove(id);
      }
    }();
  }
}

/// Renders an in-app custom emoji (by id) as a square image, resolving and
/// caching its file URL. Shows [fallback] text once resolved with no image, and
/// nothing (reserved space) while still loading.
class CustomEmojiImage extends StatefulWidget {
  final String customEmojiId;
  final double size;
  final String fallback;

  const CustomEmojiImage({
    super.key,
    required this.customEmojiId,
    this.size = 22,
    this.fallback = '🙂',
  });

  @override
  State<CustomEmojiImage> createState() => _CustomEmojiImageState();
}

class _CustomEmojiImageState extends State<CustomEmojiImage> {
  String? _url;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant CustomEmojiImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.customEmojiId != widget.customEmojiId) {
      _url = null;
      _resolved = false;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    if (CustomEmojiUrlCache.isKnown(widget.customEmojiId)) {
      _url = CustomEmojiUrlCache.cached(widget.customEmojiId);
      _resolved = true;
      if (mounted) setState(() {});
      return;
    }
    final url = await CustomEmojiUrlCache.resolve(
      context.read<ApiService>(),
      widget.customEmojiId,
    );
    if (!mounted) return;
    setState(() {
      _url = url;
      _resolved = true;
    });
  }

  Widget _fallbackGlyph() => SizedBox(
    width: widget.size,
    height: widget.size,
    child: Center(
      child: Text(
        widget.fallback,
        style: TextStyle(fontSize: widget.size * 0.9),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final url = _url;
    if (url == null || url.isEmpty) {
      // Reserve space while loading; show the fallback glyph once resolved.
      return _resolved
          ? _fallbackGlyph()
          : SizedBox(width: widget.size, height: widget.size);
    }
    return CachedNetworkImage(
      imageUrl: ApiConfig.resolveMedia(url),
      width: widget.size,
      height: widget.size,
      fit: BoxFit.contain,
      errorWidget: (_, _, _) => _fallbackGlyph(),
    );
  }
}

/// Renders a reaction key — a unicode emoji or a `custom:<id>` reference — at the
/// requested [size]. Shared by the reaction bar, chips, and picker.
class ReactionGlyph extends StatelessWidget {
  final String reactionKey;
  final double size;

  const ReactionGlyph(this.reactionKey, {super.key, this.size = 24});

  @override
  Widget build(BuildContext context) {
    // Mirrors `customReactionPrefix` in models/message.dart.
    const prefix = 'custom:';
    if (reactionKey.startsWith(prefix)) {
      return CustomEmojiImage(
        customEmojiId: reactionKey.substring(prefix.length),
        size: size,
      );
    }
    return Text(reactionKey, style: TextStyle(fontSize: size * 0.92));
  }
}
