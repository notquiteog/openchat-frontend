import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_config.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';

/// Search publicly discoverable sticker packs and add them to the library.
/// Backed by the `/discover/stickers` endpoint (Batch 6.2). Custom-emoji
/// packs have their own screen: CustomEmojiDiscoverScreen.
class StickerDiscoverScreen extends StatefulWidget {
  const StickerDiscoverScreen({super.key});

  @override
  State<StickerDiscoverScreen> createState() => _StickerDiscoverScreenState();
}

class _StickerDiscoverScreenState extends State<StickerDiscoverScreen> {
  final _queryCtrl = TextEditingController();
  List<dynamic> _results = const [];
  bool _loading = false;
  final _added = <String>{};

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => _loading = true);
    final api = context.read<ApiService>();
    final q = _queryCtrl.text.trim();
    try {
      final results = await api.discoverStickerPacks(q);
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add(Map<String, dynamic> pack) async {
    final api = context.read<ApiService>();
    final id = pack['id'] as String;
    try {
      await api.addStickerPackToLibrary(id);
      if (!mounted) return;
      setState(() => _added.add(id));
      showAppToast(context, 'Added to library');
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, 'Failed: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassScreenScaffold(
      title: const Text('Discover sticker packs'),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
              16,
              8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: GlassSearchBar(
                    controller: _queryCtrl,
                    placeholder: 'Search sticker packs',
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                GlassCircleIconButton(
                  tooltip: 'Search',
                  onPressed: _search,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: GlassProgressIndicator.circular())
                : _resultsList(_results),
          ),
        ],
      ),
    );
  }

  Widget _resultsList(List<dynamic> results) {
    if (results.isEmpty) {
      return const Center(child: Text('No packs found'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final pack = results[i] as Map<String, dynamic>;
        final id = pack['id'] as String;
        final cover = pack['cover_url'] as String?;
        final added = _added.contains(id);
        final installs = (pack['install_count'] as num?)?.toInt() ?? 0;
        return GlassListTile(
          leading: cover != null && cover.isNotEmpty
              ? CircleAvatar(
                  backgroundImage: NetworkImage(ApiConfig.resolveMedia(cover)),
                )
              : const CircleAvatar(child: Icon(Icons.emoji_emotions_outlined)),
          title: Text(pack['name'] as String? ?? 'Pack'),
          subtitle: _DiscoverPackSubtitle(
            description: pack['description'] as String? ?? '',
            installs: installs,
          ),
          trailing: added
              ? const Icon(Icons.check_rounded, color: Colors.green)
              : GlassButtonWidget(
                  onPressed: () => _add(pack),
                  child: const Text('Add'),
                ),
        );
      },
    );
  }
}

class _DiscoverPackSubtitle extends StatelessWidget {
  final String description;
  final int installs;

  const _DiscoverPackSubtitle({
    required this.description,
    required this.installs,
  });

  @override
  Widget build(BuildContext context) {
    final hasDescription = description.trim().isNotEmpty;
    if (!hasDescription && installs <= 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasDescription) Text(description),
        if (installs > 0) ...[
          if (hasDescription) const SizedBox(height: 6),
          _InstallCountBadge(count: installs),
        ],
      ],
    );
  }
}

class _InstallCountBadge extends StatelessWidget {
  final int count;

  const _InstallCountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      shape: const LiquidRoundedSuperellipse(borderRadius: 999),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.library_add_check_outlined,
            size: 13,
            color: scheme.primary,
          ),
          const SizedBox(width: 4),
          Text(
            count == 1 ? '1 install' : '$count installs',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
