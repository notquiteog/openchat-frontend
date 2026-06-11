import 'dart:async';
import 'dart:typed_data';

/// Web stub — transcription needs dart:ffi (sherpa-onnx) and a PCM decoder.
class TranscriptionException implements Exception {
  final String message;
  const TranscriptionException(this.message);
  @override
  String toString() => message;
}

class TranscriptionService {
  TranscriptionService._();

  static bool get isSupported => false;
  static Stream<double> get downloadProgress => const Stream.empty();
  static Future<bool> isModelCached() async => false;
  static Future<int> cachedModelSizeBytes() async => 0;
  static Future<void> ensureModel() async =>
      throw const TranscriptionException(
          'transcription is not supported on this platform');
  static Future<void> deleteModel() async {}
  static Future<String> transcribeM4a(Uint8List bytes) async =>
      throw const TranscriptionException(
          'transcription is not supported on this platform');
}
