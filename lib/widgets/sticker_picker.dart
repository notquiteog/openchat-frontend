import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/api_config.dart';
import '../screens/stickers/sticker_pack_screen.dart';
import '../services/api_service.dart';

class StickerPicker extends StatefulWidget {
  final void Function(String stickerID) onStickerSelected;

  const StickerPicker({super.key, required this.onStickerSelected});

  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends State<StickerPicker>
    with SingleTickerProviderStateMixin {
  TabController? _tabCtrl;
  List<Map<String, dynamic>> _packs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPacks();
  }

  Future<void> _loadPacks() async {
    try {
      final api = context.read<ApiService>();
      final raw = await api.getStickerPacks();
      // Fetch full pack data (includes stickers) for each pack
      final packs = <Map<String, dynamic>>[];
      for (final p in raw.cast<Map<String, dynamic>>()) {
        try {
          final full = await api.getStickerPack(p['id'] as String);
          packs.add(full);
        } catch (_) {
          packs.add(p);
        }
      }
      if (mounted) {
        setState(() {
          _packs = packs;
          _tabCtrl = TabController(length: packs.length, vsync: this);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _tabCtrl?.dispose();
    super.dispose();
  }

  void _openPackManager() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const StickerPackScreen()),
    ).then((_) {
      // Refresh packs after returning from the manager
      setState(() => _loading = true);
      _loadPacks();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 260,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: Colors.grey.withValues(alpha: 0.2))),
      ),
      child: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _packs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('No sticker packs yet',
                          style: TextStyle(color: Colors.grey)),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Create a pack'),
                        onPressed: _openPackManager,
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Tab bar: one tab per pack + a "+" tab to manage packs
                    TabBar(
                      controller: _tabCtrl,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: [
                        ..._packs.map((p) {
                          final coverUrl = p['cover_url'] as String?;
                          return Tab(
                            child: coverUrl != null
                                ? CachedNetworkImage(
                                    imageUrl: ApiConfig.resolveMedia(coverUrl),
                                    width: 28,
                                    height: 28,
                                    errorWidget: (_, __, ___) =>
                                        Text(p['name']?.toString().substring(0, 1) ?? 'S'),
                                  )
                                : Text(
                                    p['name'] as String? ?? 'Pack',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                          );
                        }),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        controller: _tabCtrl,
                        children: _packs.map((pack) {
                          final stickers = (pack['stickers'] as List? ?? [])
                              .cast<Map<String, dynamic>>();
                          if (stickers.isEmpty) {
                            return Center(
                              child: Text(
                                'No stickers in this pack yet',
                                style: TextStyle(color: Colors.grey[500]),
                              ),
                            );
                          }
                          return GridView.builder(
                            padding: const EdgeInsets.all(8),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 5,
                              crossAxisSpacing: 6,
                              mainAxisSpacing: 6,
                            ),
                            itemCount: stickers.length,
                            itemBuilder: (context, i) {
                              final sticker = stickers[i];
                              final fileUrl = sticker['file_url'] as String?;
                              final emoji = sticker['emoji'] as String? ?? '😀';
                              return GestureDetector(
                                onTap: () =>
                                    widget.onStickerSelected(sticker['id'] as String),
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    color: Colors.grey.withValues(alpha: 0.08),
                                  ),
                                  child: fileUrl != null
                                      ? ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: CachedNetworkImage(
                                            imageUrl: ApiConfig.resolveMedia(fileUrl),
                                            fit: BoxFit.cover,
                                            placeholder: (_, __) => Center(
                                              child: Text(emoji,
                                                  style: const TextStyle(fontSize: 24)),
                                            ),
                                            errorWidget: (_, __, ___) => Center(
                                              child: Text(emoji,
                                                  style: const TextStyle(fontSize: 24)),
                                            ),
                                          ),
                                        )
                                      : Center(
                                          child: Text(emoji,
                                              style: const TextStyle(fontSize: 28)),
                                        ),
                                ),
                              );
                            },
                          );
                        }).toList(),
                      ),
                    ),
                    // Manage packs button
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: SizedBox(
                        width: double.infinity,
                        child: TextButton.icon(
                          icon: const Icon(Icons.manage_search, size: 18),
                          label: const Text('Manage sticker packs'),
                          onPressed: _openPackManager,
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
