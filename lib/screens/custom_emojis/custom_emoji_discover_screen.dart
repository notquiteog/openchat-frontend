import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_config.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';

/// Search publicly discoverable custom-emoji packs and add them to the
/// library. Backed by the `/discover/custom-emoji` endpoint. Sticker packs
/// have their own screen: StickerDiscoverScreen.
class CustomEmojiDiscoverScreen extends StatefulWidget {
  const CustomEmojiDiscoverScreen({super.key});

  @override
  State<CustomEmojiDiscoverScreen> createState() =>
      _CustomEmojiDiscoverScreenState();
}

class _CustomEmojiDiscoverScreenState extends State<CustomEmojiDiscoverScreen> {
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
      final results = await api.discoverCustomEmojiPacks(q);
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
    final messenger = ScaffoldMessenger.of(context);
    final id = pack['id'] as String;
    try {
      await api.addCustomEmojiPackToLibrary(id);
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
      appBar: GlassAppBar(title: const Text('Discover emoji packs')),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
              16,
              8,
            ),
            child: TextField(
              controller: _queryCtrl,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Search emoji packs',
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
        return GlassListTile(
          leading: cover != null && cover.isNotEmpty
              ? CircleAvatar(
                  backgroundImage: NetworkImage(ApiConfig.resolveMedia(cover)),
                )
              : const CircleAvatar(child: Icon(Icons.add_reaction_outlined)),
          title: Text(pack['name'] as String? ?? 'Pack'),
          subtitle: Text(pack['description'] as String? ?? ''),
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
