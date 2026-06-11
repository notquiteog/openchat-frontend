/// Mesh wire protocol, layer 0: BLE links. One GATT service with two
/// characteristics — central writes frames into `inbox`, peripheral pushes
/// frames out through `outbox` notifications. On dual-role platforms
/// (Android, iOS, macOS, Windows — see mesh_platform.dart) both roles run at
/// once (advertise + scan), so two devices connect whichever direction wins
/// first; central-only platforms (Linux) just scan and dial.
///
/// Active ONLY while the Nearby screen is open: advertising carries the
/// service UUID and a random per-session id — never identity — and
/// everything stops when the screen closes (no background beacon).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:flutter_blue_ce/flutter_blue_ce.dart' as fbp;

import 'mesh_frames.dart';

const String meshServiceUuid = '6f70656e-6368-6174-0001-6d6573683031';
const String meshInboxUuid = '6f70656e-6368-6174-0002-6d6573683031';
const String meshOutboxUuid = '6f70656e-6368-6174-0003-6d6573683031';

/// Conservative default when MTU negotiation fails: 23-byte minimum MTU
/// minus the 3-byte ATT header.
const int _fallbackChunkBytes = 20;

/// Resolves once the adapter reports a usable state. Returns true when
/// Bluetooth is on — anything else (off, unauthorized, unavailable, or no
/// report within [timeout]) means the radio cannot start.
Future<bool> meshAdapterIsOn({
  Duration timeout = const Duration(seconds: 4),
}) async {
  try {
    final state = await fbp.FlutterBluePlus.adapterState
        .firstWhere(
          (s) =>
              s != fbp.BluetoothAdapterState.unknown &&
              s != fbp.BluetoothAdapterState.turningOn &&
              s != fbp.BluetoothAdapterState.turningOff,
        )
        .timeout(timeout);
    return state == fbp.BluetoothAdapterState.on;
  } catch (_) {
    return false;
  }
}

/// A bidirectional chunk pipe to one peer, regardless of which side dialed.
abstract class MeshLink {
  /// Stable transport-level id (BLE address) for bookkeeping.
  String get linkId;
  Stream<Uint8List> get inboundChunks;
  int get maxChunkBytes;
  Future<void> sendChunk(Uint8List chunk);
  Future<void> close();

  /// Signal strength at discovery time (dBm); null when we are the
  /// peripheral — the OS GATT server doesn't report the central's RSSI.
  int? get rssi => null;

  /// Sends a whole frame as ordered chunks.
  Future<void> sendFrame(Uint8List frame) async {
    for (final chunk in splitMeshFrame(frame, maxChunkBytes)) {
      await sendChunk(chunk);
    }
  }
}

/// Central role: we scanned, we connected, we write into the peer's inbox
/// and subscribe to its outbox.
class CentralMeshLink extends MeshLink {
  CentralMeshLink._(this._device, this._inbox, this._outbox, this._mtu, this.rssi);

  final fbp.BluetoothDevice _device;
  final fbp.BluetoothCharacteristic _inbox;
  final fbp.BluetoothCharacteristic _outbox;
  final int _mtu;

  @override
  final int? rssi;

  StreamSubscription<List<int>>? _notifySub;
  final StreamController<Uint8List> _inbound = StreamController.broadcast();

  static Future<CentralMeshLink> connect(
    fbp.BluetoothDevice device, {
    int? rssi,
  }) async {
    // connect() itself negotiates MTU 512 on Android; iOS/macOS/Windows
    // negotiate automatically and report through mtuNow. requestMtu() throws
    // everywhere but Android, so never call it here.
    await device.connect(timeout: const Duration(seconds: 15));
    final services = await device.discoverServices();
    final mtu = device.mtuNow < 23 ? _fallbackChunkBytes + 3 : device.mtuNow;
    final service = services.firstWhere(
      (s) => s.uuid.str128.toLowerCase() == meshServiceUuid,
      orElse: () => throw StateError('peer does not expose the mesh service'),
    );
    fbp.BluetoothCharacteristic byUuid(String uuid) =>
        service.characteristics.firstWhere(
          (c) => c.uuid.str128.toLowerCase() == uuid,
          orElse: () => throw StateError('mesh characteristic missing'),
        );
    final link = CentralMeshLink._(
      device,
      byUuid(meshInboxUuid),
      byUuid(meshOutboxUuid),
      mtu,
      rssi,
    );
    link._notifySub = link._outbox.onValueReceived.listen(
      (value) => link._inbound.add(Uint8List.fromList(value)),
    );
    await link._outbox.setNotifyValue(true);
    return link;
  }

  @override
  String get linkId => _device.remoteId.str;

  @override
  Stream<Uint8List> get inboundChunks => _inbound.stream;

  @override
  int get maxChunkBytes => _mtu - 3;

  @override
  Future<void> sendChunk(Uint8List chunk) =>
      _inbox.write(chunk, withoutResponse: false);

  @override
  Future<void> close() async {
    await _notifySub?.cancel();
    await _inbound.close();
    try {
      await _device.disconnect();
    } catch (_) {}
  }
}

