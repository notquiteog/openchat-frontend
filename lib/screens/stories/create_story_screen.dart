import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../../crypto/pgp_service.dart';
import '../../models/message.dart';
import '../../models/user.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/attachment_service.dart';
import '../../services/secure_storage_service.dart';
import '../../widgets/glass.dart';

class _StoryEncryptException implements Exception {
  final String message;
  const _StoryEncryptException(this.message);
}

class CreateStoryScreen extends StatefulWidget {
  const CreateStoryScreen({super.key});

  @override
  State<CreateStoryScreen> createState() => _CreateStoryScreenState();
}

class _CreateStoryScreenState extends State<CreateStoryScreen> {
  final _captionCtrl = TextEditingController();
  PendingAttachment? _pending;
  VideoPlayerController? _videoPreview;
  String _privacy = 'contacts';
  int _durationSeconds = 24 * 60 * 60;
  bool _posting = false;
  String? _error;

  @override
  void dispose() {
    _captionCtrl.dispose();
    _videoPreview?.dispose();
    super.dispose();
  }

  /// Builds a muted, looping preview controller for a picked video so the
  /// composer shows the real footage instead of a placeholder icon.
  Future<void> _setPreviewFor(PendingAttachment pending) async {
    await _videoPreview?.dispose();
    _videoPreview = null;
    final path = pending.previewPath;
    if (pending.messageType != MessageType.video || path == null) return;
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.play();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _videoPreview = controller);
    } catch (_) {
      await controller.dispose();
    }
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
        await _setPreviewFor(pending);
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
      final api = context.read<ApiService>();
      final privacy = _privacy == 'close_friends' ? 'selected' : _privacy;
      final allowUserIds = _privacy == 'close_friends'
          ? closeFriends
          : const <String>[];
      final caption = _captionCtrl.text.trim();

      if (privacy == 'public') {
        // Public stories have no fixed audience to encrypt to — the legacy
        // plaintext-metadata path is inherent to "anyone can view".
        await api.createStory(
          attachmentId: pending.attachmentId,
          fileName: pending.fileName,
          fileSize: pending.fileSize,
          mimeType: pending.mimeType,
          fileKey: pending.fileKey,
          fileNonce: pending.fileNonce,
          mediaType: mediaType,
          caption: caption,
          privacy: privacy,
          expiresInSeconds: _durationSeconds,
        );
      } else {
        // Private audience: the media key, nonce, caption, filename, and MIME
        // type travel inside a PGP envelope encrypted to the viewers — the
        // server must not be able to decrypt story media (the attachment
        // pipeline's documented invariant).
        final encryptedMeta = await _encryptStoryMeta(
          fileKey: pending.fileKey,
          fileNonce: pending.fileNonce,
          fileName: pending.fileName,
          mimeType: pending.mimeType,
          caption: caption,
          audienceUserIds: privacy == 'selected' ? allowUserIds : null,
        );
        await api.createStory(
          attachmentId: pending.attachmentId,
          fileSize: pending.fileSize,
          mediaType: mediaType,
          encryptedPayload: encryptedMeta,
          privacy: privacy,
          allowUserIds: allowUserIds,
          expiresInSeconds: _durationSeconds,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } on _StoryEncryptException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not publish story.');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  /// Encrypts the story metadata to the audience's PGP keys (plus our own so
  /// we can re-view it). [audienceUserIds] null = all DM contacts.
  Future<String> _encryptStoryMeta({
    required String fileKey,
    required String fileNonce,
    required String fileName,
    required String mimeType,
    required String caption,
    List<String>? audienceUserIds,
  }) async {
    final api = context.read<ApiService>();
    final storage = context.read<SecureStorageService>();
    final me = context.read<AuthProvider>().currentUser?.id ?? '';
    final chat = context.read<ChatProvider>();

    final privateKey = await storage.getPrivateKeyIfUnlocked() ?? '';
    final ownPublicKey = await storage.getPublicKey() ?? '';
    final ownFingerprint = await storage.getFingerprint() ?? '';
    if (privateKey.isEmpty || ownPublicKey.isEmpty) {
      throw const _StoryEncryptException(
        'Unlock your PGP key in Settings to post a private story.',
      );
    }

    var audience = audienceUserIds;
    if (audience == null) {
      final seen = <String>{};
      audience = <String>[];
      for (final c in chat.conversations.where((c) => c.isDM)) {
        final u = c.otherUser(me);
        if (u != null && seen.add(u.id)) audience.add(u.id);
      }
    }

    final recipients = <PgpRecipient>[
      if (me.isNotEmpty && ownFingerprint.isNotEmpty)
        PgpRecipient(
          userId: me,
          publicKeyArmored: ownPublicKey,
          keyFingerprint: ownFingerprint,
        ),
    ];
    for (final userId in audience) {
      try {
        final key = await api.getRecentUserPublicKeyEntry(userId);
        if (key != null && key.publicKey.trim().isNotEmpty) {
          recipients.add(
            PgpRecipient(
              userId: userId,
              publicKeyArmored: key.publicKey,
              keyFingerprint: key.fingerprint,
            ),
          );
        }
      } catch (_) {
        // A viewer whose key can't be fetched simply can't decrypt this
        // story — better than blocking the post or downgrading to plaintext.
      }
    }
    if (recipients.isEmpty) {
      throw const _StoryEncryptException(
        'No viewers with available keys — story not posted.',
      );
    }

    return PgpService.encrypt(
      plaintext: jsonEncode({
        'openchat_story_meta': 1,
        'file_key': fileKey,
        'file_nonce': fileNonce,
        'file_name': fileName,
        'mime_type': mimeType,
        'caption': caption,
      }),
      recipients: recipients,
      signingPrivateKeyArmored: privateKey,
    );
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

  int get _privacyIndex => switch (_privacy) {
    'close_friends' => 1,
    'public' => 2,
    _ => 0,
  };

  void _onPrivacy(int index) {
    if (_posting) return;
    final v = const ['contacts', 'close_friends', 'public'][index];
    setState(() => _privacy = v);
    if (v == 'close_friends') _pickCloseFriends();
  }

  Future<void> _showReplaceSheet() async {
    await showGlassActionSheet<void>(
      context: context,
      title: 'Change media',
      actions: [
        GlassActionSheetAction(
          label: 'Photo',
          icon: const Icon(Icons.image_outlined),
          onPressed: _pickImage,
        ),
        GlassActionSheetAction(
          label: 'Video',
          icon: const Icon(Icons.videocam_outlined),
          onPressed: _pickVideo,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    final hasMedia = pending != null;
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: _buildBackground(pending)),
          // Legibility scrim behind the top bar and bottom controls.
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x99000000),
                      Color(0x00000000),
                      Color(0x33000000),
                      Color(0xD9000000),
                    ],
                    stops: [0.0, 0.2, 0.45, 1.0],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 12, 0),
              child: Row(
                children: [
                  GlassCircleIconButton(
                    tooltip: 'Close',
                    size: 40,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'New story',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                    ),
                  ),
                  const Spacer(),
                  if (hasMedia)
                    GlassButtonWidget.icon(
                      onPressed: _posting ? null : _showReplaceSheet,
                      icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                      label: const Text('Change'),
                    ),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: _buildControls(pending),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackground(PendingAttachment? pending) {
    if (pending == null) {
      return _EmptyPicker(
        busy: _posting,
        onPickImage: _pickImage,
        onPickVideo: _pickVideo,
      );
    }
    if (pending.messageType == MessageType.video) {
      final c = _videoPreview;
      if (c != null && c.value.isInitialized) {
        return FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: c.value.size.width,
            height: c.value.size.height,
            child: VideoPlayer(c),
          ),
        );
      }
      return const ColoredBox(
        color: Color(0xFF101012),
        child: Center(
          child: Icon(
            Icons.movie_creation_outlined,
            color: Colors.white54,
            size: 64,
          ),
        ),
      );
    }
    final path = pending.previewPath;
    if (path != null) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const ColoredBox(color: Color(0xFF101012)),
      );
    }
    return const ColoredBox(color: Color(0xFF101012));
  }

  Widget _buildControls(PendingAttachment? pending) {
    final closeFriends = context
        .watch<SettingsProvider>()
        .closeFriendIds
        .length;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.62,
      ),
      child: SingleChildScrollView(
        reverse: true,
        padding: EdgeInsets.fromLTRB(
          12,
          0,
          12,
          12 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 28),
          allowElevation: true,
          glowIntensity: 0.06,
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CaptionField(controller: _captionCtrl),
              const SizedBox(height: 14),
              _label('Who can see this'),
              const SizedBox(height: 8),
              GlassSegmentedControl(
                segments: const ['Contacts', 'Close', 'Public'],
                selectedIndex: _privacyIndex,
                onSegmentSelected: _onPrivacy,
              ),
              if (_privacy == 'close_friends')
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$closeFriends close ${closeFriends == 1 ? 'friend' : 'friends'}',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                      GlassButtonWidget(
                        onPressed: _pickCloseFriends,
                        child: const Text('Edit'),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 14),
              _label('Disappears after'),
              const SizedBox(height: 8),
              GlassSegmentedControl(
                segments: const ['6h', '12h', '24h', '48h'],
                selectedIndex: switch (_durationSeconds) {
                  const (6 * 60 * 60) => 0,
                  const (12 * 60 * 60) => 1,
                  const (48 * 60 * 60) => 3,
                  _ => 2,
                },
                onSegmentSelected: (index) {
                  if (_posting) return;
                  setState(() {
                    _durationSeconds = const [
                      6 * 60 * 60,
                      12 * 60 * 60,
                      24 * 60 * 60,
                      48 * 60 * 60,
                    ][index];
                  });
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Color(0xFFFF6B6B))),
              ],
              const SizedBox(height: 16),
              GlassButtonWidget.icon(
                onPressed: pending == null || _posting ? null : _publish,
                icon: _posting
                    ? const GlassProgressIndicator.circular(
                        size: 18,
                        strokeWidth: 2,
                      )
                    : const Icon(Icons.send_rounded),
                label: Text(_posting ? 'Publishing…' : 'Share story'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
    ),
  );
}

/// Empty state: a glass card prompting the user to add a photo or video.
class _EmptyPicker extends StatelessWidget {
  final bool busy;
  final VoidCallback onPickImage;
  final VoidCallback onPickVideo;

  const _EmptyPicker({
    required this.busy,
    required this.onPickImage,
    required this.onPickVideo,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1A1B22), Color(0xFF0B0B0E)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.auto_awesome_motion_outlined,
              color: Colors.white38,
              size: 56,
            ),
            const SizedBox(height: 14),
            const Text(
              'Share a moment',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Pick a photo or video for your story',
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
            const SizedBox(height: 20),
            Wrap(
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
          ],
        ),
      ),
    );
  }
}

/// Caption input styled for the dark glass composer.
class _CaptionField extends StatelessWidget {
  final TextEditingController controller;

  const _CaptionField({required this.controller});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: 3,
      minLines: 1,
      style: const TextStyle(color: Colors.white),
      cursorColor: Colors.white,
      decoration: InputDecoration(
        hintText: 'Add a caption…',
        hintStyle: const TextStyle(color: Colors.white54),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.08),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
