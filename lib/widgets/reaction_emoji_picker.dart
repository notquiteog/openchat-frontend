import 'package:cached_network_image/cached_network_image.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart'
    show Category, CategoryEmoji, Emoji, defaultEmojiSet;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/api_config.dart';
import '../models/message.dart' show customReactionPrefix;
import '../providers/settings_provider.dart';
import '../services/api_service.dart';
import 'custom_emoji_image.dart';
import 'glass.dart';

/// Opens the full reaction picker — recents + every in-app custom-emoji pack +
/// every system emoji, with search — and returns the chosen reaction key (a
/// unicode emoji or a `custom:<id>` reference), or null if dismissed.
Future<String?> showReactionEmojiPicker(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _ReactionEmojiPickerSheet(),
  );
}

class _ReactionEmojiPickerSheet extends StatefulWidget {
  const _ReactionEmojiPickerSheet();

  @override
  State<_ReactionEmojiPickerSheet> createState() =>
      _ReactionEmojiPickerSheetState();
}

class _ReactionEmojiPickerSheetState extends State<_ReactionEmojiPickerSheet> {
  /// Flattened system emoji for searching (built once).
  static final List<Emoji> _allSystem = [
    for (final c in defaultEmojiSet) ...c.emoji,
  ];

  List<Map<String, dynamic>> _packs = [];
  bool _loadingPacks = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadPacks();
  }

  Future<void> _loadPacks() async {
    try {
      final api = context.read<ApiService>();
      final raw = await api.getCustomEmojiPacks();
      final packs = <Map<String, dynamic>>[];
      for (final p in raw.cast<Map<String, dynamic>>()) {
        try {
          packs.add(await api.getCustomEmojiPack(p['id'] as String));
        } catch (_) {
          packs.add(p);
        }
      }
      // Seed the URL cache so chips/bar render these instantly later.
      for (final pack in packs) {
        for (final e
            in (pack['custom_emojis'] as List? ?? const [])
                .cast<Map<String, dynamic>>()) {
          final id = e['id'] as String?;
          if (id != null) CustomEmojiUrlCache.put(id, e['file_url'] as String?);
        }
      }
      if (!mounted) return;
      setState(() {
        _packs = packs;
        _loadingPacks = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingPacks = false);
    }
  }

  void _pick(String key) => Navigator.pop(context, key);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = (MediaQuery.sizeOf(context).height * 0.62).clamp(
      360.0,
      600.0,
    );
    return GlassBottomSheetFrame(
      scrollable: false,
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            const GlassSheetGrabber(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
              child: Row(
                children: [
                  const Text(
                    'React',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                  ),
                  const Spacer(),
                  GlassCircleIconButton(
                    tooltip: 'Close',
                    size: 32,
                    glowIntensity: 0.04,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 17),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextField(
                autofocus: false,
                onChanged: (v) =>
                    setState(() => _query = v.trim().toLowerCase()),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search emoji',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  filled: true,
                  fillColor: scheme.onSurface.withValues(alpha: 0.06),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: _loadingPacks && _query.isEmpty
                  ? const Center(
                      child: GlassProgressIndicator.circular(strokeWidth: 2),
                    )
                  : CustomScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      slivers: _query.isEmpty
                          ? _browseSlivers(context)
                          : _searchSlivers(context),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Browse (no query) ----

  List<Widget> _browseSlivers(BuildContext context) {
    final recents = context.read<SettingsProvider>().recentReactions;
    return [
      if (recents.isNotEmpty) ...[
        _header(context, Icons.history_rounded, 'Recently used'),
        _glyphGrid(
          count: recents.length,
          glyph: (i) => ReactionGlyph(recents[i], size: 28),
          keyAt: (i) => recents[i],
        ),
      ],
      for (final pack in _packs)
        ...(() {
          final emojis = (pack['custom_emojis'] as List? ?? const [])
              .cast<Map<String, dynamic>>();
          if (emojis.isEmpty) return const <Widget>[];
          return [
            _header(
              context,
              Icons.add_reaction_outlined,
              pack['name'] as String? ?? 'Custom',
            ),
            _glyphGrid(
              count: emojis.length,
              glyph: (i) => _customGlyph(emojis[i]),
              keyAt: (i) =>
                  '$customReactionPrefix${emojis[i]['id'] as String? ?? ''}',
            ),
          ];
        })(),
      for (final cat in defaultEmojiSet) ...[
        _header(context, _categoryIcon(cat.category), _categoryLabel(cat)),
        _glyphGrid(
          count: cat.emoji.length,
          glyph: (i) =>
              Text(cat.emoji[i].emoji, style: const TextStyle(fontSize: 26)),
          keyAt: (i) => cat.emoji[i].emoji,
        ),
      ],
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
    ];
  }

  // ---- Search ----

  List<Widget> _searchSlivers(BuildContext context) {
    final q = _query;
    final system = _allSystem
        .where((e) => e.name.toLowerCase().contains(q))
        .toList(growable: false);
    final custom = <Map<String, dynamic>>[];
    for (final pack in _packs) {
      for (final e
          in (pack['custom_emojis'] as List? ?? const [])
              .cast<Map<String, dynamic>>()) {
        final name = (e['name'] as String? ?? '').toLowerCase();
        if (name.contains(q)) custom.add(e);
      }
    }
    if (system.isEmpty && custom.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              'No emoji match “$_query”',
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
      ];
    }
    return [
      if (custom.isNotEmpty)
        _glyphGrid(
          count: custom.length,
          glyph: (i) => _customGlyph(custom[i]),
          keyAt: (i) =>
              '$customReactionPrefix${custom[i]['id'] as String? ?? ''}',
        ),
      if (system.isNotEmpty)
        _glyphGrid(
          count: system.length,
          glyph: (i) =>
              Text(system[i].emoji, style: const TextStyle(fontSize: 26)),
          keyAt: (i) => system[i].emoji,
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
    ];
  }

  // ---- Building blocks ----

  Widget _customGlyph(Map<String, dynamic> e) {
    final fileUrl = e['file_url'] as String?;
    if (fileUrl == null || fileUrl.isEmpty) {
      return Text(
        e['emoji'] as String? ?? '🙂',
        style: const TextStyle(fontSize: 24),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(3),
      child: CachedNetworkImage(
        imageUrl: ApiConfig.resolveMedia(fileUrl),
        fit: BoxFit.contain,
        errorWidget: (_, _, _) => Text(
          e['emoji'] as String? ?? '🙂',
          style: const TextStyle(fontSize: 24),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Row(
          children: [
            Icon(
              icon,
              size: 15,
              color: scheme.onSurface.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 6),
            Text(
              label.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _glyphGrid({
    required int count,
    required Widget Function(int index) glyph,
    required String Function(int index) keyAt,
  }) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 8,
          mainAxisSpacing: 2,
          crossAxisSpacing: 2,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) =>
              _GlyphCell(onTap: () => _pick(keyAt(i)), child: glyph(i)),
          childCount: count,
        ),
      ),
    );
  }

  String _categoryLabel(CategoryEmoji cat) => switch (cat.category) {
    Category.SMILEYS => 'Smileys & people',
    Category.ANIMALS => 'Animals & nature',
    Category.FOODS => 'Food & drink',
    Category.ACTIVITIES => 'Activities',
    Category.TRAVEL => 'Travel & places',
    Category.OBJECTS => 'Objects',
    Category.SYMBOLS => 'Symbols',
    Category.FLAGS => 'Flags',
    _ => 'Emoji',
  };

  IconData _categoryIcon(Category cat) => switch (cat) {
    Category.SMILEYS => Icons.emoji_emotions_outlined,
    Category.ANIMALS => Icons.pets_rounded,
    Category.FOODS => Icons.lunch_dining_outlined,
    Category.ACTIVITIES => Icons.sports_basketball_outlined,
    Category.TRAVEL => Icons.directions_car_filled_outlined,
    Category.OBJECTS => Icons.lightbulb_outline_rounded,
    Category.SYMBOLS => Icons.emoji_symbols_outlined,
    Category.FLAGS => Icons.flag_outlined,
    _ => Icons.emoji_emotions_outlined,
  };
}

/// One tappable emoji cell with an iOS-style press highlight.
class _GlyphCell extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;

  const _GlyphCell({required this.onTap, required this.child});

  @override
  State<_GlyphCell> createState() => _GlyphCellState();
}

class _GlyphCellState extends State<_GlyphCell> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.82 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: Container(
          decoration: BoxDecoration(
            color: _pressed
                ? scheme.primary.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(child: widget.child),
        ),
      ),
    );
  }
}
