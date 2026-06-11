import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../utils/wav_pcm.dart';

class TranscriptionException implements Exception {
  final String message;
  const TranscriptionException(this.message);
  @override
  String toString() => message;
}

class _ModelFile {
  final String name;
  final int minBytes; // truncation / HTML-error-page sniff
  const _ModelFile(this.name, this.minBytes);
}

/// On-device Whisper-tiny transcription — native platforms. See the barrel
/// (transcription_service.dart) for the architecture note.
class TranscriptionService {
  TranscriptionService._();

  /// sherpa-onnx's official export of OpenAI Whisper tiny (multilingual,
  /// int8-quantized). Individual files instead of the release tar.bz2 so the
  /// download is resumable per-file and needs no bzip2 handling.
  static const String _baseUrl =
      'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny/resolve/main';

  static const List<_ModelFile> _files = [
    _ModelFile('tiny-encoder.int8.onnx', 8 * 1024 * 1024),
    _ModelFile('tiny-decoder.int8.onnx', 20 * 1024 * 1024),
    _ModelFile('tiny-tokens.txt', 100 * 1024),
  ];

  static Future<void>? _inflightDownload;
  static final StreamController<double> _progress =
      StreamController<double>.broadcast();

  /// Whole-model download progress in [0, 1].
  static Stream<double> get downloadProgress => _progress.stream;

  /// FFI + a usable PCM decoder. Linux/Windows additionally need a system
  /// `ffmpeg` on PATH, checked lazily at transcribe time (not here) so the
  /// settings screen can still offer the model download.
  static bool get isSupported => true;

