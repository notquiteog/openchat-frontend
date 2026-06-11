library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../crypto/pgp_service.dart';
import '../secure_storage_service.dart';
import 'ble_mesh_transport.dart';
import 'mesh_frames.dart';
import 'mesh_platform.dart';
import 'mesh_session.dart';

/// One nearby device as the UI sees it.
class NearbyPeer {
  final String linkId;
  final MeshSession session;

  /// Signal strength at discovery (dBm); null on peripheral-side links.
  final int? rssi;

  /// Display name of the matched contact when the verified fingerprint
  /// belongs to someone we know; null = "unknown — verify fingerprint".
  String? matchedContactName;

  /// Envelopes pushed over this link (the peer may not have acked yet).
  int sentCount = 0;

  /// Envelopes the peer confirmed ingesting (ack accepted). Older builds
  /// never ack, so this can lag sentCount on mixed-version links.
  int confirmedCount = 0;

  /// Envelopes the peer explicitly refused (ack rejected) — usually the DM
  /// doesn't exist on that device. Not retried this session.
  int rejectedCount = 0;
  int receivedCount = 0;

  /// Nonces the peer already answered — never re-sent on this session.
  final Set<String> ackedNonces = {};
  bool _draining = false;
  bool _redrainRequested = false;

  NearbyPeer({required this.linkId, required this.session, this.rssi});

  MeshSessionState get state => session.state;
  String? get fingerprint => session.peer?.fingerprint;
  String? get advertisedName => session.peer?.displayName;
}

/// Orchestrates the whole Nearby feature while its screen is open: both BLE
/// roles (or central-only, per [MeshRole]), one authenticated [MeshSession]
/// per link, queued-message delivery to verified peers with per-envelope
/// acks, and ingest of envelopes they push to us. Stopping the service tears
/// down advertising, scanning, and every session — the radio is silent the
/// moment the screen closes.
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
  Timer? _redrainDebounce;
  bool _running = false;
  bool _discoverable = false;
  String? _error;

  bool get isRunning => _running;

  /// True when the peripheral half is live — other devices can find us. On
  /// central-only platforms (Linux) this stays false: we can find dual-role
  /// peers, but they cannot initiate toward us.
  bool get isDiscoverable => _discoverable;
  String? get error => _error;
  List<NearbyPeer> get peers => List.unmodifiable(_peers.values);

  static MeshRole get role => currentMeshRole;
  static bool get isSupported => role.canRun;

  Future<void> start() async {
    if (_running || !isSupported) return;
    _error = null;
    if (!await _ensurePermissions()) {
      _error = 'Bluetooth permissions are required for Nearby';
      notifyListeners();
      return;
    }
    if (!await meshAdapterIsOn()) {
      _error = 'Bluetooth is turned off or unavailable';
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
    if (role.advertises) {
      try {
        // The advertised name is a random tag — identity never beacons.
        final tag = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
        await _peripheral.start(localName: 'oc-$tag');
        _discoverable = true;
      } catch (_) {
        // Some adapters can't advertise (no LE peripheral mode). Degrade to
        // central-only instead of failing the whole feature.
        _discoverable = false;
      }
    }
    try {
      await _central.start();
    } catch (e) {
      _error = 'Bluetooth unavailable: $e';
      await stop();
    }
    notifyListeners();
  }

  /// Runtime permission prompts exist only on mobile; desktop platforms gate
  /// Bluetooth at the OS level (macOS asks via the Info.plist usage string).
  Future<bool> _ensurePermissions() async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final granted = await [
          Permission.bluetoothScan,
          Permission.bluetoothAdvertise,
          Permission.bluetoothConnect,
        ].request();
        return granted.values.every((status) => status.isGranted);
      case TargetPlatform.iOS:
        return (await Permission.bluetooth.request()).isGranted;
      default:
        return true;
    }
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
    final peer = NearbyPeer(
      linkId: link.linkId,
      session: session,
      rssi: link.rssi,
    );
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

    _subs.add(session.acks.listen((ack) {
      if (!peer.ackedNonces.add(ack.nonce)) return;
      if (ack.accepted) {
        peer.confirmedCount++;
      } else {
        peer.rejectedCount++;
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
      final nonce = envelope['client_nonce']?.toString() ?? '';
      if (nonce.isNotEmpty) {
        // Receipt back to the sender; harmlessly ignored by older builds.
        unawaited(
          session.sendAck(nonce, accepted: accepted).catchError((_) {}),
        );
      }
    }));

    unawaited(session.start().catchError((_) {}));
    notifyListeners();
  }

  /// Pushes every queued outbox message for this verified peer over the
  /// link, skipping nonces the peer already answered this session. Items
  /// stay queued for the normal server drain — the mesh is a second path,
  /// and the server copy wins dedup later.
  Future<void> deliverQueuedTo(NearbyPeer peer) async {
    final fp = peer.fingerprint;
    if (fp == null || !peer.session.authenticated) return;
    if (peer._draining) {
      // A drain is in flight; have it sweep the outbox once more when it
      // finishes so an item queued mid-drain is not stranded.
      peer._redrainRequested = true;
      return;
    }
    peer._draining = true;
    try {
      do {
        peer._redrainRequested = false;
        final envelopes = await envelopesForPeer(fp);
        for (final envelope in envelopes) {
          final nonce = envelope['client_nonce']?.toString() ?? '';
          if (nonce.isNotEmpty && peer.ackedNonces.contains(nonce)) continue;
          try {
            await peer.session.sendMessageEnvelope(envelope);
            peer.sentCount++;
            notifyListeners();
          } catch (_) {
            return; // link died mid-drain; remaining items stay queued
          }
        }
      } while (peer._redrainRequested && _running);
    } finally {
      peer._draining = false;
    }
  }

  /// Call when the outbox may have grown (e.g. the user wrote a message in
  /// a DM while this screen is open). Debounced; re-drains every
  /// authenticated peer, so an in-range contact receives new messages live.
  void notifyOutboxMaybeChanged() {
    if (!_running) return;
    _redrainDebounce?.cancel();
    _redrainDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!_running) return;
      for (final peer in _peers.values) {
        if (peer.session.authenticated) {
          unawaited(deliverQueuedTo(peer));
        }
      }
    });
  }

  void _dropPeer(String linkId) {
    final peer = _peers.remove(linkId);
    peer?.session.dispose();
    if (peer != null) notifyListeners();
  }

  Future<void> stop() async {
    _running = false;
    _discoverable = false;
    _redrainDebounce?.cancel();
    _redrainDebounce = null;
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
