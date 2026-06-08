// Socialist Millionaire Protocol (OTRv3 variant) for in-band, zero-knowledge
// contact verification. Two parties confirm they hold the same secret answer
// without revealing it; a man-in-the-middle who substituted keys cannot pass
// because the secret is bound to both fingerprints.
//
// Group: RFC 3526 MODP Group 14 (2048-bit), g = 2, subgroup order q = (p-1)/2.
// Message values travel as hex strings. The four-message exchange:
//   A → B  init   (g2a, g3a + proofs)
//   B → A  step2  (g2b, g3b, Pb, Qb + proofs)
//   A → B  step3  (Pa, Qa, Ra + proofs)
//   B → A  step4  (Rb + proof)
// Both sides then check Rab == Pa / Pb. Equal ⇔ same secret.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

final BigInt _p = BigInt.parse(
  'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E08'
  '8A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B'
  '302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9'
  'A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE6'
  '49286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8'
  'FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D'
  '670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C'
  '180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718'
  '3995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFF'
  'FFFFFFFF',
  radix: 16,
);
final BigInt _g = BigInt.two;
final BigInt _q = (_p - BigInt.one) >> 1; // (p-1)/2
final BigInt _one = BigInt.one;

final Random _rng = Random.secure();

/// Normalised SMP secret, bound to both parties' fingerprints so a key
/// substitution by a MITM changes the secret and fails verification.
/// [myFingerprint]/[theirFingerprint] order-independent (sorted).
BigInt smpSecret({
  required String myFingerprint,
  required String theirFingerprint,
  required String answer,
}) {
  final a = myFingerprint.trim().toUpperCase();
  final b = theirFingerprint.trim().toUpperCase();
  final low = a.compareTo(b) <= 0 ? a : b;
  final high = a.compareTo(b) <= 0 ? b : a;
  final norm = answer.trim();
  final digest = crypto.sha256.convert(
    utf8.encode('openchat-smp-v1|$low|$high|$norm'),
  );
  return _bytesToBigInt(Uint8List.fromList(digest.bytes)) % _q;
}

// ── BigInt / hex helpers ────────────────────────────────────────────────────

BigInt _bytesToBigInt(Uint8List bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b);
  }
  return result;
}

String _toHex(BigInt v) => v.toRadixString(16);
BigInt _fromHex(String s) => BigInt.parse(s, radix: 16);

/// Random exponent in [2, q-1].
BigInt _randExp() {
  // 2048-bit random, reduced into [2, q-1].
  final bytes = Uint8List(256);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = _rng.nextInt(256);
  }
  final v = _bytesToBigInt(bytes) % (_q - BigInt.two);
  return v + BigInt.two;
}

BigInt _pow(BigInt base, BigInt exp) => base.modPow(exp, _p);

BigInt _mul(BigInt a, BigInt b) => (a * b) % _p;

BigInt _inv(BigInt a) => a.modInverse(_p);

/// Fiat–Shamir challenge: SHA-256 over a version byte and the MPIs, as a BigInt.
BigInt _hash(int version, List<BigInt> values) {
  final buf = <int>[version];
  for (final v in values) {
    final hex = v.toRadixString(16);
    final padded = hex.length.isOdd ? '0$hex' : hex;
    final bytes = <int>[];
    for (var i = 0; i < padded.length; i += 2) {
      bytes.add(int.parse(padded.substring(i, i + 2), radix: 16));
    }
    // Length-prefix (4 bytes big-endian) so concatenations are unambiguous.
    final len = bytes.length;
    buf
      ..add((len >> 24) & 0xff)
      ..add((len >> 16) & 0xff)
      ..add((len >> 8) & 0xff)
      ..add(len & 0xff)
      ..addAll(bytes);
  }
  return _bytesToBigInt(
    Uint8List.fromList(crypto.sha256.convert(buf).bytes),
  );
}

bool _inRange(BigInt v) => v > _one && v < (_p - _one);

// ── Zero-knowledge proofs (OTR style) ───────────────────────────────────────

/// Proof of knowledge of x such that X = g^x.
Map<String, String> _proveKnowLog(int version, BigInt x) {
  final r = _randExp();
  final c = _hash(version, [_pow(_g, r)]);
  final d = (r - x * c) % _q;
  return {'c': _toHex(c % _q), 'd': _toHex((d + _q) % _q)};
}

bool _verifyKnowLog(int version, BigInt bigX, String cHex, String dHex) {
  final c = _fromHex(cHex);
  final d = _fromHex(dHex);
  final check = _hash(version, [_mul(_pow(_g, d), _pow(bigX, c))]);
  return (check % _q) == (c % _q);
}

