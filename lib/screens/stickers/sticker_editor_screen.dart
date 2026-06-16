import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/segmentation_service.dart';
import '../../widgets/glass.dart';

/// Create a sticker from a photo: pick → crop → (optional) background removal →
/// upload to [packId] (Batch 6.1). The backend converts the upload to WebP.
class StickerEditorScreen extends StatefulWidget {
  final String packId;
  const StickerEditorScreen({super.key, required this.packId});

  @override
  State<StickerEditorScreen> createState() => _StickerEditorScreenState();
}

class _StickerEditorScreenState extends State<StickerEditorScreen> {
  final _picker = ImagePicker();
  final _nameCtrl = TextEditingController();
  Uint8List? _bytes;
  bool _busy = false;
  bool _bgRemoved = false;
  // First-run u2netp download progress (0..1); null when not downloading.
  double? _modelDownloadProgress;
  StreamSubscription<double>? _modelDownloadSub;

  @override
  void dispose() {
    _modelDownloadSub?.cancel();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAndCrop() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop sticker',
          lockAspectRatio: true,
          hideBottomControls: false,
        ),
        IOSUiSettings(title: 'Crop sticker', aspectRatioLockEnabled: true),
      ],
    );
    final bytes = cropped != null
        ? await cropped.readAsBytes()
        : await picked.readAsBytes();
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _bgRemoved = false;
    });
  }

  Future<void> _removeBackground() async {
    final bytes = _bytes;
    if (bytes == null) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    // The segmentation model is fetched on demand — warn about the one-time
    // download and surface its progress on the button label.
    final modelCached = await SegmentationService.isModelCached();
    if (!mounted) return;
    if (SegmentationService.isSupported && !modelCached) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Downloading AI model (one-time, ~5MB)…')),
      );
      _modelDownloadSub = SegmentationService.downloadProgress.listen((p) {
        if (mounted) setState(() => _modelDownloadProgress = p);
      });
    }
    try {
      final result = await SegmentationService.removeBackgroundOrThrow(bytes);
      if (!mounted) return;
      setState(() {
        _bytes = result;
        _bgRemoved = true;
      });
    } on SegmentationException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Background removal failed: ${e.message}')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Background removal failed: $e')),
      );
    } finally {
      await _modelDownloadSub?.cancel();
      _modelDownloadSub = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _modelDownloadProgress = null;
        });
      }
    }
  }

  Future<void> _upload() async {
    final bytes = _bytes;
    final name = _nameCtrl.text.trim();
    if (bytes == null || name.isEmpty) return;
    setState(() => _busy = true);
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await api.addStickerToPack(
        packID: widget.packId,
        fileBytes: bytes,
        filename: _bgRemoved ? 'sticker.png' : 'sticker.jpg',
        name: name,
      );
      messenger.showSnackBar(const SnackBar(content: Text('Sticker added')));
      navigator.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        messenger.showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Create sticker')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
          16,
          16,
        ),
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: _bytes == null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.add_photo_alternate_outlined,
                            size: 56,
                            color: scheme.onSurface.withValues(alpha: 0.4),
                          ),
                          const SizedBox(height: 8),
                          const Text('Pick a photo to start'),
                        ],
                      ),
                    )
                  : Image.memory(_bytes!, fit: BoxFit.contain),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              GlassButtonWidget.icon(
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(_bytes == null ? 'Pick & crop' : 'Replace'),
                onPressed: _busy ? null : _pickAndCrop,
              ),
              if (_bytes != null)
                GlassButtonWidget.icon(
                  icon: _busy
                      ? const GlassProgressIndicator.circular(
                          size: 16,
                          strokeWidth: 2,
                        )
                      : const Icon(Icons.auto_fix_high_rounded),
                  label: Text(
                    _bgRemoved
                        ? 'Background removed'
                        : _modelDownloadProgress != null
                        ? 'Downloading model… ${(_modelDownloadProgress! * 100).round()}%'
                        : 'Remove background',
                  ),
                  onPressed: _busy || _bgRemoved ? null : _removeBackground,
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Sticker name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          GlassButtonWidget(
            onPressed: (_bytes != null && !_busy) ? _upload : null,
            child: const Text('Add to pack'),
          ),
        ],
      ),
    );
  }
}
