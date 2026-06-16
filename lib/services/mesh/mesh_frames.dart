/// Mesh wire protocol, layer 1: frames and BLE-sized chunks. Pure Dart — no
/// transport imports — so the whole codec is unit-testable without hardware.
///
/// Frame: [0x4F 0x4D][version=1][type][u32 LE payload length][payload][u32 LE
/// CRC32 over everything before it]. The CRC is the integrity check for chunk
/// reassembly; authenticity comes from the PGP layer above, not from here.
///
/// Chunk (one BLE write/notification): [u16 LE seq][u8 flags][data]. seq 0
/// starts a new frame; bit0 of flags marks the last chunk. A characteristic
/// delivers writes in order, so reassembly only needs to detect gaps.
library;

import 'dart:typed_data';

const int meshFrameHello = 1;
const int meshFrameProof = 2;
const int meshFrameMessage = 3;
const int meshFrameAck = 4;
// Encrypted attachment transfer over LAN (#26). Carries a JSON envelope with
// the attachment ciphertext base64-encoded inline. Only sent over LAN links —
// the BLE MTU makes multi-megabyte transfers impractical.
const int meshFrameAttachment = 5;

const int _magic0 = 0x4F; // 'O'
const int _magic1 = 0x4D; // 'M'
const int _version = 1;
const int _headerLength = 8;

/// Max payload accepted by the decoder for control/message frames — a corrupt
/// length field must not ask the reassembler to buffer gigabytes. Generous:
/// envelopes are < 64 KiB.
const int meshMaxFrameBytes = 256 * 1024;

/// Max payload for attachment frames (#26). Larger than [meshMaxFrameBytes]
/// because the ciphertext rides inline, but still bounded so a corrupt length
/// can't exhaust memory. Sized comfortably above a base64-expanded ~10 MiB
/// attachment; mesh attachment transfer is LAN-only.
const int meshMaxAttachmentFrameBytes = 16 * 1024 * 1024;

class MeshFrame {
  final int type;
  final Uint8List payload;
  const MeshFrame({required this.type, required this.payload});
}

class MeshFrameException implements Exception {
  final String message;
  const MeshFrameException(this.message);
  @override
  String toString() => message;
}

Uint8List encodeMeshFrame(
  int type,
  Uint8List payload, {
  int maxBytes = meshMaxFrameBytes,
}) {
  if (payload.length > maxBytes) {
    throw const MeshFrameException('frame payload too large');
  }
  final out = Uint8List(_headerLength + payload.length + 4);
  final view = ByteData.sublistView(out);
  out[0] = _magic0;
  out[1] = _magic1;
  out[2] = _version;
  out[3] = type;
  view.setUint32(4, payload.length, Endian.little);
  out.setRange(_headerLength, _headerLength + payload.length, payload);
  final crc = crc32(Uint8List.sublistView(out, 0, out.length - 4));
  view.setUint32(out.length - 4, crc, Endian.little);
  return out;
}

MeshFrame decodeMeshFrame(Uint8List bytes, {int maxBytes = meshMaxFrameBytes}) {
  if (bytes.length < _headerLength + 4 ||
      bytes[0] != _magic0 ||
      bytes[1] != _magic1) {
    throw const MeshFrameException('not a mesh frame');
  }
  if (bytes[2] != _version) {
    throw MeshFrameException('unsupported mesh frame version ${bytes[2]}');
  }
  final view = ByteData.sublistView(bytes);
  final length = view.getUint32(4, Endian.little);
  if (length > maxBytes || bytes.length != _headerLength + length + 4) {
    throw const MeshFrameException('mesh frame length mismatch');
  }
  final expected = view.getUint32(bytes.length - 4, Endian.little);
  final actual = crc32(Uint8List.sublistView(bytes, 0, bytes.length - 4));
  if (expected != actual) {
    throw const MeshFrameException('mesh frame CRC mismatch');
  }
  return MeshFrame(
    type: bytes[3],
    payload: Uint8List.sublistView(bytes, _headerLength, bytes.length - 4),
  );
}

/// Splits an encoded frame into BLE-write-sized chunks. [maxChunkBytes] is
/// the usable characteristic payload (negotiated MTU minus the 3-byte ATT
/// header — the transport passes that in).
List<Uint8List> splitMeshFrame(Uint8List frame, int maxChunkBytes) {
  final dataPerChunk = maxChunkBytes - 3;
  if (dataPerChunk < 1) {
    throw const MeshFrameException('chunk size too small for header');
  }
  final chunks = <Uint8List>[];
  var offset = 0;
  var seq = 0;
  while (offset < frame.length || chunks.isEmpty) {
    final end = (offset + dataPerChunk).clamp(0, frame.length);
    final last = end >= frame.length;
    final chunk = Uint8List(3 + (end - offset));
    ByteData.sublistView(chunk).setUint16(0, seq, Endian.little);
    chunk[2] = last ? 1 : 0;
    chunk.setRange(3, chunk.length, frame, offset);
    chunks.add(chunk);
    offset = end;
    seq++;
    if (seq > 0xFFFF) {
      throw const MeshFrameException('frame too large to chunk');
    }
    if (last) break;
  }
  return chunks;
}

/// Reassembles in-order chunks back into frames. Returns the complete frame
/// bytes when the last chunk arrives, null while more are needed. A gap or a
/// restart (seq 0 mid-frame) drops the partial frame — the CRC layer above
/// would reject it anyway; this just fails earlier and cheaper.
class MeshReassembler {
  /// Upper bound on a reassembled frame — pass [meshMaxAttachmentFrameBytes]
  /// for LAN links that may carry attachment frames (#26), the default
  /// [meshMaxFrameBytes] for BLE/control-only links.
  MeshReassembler({this.maxBytes = meshMaxFrameBytes});

  final int maxBytes;
  final BytesBuilder _buffer = BytesBuilder();
  int _expectedSeq = 0;

  Uint8List? addChunk(Uint8List chunk) {
    if (chunk.length < 3) throw const MeshFrameException('runt chunk');
    final seq = ByteData.sublistView(chunk).getUint16(0, Endian.little);
    final last = (chunk[2] & 1) != 0;
    if (seq == 0) {
      _buffer.clear();
      _expectedSeq = 0;
    }
    if (seq != _expectedSeq) {
      _buffer.clear();
      _expectedSeq = 0;
      throw MeshFrameException('chunk gap (got $seq)');
    }
    _buffer.add(Uint8List.sublistView(chunk, 3));
    if (_buffer.length > maxBytes + 64) {
      _buffer.clear();
      _expectedSeq = 0;
      throw const MeshFrameException('reassembly overflow');
    }
    _expectedSeq++;
    if (last) {
      final frame = _buffer.takeBytes();
      _expectedSeq = 0;
      return frame;
    }
    return null;
  }
}

/// CRC-32 (IEEE 802.3, reflected). Table built lazily once.
Uint32List? _crcTable;

int crc32(Uint8List bytes) {
  final table = _crcTable ??= _buildCrcTable();
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = table[(crc ^ b) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

Uint32List _buildCrcTable() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    table[i] = c;
  }
  return table;
}
