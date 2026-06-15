/// Asymmetric Message Franking with preprocessing (Hecate, eprint 2021/1686),
/// client half. Lets a recipient submit a *provable* CSAM report the moderator
/// (system admins) can deanonymize, without the server being able to
/// deanonymize any unreported message.
///
/// WIRE FORMAT — byte-identical with `backend/internal/amf/amf.go`. Any change
/// here must change there too; the deterministic KAT in
/// `frontend/test/fixtures/amf_vector.json` (emitted by the Go
/// `TestEmitVectorForDart`) guards the contract.
///
/// Sizes: x1 = nonce(12)‖ct(16)‖tag(16) = 44; the mask Hexp(m) is also 44 so
/// x2 = Hexp(m) ⊕ x1 is well-defined. Canonical content
/// m = "openchat-amf-content:v1:"+convID+":"+type+":"+base64Std(payload).
/// Signed data: σ1 over x1‖pk_e‖be64(t1); σ2 over x2; σ3 over com‖be64(t2).
/// com = SHA256(r‖x1‖x2). t1/t2 are int64 unix seconds.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

const int amfX1Len = 44;
const String _contentPrefix = 'openchat-amf-content:v1:';

/// Receiver-side verification outcome. [invalid] = structurally bad
/// (tampered/malformed) ⇒ not reportable; [stale] = structurally sound but
/// outside the freshness window (e.g. a delayed offline send) ⇒ display but not
/// reportable; [valid] = fresh + sound ⇒ display + CSAM-reportable.
enum AmfVerifyOutcome { valid, stale, invalid }

/// Default freshness window for the t2 − t1 (issuance → server stamp) gap.
/// Mirrors `amf.DefaultMaxFrankAge`.
const Duration amfDefaultMaxFrankAge = Duration(hours: 1);

/// Tolerated backward clock-skew (NTP step between issue and stamp). Mirrors
/// `amf.clockSkewGrace`.
const Duration _clockSkewGrace = Duration(minutes: 5);

final _ed25519 = Ed25519();

/// The franking token minted by the server at post-token issuance. [skE] is the
/// ephemeral signing seed — use it once (to sign σ2 in [AmfService.frank]) then
/// drop it; never persist or reuse it.
class AmfToken {
  final Uint8List x1; // 44
  final int t1;
  final Uint8List sig1; // 64
  final Uint8List pkE; // 32
  final Uint8List skE; // 32 (Ed25519 seed)

  const AmfToken({
    required this.x1,
    required this.t1,
    required this.sig1,
    required this.pkE,
    required this.skE,
  });

  factory AmfToken.fromJson(Map<String, dynamic> j) => AmfToken(
    x1: base64.decode(j['x1'] as String),
    t1: (j['t1'] as num).toInt(),
    sig1: base64.decode(j['sig1'] as String),
    pkE: base64.decode(j['pk_e'] as String),
    skE: base64.decode(j['sk_e'] as String),
  );
}

/// The franking data the client embeds in the E2E payload (server-opaque). The
/// commitment [com] is the only part sent server-visible (in the send request).
class AmfFranking {
  final Uint8List x1;
  final Uint8List x2;
  final Uint8List r;
  final int t1;
  final Uint8List sig1;
  final Uint8List sig2;
  final Uint8List pkE;
  final Uint8List com;

  const AmfFranking({
    required this.x1,
    required this.x2,
    required this.r,
    required this.t1,
    required this.sig1,
    required this.sig2,
    required this.pkE,
    required this.com,
  });

  /// The object embedded in the encrypted payload's `franking` field.
  Map<String, dynamic> toPayloadJson() => {
    'x1': base64.encode(x1),
    'x2': base64.encode(x2),
    'r': base64.encode(r),
    't1': t1,
    'sig1': base64.encode(sig1),
    'sig2': base64.encode(sig2),
    'pk_e': base64.encode(pkE),
  };

  static AmfFranking? fromPayloadJson(Map<String, dynamic> j) {
    try {
      return AmfFranking(
        x1: base64.decode(j['x1'] as String),
        x2: base64.decode(j['x2'] as String),
        r: base64.decode(j['r'] as String),
        t1: (j['t1'] as num).toInt(),
        sig1: base64.decode(j['sig1'] as String),
        sig2: base64.decode(j['sig2'] as String),
        pkE: base64.decode(j['pk_e'] as String),
        com: Uint8List(0), // com is re-derived locally; not stored in payload
      );
    } catch (_) {
      return null;
    }
  }
}

/// Everything [AmfService.verify] / report assembly needs: the payload-side
/// franking + the server stamp (com,t2,σ3) + the content coordinates.
class AmfFrankedMessage {
  final String conversationId;
  final String messageType;
  final String payload;

