import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_config.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';

/// Search publicly discoverable sticker / custom-emoji packs and add them to the
/// library. Backed by the `/discover/*` endpoints (Batch 6.2).
class StickerDiscoverScreen extends StatefulWidget {
  const StickerDiscoverScreen({super.key});

  @override
  State<StickerDiscoverScreen> createState() => _StickerDiscoverScreenState();
}

class _StickerDiscoverScreenState extends State<StickerDiscoverScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);
  final _queryCtrl = TextEditingController();
  List<dynamic> _stickerResults = const [];
  List<dynamic> _emojiResults = const [];
  bool _loading = false;
  final _added = <String>{};

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _tab.dispose();
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => _loading = true);
    final api = context.read<ApiService>();
    final q = _queryCtrl.text.trim();
    try {
      final results = await Future.wait([
        api.discoverStickerPacks(q),
        api.discoverCustomEmojiPacks(q),
      ]);
      if (!mounted) return;
      setState(() {
        _stickerResults = results[0];
        _emojiResults = results[1];
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add(Map<String, dynamic> pack, {required bool emoji}) async {
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    final id = pack['id'] as String;
    try {
      if (emoji) {
        await api.addCustomEmojiPackToLibrary(id);
      } else {
        await api.addStickerPackToLibrary(id);
      }
      if (mounted) setState(() => _added.add(id));
      messenger.showSnackBar(const SnackBar(content: Text('Added to library')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: const Text('Discover packs'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [Tab(text: 'Stickers'), Tab(text: 'Emoji')],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.paddingOf(context).top +
                  kToolbarHeight +
                  kTextTabBarHeight +
                  12,
              16,
              8,
            ),
            child: TextField(
              controller: _queryCtrl,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Search packs',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_forward_rounded),
                  onPressed: _search,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: GlassProgressIndicator.circular())
                : TabBarView(
                    controller: _tab,
                    children: [
                      _resultsList(_stickerResults, emoji: false),
                      _resultsList(_emojiResults, emoji: true),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _resultsList(List<dynamic> results, {required bool emoji}) {
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
        return GlassListTile(
          leading: cover != null && cover.isNotEmpty
              ? CircleAvatar(
                  backgroundImage: NetworkImage(ApiConfig.resolveMedia(cover)),
                )
              : const CircleAvatar(child: Icon(Icons.emoji_emotions_outlined)),
          title: Text(pack['name'] as String? ?? 'Pack'),
          subtitle: Text(pack['description'] as String? ?? ''),
          trailing: added
              ? const Icon(Icons.check_rounded, color: Colors.green)
              : GlassButtonWidget(
                  onPressed: () => _add(pack, emoji: emoji),
                  child: const Text('Add'),
                ),
        );
      },
    );
  }
}
