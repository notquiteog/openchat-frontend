import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/utils/skill_game.dart';

// Mirrors the server fixture in backend store/skill_games_test.go
// (TestScoreGameTapsFixture): the client preview must score exactly what the
// server computes, or the play sheet would animate a different game than the
// one being judged.
void main() {
  const pattern = GamePattern(periodMs: 1000, phase: 0.25);

  test('marker position and score match the server fixture', () {
    // position(t) = sin(2π·(t/1000 + 0.25)):
    //   t=0   → 1  → score 0
    //   t=250 → 0  → score 100
    //   t=500 → −1 → score 0
    expect(skillMarkerPosition(pattern, 0), closeTo(1, 1e-9));
    expect(skillMarkerPosition(pattern, 250), closeTo(0, 1e-9));
    expect(skillMarkerPosition(pattern, 500), closeTo(-1, 1e-9));

    expect(skillAttemptScore(pattern, 0), 0);
    expect(skillAttemptScore(pattern, 250), 100);
    expect(skillAttemptScore(pattern, 500), 0);
  });

  test('attempts per game match the server', () {
    expect(skillGameAttempts('🎲'), 5);
    expect(skillGameAttempts('🎯'), 3);
    // The removed chance variants are not skill games.
    for (final gone in ['🏀', '⚽', '🎳', '🎰', '🪙']) {
      expect(skillGameAttempts(gone), 0);
    }
  });

  test('patterns parse from the my_patterns wire shape', () {
    final patterns = GamePattern.parseList([
      {'period_ms': 900, 'phase': 0.5},
      {'period_ms': 1200, 'phase': 0.125},
      {'bogus': true},
    ]);
    expect(patterns, hasLength(2));
    expect(patterns.first.periodMs, 900);
    expect(patterns.last.phase, 0.125);
    expect(GamePattern.parseList(null), isEmpty);
  });
}
