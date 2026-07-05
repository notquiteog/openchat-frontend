import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/api_config.dart';
import '../providers/settings_provider.dart';
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
  final _searchCtrl = TextEditingController();
  TabController? _tabCtrl;
  List<Map<String, dynamic>> _packs = [];
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      final query = _searchCtrl.text.trim();
      if (query == _query) return;
      setState(() => _query = query);
    });
    _loadPacks();
  }

  Future<void> _loadPacks() async {
    try {
      final api = context.read<ApiService>();
      final raw = await api.getStickerPacks();
      // The list endpoint now hydrates each pack with its `stickers` array,
      // so we build the pack list directly from `raw` without an extra
      // getStickerPack() request per pack.
      final packs = raw.cast<Map<String, dynamic>>().toList();
      if (!mounted) return;
      setState(() {
        _packs = packs;
        _tabCtrl?.dispose();
        _tabCtrl = packs.isEmpty
            ? null
            : TabController(length: packs.length + 1, vsync: this);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _tabCtrl?.dispose();
    super.dispose();
  }

  void _openPackManager() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const StickerPackScreen()),
    ).then((_) {
      if (!mounted) return;
      setState(() => _loading = true);
      _loadPacks();
    });
  }

  List<Map<String, dynamic>> _stickersForPack(Map<String, dynamic> pack) =>
      (pack['stickers'] as List? ?? const [])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList();

  List<Map<String, dynamic>> _allStickers() => [
    for (final pack in _packs) ..._stickersForPack(pack),
  ];

  List<Map<String, dynamic>> _recentStickers(List<String> recentIds) {
    final byId = {
      for (final sticker in _allStickers())
        if ((sticker['id']?.toString() ?? '').isNotEmpty)
          sticker['id'].toString(): sticker,
    };
    return [
      for (final id in recentIds)
        if (byId[id] != null) byId[id]!,
    ];
  }

  List<Map<String, dynamic>> _searchResults(String query) {
    final needle = query.toLowerCase();
    return _allStickers().where((sticker) {
      final name = sticker['name']?.toString().toLowerCase() ?? '';
      final emoji = sticker['emoji']?.toString().toLowerCase() ?? '';
      return name.contains(needle) || emoji.contains(needle);
    }).toList();
  }

  void _selectSticker(Map<String, dynamic> sticker) {
    final id = sticker['id']?.toString() ?? '';
    if (id.isEmpty) return;
    widget.onStickerSelected(id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tabCtrl = _tabCtrl;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: GlassContainer(
        shape: const LiquidRoundedSuperellipse(borderRadius: 24),
        allowElevation: true,
        glowIntensity: 0.05,
        padding: EdgeInsets.zero,
        child: SizedBox(
          height: 300,
          child: _loading
              ? const Center(
                  child: GlassProgressIndicator.circular(strokeWidth: 2),
                )
              : _packs.isEmpty
              ? _EmptyStickerState(
                  icon: Icons.sentiment_satisfied_outlined,
                  title: 'No sticker packs yet',
                  actionLabel: 'Create a pack',
                  onAction: _openPackManager,
                )
              : Column(
                  children: [
                    const SizedBox(height: 8),
                    const GlassSheetGrabber(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                      child: TextField(
                        controller: _searchCtrl,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Search stickers',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear',
                                  icon: const Icon(Icons.close_rounded),
                                  onPressed: _searchCtrl.clear,
                                ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),
                    if (_query.isEmpty && tabCtrl != null)
                      TabBar(
                        controller: tabCtrl,
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        dividerColor: scheme.outlineVariant.withValues(
                          alpha: 0.18,
                        ),
                        indicatorColor: scheme.primary,
                        indicatorSize: TabBarIndicatorSize.tab,
                        tabs: [
                          const Tab(icon: Icon(Icons.history_rounded)),
                          for (final pack in _packs) _packTab(pack),
                        ],
                      ),
                    Expanded(
                      child: _query.isNotEmpty
                          ? _StickerGrid(
                              stickers: _searchResults(_query),
                              emptyText: 'No matches',
                              onStickerSelected: _selectSticker,
                            )
                          : TabBarView(
                              controller: tabCtrl,
                              children: [
                                _StickerGrid(
                                  stickers: _recentStickers(
                                    context
                                        .watch<SettingsProvider>()
                                        .recentStickerIds,
                                  ),
                                  emptyText: 'No recent stickers yet',
                                  onStickerSelected: _selectSticker,
                                ),
                                for (final pack in _packs)
                                  _StickerGrid(
                                    stickers: _stickersForPack(pack),
                                    emptyText: 'No stickers in this pack yet',
                                    onStickerSelected: _selectSticker,
                                  ),
                              ],
                            ),
                    ),
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

  Tab _packTab(Map<String, dynamic> pack) {
    final coverUrl = pack['cover_url'] as String?;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      return Tab(
        child: CachedNetworkImage(
          imageUrl: ApiConfig.resolveMedia(coverUrl),
          width: 26,
          height: 26,
          errorWidget: (_, _, _) => Text(_packInitial(pack)),
        ),
      );
    }
    return Tab(
      child: Text(
        pack['name'] as String? ?? 'Pack',
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  String _packInitial(Map<String, dynamic> pack) {
    final name = pack['name']?.toString().trim();
    return name == null || name.isEmpty ? 'S' : name.substring(0, 1);
  }
}

class _StickerGrid extends StatelessWidget {
  final List<Map<String, dynamic>> stickers;
  final String emptyText;
  final void Function(Map<String, dynamic> sticker) onStickerSelected;

  const _StickerGrid({
    required this.stickers,
    required this.emptyText,
    required this.onStickerSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (stickers.isEmpty) {
      return Center(
        child: Text(
          emptyText,
          style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.45)),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: stickers.length,
      itemBuilder: (context, i) {
        final sticker = stickers[i];
        final fileUrl = sticker['file_url'] as String?;
        return Tooltip(
          message: sticker['name'] as String? ?? 'Sticker',
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onStickerSelected(sticker),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: scheme.surfaceContainerLowest.withValues(alpha: 0.55),
              ),
              child: fileUrl != null && fileUrl.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: CachedNetworkImage(
                        imageUrl: ApiConfig.resolveMedia(fileUrl),
                        fit: BoxFit.cover,
                        placeholder: (_, _) => const Center(
                          child: GlassProgressIndicator.circular(
                            strokeWidth: 2,
                          ),
                        ),
                        errorWidget: (_, _, _) =>
                            const Icon(Icons.broken_image_outlined),
                      ),
                    )
                  : const Center(child: Icon(Icons.broken_image_outlined)),
            ),
          ),
        );
      },
    );
  }
}

class _EmptyStickerState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String actionLabel;
  final VoidCallback onAction;

  const _EmptyStickerState({
    required this.icon,
    required this.title,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: scheme.onSurface.withValues(alpha: 0.38)),
          const SizedBox(height: 10),
          Text(
            title,
            style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.55)),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            icon: const Icon(Icons.add, size: 17),
            label: Text(actionLabel),
            onPressed: onAction,
          ),
        ],
      ),
    );
  }
}