  final Uint8List x1;
  final Uint8List x2;
  final Uint8List r;
  final Uint8List pkE;
  final int t1;
  final Uint8List sig1;
  final Uint8List sig2;

  final Uint8List com;
  final int t2;
  final Uint8List sig3;

  const AmfFrankedMessage({
    required this.conversationId,
    required this.messageType,
    required this.payload,
    required this.x1,
    required this.x2,
    required this.r,
    required this.pkE,
    required this.t1,
    required this.sig1,
    required this.sig2,
    required this.com,
    required this.t2,
    required this.sig3,
  });

  /// The CSAM report blob POSTed to `/api/v1/reports/csam` and stored opaquely
  /// server-side. Mirrors the Go `amf` report parse. Carries the encrypted
  /// sender id (x1) — never the plaintext id.
  Map<String, dynamic> toReportJson() => {
    'v': 1,
    'conversation_id': conversationId,
    'message_type': messageType,
    'payload': payload,
    'x1': base64.encode(x1),
    'x2': base64.encode(x2),
    'r': base64.encode(r),
    'pk_e': base64.encode(pkE),
    't1': t1,
    'sig1': base64.encode(sig1),
    'sig2': base64.encode(sig2),
    'com': base64.encode(com),
    't2': t2,
    'sig3': base64.encode(sig3),
  };
}

/// The pinned AMF public keys (from `/api/v1/.well-known/amf-keys`).
class AmfPublicKeys {
  final Uint8List moderatorPublicKey;
  final Uint8List platformPublicKey;
  const AmfPublicKeys({
    required this.moderatorPublicKey,
    required this.platformPublicKey,
  });
}

class AmfService {
  /// Canonical content bytes whose SHA-256 expansion masks x1. Recomputed
  /// identically by Frank, Verify, and the server's Inspect.
  static List<int> canonicalContent(
    String convID,
    String messageType,
    String payload,
  ) {
    final encodedPayload = base64.encode(utf8.encode(payload));
    return utf8.encode('$_contentPrefix$convID:$messageType:$encodedPayload');
  }

  /// Expands SHA-256 to 44 bytes: (SHA256(m‖0x00) ‖ SHA256(m‖0x01))[:44].
  static Uint8List hexp(List<int> m) {
    final h0 = crypto.sha256.convert([...m, 0x00]).bytes;
    final h1 = crypto.sha256.convert([...m, 0x01]).bytes;
    return Uint8List.fromList([...h0, ...h1].sublist(0, amfX1Len));
  }

  static Uint8List _commit(List<int> r, List<int> x1, List<int> x2) =>
      Uint8List.fromList(crypto.sha256.convert([...r, ...x1, ...x2]).bytes);

  /// The canonical bytes the platform key signs over the published key bundle,
  /// byte-identical to Go `AMFKeysSignedData`. Lets a client confirm the
  /// moderator key it pins is vouched for by the (pinned) platform key.
  static List<int> keyBundleSignedData(
    List<int> modPub,
    List<int> platPub,
  ) => <int>[...utf8.encode('openchat-amf-keys:v1:'), ...modPub, ...platPub];

  /// Verifies the `/.well-known/amf-keys` bundle signature under [platformPub].
  static Future<bool> verifyKeyBundle({
    required List<int> moderatorPub,
    required List<int> platformPub,
    required List<int> signature,
  }) async {
    if (moderatorPub.length != 32 ||
        platformPub.length != 32 ||
        signature.length != 64) {
      return false;
    }
    return _verifySig(
      keyBundleSignedData(moderatorPub, platformPub),
      signature,
      platformPub,
    );
  }

  /// Big-endian 8-byte encoding of [t] (web-safe; t fits in 53 bits).
  static Uint8List be64(int t) {
    final b = Uint8List(8);
    var v = t;
    for (var i = 7; i >= 0; i--) {
      b[i] = v & 0xff;
      v = v >> 8;
    }
    return b;
  }

  static Uint8List _xor(List<int> a, List<int> b) {
    if (a.length != b.length) {
      throw ArgumentError('xor operands must have equal length');
    }
    final out = Uint8List(a.length);
    for (var i = 0; i < a.length; i++) {
      out[i] = a[i] ^ b[i];
    }
    return out;
  }

