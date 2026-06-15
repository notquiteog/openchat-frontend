import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/api_config.dart';
import '../providers/settings_provider.dart';
import '../screens/custom_emojis/custom_emoji_pack_screen.dart';
import '../services/api_service.dart';
import 'glass.dart';

class CustomEmojiPicker extends StatefulWidget {
  final void Function(Map<String, dynamic> emoji) onEmojiSelected;

  const CustomEmojiPicker({super.key, required this.onEmojiSelected});

  @override
  State<CustomEmojiPicker> createState() => _CustomEmojiPickerState();
}

class _CustomEmojiPickerState extends State<CustomEmojiPicker>
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
      final raw = await api.getCustomEmojiPacks();
      final packs = <Map<String, dynamic>>[];
      for (final p in raw.cast<Map<String, dynamic>>()) {
        try {
          final full = await api.getCustomEmojiPack(p['id'] as String);
          packs.add(full);
        } catch (_) {
          packs.add(p);
        }
      }
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
      MaterialPageRoute(builder: (_) => const CustomEmojiPackScreen()),
    ).then((_) {
      if (!mounted) return;
      setState(() => _loading = true);
      _loadPacks();
    });
  }

  List<Map<String, dynamic>> _emojisForPack(Map<String, dynamic> pack) =>
      (pack['custom_emojis'] as List? ?? const [])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList();

  List<Map<String, dynamic>> _allEmojis() => [
    for (final pack in _packs) ..._emojisForPack(pack),
  ];

  List<Map<String, dynamic>> _recentEmojis(List<String> recentIds) {
    final byId = {
      for (final emoji in _allEmojis())
        if ((emoji['id']?.toString() ?? '').isNotEmpty)
          emoji['id'].toString(): emoji,
    };
    return [
      for (final id in recentIds)
        if (byId[id] != null) byId[id]!,
    ];
  }

  List<Map<String, dynamic>> _searchResults(String query) {
    final needle = query.toLowerCase();
    return _allEmojis().where((emoji) {
      final name = emoji['name']?.toString().toLowerCase() ?? '';
      final glyph = emoji['emoji']?.toString().toLowerCase() ?? '';
      return name.contains(needle) || glyph.contains(needle);
    }).toList();
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
              ? _EmptyEmojiState(
                  icon: Icons.add_reaction_outlined,
                  title: 'No custom emoji packs yet',
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
                          hintText: 'Search emoji',
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
                          ? _EmojiGrid(
                              emojis: _searchResults(_query),
                              emptyText: 'No matches',
                              onEmojiSelected: widget.onEmojiSelected,
                            )
                          : TabBarView(
                              controller: tabCtrl,
                              children: [
                                _EmojiGrid(
                                  emojis: _recentEmojis(
                                    context
                                        .watch<SettingsProvider>()
                                        .recentEmojiIds,
                                  ),
                                  emptyText: 'No recent emoji yet',
                                  onEmojiSelected: widget.onEmojiSelected,
                                ),
                                for (final pack in _packs)
                                  _EmojiGrid(
                                    emojis: _emojisForPack(pack),
                                    emptyText:
                                        'No custom emoji in this pack yet',
                                    onEmojiSelected: widget.onEmojiSelected,
                                  ),
                              ],
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: TextButton.icon(
                          icon: const Icon(
                            Icons.add_reaction_outlined,
                            size: 17,
                          ),
                          label: const Text('Manage custom emoji packs'),
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
    return name == null || name.isEmpty ? 'E' : name.substring(0, 1);
  }
}

class _EmojiGrid extends StatelessWidget {
  final List<Map<String, dynamic>> emojis;
  final String emptyText;
  final void Function(Map<String, dynamic> emoji) onEmojiSelected;

  const _EmojiGrid({
    required this.emojis,
    required this.emptyText,
    required this.onEmojiSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (emojis.isEmpty) {
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
        crossAxisCount: 7,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: emojis.length,
      itemBuilder: (context, i) {
        final emoji = emojis[i];
        final fileUrl = emoji['file_url'] as String?;
        return Tooltip(
          message: emoji['name'] as String? ?? 'Custom emoji',
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onEmojiSelected(emoji),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: scheme.surfaceContainerLowest.withValues(alpha: 0.55),
              ),
              child: fileUrl != null && fileUrl.isNotEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(5),
                      child: CachedNetworkImage(
                        imageUrl: ApiConfig.resolveMedia(fileUrl),
                        fit: BoxFit.contain,
                        errorWidget: (_, _, _) => Text(
                          emoji['emoji'] as String? ?? '🙂',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : Center(
                      child: Text(
                        emoji['emoji'] as String? ?? '🙂',
                        textAlign: TextAlign.center,
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _EmptyEmojiState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String actionLabel;
  final VoidCallback onAction;

  const _EmptyEmojiState({
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
