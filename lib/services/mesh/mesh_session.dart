import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'mesh_frames.dart';

/// Mesh wire protocol, layer 2: the identity-proof handshake and message
/// channel. Transport-agnostic and crypto-injectable, so the whole state
/// machine is unit-testable by wiring two sessions together with fake crypto.
///
/// Both sides run the same symmetric dance after the GATT link is up:
///   1. hello  {session_id, fingerprint, public_key, name, challenge}
///   2. proof  {signature over `openchat-mesh-proof:v1:(signer session):`
///              `(verifier session):(verifier challenge)`}
/// A signature binds the signer's PGP key to THIS pair of ephemeral session
/// ids and the verifier's fresh challenge — replaying a recorded proof at a
/// new session fails because both ids and the challenge differ. Only after
/// BOTH proofs verify does the session accept message and ack frames.
///
/// The advertisement itself carries only the random session id: identity is
/// revealed exclusively to a connected peer, never beaconed.

typedef MeshSign = Future<String> Function(String data);
typedef MeshVerify = Future<bool> Function(
    String data, String signature, String publicKeyArmored);
typedef MeshFingerprintOf = Future<String> Function(String publicKeyArmored);
typedef MeshFrameSender = Future<void> Function(int type, Uint8List payload);

enum MeshSessionState { idle, helloSent, awaitingProof, authenticated, failed }

/// Receiver's verdict for one message envelope, keyed by its client nonce.
/// accepted=false means the peer could not ingest it (e.g. no matching DM on
/// that device) — re-sending the same payload will not change the outcome.
class MeshAck {
  final String nonce;
  final bool accepted;
  const MeshAck({required this.nonce, required this.accepted});
}

class MeshPeer {
  final String sessionId;
  final String fingerprint;
  final String publicKeyArmored;
  final String displayName;

  const MeshPeer({
    required this.sessionId,
    required this.fingerprint,
    required this.publicKeyArmored,
    required this.displayName,
  });
}

class MeshSession {
  MeshSession({
    required this.selfFingerprint,
    required this.selfPublicKeyArmored,
    required this.selfDisplayName,
    required this._sign,
    required this._verify,
    required this._fingerprintOf,
    required this._sendFrame,
    String? sessionId,
    Random? random,
  }) : _random = random ?? Random.secure() {
    this.sessionId = sessionId ?? _randomHex(16);
    _challenge = _randomHex(32);
  }

  final String selfFingerprint;
  final String selfPublicKeyArmored;
  final String selfDisplayName;
  final MeshSign _sign;
  final MeshVerify _verify;
  final MeshFingerprintOf _fingerprintOf;
  final MeshFrameSender _sendFrame;
  final Random _random;

  late final String sessionId;
  late final String _challenge;

  MeshSessionState _state = MeshSessionState.idle;
  MeshPeer? _peer;
  bool _proofSent = false;
  bool _peerProofVerified = false;
  String? _failure;

  final StreamController<MeshSessionState> _stateController =
      StreamController.broadcast();
  final StreamController<Map<String, dynamic>> _messages =
      StreamController.broadcast();
  final StreamController<MeshAck> _acks = StreamController.broadcast();

  MeshSessionState get state => _state;
  MeshPeer? get peer => _peer;
  String? get failure => _failure;
  bool get authenticated => _state == MeshSessionState.authenticated;
  Stream<MeshSessionState> get stateChanges => _stateController.stream;

  /// Decoded `message` frame payloads, emitted only on authenticated
  /// sessions.
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// Delivery receipts from the peer for envelopes we sent. Older builds
  /// never send acks, so absence of an ack only means "unconfirmed".
  Stream<MeshAck> get acks => _acks.stream;