  /// Frank (sender, on send): compute x2 = Hexp(m) ⊕ x1, σ2 = Sign_{sk_e}(x2),
  /// r ←$, com = SHA256(r‖x1‖x2). [rOverride] is for the deterministic KAT only.
  static Future<AmfFranking> frank(
    AmfToken token, {
    required String conversationId,
    required String messageType,
    required String payload,
    List<int>? rOverride,
  }) async {
    final m = canonicalContent(conversationId, messageType, payload);
    final x2 = _xor(hexp(m), token.x1);
    final r = rOverride != null
        ? Uint8List.fromList(rOverride)
        : _randomBytes(32);
    final skeKeyPair = await _ed25519.newKeyPairFromSeed(token.skE);
    final sig2 = await _ed25519.sign(x2, keyPair: skeKeyPair);
    final com = _commit(r, token.x1, x2);
    return AmfFranking(
      x1: token.x1,
      x2: x2,
      r: r,
      t1: token.t1,
      sig1: token.sig1,
      sig2: Uint8List.fromList(sig2.bytes),
      pkE: token.pkE,
      com: com,
    );
  }

  /// Verify (receiver): true iff the franking is internally consistent AND
  /// fresh. A convenience over [verifyDetailed] for the cross-language KAT.
  static Future<bool> verify(
    AmfFrankedMessage fm,
    AmfPublicKeys keys, {
    Duration maxAge = amfDefaultMaxFrankAge,
  }) async =>
      (await verifyDetailed(fm, keys, maxAge: maxAge)) ==
      AmfVerifyOutcome.valid;

  /// The full tri-state result. The 3 signature checks + commitment open +
  /// binding (x1⊕x2 == Hexp(m)) are STRUCTURAL: any failure ⇒ [invalid]
  /// (tampered/malformed). A structurally-sound franking that merely fails the
  /// freshness window ⇒ [stale] (e.g. a delayed offline-outbox send) — still a
  /// genuine message, just not CSAM-reportable, so the receiver displays it.
  static Future<AmfVerifyOutcome> verifyDetailed(
    AmfFrankedMessage fm,
    AmfPublicKeys keys, {
    Duration maxAge = amfDefaultMaxFrankAge,
  }) async {
    if (fm.x1.length != amfX1Len ||
        fm.x2.length != amfX1Len ||
        fm.r.length != 32 ||
        fm.pkE.length != 32 ||
        fm.sig1.length != 64 ||
        fm.sig2.length != 64 ||
        fm.com.length != 32 ||
        fm.sig3.length != 64) {
      return AmfVerifyOutcome.invalid;
    }
    // σ1: moderator vouches (x1, pk_e, t1).
    final sig1Data = <int>[...fm.x1, ...fm.pkE, ...be64(fm.t1)];
    if (!await _verifySig(sig1Data, fm.sig1, keys.moderatorPublicKey)) {
      return AmfVerifyOutcome.invalid;
    }
    // σ2: the ephemeral key (vouched by σ1) signed x2.
    if (!await _verifySig(fm.x2, fm.sig2, fm.pkE)) {
      return AmfVerifyOutcome.invalid;
    }
    // σ3: the platform stamped the commitment at t2.
    final sig3Data = <int>[...fm.com, ...be64(fm.t2)];
    if (!await _verifySig(sig3Data, fm.sig3, keys.platformPublicKey)) {
      return AmfVerifyOutcome.invalid;
    }
    // Commitment opens.
    if (!_constEq(_commit(fm.r, fm.x1, fm.x2), fm.com)) {
      return AmfVerifyOutcome.invalid;
    }
    // Binding: x1 ⊕ x2 == Hexp(m).
    final m = canonicalContent(fm.conversationId, fm.messageType, fm.payload);
    if (!_constEq(_xor(fm.x1, fm.x2), hexp(m))) {
      return AmfVerifyOutcome.invalid;
    }
    // Freshness gives backward security. Directional (matches Go): the stamp t2
    // must not predate issuance t1 beyond a small clock-skew grace, and the
    // issuance→stamp gap must be under maxAge — not a symmetric |t1−t2|.
    final gap = fm.t2 - fm.t1; // normally ≥ 0
    if (gap < -_clockSkewGrace.inSeconds || Duration(seconds: gap) >= maxAge) {
      return AmfVerifyOutcome.stale;
    }
    return AmfVerifyOutcome.valid;
  }

  static Future<bool> _verifySig(
    List<int> message,
    List<int> sig,
    List<int> publicKey,
  ) async {
    try {
      return await _ed25519.verify(
        message,
        signature: Signature(
          sig,
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  static bool _constEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Uint8List _randomBytes(int n) {
    // Same secure-random pattern as the rest of the app (e.g.
    // encrypted_backup_service): a cryptographically secure source.
    final rnd = Random.secure();
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = rnd.nextInt(256);
    }
    return out;
  }
}
