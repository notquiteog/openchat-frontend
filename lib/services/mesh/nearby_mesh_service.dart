library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../crypto/pgp_service.dart';
import '../secure_storage_service.dart';
import 'ble_mesh_transport.dart';
import 'lan_mesh_transport.dart';
import 'mesh_frames.dart';
import 'mesh_platform.dart';
import 'mesh_session.dart';

/// One nearby device as the UI sees it.
class NearbyPeer {
  final String linkId;
  final MeshSession session;

  /// The transport carrying this peer (null only in unit tests).
  final MeshLink? link;

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

  NearbyPeer({
    required this.linkId,
    required this.session,
    this.link,
    this.rssi,
  });

  MeshSessionState get state => session.state;
  String? get fingerprint => session.peer?.fingerprint;
  String? get advertisedName => session.peer?.displayName;
  bool get isLan => link is LanMeshLink;
}

/// Orchestrates the whole Nearby feature: both BLE roles (or central-only,
/// per [MeshRole]), one authenticated [MeshSession] per link, queued-message
/// delivery to verified peers with per-envelope acks, and ingest of
/// envelopes they push to us.
///
/// Foreground-only guarantee: the radio runs while the Nearby screen is
/// attached — or, when [keepAliveWhileAppOpen] is on, while the app itself
/// is in the foreground — and stops the moment the app backgrounds or the
/// last reason to run goes away. There is never a background beacon.
class NearbyMeshService extends ChangeNotifier with WidgetsBindingObserver {
  NearbyMeshService({
    required this._storage,
    required this.onEnvelope,
    required this.envelopesForPeer,
    required this.contactNameForFingerprint,
    this.onEnvelopeAcked,
    this._outboxSignal,
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

  /// The peer answered one of our envelopes (nonce == pending message id).
  /// Lets ChatProvider flip the pending bubble to "delivered nearby".
  final void Function(String nonce, bool accepted)? onEnvelopeAcked;

  /// Fires when the outbox may have grown (ChatProvider itself); listened to
  /// only while running, so a queued message re-drains live.
  final Listenable? _outboxSignal;

  final MeshPeripheral _peripheral = MeshPeripheral();
  final MeshCentral _central = MeshCentral();
  final LanMeshTransport _lan = LanMeshTransport();
  final Map<String, NearbyPeer> _peers = {};
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _redrainDebounce;
  bool _running = false;
  bool _discoverable = false;
  bool _observing = false;
  bool _resumeOnForeground = false;
  int _attachedScreens = 0;
  bool _keepAliveWhileAppOpen = false;
  String? _selfFingerprint;
  String? _error;

  bool get isRunning => _running;

  /// True when the peripheral half is live — other devices can find us. On
  /// central-only platforms (Linux) this stays false: we can find dual-role
  /// peers, but they cannot initiate toward us.
  bool get isDiscoverable => _discoverable;

  /// Our own key fingerprint, available once the radio has started — the
  /// comparison sheet shows it next to an unknown peer's.
  String? get selfFingerprint => _selfFingerprint;

  /// True while the local-network transport (UDP discovery + TCP frames) is
  /// up — the fast path, and the only one two Linux machines share.
  bool get lanActive => _lan.isRunning;
  String? get error => _error;
  List<NearbyPeer> get peers => List.unmodifiable(_peers.values);

  static MeshRole get role => currentMeshRole;
  static bool get isSupported => role.canRun;

  /// Radio outlives the Nearby screen (but never the foregrounded app) so
  /// the user can chat while queued messages keep exchanging.
  bool get keepAliveWhileAppOpen => _keepAliveWhileAppOpen;
  set keepAliveWhileAppOpen(bool value) {
    if (_keepAliveWhileAppOpen == value) return;
    _keepAliveWhileAppOpen = value;
    if (!value && _attachedScreens <= 0) {
      unawaited(stop());
    } else {
      notifyListeners();
    }
  }

  /// The Nearby screen came on stage: make sure the radio is up.
  void attachScreen() {
    _attachedScreens++;
    unawaited(start());
  }

  /// The Nearby screen left. Without the keep-alive opt-in this silences the
  /// radio immediately — the original foreground-only behavior.
  void detachScreen() {
    _attachedScreens = (_attachedScreens - 1).clamp(0, 1 << 30);
    if (_attachedScreens <= 0 && !_keepAliveWhileAppOpen) {
      unawaited(stop());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // No background beaconing, ever — regardless of keep-alive.
        if (_running) {
          _resumeOnForeground = true;
          unawaited(stop());
        }
      case AppLifecycleState.resumed:
        if (_resumeOnForeground) {
          _resumeOnForeground = false;
          unawaited(start());
        }
      case AppLifecycleState.inactive:
        break; // transient (app switcher, permission dialogs) — keep running
    }
  }

  Future<void> start() async {
    if (_running || !isSupported) return;
    if (!_observing) {
      // Lazy registration keeps the constructor binding-free (testable) and
      // the observer survives stop() so a backgrounded radio can resume.
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    _error = null;
    final privateKey = await _storage.getPrivateKey();
    final publicKey = await _storage.getPublicKey();
    if (privateKey == null || publicKey == null) {
      _error = 'No PGP identity on this device';
      notifyListeners();
      return;
    }
    final fingerprint = await PgpService.fingerprintFromPublicKey(publicKey);
    _selfFingerprint = fingerprint;
    final username = await _storage.getUsername() ?? '';
    final userId = await _storage.getUserID() ?? '';
    final self = (
      privateKey: privateKey,
      publicKey: publicKey,
      fingerprint: fingerprint,
      username: username,
      userId: userId,
    );
    _running = true;
    _subs.add(_peripheral.newLinks.listen((link) => _attachLink(link, self)));
    _subs.add(_central.newLinks.listen((link) => _attachLink(link, self)));
    _subs.add(_lan.newLinks.listen((link) => _attachLink(link, self)));

    // The advertised name / LAN beacon is a RANDOM session tag — identity
    // never beacons on either transport.
    final tag = DateTime.now().microsecondsSinceEpoch.toRadixString(36);

    // BLE and LAN start independently: Bluetooth being off (or denied)
    // must not take the local-network path down with it, and vice versa.
    var bleUp = false;
    if (await _ensurePermissions() && await meshAdapterIsOn()) {
      if (role.advertises) {
        try {
          await _peripheral.start(localName: 'oc-$tag');
          _discoverable = true;
        } catch (_) {
          // Some adapters can't advertise (no LE peripheral mode). Degrade
          // to central-only instead of failing the whole feature.
          _discoverable = false;
        }
      }
      try {
        await _central.start();
        bleUp = true;
      } catch (_) {}
    }
    try {
      await _lan.start(sessionTag: tag);
    } catch (_) {}

    if (!bleUp && !_lan.isRunning) {
      _error = 'Neither Bluetooth nor a local network is available';
      await stop();
      return;
    }
    _outboxSignal?.addListener(notifyOutboxMaybeChanged);
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
    ({
      String privateKey,
      String publicKey,
      String fingerprint,
      String username,
      String userId,
    }) self,
  ) {
    if (!_running || _peers.containsKey(link.linkId)) return;
    final session = MeshSession(
      selfFingerprint: self.fingerprint,
      selfPublicKeyArmored: self.publicKey,
      selfDisplayName: self.username,
      selfUserId: self.userId,
      sign: (data) =>
          PgpService.sign(data: data, privateKeyArmored: self.privateKey),
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
      link: link,
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
        // The same person can surface on BLE and LAN at once. Keep one
        // link, preferring LAN (~1000× the throughput).
        final twin = _peers.values
            .where((p) =>
                p.linkId != peer.linkId &&
                p.session.authenticated &&
                p.fingerprint == fp)
            .firstOrNull;
        if (twin != null) {
          final loser = peer.isLan && !twin.isLan ? twin : peer;
          unawaited(loser.link?.close()); // onDone drops the peer entry
          if (loser == peer) return;
        }
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
      onEnvelopeAcked?.call(ack.nonce, ack.accepted);
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
    if (peer == null) return;
    unawaited(peer.link?.close()); // idempotent — usually already closed
    peer.session.dispose();
    notifyListeners();
  }

  Future<void> stop() async {
    _running = false;
    _discoverable = false;
    _outboxSignal?.removeListener(notifyOutboxMaybeChanged);
    _redrainDebounce?.cancel();
    _redrainDebounce = null;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    await _central.stop();
    await _peripheral.stop();
    await _lan.stop();
    for (final peer in _peers.values) {
      // Central-dialed GATT links and LAN sockets outlive their transports'
      // stop() — close them explicitly or the connections linger.
      unawaited(peer.link?.close());
      peer.session.dispose();
    }
    _peers.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    unawaited(stop());
    super.dispose();
  }
}
