import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/api_config.dart';
import '../screens/custom_emojis/custom_emoji_pack_screen.dart';
import '../services/api_service.dart';

class CustomEmojiPicker extends StatefulWidget {
  final void Function(Map<String, dynamic> emoji) onEmojiSelected;

  const CustomEmojiPicker({super.key, required this.onEmojiSelected});

  @override
  State<CustomEmojiPicker> createState() => _CustomEmojiPickerState();
}

class _CustomEmojiPickerState extends State<CustomEmojiPicker>
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
            : TabController(length: packs.length, vsync: this);
        _loading = false;
      });
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
      MaterialPageRoute(builder: (_) => const CustomEmojiPackScreen()),
    ).then((_) {
      if (!mounted) return;
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
        border: Border(
          top: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
        ),
      ),
      child: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _packs.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'No custom emoji packs yet',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    icon: const Icon(Icons.add_reaction_outlined),
                    label: const Text('Create a pack'),
                    onPressed: _openPackManager,
                  ),
                ],
              ),
            )
          : Column(
              children: [
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
                                errorWidget: (_, _, _) => Text(
                                  p['name']?.toString().substring(0, 1) ?? 'E',
                                ),
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
                      final emojis = (pack['custom_emojis'] as List? ?? [])
                          .cast<Map<String, dynamic>>();
                      if (emojis.isEmpty) {
                        return Center(
                          child: Text(
                            'No custom emoji in this pack yet',
                            style: TextStyle(color: Colors.grey[500]),
                          ),
                        );
                      }
                      return GridView.builder(
                        padding: const EdgeInsets.all(8),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 7,
                              crossAxisSpacing: 6,
                              mainAxisSpacing: 6,
                            ),
                        itemCount: emojis.length,
                        itemBuilder: (context, i) {
                          final emoji = emojis[i];
                          final fileUrl = emoji['file_url'] as String?;
                          return Tooltip(
                            message: emoji['name'] as String? ?? 'Custom emoji',
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () => widget.onEmojiSelected(emoji),
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  color: Colors.grey.withValues(alpha: 0.08),
                                ),
                                child: fileUrl != null
                                    ? Padding(
                                        padding: const EdgeInsets.all(5),
                                        child: CachedNetworkImage(
                                          imageUrl: ApiConfig.resolveMedia(
                                            fileUrl,
                                          ),
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
                    }).toList(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      icon: const Icon(Icons.add_reaction_outlined, size: 18),
                      label: const Text('Manage custom emoji packs'),
                      onPressed: _openPackManager,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
