import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// RSA-FDH blind signatures for sealed-post entitlement tokens (#53), client
/// side. The byte-exact counterpart of backend/internal/pgp/blindsign.go —
/// guarded by the cross-language KAT in test/crypto/blind_token_test.dart
/// against test/fixtures/blind_signature_vector.json (emitted by the Go
/// `TestEmitBlindVectorForDart`). If you change anything here, regenerate the
/// fixture and keep both sides in lock-step.
///
/// Flow: the client mints a random token, blinds it (`blindToken`), sends the
/// blinded value to the server to be blind-signed (server never sees the
/// token), unblinds the result (`unblindSignature`), and later redeems
/// {token, signature}. The server can verify the signature is its own but can't
/// link it to the issuance — breaking the issue↔redeem timing correlation a
/// plain bearer token would expose.
///
/// Wire format (must match Go): big integers are big-endian, left-zero-padded
/// to modBytes(n) = (n.bitLength + 7) ~/ 8 bytes; FDH expands
/// SHA-256(domain ‖ token ‖ be32(counter)) until ≥ modBytes(n), truncates,
/// reads big-endian, reduces mod n.
const String _blindFDHDomain = 'OCBLIND1';

/// A blinded token plus the blinding factor needed to unblind the signature.
class BlindedToken {
  const BlindedToken({required this.blinded, required this.blindingFactor});

  /// The value to send to the server for blind-signing (big-endian, modBytes).
  final Uint8List blinded;

  /// The secret blinding factor r — keep it to unblind the returned signature.
  final Uint8List blindingFactor;
}

int _modBytes(BigInt n) => (n.bitLength + 7) ~/ 8;

Uint8List _bigIntToBytes(BigInt x) {
  if (x == BigInt.zero) return Uint8List(1);
  var v = x;
  final out = <int>[];
  final mask = BigInt.from(0xff);
  while (v > BigInt.zero) {
    out.add((v & mask).toInt());
    v = v >> 8;
  }
  return Uint8List.fromList(out.reversed.toList());
}

BigInt _bytesToBigInt(Uint8List b) {
  var r = BigInt.zero;
  for (final byte in b) {
    r = (r << 8) | BigInt.from(byte);
  }
  return r;
}

Uint8List _leftPadTo(BigInt x, int size) {
  final bytes = _bigIntToBytes(x);
  if (bytes.length == size) return bytes;
  final out = Uint8List(size);
  if (bytes.length > size) {
    out.setRange(0, size, bytes.sublist(bytes.length - size));
  } else {
    out.setRange(size - bytes.length, size, bytes);
  }
  return out;
}

/// Parse the server-provided modulus / exponent (raw big-endian bytes) into
/// integers for the blind/verify functions.
BigInt blindModulusFromBytes(Uint8List nBytes) => _bytesToBigInt(nBytes);
BigInt blindExponentFromBytes(Uint8List eBytes) => _bytesToBigInt(eBytes);

BigInt _fdh(Uint8List token, BigInt n) {
  final needed = _modBytes(n);
  final domain = utf8.encode(_blindFDHDomain);
  final buf = BytesBuilder();
  var ctr = 0;
  while (buf.length < needed) {
    final block = <int>[
      ...domain,
      ...token,
      (ctr >> 24) & 0xff,
      (ctr >> 16) & 0xff,
      (ctr >> 8) & 0xff,
      ctr & 0xff,
    ];
    buf.add(sha256.convert(block).bytes);
    ctr++;
  }
  final m = _bytesToBigInt(
    Uint8List.fromList(buf.toBytes().sublist(0, needed)),
  );
  return m % n;
}

/// Blinds [token] with an explicit factor [r]. Exposed for the KAT; production
/// code uses [blindToken], which generates a fresh random r.
BlindedToken blindTokenWithFactor(
  Uint8List token,
  BigInt n,
  BigInt e,
  BigInt r,
) {
  final m = _fdh(token, n);
  final blinded = (m * r.modPow(e, n)) % n;
  final size = _modBytes(n);
  return BlindedToken(
    blinded: _leftPadTo(blinded, size),
    blindingFactor: _leftPadTo(r, size),
  );
}

/// Blinds [token] for blind-signing under public key (n, e), choosing a fresh
/// random blinding factor coprime to n.
BlindedToken blindToken(Uint8List token, BigInt n, BigInt e) {
  return blindTokenWithFactor(token, n, e, _randomCoprime(n));
}

/// Unblinds a server blind-signature back to a valid signature over the token:
/// s = s' · r⁻¹ mod n.
Uint8List unblindSignature(
  Uint8List blindSignature,
  Uint8List blindingFactor,
  BigInt n,
) {
  final s = _bytesToBigInt(blindSignature);
  final r = _bytesToBigInt(blindingFactor);
  final rInv = r.modInverse(n);
  return _leftPadTo((s * rInv) % n, _modBytes(n));
}

/// Self-check that a signature verifies: sᵉ mod n == FDH(token).
bool verifyBlindToken(Uint8List token, Uint8List sig, BigInt n, BigInt e) {
  final s = _bytesToBigInt(sig);
  if (s <= BigInt.zero || s >= n) return false;
  return s.modPow(e, n) == _fdh(token, n);
}

BigInt _randomCoprime(BigInt n) {
  final rng = Random.secure();
  final size = _modBytes(n);
  while (true) {
    final bytes = Uint8List.fromList(
      List<int>.generate(size, (_) => rng.nextInt(256)),
    );
    final v = _bytesToBigInt(bytes) % n;
    if (v < BigInt.two) continue;
    if (v.gcd(n) == BigInt.one) return v;
  }
}

/// Generates a fresh 32-byte random post token (the value the server's
/// signature attests). Returned to the caller to keep alongside the signature.
Uint8List generatePostToken() {
  final rng = Random.secure();
  return Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
}
