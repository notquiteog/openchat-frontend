import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../config/api_config.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';

const _customEmojiPackNameMax = 128;
const _customEmojiPackDescriptionMax = 2048;
const _customEmojiNameMax = 64;

class CustomEmojiPackScreen extends StatefulWidget {
  const CustomEmojiPackScreen({super.key});

  @override
  State<CustomEmojiPackScreen> createState() => _CustomEmojiPackScreenState();
}

class _CustomEmojiPackScreenState extends State<CustomEmojiPackScreen> {
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
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _createPack() {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('New Custom Emoji Pack'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Pack name'),
              textCapitalization: TextCapitalization.words,
              maxLength: _customEmojiPackNameMax,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: descCtrl,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
              ),
              maxLines: 2,
              maxLength: _customEmojiPackDescriptionMax,
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
                await context.read<ApiService>().createCustomEmojiPack(
                  name: name,
                  description: descCtrl.text.trim().isEmpty
                      ? null
                      : descCtrl.text.trim(),
                );
                await _loadPacks();
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to create pack: $e')),
                );
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
        title: const Text('Custom Emoji Packs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_reaction_outlined),
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
                    Icons.add_reaction_outlined,
                    size: 72,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.35),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No custom emoji packs yet',
                    style: TextStyle(
                      fontSize: 16,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.55),
                    ),
                  ),
                  const SizedBox(height: 12),
                  GlassButtonWidget.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Create a pack'),
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
                final count = (pack['custom_emojis'] as List? ?? []).length;
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
                                SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: coverUrl != null
                                      ? CachedNetworkImage(
                                          imageUrl:
                                              ApiConfig.resolveMedia(coverUrl),
                                          fit: BoxFit.contain,
                                          errorWidget: (_, _, _) => Icon(
                                            Icons.add_reaction_outlined,
                                            color: scheme.primary,
                                          ),
                                        )
                                      : Icon(Icons.add_reaction_outlined,
                                          size: 36, color: scheme.primary),
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
                                            ? '$count custom emoji'
                                            : '$count custom emoji · Added',
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
      final pack = await context.read<ApiService>().getCustomEmojiPack(
        _pack['id'] as String,
      );
      if (!mounted) return;
      setState(() {
        _pack = pack;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _removeFromLibrary() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
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
      await api.removeCustomEmojiPackFromLibrary(_pack['id'] as String);
      if (mounted) navigator.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed to remove: $e')));
    }
  }

  Future<void> _addCustomEmoji() async {
    final picked = await fs.openFile(
      acceptedTypeGroups: const [
        fs.XTypeGroup(
          label: 'Images',
          mimeTypes: ['image/*'],
          extensions: ['gif', 'webp', 'png', 'jpg', 'jpeg'],
        ),
      ],
    );
    if (picked == null || !mounted) return;

    final nameCtrl = TextEditingController(
      text: picked.name.split('.').first.replaceAll('_', ' '),
    );
    final emojiCtrl = TextEditingController(text: '🙂');
    String? emojiError;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => GlassAlertDialog(
          title: const Text('Add Custom Emoji'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Name'),
                maxLength: _customEmojiNameMax,
                autofocus: true,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: emojiCtrl,
                decoration: InputDecoration(
                  labelText: 'Base emoji',
                  helperText: 'One emoji only',
                  errorText: emojiError,
                ),
                // Clamp input to a single grapheme cluster (handles ZWJ
                // sequences, skin-tone modifiers, flags, etc. correctly).
                inputFormatters: [const _SingleEmojiFormatter()],
                onChanged: (_) {
                  if (emojiError != null) {
                    setDialogState(() => emojiError = null);
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final text = emojiCtrl.text.trim();
                if (text.isEmpty) {
                  setDialogState(() => emojiError = 'Enter an emoji');
                  return;
                }
                if (text.characters.length != 1) {
                  setDialogState(() => emojiError = 'Use exactly one emoji');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Upload'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final api = context.read<ApiService>();
    final name = nameCtrl.text.trim().isEmpty
        ? 'Custom emoji'
        : nameCtrl.text.trim();
    final emoji = emojiCtrl.text.trim().isEmpty ? '🙂' : emojiCtrl.text.trim();
    setState(() => _loading = true);
    try {
      final bytes = await picked.readAsBytes();
      await api.addCustomEmojiToPack(
        packID: _pack['id'] as String,
        fileBytes: bytes,
        filename: picked.name,
        name: name,
        emoji: emoji,
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    }
  }

  Future<void> _deleteCustomEmoji(String emojiID) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Delete custom emoji?'),
        content: const Text(
          'This custom emoji will be removed from the pack permanently.',
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
      await api.deleteCustomEmojiFromPack(_pack['id'] as String, emojiID);
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
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
      await api.updateCustomEmojiPack(_pack['id'] as String, coverUrl: url);
      await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to set cover: $e')));
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
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Edit Pack'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Pack name'),
              maxLength: _customEmojiPackNameMax,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: descCtrl,
              decoration: const InputDecoration(labelText: 'Description'),
              maxLines: 2,
              maxLength: _customEmojiPackDescriptionMax,
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
                await api.updateCustomEmojiPack(
                  _pack['id'] as String,
                  name: name,
                  description: desc.isEmpty ? null : desc,
                );
                await _reload();
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('Failed to update: $e')));
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
    final emojis = (_pack['custom_emojis'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final coverUrl = _pack['cover_url'] as String?;
    final count = emojis.length;
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
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      isOwner
                          ? '$count custom emoji'
                          : '$count custom emoji · Added from another user',
                      style: TextStyle(color: Colors.grey[600], fontSize: 13),
                    ),
                  ),
                ),
                Expanded(
                  child: emojis.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.add_reaction_outlined,
                                size: 56,
                                color: Colors.grey,
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'No custom emoji yet',
                                style: TextStyle(color: Colors.grey),
                              ),
                              if (isOwner) ...[
                                const SizedBox(height: 8),
                                GlassButtonWidget.icon(
                                  icon: const Icon(Icons.add),
                                  label: const Text('Add custom emoji'),
                                  onPressed: _addCustomEmoji,
                                ),
                              ],
                            ],
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.all(8),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 5,
                                crossAxisSpacing: 6,
                                mainAxisSpacing: 6,
                              ),
                          itemCount: emojis.length,
                          itemBuilder: (context, i) {
                            final emoji = emojis[i];
                            final fileUrl = emoji['file_url'] as String?;
                            return GestureDetector(
                              onLongPress: isOwner
                                  ? () => _deleteCustomEmoji(
                                      emoji['id'] as String,
                                    )
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
                                        ? Padding(
                                            padding: const EdgeInsets.all(8),
                                            child: CachedNetworkImage(
                                              imageUrl: ApiConfig.resolveMedia(
                                                fileUrl,
                                              ),
                                              fit: BoxFit.contain,
                                              errorWidget: (_, _, _) => Center(
                                                child: Text(
                                                  emoji['emoji'] as String? ??
                                                      '🙂',
                                                ),
                                              ),
                                            ),
                                          )
                                        : Center(
                                            child: Text(
                                              emoji['emoji'] as String? ?? '🙂',
                                            ),
                                          ),
                                  ),
                                  if (isOwner)
                                    Positioned(
                                      top: 2,
                                      right: 2,
                                      child: GestureDetector(
                                        onTap: () => _deleteCustomEmoji(
                                          emoji['id'] as String,
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
      floatingActionButton: isOwner
          ? GlassButtonWidget.icon(
              onPressed: _addCustomEmoji,
              icon: const Icon(Icons.add_reaction_outlined),
              label: const Text('Add Custom Emoji'),
            )
          : null,
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Limits a [TextField] to exactly one Unicode grapheme cluster.
///
/// Grapheme clusters correctly handle complex emoji: skin-tone modifier
/// sequences (👋🏽), ZWJ family sequences (👨‍👩‍👧), flag indicators (🇺🇸),
/// and variation-selector forms (❤️) all count as a single character.
class _SingleEmojiFormatter extends TextInputFormatter {
  const _SingleEmojiFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final chars = newValue.text.characters;
    if (chars.length <= 1) return newValue;
    // More than one grapheme cluster — keep only the first.
    final first = chars.first;
    return TextEditingValue(
      text: first,
      selection: TextSelection.collapsed(offset: first.length),
    );
  }
}