/// Peripheral role: the OS GATT server owns the connection; we key everything
/// by the central's device id, receive its inbox writes via callback, and
/// answer through outbox notifications.
class PeripheralMeshLink extends MeshLink {
  PeripheralMeshLink({required this.deviceId, required this._mtu});

  final String deviceId;
  int _mtu;
  final StreamController<Uint8List> _inbound = StreamController.broadcast();

  set mtu(int value) => _mtu = value;

  void handleInboundWrite(Uint8List value) => _inbound.add(value);

  @override
  String get linkId => deviceId;

  @override
  Stream<Uint8List> get inboundChunks => _inbound.stream;

  @override
  int get maxChunkBytes => _mtu - 3;

  @override
  Future<void> sendChunk(Uint8List chunk) => BlePeripheral.updateCharacteristic(
    characteristicId: meshOutboxUuid,
    value: chunk,
    deviceId: deviceId,
  );

  @override
  Future<void> close() async {
    await _inbound.close();
  }
}

/// The peripheral half of the radio: GATT server + advertising. Emits a
/// [PeripheralMeshLink] for every central that starts writing to us.
class MeshPeripheral {
  MeshPeripheral();

  final Map<String, PeripheralMeshLink> _links = {};
  final StreamController<PeripheralMeshLink> _newLinks =
      StreamController.broadcast();
  bool _running = false;

  Stream<PeripheralMeshLink> get newLinks => _newLinks.stream;

  Future<void> start({required String localName}) async {
    if (_running) return;
    await BlePeripheral.initialize();
    BlePeripheral.setWriteRequestCallback(_onWrite);
    BlePeripheral.setMtuChangeCallback((deviceId, mtu) {
      _links[deviceId]?.mtu = mtu;
    });
    BlePeripheral.setConnectionStateChangeCallback((deviceId, connected) {
      if (!connected) {
        final link = _links.remove(deviceId);
        if (link != null) unawaited(link.close());
      }
    });
    await BlePeripheral.addService(
      BleService(
        uuid: meshServiceUuid,
        primary: true,
        characteristics: [
          BleCharacteristic(
            uuid: meshInboxUuid,
            properties: [
              CharacteristicProperties.write.index,
              CharacteristicProperties.writeWithoutResponse.index,
            ],
            permissions: [AttributePermissions.writeable.index],
          ),
          BleCharacteristic(
            uuid: meshOutboxUuid,
            properties: [
              CharacteristicProperties.read.index,
              CharacteristicProperties.notify.index,
            ],
            permissions: [AttributePermissions.readable.index],
            value: Uint8List(0),
          ),
        ],
      ),
    );
    // localName is a RANDOM session tag, never a username — identity stays
    // inside the authenticated handshake.
    await BlePeripheral.startAdvertising(
      services: [meshServiceUuid],
      localName: localName,
    );
    _running = true;
  }

  WriteRequestResult? _onWrite(
    String deviceId,
    String characteristicId,
    int offset,
    Uint8List? value,
  ) {
    if (characteristicId.toLowerCase() != meshInboxUuid || value == null) {
      return WriteRequestResult(status: 1);
    }
    final link = _links.putIfAbsent(deviceId, () {
      final created = PeripheralMeshLink(
        deviceId: deviceId,
        mtu: _fallbackChunkBytes + 3,
      );
      _newLinks.add(created);
      return created;
    });
    link.handleInboundWrite(value);
    return WriteRequestResult();
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    try {
      await BlePeripheral.stopAdvertising();
    } catch (_) {}
    try {
      await BlePeripheral.clearServices();
    } catch (_) {}
    for (final link in _links.values) {
      unawaited(link.close());
    }
    _links.clear();
  }
}

/// The central half: scan for the mesh service and dial discovered devices.
class MeshCentral {
  bool _scanning = false;
  StreamSubscription<List<fbp.ScanResult>>? _scanSub;
  final Set<String> _dialing = {};
  final StreamController<CentralMeshLink> _newLinks =
      StreamController.broadcast();

  Stream<CentralMeshLink> get newLinks => _newLinks.stream;

  Future<void> start() async {
    if (_scanning) return;
    _scanning = true;
    _scanSub = fbp.FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        unawaited(_maybeDial(result.device, result.rssi));
      }
    });
    await fbp.FlutterBluePlus.startScan(
      withServices: [fbp.Guid(meshServiceUuid)],
      continuousUpdates: true,
    );
  }

  Future<void> _maybeDial(fbp.BluetoothDevice device, int rssi) async {
    final id = device.remoteId.str;
    if (!_scanning || !_dialing.add(id)) return;
    try {
      final link = await CentralMeshLink.connect(device, rssi: rssi);
      if (!_scanning) {
        await link.close();
        return;
      }
      _newLinks.add(link);
    } catch (_) {
      // Out of range / not actually a mesh peer — allow a later retry.
      _dialing.remove(id);
    }
  }

  Future<void> stop() async {
    _scanning = false;
    await _scanSub?.cancel();
    _scanSub = null;
    _dialing.clear();
    try {
      await fbp.FlutterBluePlus.stopScan();
    } catch (_) {}
  }
}