  static Future<String> _modelDir() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'asr', 'whisper-tiny');
  }

  static Future<bool> isModelCached() async {
    final dir = await _modelDir();
    for (final f in _files) {
      final file = File(p.join(dir, f.name));
      if (!await file.exists() || await file.length() < f.minBytes) {
        return false;
      }
    }
    return true;
  }

  static Future<int> cachedModelSizeBytes() async {
    final dir = Directory(await _modelDir());
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list()) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  static Future<void> deleteModel() async {
    final dir = Directory(await _modelDir());
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Downloads the model files if missing. Concurrent callers share one
  /// download. Progress is by bytes across all three files.
  static Future<void> ensureModel() async {
    if (await isModelCached()) return;
    return _inflightDownload ??=
        _downloadAll().whenComplete(() => _inflightDownload = null);
  }

  static Future<void> _downloadAll() async {
    final dir = await _modelDir();
    await Directory(dir).create(recursive: true);
    final client = http.Client();
    try {
      // Sizes first so the progress bar is byte-accurate across files.
      final sizes = <String, int>{};
      var totalBytes = 0;
      for (final f in _files) {
        final head =
            await client.head(Uri.parse('$_baseUrl/${f.name}'));
        final len = int.tryParse(head.headers['content-length'] ?? '') ?? 0;
        sizes[f.name] = len;
        totalBytes += len;
      }
      var received = 0;
      for (final f in _files) {
        final dest = File(p.join(dir, f.name));
        if (await dest.exists() && await dest.length() >= f.minBytes) {
          received += sizes[f.name] ?? await dest.length();
          if (totalBytes > 0) _progress.add(received / totalBytes);
          continue;
        }
        // Stream into a temp file, then rename — a crash mid-download never
        // leaves a half-written file where isModelCached trusts it.
        final tmp = File('${dest.path}.part');
        final response = await client
            .send(http.Request('GET', Uri.parse('$_baseUrl/${f.name}')));
        if (response.statusCode != 200) {
          throw TranscriptionException(
              'model download failed: HTTP ${response.statusCode} for ${f.name}');
        }
        final sink = tmp.openWrite();
        try {
          await for (final chunk in response.stream) {
            sink.add(chunk);
            received += chunk.length;
            if (totalBytes > 0) _progress.add(received / totalBytes);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (await tmp.length() < f.minBytes) {
          await tmp.delete();
          throw TranscriptionException(
              'model download failed: ${f.name} is truncated');
        }
        await tmp.rename(dest.path);
      }
      _progress.add(1.0);
    } on TranscriptionException {
      rethrow;
    } catch (e) {
      throw TranscriptionException('model download failed: $e');
    } finally {
      client.close();
    }
  }

  /// Transcribes an AAC/m4a voice note. The caller hands over the DECRYPTED
  /// bytes; they only ever touch disk as shredded temp files.
  static Future<String> transcribeM4a(Uint8List m4aBytes) async {
    await ensureModel();
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final input = File(p.join(dir.path, 'oc_asr_$stamp.m4a'));
    final wav = File(p.join(dir.path, 'oc_asr_$stamp.wav'));
    try {
      await input.writeAsBytes(m4aBytes, flush: true);
      await _decodeToWav(input, wav);
      final pcm = parseWav(await wav.readAsBytes());
      if (pcm.samples.isEmpty) {
        throw const TranscriptionException('decoded audio is empty');
      }
      return await _recognize(pcm);
    } finally {
      await _shred(input);
      await _shred(wav);
    }
  }

  static Future<void> _decodeToWav(File input, File output) async {
    final args = [
      '-y', '-i', input.path,
      '-ar', '16000', '-ac', '1', '-f', 'wav', output.path,
    ];
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      final session = await FFmpegKit.executeWithArguments(args);
      final rc = await session.getReturnCode();
      if (!ReturnCode.isSuccess(rc)) {
        throw TranscriptionException('audio decode failed (ffmpeg rc=$rc)');
      }
      return;
    }
    // Linux/Windows: ffmpeg-kit has no desktop build here — use the system
    // binary, which most desktop installs already have.
    try {
      final res = await Process.run('ffmpeg', args);
      if (res.exitCode != 0) {
        throw TranscriptionException(
            'audio decode failed (ffmpeg exit ${res.exitCode})');
      }
    } on ProcessException {
      throw const TranscriptionException(
          'ffmpeg not found — install ffmpeg to transcribe voice notes on desktop');
    }
  }

  static Future<String> _recognize(WavPcm pcm) async {
    final dir = await _modelDir();
    final encoder = p.join(dir, 'tiny-encoder.int8.onnx');
    final decoder = p.join(dir, 'tiny-decoder.int8.onnx');
    final tokens = p.join(dir, 'tiny-tokens.txt');
    final samples = pcm.samples;
    final sampleRate = pcm.sampleRate;
    // Whisper-tiny loads in ~a second and a voice note decodes in a few —
    // keep all of it off the UI isolate. Bindings are per-isolate, so init
    // inside.
    return Isolate.run(() {
      sherpa.initBindings();
      final recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            whisper: sherpa.OfflineWhisperModelConfig(
              encoder: encoder,
              decoder: decoder,
            ),
            tokens: tokens,
            numThreads: 2,
            debug: false,
            modelType: 'whisper',
          ),
        ),
      );
      try {
        final stream = recognizer.createStream();
        try {
          stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
          recognizer.decode(stream);
          return recognizer.getResult(stream).text.trim();
        } finally {
          stream.free();
        }
      } finally {
        recognizer.free();
      }
    });
  }

  /// Overwrite-then-delete. Best effort — on flash storage an overwrite is
  /// not a guarantee, but it beats leaving plaintext audio in /tmp.
  static Future<void> _shred(File f) async {
    try {
      if (!await f.exists()) return;
      final len = await f.length();
      final raf = await f.open(mode: FileMode.writeOnly);
      try {
        const chunk = 64 * 1024;
        final zeros = Uint8List(chunk);
        var written = 0;
        while (written < len) {
          final n = (len - written) < chunk ? (len - written) : chunk;
          await raf.writeFrom(zeros, 0, n);
          written += n;
        }
        await raf.flush();
      } finally {
        await raf.close();
      }
      await f.delete();
    } on IOException {
      // Best effort.
    }
  }
}
