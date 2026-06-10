import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../utils/skill_game.dart';
import 'glass.dart';

/// The skill minigame: a marker sweeps across a track following the player's
/// seed-derived pattern (sin(2π·(t/period + phase))); tapping stops it, and
/// stopping dead-center scores 100. One round per pattern (dice 5, darts 3).
///
/// Returns the tap offsets (ms per attempt, in the marker's own timebase) for
/// submission — the SERVER recomputes the score from the same patterns, so
/// the numbers shown here are previews. Returns null if dismissed mid-game
/// (nothing is submitted; the player can try again while the window is open).
Future<List<int>?> showGamePlaySheet(
  BuildContext context, {
  required String gameType,
  required List<GamePattern> patterns,
}) {
  return showModalBottomSheet<List<int>>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    builder: (_) => _GamePlaySheet(gameType: gameType, patterns: patterns),
  );
}

class _GamePlaySheet extends StatefulWidget {
  const _GamePlaySheet({required this.gameType, required this.patterns});

  final String gameType;
  final List<GamePattern> patterns;

  @override
  State<_GamePlaySheet> createState() => _GamePlaySheetState();
}

class _GamePlaySheetState extends State<_GamePlaySheet>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _elapsedMs = 0;
  double _attemptStartMs = 0;
  int _attempt = 0;
  final List<int> _taps = [];
  int? _lastScore;
  bool _betweenAttempts = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() => _elapsedMs = elapsed.inMicroseconds / 1000.0);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _tap() {
    if (_betweenAttempts || _attempt >= widget.patterns.length) return;
    final tapMs = (_elapsedMs - _attemptStartMs).round();
    final pattern = widget.patterns[_attempt];
    _taps.add(tapMs);
    _lastScore = skillAttemptScore(pattern, tapMs);
    _betweenAttempts = true;
    setState(() {});
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      setState(() {
        _attempt += 1;
        _attemptStartMs = _elapsedMs;
        _betweenAttempts = false;
      });
      if (_attempt >= widget.patterns.length) {
        Navigator.of(context).pop(List<int>.of(_taps));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = widget.patterns.length;
    final done = _attempt >= total;
    final current = done ? null : widget.patterns[_attempt];
    final position = current == null || _betweenAttempts
        ? (_taps.isEmpty
              ? 0.0
              : skillMarkerPosition(
                  widget.patterns[_taps.length - 1],
                  _taps.last,
                ))
        : skillMarkerPosition(current, _elapsedMs - _attemptStartMs);
    final previewTotal = [
      for (var i = 0; i < _taps.length; i++)
        skillAttemptScore(widget.patterns[i], _taps[i]),
    ].fold<int>(0, (a, b) => a + b);

    return GlassBottomSheetFrame(
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const GlassSheetGrabber(),
              Row(
                children: [
                  Text(
                    widget.gameType,
                    style: const TextStyle(fontSize: 26),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${skillGameName(widget.gameType)} — '
                      '${widget.gameType == '🎯' ? 'throw' : 'stop'} '
                      '${(_attempt + 1).clamp(1, total)} of $total',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    '$previewTotal',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Tap when the marker crosses the center line.',
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 18),
              GestureDetector(
                key: const Key('game-play-area'),
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => _tap(),
                child: SizedBox(
                  height: 150,
                  width: double.infinity,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _MarkerTrack(position: position, scheme: scheme),
                      const SizedBox(height: 18),
                      SizedBox(
                        height: 34,
                        child: _betweenAttempts && _lastScore != null
                            ? Text(
                                _lastScore! >= 90
                                    ? '$_lastScore — perfect!'
                                    : _lastScore! >= 60
                                    ? '$_lastScore — nice'
                                    : '$_lastScore',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  color: _lastScore! >= 60
                                      ? scheme.primary
                                      : scheme.onSurface.withValues(
                                          alpha: 0.7,
                                        ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Forfeit for now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MarkerTrack extends StatelessWidget {
  const _MarkerTrack({required this.position, required this.scheme});

  /// Marker position in [-1, 1]; 0 is the scoring center.
  final double position;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        const markerSize = 26.0;
        final x = (position + 1) / 2 * (width - markerSize);
        return SizedBox(
          height: 56,
          child: Stack(
            children: [
              // Track
              Positioned(
                left: 0,
                right: 0,
                top: 24,
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: scheme.onSurface.withValues(alpha: 0.10),
                  ),
                ),
              ),
              // Center target zone
              Positioned(
                left: width / 2 - 14,
                top: 16,
                child: Container(
                  width: 28,
                  height: 24,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: scheme.primary.withValues(alpha: 0.18),
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ),
              // Marker
              Positioned(
                left: x,
                top: 15,
                child: Container(
                  width: markerSize,
                  height: markerSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.primary,
                    boxShadow: [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.45),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
