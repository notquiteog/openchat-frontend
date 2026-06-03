import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../config/api_config.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';

const _stickerPackNameMax = 128;
const _stickerPackDescriptionMax = 2048;
const _stickerNameMax = 64;

class StickerPackScreen extends StatefulWidget {
  const StickerPackScreen({super.key});

  @override
  State<StickerPackScreen> createState() => _StickerPackScreenState();
}

class _StickerPackScreenState extends State<StickerPackScreen> {
  List<Map<String, dynamic>> _packs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPacks();
  }

  Future<void> _loadPacks() async {
    setState(() => _loading = true);
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
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _createPack() {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Sticker Pack'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Pack name'),
              textCapitalization: TextCapitalization.words,
              maxLength: _stickerPackNameMax,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: descCtrl,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
              ),
              maxLines: 2,
              maxLength: _stickerPackDescriptionMax,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(ctx);
              try {
                await context.read<ApiService>().createStickerPack(
                  name: name,
                  description: descCtrl.text.trim().isEmpty
                      ? null
                      : descCtrl.text.trim(),
                );
                _loadPacks();
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to create pack: $e')),
                  );
                }
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GlassAppBar(
        title: const Text('Sticker Packs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New pack',
            onPressed: _createPack,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _packs.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.emoji_emotions_outlined,
                    size: 72,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.35),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No sticker packs yet',
                    style: TextStyle(
                      fontSize: 16,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.55),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Create a pack'),
                    style: FilledButton.styleFrom(
                        shape: const StadiumBorder()),
                    onPressed: _createPack,
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              itemCount: _packs.length,
              itemBuilder: (context, i) {
                final pack = _packs[i];
                final coverUrl = pack['cover_url'] as String?;
                final count = (pack['stickers'] as List? ?? []).length;
                final currentUserId = context
                    .read<AuthProvider>()
                    .currentUser
                    ?.id;
                final isOwner =
                    currentUserId != null &&
                    pack['creator_id'] == currentUserId;
                final scheme = Theme.of(context).colorScheme;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GlassCard(
                    padding: EdgeInsets.zero,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => _PackDetailScreen(pack: pack),
                            ),
                          ).then((_) => _loadPacks()),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: coverUrl != null
                                        ? CachedNetworkImage(
                                            imageUrl:
                                                ApiConfig.resolveMedia(coverUrl),
                                            fit: BoxFit.cover,
                                            errorWidget: (_, _, _) => Icon(
                                              Icons.emoji_emotions,
                                              size: 36,
                                              color: scheme.primary,
                                            ),
                                          )
                                        : Icon(Icons.emoji_emotions,
                                            size: 36, color: scheme.primary),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        pack['name'] as String? ?? 'Pack',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600),
                                      ),
                                      Text(
                                        isOwner
                                            ? '$count stickers'
                                            : '$count stickers · Added',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: scheme.onSurface
                                              .withValues(alpha: 0.55),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(Icons.chevron_right,
                                    size: 18,
                                    color: scheme.onSurface
                                        .withValues(alpha: 0.35)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _PackDetailScreen extends StatefulWidget {
  final Map<String, dynamic> initialPack;
  const _PackDetailScreen({required Map<String, dynamic> pack})
    : initialPack = pack;

  @override
  State<_PackDetailScreen> createState() => _PackDetailScreenState();
}

class _PackDetailScreenState extends State<_PackDetailScreen> {
  late Map<String, dynamic> _pack;
  bool _loading = false;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _pack = widget.initialPack;
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final pack = await context.read<ApiService>().getStickerPack(
        _pack['id'] as String,
      );
      if (mounted) {
        setState(() {
          _pack = pack;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _removeFromLibrary() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove pack?'),
        content: const Text(
          'This pack will be removed from your library. You can add it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final api = context.read<ApiService>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await api.removeStickerPackFromLibrary(_pack['id'] as String);
      if (mounted) navigator.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed to remove: $e')));
    }
  }

  Future<void> _addSticker() async {
    final stickers = (_pack['stickers'] as List? ?? []);
    if (stickers.length >= 50) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This pack is full (50 sticker maximum)')),
      );
      return;
    }

    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;

    final nameCtrl = TextEditingController(
      text: picked.name.split('.').first.replaceAll('_', ' '),
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Sticker'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Name'),
              maxLength: _stickerNameMax,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Upload'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final api = context.read<ApiService>();
    final stickerName = nameCtrl.text.trim().isEmpty
        ? 'Sticker'
        : nameCtrl.text.trim();
    setState(() => _loading = true);
    try {
      final bytes = await picked.readAsBytes();
      await api.addStickerToPack(
        packID: _pack['id'] as String,
        fileBytes: bytes,
        filename: picked.name,
        name: stickerName,
      );
      await _reload();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    }
  }

  Future<void> _deleteSticker(String stickerID) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete sticker?'),
        content: const Text(
          'This sticker will be removed from the pack permanently.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final api = context.read<ApiService>();
    try {
      await api.deleteStickerFromPack(_pack['id'] as String, stickerID);
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
      }
    }
  }

  Future<void> _setCoverImage() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    setState(() => _loading = true);
    final api = context.read<ApiService>();
    try {
      final bytes = await picked.readAsBytes();
      final url = await api.uploadAvatar(
        fileBytes: bytes,
        filename: picked.name,
      );
      await api.updateStickerPack(_pack['id'] as String, coverUrl: url);
      await _reload();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to set cover: $e')));
      }
    }
  }

  void _editPackInfo() {
    final nameCtrl = TextEditingController(
      text: _pack['name'] as String? ?? '',
    );
    final descCtrl = TextEditingController(
      text: _pack['description'] as String? ?? '',
    );
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Pack'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Pack name'),
              maxLength: _stickerPackNameMax,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: descCtrl,
              decoration: const InputDecoration(labelText: 'Description'),
              maxLines: 2,
              maxLength: _stickerPackDescriptionMax,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              final desc = descCtrl.text.trim();
              final api = context.read<ApiService>();
              Navigator.pop(ctx);
              try {
                await api.updateStickerPack(
                  _pack['id'] as String,
                  name: name,
                  description: desc.isEmpty ? null : desc,
                );
                await _reload();
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to update: $e')),
                  );
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stickers = (_pack['stickers'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final coverUrl = _pack['cover_url'] as String?;
    final count = stickers.length;

    // A pack added from another user is use-only: no editing, no add/delete of
    // stickers, no cover/info changes. Only the creator manages those.
    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    final isOwner =
        currentUserId != null && _pack['creator_id'] == currentUserId;

    return Scaffold(
      appBar: GlassAppBar(
        title: Text(_pack['name'] as String? ?? 'Pack'),
        actions: isOwner
            ? [
                IconButton(
                  icon: const Icon(Icons.image_outlined),
                  tooltip: 'Set cover image',
                  onPressed: _setCoverImage,
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit pack info',
                  onPressed: _editPackInfo,
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.bookmark_remove_outlined),
                  tooltip: 'Remove from library',
                  onPressed: _removeFromLibrary,
                ),
              ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (coverUrl != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: CachedNetworkImage(
                      imageUrl: ApiConfig.resolveMedia(coverUrl),
                      height: 64,
                      errorWidget: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: isOwner
                      ? Row(
                          children: [
                            Text(
                              '$count / 50 stickers',
                              style: TextStyle(
                                color: count >= 50
                                    ? Colors.red
                                    : Colors.grey[600],
                                fontSize: 13,
                                fontWeight: count >= 50
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: LinearProgressIndicator(
                                value: count / 50,
                                color: count >= 50
                                    ? Colors.red
                                    : Theme.of(context).colorScheme.primary,
                                backgroundColor: Colors.grey.withValues(
                                  alpha: 0.2,
                                ),
                              ),
                            ),
                          ],
                        )
                      : Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '$count sticker${count == 1 ? '' : 's'} · Added from another user',
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 13,
                            ),
                          ),
                        ),
                ),
                Expanded(
                  child: stickers.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.add_photo_alternate_outlined,
                                size: 56,
                                color: Colors.grey,
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'No stickers yet',
                                style: TextStyle(color: Colors.grey),
                              ),
                              if (isOwner) ...[
                                const SizedBox(height: 8),
                                FilledButton.icon(
                                  icon: const Icon(Icons.add),
                                  label: const Text('Add sticker'),
                                  onPressed: _addSticker,
                                ),
                              ],
                            ],
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.all(8),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 4,
                                crossAxisSpacing: 6,
                                mainAxisSpacing: 6,
                              ),
                          itemCount: stickers.length,
                          itemBuilder: (context, i) {
                            final sticker = stickers[i];
                            final fileUrl = sticker['file_url'] as String?;
                            return GestureDetector(
                              onLongPress: isOwner
                                  ? () =>
                                        _deleteSticker(sticker['id'] as String)
                                  : null,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      color: Colors.grey.withValues(alpha: 0.1),
                                    ),
                                    child: fileUrl != null
                                        ? ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: CachedNetworkImage(
                                              imageUrl: ApiConfig.resolveMedia(
                                                fileUrl,
                                              ),
                                              fit: BoxFit.cover,
                                              errorWidget: (_, _, _) =>
                                                  const Center(
                                                    child: Icon(
                                                      Icons
                                                          .broken_image_outlined,
                                                    ),
                                                  ),
                                            ),
                                          )
                                        : const Center(
                                            child: Icon(
                                              Icons.broken_image_outlined,
                                            ),
                                          ),
                                  ),
                                  if (isOwner)
                                    Positioned(
                                      top: 2,
                                      right: 2,
                                      child: GestureDetector(
                                        onTap: () => _deleteSticker(
                                          sticker['id'] as String,
                                        ),
                                        child: Container(
                                          width: 20,
                                          height: 20,
                                          decoration: const BoxDecoration(
                                            color: Colors.red,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(
                                            Icons.close,
                                            size: 14,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
      floatingActionButton: isOwner && count < 50
          ? FloatingActionButton.extended(
              onPressed: _addSticker,
              icon: const Icon(Icons.add_photo_alternate),
              label: const Text('Add Sticker'),
            )
          : null,
    );
  }
}