/// Proof that (Pp = g3^r, Qp = g^r * g2^secret) were built with the same r and
/// secret. Returns (c, d5, d6).
Map<String, String> _proveCoords(
  int version,
  BigInt g2,
  BigInt g3,
  BigInt r,
  BigInt secret,
) {
  final r5 = _randExp();
  final r6 = _randExp();
  final c = _hash(version, [
    _pow(g3, r5),
    _mul(_pow(_g, r5), _pow(g2, r6)),
  ]);
  final d5 = ((r5 - r * c) % _q + _q) % _q;
  final d6 = ((r6 - secret * c) % _q + _q) % _q;
  return {'c': _toHex(c % _q), 'd5': _toHex(d5), 'd6': _toHex(d6)};
}

bool _verifyCoords(
  int version,
  BigInt g2,
  BigInt g3,
  BigInt pp,
  BigInt qp,
  String cHex,
  String d5Hex,
  String d6Hex,
) {
  final c = _fromHex(cHex);
  final d5 = _fromHex(d5Hex);
  final d6 = _fromHex(d6Hex);
  final v1 = _mul(_pow(g3, d5), _pow(pp, c));
  final v2 = _mul(_mul(_pow(_g, d5), _pow(g2, d6)), _pow(qp, c));
  return (_hash(version, [v1, v2]) % _q) == (c % _q);
}

/// Proof that R = (Qa/Qb)^x and the prover knows x = log_g(g3owner). (c, d).
Map<String, String> _proveEqualLogs(
  int version,
  BigInt qaqb,
  BigInt x,
) {
  final r = _randExp();
  final c = _hash(version, [_pow(_g, r), _pow(qaqb, r)]);
  final d = ((r - x * c) % _q + _q) % _q;
  return {'c': _toHex(c % _q), 'd': _toHex(d)};
}

bool _verifyEqualLogs(
  int version,
  BigInt qaqb,
  BigInt g3owner,
  BigInt r,
  String cHex,
  String dHex,
) {
  final c = _fromHex(cHex);
  final d = _fromHex(dHex);
  final v1 = _mul(_pow(_g, d), _pow(g3owner, c));
  final v2 = _mul(_pow(qaqb, d), _pow(r, c));
  return (_hash(version, [v1, v2]) % _q) == (c % _q);
}

class SmpException implements Exception {
  final String message;
  const SmpException(this.message);
  @override
  String toString() => 'SmpException: $message';
}

/// An inbound SMP control message routed from the chat transport to the SMP
/// provider. [payload] is the decoded `{openchat_smp, step, session, data}` map.
class SmpInbound {
  final String conversationId;
  final String senderId;
  final Map<String, dynamic> payload;
  const SmpInbound({
    required this.conversationId,
    required this.senderId,
    required this.payload,
  });
}

/// Initiator-side session (Alice).
class SmpInitiator {
  final BigInt _x;
  late BigInt _a2;
  late BigInt _a3;
  late BigInt _g2;
  late BigInt _g3;
  late BigInt _pa;
  late BigInt _pb;
  late BigInt _qaDivQb;

  SmpInitiator(this._x);

  /// SMP message 1: g2a, g3a + knowledge proofs.
  Map<String, String> init() {
    _a2 = _randExp();
    _a3 = _randExp();
    final g2a = _pow(_g, _a2);
    final g3a = _pow(_g, _a3);
    final p2 = _proveKnowLog(1, _a2);
    final p3 = _proveKnowLog(2, _a3);
    return {
      'g2a': _toHex(g2a),
      'g3a': _toHex(g3a),
      'c2': p2['c']!,
      'd2': p2['d']!,
      'c3': p3['c']!,
      'd3': p3['d']!,
    };
  }

  /// Consume SMP message 2 (from Bob) and produce SMP message 3.
  Map<String, String> step3(Map<String, String> msg2) {
    final g2b = _fromHex(msg2['g2b']!);
    final g3b = _fromHex(msg2['g3b']!);
    final pb = _fromHex(msg2['Pb']!);
    final qb = _fromHex(msg2['Qb']!);
    if (!_inRange(g2b) || !_inRange(g3b) || !_inRange(pb) || !_inRange(qb)) {
      throw const SmpException('peer values out of range');
    }
    if (!_verifyKnowLog(3, g2b, msg2['c2']!, msg2['d2']!) ||
        !_verifyKnowLog(4, g3b, msg2['c3']!, msg2['d3']!)) {
      throw const SmpException('invalid knowledge proof in message 2');
    }
    _g2 = _pow(g2b, _a2);
    _g3 = _pow(g3b, _a3);
    if (!_verifyCoords(
      5,
      _g2,
      _g3,
      pb,
      qb,
      msg2['cP']!,
      msg2['d5']!,
      msg2['d6']!,
    )) {
      throw const SmpException('invalid coordinate proof in message 2');
    }
    _pb = pb;
    final r4 = _randExp();
    _pa = _pow(_g3, r4);
    final qa = _mul(_pow(_g, r4), _pow(_g2, _x));
    _qaDivQb = _mul(qa, _inv(qb));
    final ra = _pow(_qaDivQb, _a3);
    final coords = _proveCoords(6, _g2, _g3, r4, _x);
    final eq = _proveEqualLogs(7, _qaDivQb, _a3);
    return {
      'Pa': _toHex(_pa),
      'Qa': _toHex(qa),
      'Ra': _toHex(ra),
      'cP': coords['c']!,
      'd5': coords['d5']!,
      'd6': coords['d6']!,
      'cR': eq['c']!,
      'dR': eq['d']!,
    };
  }