  String _randomHex(int bytes) {
    final b = List<int>.generate(bytes, (_) => _random.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  static String proofData({
    required String signerSessionId,
    required String verifierSessionId,
    required String verifierChallenge,
  }) =>
      'openchat-mesh-proof:v1:$signerSessionId:$verifierSessionId:$verifierChallenge';

  /// Kicks off the handshake. Safe to call once per session, from either or
  /// both ends (hellos cross harmlessly).
  Future<void> start() async {
    if (_state != MeshSessionState.idle) return;
    _setState(MeshSessionState.helloSent);
    await _sendHello();
  }

  Future<void> _sendHello() => _sendJson(meshFrameHello, {
        'session_id': sessionId,
        'fingerprint': selfFingerprint,
        'public_key': selfPublicKeyArmored,
        'name': selfDisplayName,
        'challenge': _challenge,
      });

  Future<void> _sendJson(int type, Map<String, dynamic> json) =>
      _sendFrame(type, Uint8List.fromList(utf8.encode(jsonEncode(json))));

  /// Sends an encrypted message envelope. Only legal once authenticated.
  Future<void> sendMessageEnvelope(Map<String, dynamic> envelope) async {
    if (!authenticated) {
      throw StateError('mesh session is not authenticated');
    }
    await _sendJson(meshFrameMessage, envelope);
  }

  /// Acknowledges a received envelope by client nonce. Only legal once
  /// authenticated.
  Future<void> sendAck(String nonce, {required bool accepted}) async {
    if (!authenticated) {
      throw StateError('mesh session is not authenticated');
    }
    await _sendJson(meshFrameAck, {'nonce': nonce, 'accepted': accepted});
  }

  /// Feed every decoded frame from the transport here.
  Future<void> handleFrame(MeshFrame frame) async {
    if (_state == MeshSessionState.failed) return;
    Map<String, dynamic> json;
    try {
      json = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(frame.payload)) as Map,
      );
    } catch (_) {
      _fail('malformed frame payload');
      return;
    }
    switch (frame.type) {
      case meshFrameHello:
        await _handleHello(json);
      case meshFrameProof:
        await _handleProof(json);
      case meshFrameMessage:
        if (!authenticated) {
          _fail('message before authentication');
          return;
        }
        _messages.add(json);
      case meshFrameAck:
        if (!authenticated) {
          _fail('ack before authentication');
          return;
        }
        final nonce = json['nonce']?.toString() ?? '';
        if (nonce.isNotEmpty) {
          _acks.add(MeshAck(
            nonce: nonce,
            accepted: json['accepted'] == true,
          ));
        }
      default:
        _fail('unknown frame type ${frame.type}');
    }
  }

  Future<void> _handleHello(Map<String, dynamic> json) async {
    if (_peer != null) return; // duplicate hello — ignore
    final peerSession = json['session_id']?.toString() ?? '';
    final claimedFp = (json['fingerprint']?.toString() ?? '').toUpperCase();
    final publicKey = json['public_key']?.toString() ?? '';
    final challenge = json['challenge']?.toString() ?? '';
    if (peerSession.isEmpty ||
        claimedFp.isEmpty ||
        publicKey.isEmpty ||
        challenge.isEmpty) {
      _fail('incomplete hello');
      return;
    }
    if (peerSession == sessionId) {
      _fail('session id collision');
      return;
    }
    // The fingerprint must actually be the key's — a peer cannot claim a
    // contact's fingerprint while presenting a different key.
    final String actualFp;
    try {
      actualFp = (await _fingerprintOf(publicKey)).toUpperCase();
    } catch (_) {
      _fail('unparseable public key');
      return;
    }
    if (actualFp != claimedFp) {
      _fail('fingerprint does not match presented key');
      return;
    }
    _peer = MeshPeer(
      sessionId: peerSession,
      fingerprint: actualFp,
      publicKeyArmored: publicKey,
      displayName: json['name']?.toString() ?? '',
    );
    // Responder path: we learned of the peer before start() ran.
    if (_state == MeshSessionState.idle) {
      await _sendHello();
    }
    final signature = await _sign(proofData(
      signerSessionId: sessionId,
      verifierSessionId: peerSession,
      verifierChallenge: challenge,
    ));
    await _sendJson(meshFrameProof, {'signature': signature});
    _proofSent = true;
    _setState(MeshSessionState.awaitingProof);
    _maybeAuthenticated();
  }

  Future<void> _handleProof(Map<String, dynamic> json) async {
    final peer = _peer;
    if (peer == null) {
      _fail('proof before hello');
      return;
    }
    if (_peerProofVerified) return;
    final signature = json['signature']?.toString() ?? '';
    final ok = signature.isNotEmpty &&
        await _verify(
          proofData(
            signerSessionId: peer.sessionId,
            verifierSessionId: sessionId,
            verifierChallenge: _challenge,
          ),
          signature,
          peer.publicKeyArmored,
        );
    if (!ok) {
      _fail('identity proof failed verification');
      return;
    }
    _peerProofVerified = true;
    _maybeAuthenticated();
  }

  void _maybeAuthenticated() {
    if (_peerProofVerified && _proofSent &&
        _state != MeshSessionState.authenticated) {
      _setState(MeshSessionState.authenticated);
    }
  }

  void _fail(String reason) {
    _failure = reason;
    _setState(MeshSessionState.failed);
  }

  void _setState(MeshSessionState next) {
    if (_state == next) return;
    // Terminal/peak states never regress: a fully-cascaded handshake (the
    // peer's replies arriving inside our own awaits) must not let an outer
    // frame's bookkeeping overwrite authenticated, and failed is sticky.
    if (_state == MeshSessionState.failed) return;
    if (_state == MeshSessionState.authenticated &&
        next != MeshSessionState.failed) {
      return;
    }
    _state = next;
    _stateController.add(next);
  }

  void dispose() {
    _stateController.close();
    _messages.close();
    _acks.close();
  }
}
