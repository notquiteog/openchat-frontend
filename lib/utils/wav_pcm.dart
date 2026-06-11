import 'dart:typed_data';

/// Minimal RIFF/WAV reader for the transcription pipeline. ffmpeg writes
/// 16-bit little-endian mono PCM; everything else is rejected loudly instead
/// of producing garbage samples.
class WavPcm {
  final int sampleRate;
  final Float32List samples; // mono, [-1, 1]

  const WavPcm({required this.sampleRate, required this.samples});
}

/// Parses a WAV file into mono float samples. Walks RIFF chunks properly —
/// ffmpeg often emits a LIST chunk before `data`, so fixed 44-byte-header
/// parsing breaks on real output.
WavPcm parseWav(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 44 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('not a RIFF/WAVE file');
  }

  int? sampleRate;
  int channels = 0;
  int bitsPerSample = 0;
  int? dataStart;
  int dataLength = 0;

  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ') {
      if (body + 16 > bytes.length) {
        throw const FormatException('truncated fmt chunk');
      }
      final format = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      sampleRate = data.getUint32(body + 4, Endian.little);
      bitsPerSample = data.getUint16(body + 14, Endian.little);
      if (format != 1 || bitsPerSample != 16) {
        throw FormatException(
          'unsupported WAV encoding (format=$format bits=$bitsPerSample); '
          'expected 16-bit PCM',
        );
      }
    } else if (id == 'data') {
      dataStart = body;
      dataLength = size;
      break;
    }
    // Chunks are word-aligned: odd sizes carry a pad byte.
    offset = body + size + (size.isOdd ? 1 : 0);
  }

  if (sampleRate == null || dataStart == null || channels < 1) {
    throw const FormatException('missing fmt or data chunk');
  }
  final end = (dataStart + dataLength).clamp(0, bytes.length);
  final frameBytes = 2 * channels;
  final frames = (end - dataStart) ~/ frameBytes;
  final out = Float32List(frames);
  for (var i = 0; i < frames; i++) {
    // Downmix by averaging — transcription input should already be mono, but
    // a stereo file shouldn't silently halve its duration.
    var acc = 0;
    for (var ch = 0; ch < channels; ch++) {
      acc += data.getInt16(dataStart + i * frameBytes + ch * 2, Endian.little);
    }
    out[i] = (acc / channels) / 32768.0;
  }
  return WavPcm(sampleRate: sampleRate, samples: out);
}
