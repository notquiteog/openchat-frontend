import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/utils/wav_pcm.dart';

/// The transcription pipeline trusts parseWav to walk RIFF chunks properly —
/// ffmpeg inserts a LIST metadata chunk before `data`, which naive 44-byte
/// header parsing reads as garbage samples.
Uint8List _buildWav({
  required int sampleRate,
  required int channels,
  required List<int> pcm16,
  List<int> preDataChunks = const [],
  int format = 1,
  int bits = 16,
}) {
  final dataBytes = ByteData(pcm16.length * 2);
  for (var i = 0; i < pcm16.length; i++) {
    dataBytes.setInt16(i * 2, pcm16[i], Endian.little);
  }
  final data = dataBytes.buffer.asUint8List();

  final fmt = ByteData(16)
    ..setUint16(0, format, Endian.little)
    ..setUint16(2, channels, Endian.little)
    ..setUint32(4, sampleRate, Endian.little)
    ..setUint32(8, sampleRate * channels * (bits ~/ 8), Endian.little)
    ..setUint16(12, channels * (bits ~/ 8), Endian.little)
    ..setUint16(14, bits, Endian.little);

  final chunks = BytesBuilder();
  chunks.add('WAVE'.codeUnits);
  void addChunk(String id, List<int> body) {
    chunks.add(id.codeUnits);
    final size = ByteData(4)..setUint32(0, body.length, Endian.little);
    chunks.add(size.buffer.asUint8List());
    chunks.add(body);
    if (body.length.isOdd) chunks.addByte(0); // RIFF word alignment
  }

  addChunk('fmt ', fmt.buffer.asUint8List());
  if (preDataChunks.isNotEmpty) addChunk('LIST', preDataChunks);
  addChunk('data', data);

  final body = chunks.takeBytes();
  final riff = BytesBuilder();
  riff.add('RIFF'.codeUnits);
  final size = ByteData(4)..setUint32(0, body.length, Endian.little);
  riff.add(size.buffer.asUint8List());
  riff.add(body);
  return riff.takeBytes();
}

void main() {
  test('parses 16-bit mono PCM', () {
    final wav = _buildWav(
      sampleRate: 16000,
      channels: 1,
      pcm16: [0, 16384, -16384, 32767, -32768],
    );
    final pcm = parseWav(wav);
    expect(pcm.sampleRate, 16000);
    expect(pcm.samples.length, 5);
    expect(pcm.samples[0], 0);
    expect(pcm.samples[1], closeTo(0.5, 0.001));
    expect(pcm.samples[2], closeTo(-0.5, 0.001));
    expect(pcm.samples[3], closeTo(1.0, 0.001));
    expect(pcm.samples[4], closeTo(-1.0, 0.001));
  });

  test('skips metadata chunks before data (real ffmpeg output shape)', () {
    final wav = _buildWav(
      sampleRate: 16000,
      channels: 1,
      pcm16: [1000, -1000],
      preDataChunks: List.filled(26, 0x20), // LIST chunk ffmpeg loves to emit
    );
    final pcm = parseWav(wav);
    expect(pcm.samples.length, 2);
    expect(pcm.samples[0], closeTo(1000 / 32768, 0.0001));
  });

  test('downmixes stereo by averaging instead of interleaving garbage', () {
    final wav = _buildWav(
      sampleRate: 16000,
      channels: 2,
      pcm16: [16384, -16384, 8192, 8192], // L,R,L,R
    );
    final pcm = parseWav(wav);
    expect(pcm.samples.length, 2);
    expect(pcm.samples[0], closeTo(0, 0.001));
    expect(pcm.samples[1], closeTo(0.25, 0.001));
  });

  test('rejects non-PCM encodings loudly', () {
    final wav = _buildWav(
      sampleRate: 16000,
      channels: 1,
      pcm16: [0],
      format: 3, // IEEE float
    );
    expect(() => parseWav(wav), throwsFormatException);
  });

  test('rejects non-WAV bytes', () {
    expect(
      () => parseWav(Uint8List.fromList(List.filled(64, 7))),
      throwsFormatException,
    );
  });
}
