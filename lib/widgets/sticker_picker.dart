import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/api_config.dart';
import '../screens/stickers/sticker_pack_screen.dart';
import '../services/api_service.dart';
import 'glass.dart';

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
      setState(() => _loading = true);
      _loadPacks();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: GlassContainer(
        shape: LiquidRoundedSuperellipse(borderRadius: 24),
        allowElevation: true,
        glowIntensity: 0.05,
        padding: EdgeInsets.zero,
        child: SizedBox(
          height: 268,
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _packs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.sentiment_satisfied_outlined,
                        size: 36,
                        color: scheme.onSurface.withValues(alpha: 0.38),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'No sticker packs yet',
                        style: TextStyle(
                          color: scheme.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextButton.icon(
                        icon: const Icon(Icons.add, size: 17),
                        label: const Text('Create a pack'),
                        onPressed: _openPackManager,
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Drag handle
                    const SizedBox(height: 8),
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: scheme.onSurface.withValues(alpha: 0.20),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    // Tab bar: one tab per pack
                    TabBar(
                      controller: _tabCtrl,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      dividerColor: scheme.outlineVariant.withValues(alpha: 0.18),
                      indicatorColor: scheme.primary,
                      indicatorSize: TabBarIndicatorSize.tab,
                      tabs: _packs.map((p) {
                        final coverUrl = p['cover_url'] as String?;
                        return Tab(
                          child: coverUrl != null
                              ? CachedNetworkImage(
                                  imageUrl: ApiConfig.resolveMedia(coverUrl),
                                  width: 26,
                                  height: 26,
                                  errorWidget: (_, _, _) => Text(
                                    p['name']?.toString().substring(0, 1) ?? 'S',
                                  ),
                                )
                              : Text(
                                  p['name'] as String? ?? 'Pack',
                                  overflow: TextOverflow.ellipsis,
                                ),
                        );
                      }).toList(),
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
                                style: TextStyle(
                                  color:
                                      scheme.onSurface.withValues(alpha: 0.45),
                                ),
                              ),
                            );
                          }
                          return GridView.builder(
                            padding: const EdgeInsets.all(10),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 5,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                ),
                            itemCount: stickers.length,
                            itemBuilder: (context, i) {
                              final sticker = stickers[i];
                              final fileUrl = sticker['file_url'] as String?;
                              return GestureDetector(
                                onTap: () => widget.onStickerSelected(
                                  sticker['id'] as String,
                                ),
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    color: scheme.surfaceContainerLowest
                                        .withValues(alpha: 0.55),
                                  ),
                                  child: fileUrl != null
                                      ? ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          child: CachedNetworkImage(
                                            imageUrl:
                                                ApiConfig.resolveMedia(fileUrl),
                                            fit: BoxFit.cover,
                                            placeholder: (_, _) =>
                                                const Center(
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                  ),
                                                ),
                                            errorWidget: (_, _, _) => const Icon(
                                              Icons.broken_image_outlined,
                                            ),
                                          ),
                                        )
                                      : const Center(
                                          child:
                                              Icon(Icons.broken_image_outlined),
                                        ),
                                ),
                              );
                            },
                          );
                        }).toList(),
                      ),
                    ),
                    // Manage packs
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: TextButton.icon(
                          icon: const Icon(Icons.manage_search, size: 17),
                          label: const Text('Manage sticker packs'),
                          onPressed: _openPackManager,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
