/// Mesh wire protocol, layer 0b: local-network links. UDP multicast
/// discovery beacons + one TCP frame pipe per peer. The identity handshake,
/// acks, and PGP envelopes layer on top unchanged — this is just a faster
/// radio, orders of magnitude quicker than BLE, and it works wherever an IP
/// network does (including Linux↔Linux, which BLE can't serve because
/// ble_peripheral has no BlueZ backend).
///
/// Privacy matches the BLE transport: the beacon carries a random
/// per-session tag and a port, never identity, and everything stops the
/// moment the mesh service stops. Anyone on the LAN can see *a* device is
/// discoverable — exactly what BLE advertising already reveals — but who it
/// is only emerges inside the signed handshake.
///
/// Framing on TCP: each record is [u32 LE length][bytes]. A whole mesh
/// frame travels as a single record, which the reassembler upstream treats
/// as a one-chunk frame (the link advertises a chunk size bigger than any
/// frame).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'ble_mesh_transport.dart';
import 'mesh_frames.dart';

/// Multicast group + port for discovery beacons. The group is in the
/// organization-local 239/8 block.
final InternetAddress lanMeshMulticastGroup = InternetAddress('239.77.83.72');
const int lanMeshDiscoveryPort = 47820;
const String _beaconPrefix = 'oc-mesh:v1:';

/// `oc-mesh:v1:<sessionTag>:<tcpPort>` → (tag, port), or null when the
/// datagram isn't ours. Pure — unit-testable without sockets.
({String tag, int port})? parseLanBeacon(String datagram) {
  if (!datagram.startsWith(_beaconPrefix)) return null;
  final parts = datagram.substring(_beaconPrefix.length).split(':');
  if (parts.length != 2) return null;
  final tag = parts[0];
  final port = int.tryParse(parts[1]);
  if (tag.isEmpty || tag.length > 64 || port == null || port < 1 ||
      port > 65535) {
    return null;
  }
  return (tag: tag, port: port);
}

String lanBeaconPayload(String tag, int port) => '$_beaconPrefix$tag:$port';

/// One TCP link to a LAN peer. Records arrive as whole frames, so the
/// "chunk" size just needs to exceed the largest legal frame.
class LanMeshLink extends MeshLink {
  LanMeshLink(this._socket) {
    _socket.listen(
      _onBytes,
      onDone: () => unawaited(close()),
      onError: (_) => unawaited(close()),
    );
  }

  final Socket _socket;
  final BytesBuilder _pending = BytesBuilder();
  final StreamController<Uint8List> _inbound = StreamController.broadcast();
  bool _closed = false;

  static const int _maxRecordBytes = meshMaxFrameBytes + 64;

  @override
  String get linkId =>
      'lan-${_socket.remoteAddress.address}:${_socket.remotePort}';

  @override
  Stream<Uint8List> get inboundChunks => _inbound.stream;

  @override
  int get maxChunkBytes => _maxRecordBytes;

  void _onBytes(Uint8List bytes) {
    _pending.add(bytes);
    while (true) {
      final buffered = _pending.toBytes();
      if (buffered.length < 4) return;
      final length = ByteData.sublistView(buffered).getUint32(
        0,
        Endian.little,
      );
      if (length > _maxRecordBytes) {
        // Not speaking our protocol (or hostile) — drop the link.
        unawaited(close());
        return;
      }
      if (buffered.length < 4 + length) return;
      _pending.clear();
      _pending.add(Uint8List.sublistView(buffered, 4 + length));
      _inbound.add(
        Uint8List.fromList(Uint8List.sublistView(buffered, 4, 4 + length)),
      );
    }
  }

  @override
  Future<void> sendChunk(Uint8List chunk) async {
    final header = ByteData(4)..setUint32(0, chunk.length, Endian.little);
    _socket.add(header.buffer.asUint8List());
    _socket.add(chunk);
    await _socket.flush();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
    await _inbound.close();
  }
}

/// Discovery + dialing. Both sides beacon; the lexicographically smaller
/// session tag dials, so a pair never opens two crossing connections.
class LanMeshTransport {
  ServerSocket? _server;
  RawDatagramSocket? _udp;
  Timer? _beaconTimer;
  String _tag = '';
  bool _running = false;
  final Set<String> _dialedTags = {};
  final StreamController<LanMeshLink> _newLinks =
      StreamController.broadcast();

  Stream<LanMeshLink> get newLinks => _newLinks.stream;
  bool get isRunning => _running;

  Future<void> start({required String sessionTag}) async {
    if (_running) return;
    _tag = sessionTag;
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server!.listen((socket) {
      if (_running) {
        _newLinks.add(LanMeshLink(socket));
      } else {
        socket.destroy();
      }
    });
    _udp = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      lanMeshDiscoveryPort,
      reuseAddress: true,
      reusePort: !Platform.isWindows && !Platform.isAndroid,
    );
    try {
      _udp!.joinMulticast(lanMeshMulticastGroup);
    } catch (_) {
      // Multicast joins can fail on exotic interfaces; broadcast still works.
    }
    _udp!.broadcastEnabled = true;
    // Loopback stays on so two instances on one machine can pair (handy for
    // desktop testing); our own beacons are filtered by session tag.
    _udp!.multicastLoopback = true;
    _udp!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _udp?.receive();
      if (datagram == null) return;
      final beacon = parseLanBeacon(
        utf8.decode(datagram.data, allowMalformed: true),
      );
      if (beacon != null) {
        unawaited(_maybeDial(datagram.address, beacon));
      }
    });
    _running = true;
    _beaconTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _sendBeacon(),
    );
    _sendBeacon();
  }

  void _sendBeacon() {
    final udp = _udp;
    final server = _server;
    if (udp == null || server == null) return;
    final payload = utf8.encode(lanBeaconPayload(_tag, server.port));
    try {
      udp.send(payload, lanMeshMulticastGroup, lanMeshDiscoveryPort);
      // Broadcast fallback for networks that filter multicast.
      udp.send(
        payload,
        InternetAddress('255.255.255.255'),
        lanMeshDiscoveryPort,
      );
    } catch (_) {}
  }

  Future<void> _maybeDial(
    InternetAddress from,
    ({String tag, int port}) beacon,
  ) async {
    if (!_running || beacon.tag == _tag) return;
    // Exactly one side dials: the one with the smaller tag.
    if (_tag.compareTo(beacon.tag) >= 0) return;
    if (!_dialedTags.add(beacon.tag)) return;
    try {
      final socket = await Socket.connect(
        from,
        beacon.port,
        timeout: const Duration(seconds: 5),
      );
      if (!_running) {
        socket.destroy();
        return;
      }
      _newLinks.add(LanMeshLink(socket));
    } catch (_) {
      _dialedTags.remove(beacon.tag); // out of reach — retry on a later beacon
    }
  }

  Future<void> stop() async {
    _running = false;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _udp?.close();
    _udp = null;
    await _server?.close();
    _server = null;
    _dialedTags.clear();
  }
}
