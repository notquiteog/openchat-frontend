import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/crypto/shamir.dart';

/// Shamir over GF(256): exact reconstruction from any threshold-sized subset,
/// nothing from below-threshold subsets, deterministic vectors under a seeded
/// RNG, and defensive share validation. Social key recovery stands on this.
void main() {
  final secret = Uint8List.fromList(
    List<int>.generate(32, (i) => (i * 37 + 11) & 0xFF),
  );

  test('split/combine round-trips for 3-of-5', () {
    final shares = Shamir.split(secret, shares: 5, threshold: 3);
    expect(shares, hasLength(5));
    for (final share in shares) {
      expect(share.length, secret.length + 1);
    }
    expect(Shamir.combine(shares.sublist(0, 3)), equals(secret));
  });

  test('every threshold-sized subset reconstructs', () {
    final shares = Shamir.split(secret, shares: 5, threshold: 3);
    // All C(5,3)=10 subsets.
    for (var a = 0; a < 5; a++) {
      for (var b = a + 1; b < 5; b++) {
        for (var c = b + 1; c < 5; c++) {
          expect(
            Shamir.combine([shares[a], shares[b], shares[c]]),
            equals(secret),
            reason: 'subset ($a,$b,$c)',
          );
        }
      }
    }
  });

  test('share order does not matter', () {
    final shares = Shamir.split(secret, shares: 4, threshold: 4);
    expect(
      Shamir.combine([shares[3], shares[0], shares[2], shares[1]]),
      equals(secret),
    );
  });

  test('below-threshold subsets yield garbage, not the secret', () {
    final shares = Shamir.split(secret, shares: 5, threshold: 3);
    final two = Shamir.combine(shares.sublist(0, 2));
    expect(two, isNot(equals(secret)));
  });

  test('2-of-2 works (smallest valid configuration)', () {
    final shares = Shamir.split(secret, shares: 2, threshold: 2);
    expect(Shamir.combine(shares), equals(secret));
  });

  test('deterministic under a seeded RNG (regression vector)', () {
    final shares = Shamir.split(
      Uint8List.fromList([1, 2, 3, 4]),
      shares: 3,
      threshold: 2,
      random: Random(42),
    );
    // Pin the construction: x-coordinates 1..n appended last.
    expect(shares[0].last, 1);
    expect(shares[1].last, 2);
    expect(shares[2].last, 3);
    expect(Shamir.combine([shares[0], shares[2]]),
        equals(Uint8List.fromList([1, 2, 3, 4])));
    // Same seed → identical shares (the algorithm has no hidden entropy).
    final again = Shamir.split(
      Uint8List.fromList([1, 2, 3, 4]),
      shares: 3,
      threshold: 2,
      random: Random(42),
    );
    for (var i = 0; i < 3; i++) {
      expect(again[i], equals(shares[i]));
    }
  });

  test('rejects invalid parameters and malformed shares', () {
    expect(() => Shamir.split(secret, shares: 1, threshold: 1),
        throwsArgumentError);
    expect(() => Shamir.split(secret, shares: 2, threshold: 3),
        throwsArgumentError);
    expect(() => Shamir.split(<int>[], shares: 3, threshold: 2),
        throwsArgumentError);

    final shares = Shamir.split(secret, shares: 3, threshold: 2);
    expect(() => Shamir.combine([shares[0]]), throwsArgumentError);
    expect(
      () => Shamir.combine([shares[0], shares[0]]),
      throwsArgumentError,
      reason: 'duplicate x-coordinates must be rejected',
    );
    expect(
      () => Shamir.combine([
        shares[0],
        Uint8List.fromList(shares[1].sublist(0, 5)),
      ]),
      throwsArgumentError,
      reason: 'mismatched lengths must be rejected',
    );
  });

  test('handles a 1-byte secret', () {
    final tiny = Uint8List.fromList([0xAB]);
    final shares = Shamir.split(tiny, shares: 3, threshold: 2);
    expect(Shamir.combine(shares.sublist(1)), equals(tiny));
  });
}
