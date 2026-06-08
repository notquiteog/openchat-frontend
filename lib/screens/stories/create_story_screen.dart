import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/message.dart';
import '../../models/user.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/attachment_service.dart';
import '../../widgets/glass.dart';

class CreateStoryScreen extends StatefulWidget {
  const CreateStoryScreen({super.key});

  @override
  State<CreateStoryScreen> createState() => _CreateStoryScreenState();
}

class _CreateStoryScreenState extends State<CreateStoryScreen> {
  final _captionCtrl = TextEditingController();
  PendingAttachment? _pending;
  String _privacy = 'contacts';
  int _durationSeconds = 24 * 60 * 60;
  bool _posting = false;
  String? _error;

  @override
  void dispose() {
    _captionCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    await _pick((svc) => svc.pickImage());
  }

  Future<void> _pickVideo() async {
    await _pick((svc) => svc.pickVideo());
  }

  Future<void> _pick(
    Future<PendingAttachment?> Function(AttachmentService svc) picker,
  ) async {
    setState(() {
      _posting = true;
      _error = null;
    });
    try {
      final pending = await picker(
        AttachmentService(context.read<ApiService>()),
      );
      if (!mounted) return;
      if (pending != null) {
        setState(() => _pending = pending);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not prepare story media.');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _publish() async {
    final pending = _pending;
    if (pending == null || _posting) return;
    setState(() {
      _posting = true;
      _error = null;
    });
    try {
      final mediaType = pending.messageType == MessageType.video
          ? 'video'
          : pending.messageType == MessageType.file
          ? 'file'
          : 'image';
      final closeFriends = context
          .read<SettingsProvider>()
          .closeFriendIds
          .toList();
      if (_privacy == 'close_friends' && closeFriends.isEmpty) {
        setState(() {
          _posting = false;
          _error = 'Add close friends first.';
        });
        return;
      }
      await context.read<ApiService>().createStory(
        attachmentId: pending.attachmentId,
        fileName: pending.fileName,
        fileSize: pending.fileSize,
        mimeType: pending.mimeType,
        fileKey: pending.fileKey,
        fileNonce: pending.fileNonce,
        mediaType: mediaType,
        caption: _captionCtrl.text.trim(),
        privacy: _privacy == 'close_friends' ? 'selected' : _privacy,
        allowUserIds: _privacy == 'close_friends' ? closeFriends : const [],
        expiresInSeconds: _durationSeconds,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not publish story.');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _pickCloseFriends() async {
    final me = context.read<AuthProvider>().currentUser?.id ?? '';
    final chat = context.read<ChatProvider>();
    final settings = context.read<SettingsProvider>();
    final contacts = <User>[];
    final seen = <String>{};
    for (final c in chat.conversations.where((c) => c.isDM)) {
      final u = c.otherUser(me);
      if (u != null && seen.add(u.id)) contacts.add(u);
    }
    final selected = <String>{...settings.closeFriendIds};
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => GlassBottomSheetFrame(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const GlassSheetGrabber(),
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Close friends',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
              if (contacts.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Start a DM with someone first to add them.'),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final u in contacts)
                        CheckboxListTile(
                          value: selected.contains(u.id),
                          onChanged: (v) => setSheet(() {
                            if (v == true) {
                              selected.add(u.id);
                            } else {
                              selected.remove(u.id);
                            }
                          }),
                          title: Text(u.displayName),
                          subtitle: Text('@${u.username}'),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: GlassButtonWidget(
                  onPressed: () => Navigator.pop(sheetCtx),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await settings.setCloseFriends(selected);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = _pending;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('New story')),
      body: ListView(
          padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + kToolbarHeight + 16, 16, MediaQuery.paddingOf(context).bottom + 16),
          children: [
            AspectRatio(
              aspectRatio: 9 / 16,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.dividerColor),
                ),
                child: pending == null
                    ? _PickPanel(
                        busy: _posting,
                        onPickImage: _pickImage,
                        onPickVideo: _pickVideo,
                      )
                    : _SelectedMediaPanel(
                        pending: pending,
                        onReplaceImage: _posting ? null : _pickImage,
                        onReplaceVideo: _posting ? null : _pickVideo,
                      ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _captionCtrl,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                labelText: 'Caption',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'contacts',
                  icon: Icon(Icons.group_outlined),
                  label: Text('Contacts'),
                ),
                ButtonSegment(
                  value: 'close_friends',
                  icon: Icon(Icons.star_outline_rounded),
                  label: Text('Close'),
                ),
                ButtonSegment(
                  value: 'public',
                  icon: Icon(Icons.public),
                  label: Text('Public'),
                ),
              ],
              selected: {_privacy},
              onSelectionChanged: _posting
                  ? null
                  : (value) {
                      final v = value.first;
                      setState(() => _privacy = v);
                      if (v == 'close_friends') _pickCloseFriends();
                    },
            ),
            if (_privacy == 'close_friends')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Text(
                      '${context.watch<SettingsProvider>().closeFriendIds.length} close friends',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _pickCloseFriends,
                      child: const Text('Edit'),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _durationSeconds,
              decoration: const InputDecoration(
                labelText: 'Visible for',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 6 * 60 * 60, child: Text('6 hours')),
                DropdownMenuItem(value: 12 * 60 * 60, child: Text('12 hours')),
                DropdownMenuItem(value: 24 * 60 * 60, child: Text('24 hours')),
                DropdownMenuItem(value: 48 * 60 * 60, child: Text('48 hours')),
              ],
              onChanged: _posting || pending == null
                  ? null
                  : (value) => setState(() {
                      if (value != null) _durationSeconds = value;
                    }),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 20),
            GlassButtonWidget.icon(
              onPressed: pending == null || _posting ? null : _publish,
              icon: _posting
                  ? const GlassProgressIndicator.circular(size: 18, strokeWidth: 2)
                  : const Icon(Icons.send_outlined),
              label: Text(_posting ? 'Publishing' : 'Publish story'),
            ),
          ],
        ),
    );
  }
}

class _PickPanel extends StatelessWidget {
  final bool busy;
  final VoidCallback onPickImage;
  final VoidCallback onPickVideo;

  const _PickPanel({
    required this.busy,
    required this.onPickImage,
    required this.onPickVideo,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        alignment: WrapAlignment.center,
        children: [
          GlassButtonWidget.icon(
            onPressed: busy ? null : onPickImage,
            icon: const Icon(Icons.image_outlined),
            label: const Text('Photo'),
          ),
          GlassButtonWidget.icon(
            onPressed: busy ? null : onPickVideo,
            icon: const Icon(Icons.videocam_outlined),
            label: const Text('Video'),
          ),
        ],
      ),
    );
  }
}

class _SelectedMediaPanel extends StatelessWidget {
  final PendingAttachment pending;
  final VoidCallback? onReplaceImage;
  final VoidCallback? onReplaceVideo;

  const _SelectedMediaPanel({
    required this.pending,
    this.onReplaceImage,
    this.onReplaceVideo,
  });

  @override
  Widget build(BuildContext context) {
    final isVideo = pending.messageType == MessageType.video;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(isVideo ? Icons.movie_outlined : Icons.image_outlined, size: 72),
          const SizedBox(height: 16),
          Text(
            pending.fileName,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(pending.mimeType, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            children: [
              GlassButtonWidget.icon(
                onPressed: onReplaceImage,
                icon: const Icon(Icons.image_outlined),
                label: const Text('Replace photo'),
              ),
              GlassButtonWidget.icon(
                onPressed: onReplaceVideo,
                icon: const Icon(Icons.videocam_outlined),
                label: const Text('Replace video'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
