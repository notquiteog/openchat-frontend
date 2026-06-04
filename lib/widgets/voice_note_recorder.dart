import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'glass.dart';

class VoiceNoteRecording {
  final File file;
  final Duration duration;

  const VoiceNoteRecording({required this.file, required this.duration});
}

Future<VoiceNoteRecording?> showVoiceNoteRecorder(BuildContext context) {
  return showModalBottomSheet<VoiceNoteRecording>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const VoiceNoteRecorderSheet(),
  );
}

class VoiceNoteRecorderSheet extends StatefulWidget {
  const VoiceNoteRecorderSheet({super.key});

  @override
  State<VoiceNoteRecorderSheet> createState() => _VoiceNoteRecorderSheetState();
}

class _VoiceNoteRecorderSheetState extends State<VoiceNoteRecorderSheet> {
  final _recorder = AudioRecorder();
  final List<double> _levels = List.filled(18, 0.08);
  Timer? _ticker;
  StreamSubscription<Amplitude>? _amplitudeSub;
  DateTime? _startedAt;
  Duration _elapsed = Duration.zero;
  File? _file;
  bool _recording = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _amplitudeSub?.cancel();
    unawaited(_recorder.dispose());
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      final allowed = await _recorder.hasPermission();
      if (!allowed) {
        if (mounted) {
          setState(() {
            _busy = false;
            _error = 'Microphone permission required';
          });
        }
        return;
      }

      final dir = await getTemporaryDirectory();
      final path = p.join(
        dir.path,
        'openchat_voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1,
          autoGain: true,
          echoCancel: true,
        ),
        path: path,
      );
      _startedAt = DateTime.now();
      _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        final startedAt = _startedAt;
        if (startedAt == null || !mounted) return;
        setState(() => _elapsed = DateTime.now().difference(startedAt));
      });
      _amplitudeSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 120))
          .listen((amp) {
            if (!mounted || !_recording) return;
            final normalized = ((amp.current + 55) / 55).clamp(0.06, 1.0);
            setState(() {
              _levels
                ..removeAt(0)
                ..add(normalized);
            });
          });
      if (mounted) {
        setState(() {
          _busy = false;
          _recording = true;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _recording = false;
          _error = 'Recording unavailable';
        });
      }
    }
  }

  Future<void> _stop() async {
    if (!_recording || _busy) return;
    setState(() => _busy = true);
    try {
      final path = await _recorder.stop();
      _ticker?.cancel();
      await _amplitudeSub?.cancel();
      final file = path == null ? null : File(path);
      if (file == null || !await file.exists() || await file.length() == 0) {
        throw StateError('Empty recording');
      }
      if (mounted) {
        setState(() {
          _file = file;
          _recording = false;
          _busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Recording could not be saved';
        });
      }
    }
  }

  Future<void> _cancel() async {
    _ticker?.cancel();
    await _amplitudeSub?.cancel();
    try {
      if (_recording) {
        await _recorder.cancel();
      }
    } catch (_) {}
    try {
      await _file?.delete();
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  Future<void> _send() async {
    final file = _file;
    if (file == null || _busy) return;
    Navigator.pop(context, VoiceNoteRecording(file: file, duration: _elapsed));
  }

  String _durationLabel(Duration duration) {
    final total = duration.inSeconds;
    final minutes = (total ~/ 60).toString().padLeft(2, '0');
    final seconds = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canSend = _file != null && !_busy;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: GlassContainer(
          shape: LiquidRoundedSuperellipse(borderRadius: 28),
          allowElevation: true,
          glowIntensity: 0.07,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: 116,
                height: 116,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (_recording)
                      _PulseRing(color: scheme.primary.withValues(alpha: 0.26)),
                    Container(
                      width: 74,
                      height: 74,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _recording
                            ? scheme.error.withValues(alpha: 0.92)
                            : scheme.primary,
                        boxShadow: [
                          BoxShadow(
                            color: (_recording ? scheme.error : scheme.primary)
                                .withValues(alpha: 0.28),
                            blurRadius: 28,
                            offset: const Offset(0, 12),
                          ),
                        ],
                      ),
                      child: Icon(
                        _recording ? Icons.mic : Icons.graphic_eq,
                        color: Colors.white,
                        size: 34,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _durationLabel(_elapsed),
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 46,
                child: _Waveform(levels: _levels, color: scheme.primary),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.error),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton.filledTonal(
                    tooltip: 'Cancel',
                    onPressed: _busy ? null : _cancel,
                    icon: const Icon(Icons.close),
                  ),
                  IconButton.filled(
                    tooltip: _recording ? 'Stop' : 'Record',
                    onPressed: _busy
                        ? null
                        : _recording
                        ? _stop
                        : _start,
                    icon: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(_recording ? Icons.stop : Icons.mic),
                  ),
                  IconButton.filled(
                    tooltip: 'Send',
                    onPressed: canSend ? _send : null,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Waveform extends StatelessWidget {
  final List<double> levels;
  final Color color;

  const _Waveform({required this.levels, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (final (index, level) in levels.indexed) ...[
          _WaveBar(
            level: level,
            color: color.withValues(
              alpha: 0.28 + (0.62 * (index + 1) / levels.length),
            ),
          ),
          if (index != levels.length - 1) const SizedBox(width: 4),
        ],
      ],
    );
  }
}

class _WaveBar extends StatelessWidget {
  final double level;
  final Color color;

  const _WaveBar({required this.level, required this.color});

  @override
  Widget build(BuildContext context) {
    final height = 8 + (34 * level);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      width: 5,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

class _PulseRing extends StatefulWidget {
  final Color color;

  const _PulseRing({required this.color});

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final value = _controller.value;
        final size = 92 + (24 * value);
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color.withValues(alpha: 0.28 * (1 - value)),
            border: Border.all(
              color: widget.color.withValues(alpha: 0.4 * (1 - value)),
              width: math.max(1, 2.5 * (1 - value)),
            ),
          ),
        );
      },
    );
  }
}
