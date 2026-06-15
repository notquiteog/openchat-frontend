import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_config.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../utils/pack_links.dart';
import '../../widgets/glass.dart';

class PackPreviewScreen extends StatefulWidget {
  final PackKind kind;
  final String packId;

  const PackPreviewScreen({
    super.key,
    required this.kind,
    required this.packId,
  });

  @override
  State<PackPreviewScreen> createState() => _PackPreviewScreenState();
}

class _PackPreviewScreenState extends State<PackPreviewScreen> {
  Map<String, dynamic>? _pack;
  Object? _error;
  bool _loading = true;
  bool _adding = false;
  bool _alreadyInLibrary = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<ApiService>();
      final pack = switch (widget.kind) {
        PackKind.sticker => await api.getStickerPack(widget.packId),
        PackKind.customEmoji => await api.getCustomEmojiPack(widget.packId),
      };
      if (!mounted) return;
      final currentUserId = context.read<AuthProvider>().currentUser?.id;
      setState(() {
        _pack = pack;
        _alreadyInLibrary =
            currentUserId != null && pack['creator_id'] == currentUserId;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _addToLibrary() async {
    if (_adding || _alreadyInLibrary) return;
    setState(() => _adding = true);
    try {
      final api = context.read<ApiService>();
      switch (widget.kind) {
        case PackKind.sticker:
          await api.addStickerPackToLibrary(widget.packId);
        case PackKind.customEmoji:
          await api.addCustomEmojiPackToLibrary(widget.packId);
      }
      if (!mounted) return;
      showAppToast(context, 'Added to library');
      Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      if (_looksAlreadyAdded(e)) {
        setState(() {
          _alreadyInLibrary = true;
          _adding = false;
        });
        showAppToast(context, 'Already in your library');
      } else {
        setState(() => _adding = false);
        showAppToast(context, 'Could not add pack', isError: true);
      }
    }
  }

  bool _looksAlreadyAdded(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('already') ||
        text.contains('duplicate') ||
        text.contains('unique');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LiquidMeshBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: GlassContainer(
                  shape: const LiquidRoundedSuperellipse(borderRadius: 34),
                  allowElevation: true,
                  glowIntensity: 0.10,
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: _loading
                        ? const _PackLoadingView()
                        : _error != null
                        ? _PackErrorView(error: _error!, onRetry: _load)
                        : _PackReadyView(
                            kind: widget.kind,
                            pack: _pack!,
                            adding: _adding,
                            alreadyInLibrary: _alreadyInLibrary,
                            onAdd: _addToLibrary,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PackLoadingView extends StatelessWidget {
  const _PackLoadingView();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      key: ValueKey('pack-loading'),
      height: 220,
      child: Center(child: GlassProgressIndicator.circular()),
    );
  }
}

class _PackErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _PackErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      key: const ValueKey('pack-error'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.error.withValues(alpha: 0.14),
          ),
          child: Icon(Icons.link_off_rounded, color: scheme.error, size: 30),
        ),
        const SizedBox(height: 18),
        Text(
          'Pack unavailable',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          '$error',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: GlassButtonWidget(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Close'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GlassButtonWidget.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PackReadyView extends StatelessWidget {
  final PackKind kind;
  final Map<String, dynamic> pack;
  final bool adding;
  final bool alreadyInLibrary;
  final VoidCallback onAdd;

  const _PackReadyView({
    required this.kind,
    required this.pack,
    required this.adding,
    required this.alreadyInLibrary,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = pack['name']?.toString() ?? 'Pack';
    final description = pack['description']?.toString() ?? '';
    final coverUrl = pack['cover_url']?.toString();
    final itemCount = switch (kind) {
      PackKind.sticker => (pack['stickers'] as List? ?? const []).length,
      PackKind.customEmoji =>
        (pack['custom_emojis'] as List? ?? const []).length,
    };
    final kindLabel = switch (kind) {
      PackKind.sticker => 'Sticker pack',
      PackKind.customEmoji => 'Custom emoji pack',
    };
    final countLabel = switch (kind) {
      PackKind.sticker => '$itemCount sticker${itemCount == 1 ? '' : 's'}',
      PackKind.customEmoji =>
        '$itemCount custom emoji${itemCount == 1 ? '' : ''}',
    };
    final buttonLabel = alreadyInLibrary
        ? 'Already in your library'
        : adding
        ? 'Adding...'
        : 'Add to library';

    return Column(
      key: const ValueKey('pack-ready'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.center,
          child: _PackPreviewIcon(kind: kind, coverUrl: coverUrl),
        ),
        const SizedBox(height: 18),
        Text(
          name,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            GlassChip(
              label: kindLabel,
              icon: Icon(
                kind == PackKind.sticker
                    ? Icons.emoji_emotions_rounded
                    : Icons.add_reaction_rounded,
                size: 15,
              ),
            ),
            GlassChip(
              label: countLabel,
              icon: const Icon(Icons.collections_bookmark_rounded, size: 15),
            ),
          ],
        ),
        if (description.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            description,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 24),
        GlassButtonWidget(
          onPressed: alreadyInLibrary || adding ? null : onAdd,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (adding)
                  const SizedBox.square(
                    dimension: 18,
                    child: GlassProgressIndicator.circular(strokeWidth: 2),
                  )
                else
                  Icon(
                    alreadyInLibrary
                        ? Icons.check_circle_rounded
                        : Icons.library_add_rounded,
                  ),
                const SizedBox(width: 8),
                Text(buttonLabel),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PackPreviewIcon extends StatelessWidget {
  final PackKind kind;
  final String? coverUrl;

  const _PackPreviewIcon({required this.kind, required this.coverUrl});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = kind == PackKind.sticker
        ? Icons.emoji_emotions_rounded
        : Icons.add_reaction_rounded;
    final url = coverUrl;
    return GlassContainer(
      width: 96,
      height: 96,
      shape: const LiquidRoundedSuperellipse(borderRadius: 28),
      allowElevation: true,
      glowIntensity: 0.08,
      padding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: url == null || url.isEmpty
          ? Icon(icon, size: 42, color: scheme.primary)
          : CachedNetworkImage(
              imageUrl: ApiConfig.resolveMedia(url),
              fit: BoxFit.cover,
              errorWidget: (_, _, _) =>
                  Icon(icon, size: 42, color: scheme.primary),
            ),
    );
  }
}
