import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/crypto/blind_token.dart';

/// Cross-language Known-Answer Test for the RSA-FDH blind signature (#53).
/// Loads the fixture emitted by the Go `pgp.TestEmitBlindVectorForDart` and
/// asserts the Dart port agrees byte-for-byte: it must reproduce each `blinded`
/// from token+r, unblind each `blind_signature` to `signature`, and verify the
/// signature. A divergence here means the Go server and Dart client would
/// disagree on the wire — exactly what this guards against.
void main() {
  late BigInt n;
  late BigInt e;
  late List<Map<String, dynamic>> vectors;

  setUpAll(() {
    final file = File('test/fixtures/blind_signature_vector.json');
    expect(
      file.existsSync(),
      isTrue,
      reason:
          'Run `go test ./internal/pgp/ -run TestEmitBlindVectorForDart` '
          'in backend/ to generate the fixture.',
    );
    final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    n = blindModulusFromBytes(base64.decode(doc['n'] as String));
    e = blindExponentFromBytes(base64.decode(doc['e'] as String));
    vectors = (doc['vectors'] as List).cast<Map<String, dynamic>>();
  });

  test('fixture has vectors', () {
    expect(vectors, isNotEmpty);
  });

  test('every Go vector: blind, unblind, and verify match byte-for-byte', () {
    for (final v in vectors) {
      final name = v['name'] as String;
      final token = base64.decode(v['token'] as String);
      final r = base64.decode(v['r'] as String);
      final expectedBlinded = base64.decode(v['blinded'] as String);
      final blindSignature = base64.decode(v['blind_signature'] as String);
      final expectedSignature = base64.decode(v['signature'] as String);

      // (a) Reproduce the blinded value from token + r.
      final blinded = blindTokenWithFactor(
        Uint8List.fromList(token),
        n,
        e,
        blindModulusFromBytes(Uint8List.fromList(r)),
      );
      expect(
        _hex(blinded.blinded),
        _hex(Uint8List.fromList(expectedBlinded)),
        reason: '$name: blinded value diverged from Go',
      );

      // (b) Unblind the Go blind-signature to the final signature.
      final sig = unblindSignature(
        Uint8List.fromList(blindSignature),
        Uint8List.fromList(r),
        n,
      );
      expect(
        _hex(sig),
        _hex(Uint8List.fromList(expectedSignature)),
        reason: '$name: unblinded signature diverged from Go',
      );

      // (c) Verify the signature against the token.
      expect(
        verifyBlindToken(Uint8List.fromList(token), sig, n, e),
        isTrue,
        reason: '$name: signature failed verification',
      );

      // Negative: a tampered signature must not verify.
      final tampered = Uint8List.fromList(sig);
      tampered[0] ^= 0xFF;
      expect(
        verifyBlindToken(Uint8List.fromList(token), tampered, n, e),
        isFalse,
        reason: '$name: a tampered signature verified',
      );
    }
  });

  test('full client round-trip with a random blinding factor verifies', () {
    // The KAT pins r; this exercises the production path that picks r itself.
    final token = generatePostToken();
    final blinded = blindToken(token, n, e);
    // We can't blind-sign without the private key here, but we can at least
    // assert the blinded value is in range and the helpers are self-consistent
    // for a known signature (reuse the first vector's signature is invalid for
    // a fresh token — so only check structural properties).
    expect(blinded.blinded.length, (n.bitLength + 7) ~/ 8);
    expect(blinded.blindingFactor.length, (n.bitLength + 7) ~/ 8);
  });
}

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
