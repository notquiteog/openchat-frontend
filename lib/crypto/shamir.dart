import 'dart:math';
import 'dart:typed_data';

/// Shamir secret sharing over GF(256), byte-wise (the HashiCorp Vault
/// construction): each secret byte becomes the constant term of a fresh
/// random polynomial of degree k-1; share i carries the polynomial's value at
/// x=i for every byte position, with its x-coordinate appended as the final
/// byte. Any k shares reconstruct the secret by Lagrange interpolation at
/// x=0; k-1 shares reveal nothing (every candidate secret remains equally
/// consistent).
///
/// Used by social key recovery: a 32-byte recovery secret is split among
/// guardians; each share travels to its guardian as a sealed message and is
/// individually worthless.
class Shamir {
  Shamir._();

  static const int maxShares = 255;

  // GF(2^8) log/exp tables over the AES polynomial x^8+x^4+x^3+x+1 (0x11B),
  // generator 3.
  static final Uint8List _exp = _buildExp();
  static final Uint8List _log = _buildLog();

  static Uint8List _buildExp() {
    final table = Uint8List(510);
    var x = 1;
    for (var i = 0; i < 255; i++) {
      table[i] = x;
      table[i + 255] = x; // doubled so mul never needs a mod 255
      // multiply by the generator 3 = x * 2 + x
      x ^= (x << 1) ^ ((x & 0x80) != 0 ? 0x11B : 0);
      x &= 0xFF;
    }
    return table;
  }

  static Uint8List _buildLog() {
    final table = Uint8List(256);
    var x = 1;
    for (var i = 0; i < 255; i++) {
      table[x] = i;
      x ^= (x << 1) ^ ((x & 0x80) != 0 ? 0x11B : 0);
      x &= 0xFF;
    }
    return table;
  }

  static int _mul(int a, int b) {
    if (a == 0 || b == 0) return 0;
    return _exp[_log[a] + _log[b]];
  }

  static int _div(int a, int b) {
    if (b == 0) throw ArgumentError('division by zero in GF(256)');
    if (a == 0) return 0;
    return _exp[(_log[a] - _log[b] + 255) % 255];
  }

  /// Evaluates a polynomial (coefficients[0] = constant term) at x via Horner.
  static int _eval(Uint8List coefficients, int x) {
    var out = 0;
    for (var i = coefficients.length - 1; i >= 0; i--) {
      out = _mul(out, x) ^ coefficients[i];
    }
    return out;
  }

  /// Splits [secret] into [shares] parts, any [threshold] of which recover it.
  /// Each returned share is `secret.length + 1` bytes (x-coordinate last).
  static List<Uint8List> split(
    List<int> secret, {
    required int shares,
    required int threshold,
    Random? random,
  }) {
    if (secret.isEmpty) {
      throw ArgumentError('secret must not be empty');
    }
    if (threshold < 2 || shares < threshold || shares > maxShares) {
      throw ArgumentError(
        'need 2 <= threshold <= shares <= $maxShares '
        '(got threshold=$threshold shares=$shares)',
      );
    }
    final rng = random ?? Random.secure();
    final out = List<Uint8List>.generate(
      shares,
      (i) => Uint8List(secret.length + 1)..[secret.length] = i + 1,
    );
    final coefficients = Uint8List(threshold);
    for (var byteIndex = 0; byteIndex < secret.length; byteIndex++) {
      coefficients[0] = secret[byteIndex];
      for (var c = 1; c < threshold; c++) {
        coefficients[c] = rng.nextInt(256);
      }
      for (var s = 0; s < shares; s++) {
        out[s][byteIndex] = _eval(coefficients, s + 1);
      }
    }
    return out;
  }

  /// Recombines shares produced by [split]. Needs at least the original
  /// threshold; passing fewer yields garbage (indistinguishable from any
  /// other secret), never an error — secrecy, not integrity, is Shamir's
  /// guarantee. Wrap the secret with its own integrity check (the recovery
  /// blob is AES-GCM, which authenticates).
  static Uint8List combine(List<List<int>> shares) {
    if (shares.length < 2) {
      throw ArgumentError('need at least 2 shares');
    }
    final length = shares.first.length;
    if (length < 2) {
      throw ArgumentError('shares are malformed (too short)');
    }
    final xs = <int>[];
    for (final share in shares) {
      if (share.length != length) {
        throw ArgumentError('shares have mismatched lengths');
      }
      final x = share[length - 1];
      if (x == 0) throw ArgumentError('invalid share x-coordinate 0');
      if (xs.contains(x)) {
        throw ArgumentError('duplicate share (x=$x) supplied');
      }
      xs.add(x);
    }
    final secret = Uint8List(length - 1);
    for (var byteIndex = 0; byteIndex < length - 1; byteIndex++) {
      // Lagrange interpolation at x = 0.
      var value = 0;
      for (var i = 0; i < shares.length; i++) {
        var basis = 1;
        for (var j = 0; j < shares.length; j++) {
          if (i == j) continue;
          basis = _mul(basis, _div(xs[j], xs[i] ^ xs[j]));
        }
        value ^= _mul(basis, shares[i][byteIndex]);
      }
      secret[byteIndex] = value;
    }
    return secret;
  }
}
