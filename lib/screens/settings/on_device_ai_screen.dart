import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/segmentation_service.dart';
import '../../services/transcription_service.dart';
import '../../services/translation_service.dart';
import '../../widgets/glass.dart';

/// Settings → On-device intelligence: download/delete the local AI models
/// (Whisper transcription, ML Kit translation packs, sticker background
/// removal) and see their disk footprint. Everything these models do runs
/// locally — the only network traffic is the explicit model download itself.
class OnDeviceAiScreen extends StatefulWidget {
  const OnDeviceAiScreen({super.key});

  @override
  State<OnDeviceAiScreen> createState() => _OnDeviceAiScreenState();
}

class _OnDeviceAiScreenState extends State<OnDeviceAiScreen> {
  bool _asrCached = false;
  int _asrBytes = 0;
  bool _asrBusy = false;
  double? _asrProgress;
  StreamSubscription<double>? _asrProgressSub;

  bool _segCached = false;
  int _segBytes = 0;

  final Map<TranslateLanguage, bool> _packState = {};
  final Set<TranslateLanguage> _packBusy = {};

  @override
  void initState() {
    super.initState();
    _refresh();
    _asrProgressSub = TranscriptionService.downloadProgress.listen((p) {
      if (mounted && _asrBusy) setState(() => _asrProgress = p);
    });
  }

  @override
  void dispose() {
    _asrProgressSub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final asrCached = await TranscriptionService.isModelCached();
    final asrBytes = await TranscriptionService.cachedModelSizeBytes();
    final segCached = await SegmentationService.isModelCached();
    final segBytes = await SegmentationService.cachedModelSizeBytes();
    if (TranslationService.isSupported) {
      for (final lang in TranslationService.offeredLanguages) {
        final downloaded = await TranslationService.isLanguageDownloaded(lang);
        if (!mounted) return;
        setState(() => _packState[lang] = downloaded);
      }
    }
    if (!mounted) return;
    setState(() {
      _asrCached = asrCached;
      _asrBytes = asrBytes;
      _segCached = segCached;
      _segBytes = segBytes;
    });
  }

  Future<void> _downloadAsr() async {
    setState(() {
      _asrBusy = true;
      _asrProgress = 0;
    });
    try {
      await TranscriptionService.ensureModel();
    } catch (e) {
      if (mounted) showAppToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _asrBusy = false;
          _asrProgress = null;
        });
        await _refresh();
      }
    }
  }

  Future<void> _deleteAsr() async {
    await TranscriptionService.deleteModel();
    await _refresh();
  }

  Future<void> _togglePack(TranslateLanguage lang, bool downloaded) async {
    setState(() => _packBusy.add(lang));
    try {
      if (downloaded) {
        await TranslationService.deleteLanguage(lang);
      } else {
        await TranslationService.ensureLanguage(lang);
      }
    } catch (e) {
      if (mounted) showAppToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) {
        setState(() => _packBusy.remove(lang));
        final nowDownloaded = await TranslationService.isLanguageDownloaded(
          lang,
        );
        if (mounted) setState(() => _packState[lang] = nowDownloaded);
      }
    }
  }

  String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  String _languageLabel(TranslateLanguage lang) {
    final name = lang.name;
    return name[0].toUpperCase() + name.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w700,
    );
    return GlassScreenScaffold.list(
      title: const Text('On-device intelligence'),
      children: [
          Text(
            'These models run entirely on this device. Audio and text never '
            'leave it — the only network use is the model download itself.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
          const SizedBox(height: 16),
          Text('Voice transcription', style: titleStyle),
          const SizedBox(height: 6),
          GlassListTile(
            leading: const Icon(Icons.subtitles_outlined),
            title: const Text('Whisper tiny (multilingual)'),
            subtitle: Text(
              !TranscriptionService.isSupported
                  ? 'Not supported on this platform'
                  : _asrBusy
                  ? 'Downloading ${((_asrProgress ?? 0) * 100).round()}%'
                  : _asrCached
                  ? 'Downloaded · ${_mb(_asrBytes)}'
                  : 'Not downloaded · ~90 MB',
            ),
            trailing: !TranscriptionService.isSupported
                ? null
                : _asrBusy
                ? GlassProgressIndicator.circular(size: 18)
                : _asrCached
                ? IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: _deleteAsr,
                  )
                : IconButton(
                    icon: const Icon(Icons.download_rounded),
                    onPressed: _downloadAsr,
                  ),
          ),
          const SizedBox(height: 20),
          Text('Sticker background removal', style: titleStyle),
          const SizedBox(height: 6),
          GlassListTile(
            leading: const Icon(Icons.auto_fix_high_rounded),
            title: const Text('u2netp segmentation'),
            subtitle: Text(
              !SegmentationService.isSupported
                  ? 'Not supported on this platform'
                  : _segCached
                  ? 'Downloaded · ${_mb(_segBytes)}'
                  : 'Not downloaded · ~5 MB (fetched when first used)',
            ),
            trailing: _segCached
                ? IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () async {
                      await SegmentationService.deleteModel();
                      await _refresh();
                    },
                  )
                : null,
          ),
          const SizedBox(height: 20),
          Text('Translation packs', style: titleStyle),
          const SizedBox(height: 6),
          if (!TranslationService.isSupported)
            GlassListTile(
              leading: const Icon(Icons.translate_rounded),
              title: const Text('On-device translation'),
              subtitle: const Text('Available on Android and iOS only'),
            )
          else
            for (final lang in TranslationService.offeredLanguages)
              GlassListTile(
                leading: const Icon(Icons.translate_rounded),
                title: Text(_languageLabel(lang)),
                subtitle: Text(
                  _packState[lang] == true
                      ? 'Downloaded'
                      : 'Not downloaded · ~30 MB',
                ),
                trailing: _packBusy.contains(lang)
                    ? GlassProgressIndicator.circular(size: 18)
                    : IconButton(
                        icon: Icon(
                          _packState[lang] == true
                              ? Icons.delete_outline_rounded
                              : Icons.download_rounded,
                        ),
                        onPressed: () =>
                            _togglePack(lang, _packState[lang] == true),
                      ),
              ),
        ],
    );
  }
}
