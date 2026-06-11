import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../crypto/pgp_service.dart';
import '../secure_storage_service.dart';
import 'ble_mesh_transport.dart';
import 'mesh_frames.dart';
import 'mesh_session.dart';

/// One nearby device as the UI sees it.
class NearbyPeer {
  final String linkId;
  final MeshSession session;

  /// Display name of the matched contact when the verified fingerprint
  /// belongs to someone we know; null = "unknown — verify fingerprint".
  String? matchedContactName;
  int deliveredCount = 0;
  int receivedCount = 0;

  NearbyPeer({required this.linkId, required this.session});

  MeshSessionState get state => session.state;
  String? get fingerprint => session.peer?.fingerprint;
  String? get advertisedName => session.peer?.displayName;
}

/// Orchestrates the whole Nearby feature while its screen is open: both BLE
/// roles, one authenticated [MeshSession] per link, queued-message delivery
/// to verified peers, and ingest of envelopes they push to us. Stopping the
/// service tears down advertising, scanning, and every session — the radio
/// is silent the moment the screen closes.
class NearbyMeshService extends ChangeNotifier {
  NearbyMeshService({
    required this._storage,
    required this.onEnvelope,
    required this.envelopesForPeer,
    required this.contactNameForFingerprint,
  });

  final SecureStorageService _storage;

  /// Hands a received envelope to ChatProvider; returns false when it had to
  /// be dropped (unknown conversation on this device).
  final Future<bool> Function(
    Map<String, dynamic> envelope,
    String senderFingerprint,
  ) onEnvelope;

  /// Queued outbox envelopes addressed to the DM with this fingerprint.
  final Future<List<Map<String, dynamic>>> Function(String fingerprint)
      envelopesForPeer;

  /// Contact display name for a verified fingerprint (null = unknown).
  final String? Function(String fingerprint) contactNameForFingerprint;

  final MeshPeripheral _peripheral = MeshPeripheral();
  final MeshCentral _central = MeshCentral();
  final Map<String, NearbyPeer> _peers = {};
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _running = false;
  String? _error;

  bool get isRunning => _running;
  String? get error => _error;
  List<NearbyPeer> get peers => List.unmodifiable(_peers.values);

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  Future<void> start() async {
    if (_running || !isSupported) return;
    _error = null;
    final granted = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
    ].request();
    if (granted.values.any((status) => !status.isGranted)) {
      _error = 'Bluetooth permissions are required for Nearby';
      notifyListeners();
      return;
    }
    final privateKey = await _storage.getPrivateKey();
    final publicKey = await _storage.getPublicKey();
    if (privateKey == null || publicKey == null) {
      _error = 'No PGP identity on this device';
      notifyListeners();
      return;
    }
    final fingerprint = await PgpService.fingerprintFromPublicKey(publicKey);
    final username = await _storage.getUsername() ?? '';
    _running = true;
    _subs.add(_peripheral.newLinks.listen(
      (link) => _attachLink(link, privateKey, publicKey, fingerprint, username),
    ));
    _subs.add(_central.newLinks.listen(
      (link) => _attachLink(link, privateKey, publicKey, fingerprint, username),
    ));
    try {
      // The advertised name is a random tag — identity never beacons.
      final tag = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      await _peripheral.start(localName: 'oc-$tag');
      await _central.start();
    } catch (e) {
      _error = 'Bluetooth unavailable: $e';
      await stop();
    }
    notifyListeners();
  }

  void _attachLink(
    MeshLink link,
    String privateKey,
    String publicKey,
    String fingerprint,
    String username,
  ) {
    if (!_running || _peers.containsKey(link.linkId)) return;
    final session = MeshSession(
      selfFingerprint: fingerprint,
      selfPublicKeyArmored: publicKey,
      selfDisplayName: username,
      sign: (data) =>
          PgpService.sign(data: data, privateKeyArmored: privateKey),
      verify: (data, signature, peerKey) => PgpService.verify(
        data: data,
        signatureArmor: signature,
        signerPublicKeyArmored: peerKey,
      ),
      fingerprintOf: PgpService.fingerprintFromPublicKey,
      sendFrame: (type, payload) =>
          link.sendFrame(encodeMeshFrame(type, payload)),
    );
    final peer = NearbyPeer(linkId: link.linkId, session: session);
    _peers[link.linkId] = peer;

    final reassembler = MeshReassembler();
    _subs.add(link.inboundChunks.listen((chunk) async {
      try {
        final frameBytes = reassembler.addChunk(chunk);
        if (frameBytes == null) return;
        await session.handleFrame(decodeMeshFrame(frameBytes));
      } on MeshFrameException {
        // Corrupt chunk stream — drop the partial frame, keep the link.
      }
    }, onDone: () => _dropPeer(link.linkId)));

    _subs.add(session.stateChanges.listen((state) {
      if (state == MeshSessionState.authenticated) {
        final fp = session.peer!.fingerprint;
        peer.matchedContactName = contactNameForFingerprint(fp);
        unawaited(deliverQueuedTo(peer));
      }
      notifyListeners();
    }));

    _subs.add(session.messages.listen((envelope) async {
      final fp = session.peer?.fingerprint;
      if (fp == null) return;
      final accepted = await onEnvelope(envelope, fp);
      if (accepted) {
        peer.receivedCount++;
        notifyListeners();
      }
    }));

    unawaited(session.start().catchError((_) {}));
    notifyListeners();
  }

  /// Pushes every queued outbox message for this verified peer over the
  /// link. Items stay queued for the normal server drain — the mesh is a
  /// second path, and the server copy wins dedup later.
  Future<void> deliverQueuedTo(NearbyPeer peer) async {
    final fp = peer.fingerprint;
    if (fp == null || !peer.session.authenticated) return;
    final envelopes = await envelopesForPeer(fp);
    for (final envelope in envelopes) {
      try {
        await peer.session.sendMessageEnvelope(envelope);
        peer.deliveredCount++;
        notifyListeners();
      } catch (_) {
        break; // link died mid-drain; remaining items stay queued
      }
    }
  }

  void _dropPeer(String linkId) {
    final peer = _peers.remove(linkId);
    peer?.session.dispose();
    if (peer != null) notifyListeners();
  }

  Future<void> stop() async {
    _running = false;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    await _central.stop();
    await _peripheral.stop();
    for (final peer in _peers.values) {
      peer.session.dispose();
    }
    _peers.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}