  /// Consume SMP message 4 (from Bob): final equality check.
  bool finish(Map<String, String> msg4) {
    final rb = _fromHex(msg4['Rb']!);
    final g3b = _fromHex(msg4['g3b']!);
    if (!_inRange(rb)) throw const SmpException('Rb out of range');
    if (!_verifyEqualLogs(8, _qaDivQb, g3b, rb, msg4['cR']!, msg4['dR']!)) {
      throw const SmpException('invalid equal-logs proof in message 4');
    }
    final rab = _pow(rb, _a3);
    final paDivPb = _mul(_pa, _inv(_pb));
    return rab == paDivPb;
  }
}

/// Responder-side session (Bob).
class SmpResponder {
  final BigInt _y;
  late BigInt _b2;
  late BigInt _b3;
  late BigInt _g3a;
  late BigInt _g2;
  late BigInt _g3;
  late BigInt _pa;
  late BigInt _pb;
  late BigInt _g3b;

  SmpResponder(this._y);

  bool _matched = false;
  bool get matched => _matched;

  /// Consume SMP message 1 (from Alice) and produce SMP message 2.
  Map<String, String> step2(Map<String, String> msg1) {
    final g2a = _fromHex(msg1['g2a']!);
    final g3a = _fromHex(msg1['g3a']!);
    if (!_inRange(g2a) || !_inRange(g3a)) {
      throw const SmpException('peer values out of range');
    }
    if (!_verifyKnowLog(1, g2a, msg1['c2']!, msg1['d2']!) ||
        !_verifyKnowLog(2, g3a, msg1['c3']!, msg1['d3']!)) {
      throw const SmpException('invalid knowledge proof in message 1');
    }
    _g3a = g3a;
    _b2 = _randExp();
    _b3 = _randExp();
    final g2b = _pow(_g, _b2);
    _g3b = _pow(_g, _b3);
    final p2 = _proveKnowLog(3, _b2);
    final p3 = _proveKnowLog(4, _b3);
    _g2 = _pow(g2a, _b2);
    _g3 = _pow(g3a, _b3);
    final r4 = _randExp();
    _pb = _pow(_g3, r4);
    final qb = _mul(_pow(_g, r4), _pow(_g2, _y));
    _qb = qb;
    final coords = _proveCoords(5, _g2, _g3, r4, _y);
    return {
      'g2b': _toHex(g2b),
      'g3b': _toHex(_g3b),
      'c2': p2['c']!,
      'd2': p2['d']!,
      'c3': p3['c']!,
      'd3': p3['d']!,
      'Pb': _toHex(_pb),
      'Qb': _toHex(qb),
      'cP': coords['c']!,
      'd5': coords['d5']!,
      'd6': coords['d6']!,
    };
  }

  /// Consume SMP message 3 (from Alice), set [matched], and produce message 4.
  Map<String, String> step4(Map<String, String> msg3) {
    final pa = _fromHex(msg3['Pa']!);
    final qa = _fromHex(msg3['Qa']!);
    final ra = _fromHex(msg3['Ra']!);
    if (!_inRange(pa) || !_inRange(qa) || !_inRange(ra)) {
      throw const SmpException('peer values out of range');
    }
    if (!_verifyCoords(
      6,
      _g2,
      _g3,
      pa,
      qa,
      msg3['cP']!,
      msg3['d5']!,
      msg3['d6']!,
    )) {
      throw const SmpException('invalid coordinate proof in message 3');
    }
    _pa = pa;
    final qaDivQb = _mul(qa, _inv(_qb)); // _qb retained from step2
    if (!_verifyEqualLogs(7, qaDivQb, _g3a, ra, msg3['cR']!, msg3['dR']!)) {
      throw const SmpException('invalid equal-logs proof in message 3');
    }
    final rb = _pow(qaDivQb, _b3);
    final rab = _pow(ra, _b3);
    final paDivPb = _mul(_pa, _inv(_pb));
    _matched = rab == paDivPb;
    final eq = _proveEqualLogs(8, qaDivQb, _b3);
    return {
      'Rb': _toHex(rb),
      'g3b': _toHex(_g3b),
      'cR': eq['c']!,
      'dR': eq['d']!,
    };
  }

  // Qb retained from step2 for the Qa/Qb division in step4.
  late BigInt _qb;
}
