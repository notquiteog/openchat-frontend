import 'dart:math' as math;

/// Client mirror of the server's skill-game scoring (see backend
/// store/skill_games.go). The SERVER's computation is the only one that
/// counts — this exists so the play sheet can animate the exact marker the
/// server will score and show live per-attempt feedback.

/// One attempt's marker oscillation, derived server-side from the committed
/// seed: position at tap time t (ms) is sin(2π·(t/period + phase)).
class GamePattern {
  final int periodMs;
  final double phase;

  const GamePattern({required this.periodMs, required this.phase});

  static GamePattern? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final period = (raw['period_ms'] as num?)?.toInt();
    final phase = (raw['phase'] as num?)?.toDouble();
    if (period == null || period <= 0 || phase == null) return null;
    return GamePattern(periodMs: period, phase: phase);
  }

  static List<GamePattern> parseList(Object? raw) {
    if (raw is! List) return const [];
    return raw.map(GamePattern.tryParse).whereType<GamePattern>().toList();
  }
}

/// Marker position in [-1, 1] at [tapMs] since the attempt started.
double skillMarkerPosition(GamePattern pattern, num tapMs) =>
    math.sin(2 * math.pi * (tapMs / pattern.periodMs + pattern.phase));

/// Attempt score 0–100: 100 for stopping the marker dead-center.
int skillAttemptScore(GamePattern pattern, int tapMs) =>
    ((1 - skillMarkerPosition(pattern, tapMs).abs()) * 100).round();

/// Attempts per game: dice plays 5 marker stops, darts 3 throws.
int skillGameAttempts(String gameType) => switch (gameType) {
  '🎲' => 5,
  '🎯' => 3,
  _ => 0,
};

/// Display name for a skill game type.
String skillGameName(String gameType) => switch (gameType) {
  '🎲' => 'Dice',
  '🎯' => 'Darts',
  _ => 'Game',
};
