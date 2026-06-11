import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'segmentation_pipeline.dart';

/// On-device background removal for the sticker creator — native platforms.
///
/// Runs the u2netp saliency model through ONNX Runtime via dart:ffi, so the
/// exact same code path works on Android/iOS/Linux/macOS/Windows (replacing
/// the old `openchat/segmentation` MethodChannel that had no native
/// implementation anywhere and always failed). The ~4.7 MB model is not
/// bundled with the app; it is downloaded once into
/// `<app support dir>/segmentation/u2netp.onnx` and reused afterwards.
class SegmentationService {
  SegmentationService._();

  /// rembg's release mirror of the original u2netp weights, ONNX-converted.
  static const String modelUrl =
      'https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2netp.onnx';

  // A real u2netp.onnx is ~4.7 MB; anything under 1 MB is a truncated
  // download or an HTML error page that got saved as the model.
  static const int _minModelBytes = 1024 * 1024;

  static OrtSession? _session;
  static Future<File>? _inflightDownload;
  static final StreamController<double> _progress =
      StreamController<double>.broadcast();

  /// First-run model download progress in [0, 1] — the sticker editor shows
  /// it inline on the "Remove background" button.
  static Stream<double> get downloadProgress => _progress.stream;

  static bool get isSupported => !kIsWeb;

  /// True when a plausible model file is already on disk, i.e. the next
  /// [removeBackground] call won't hit the network. Lets the UI decide
  /// whether to warn about the one-time download.
  static Future<bool> isModelCached() async =>
      _looksLikeOnnxModel(File(await _modelPath()));

  /// Disk footprint of the cached model (0 = not downloaded). Surfaced on
  /// the On-device intelligence screen.
  static Future<int> cachedModelSizeBytes() async {
    try {
      final file = File(await _modelPath());
      return await file.exists() ? await file.length() : 0;
    } on IOException {
      return 0;
    }
  }

  static Future<void> deleteModel() async {
    _session = null;
    try {
      final file = File(await _modelPath());
      if (await file.exists()) await file.delete();
    } on IOException {
      // Best effort.
    }
  }

  /// Legacy lenient API: null on any failure (caller keeps the original
  /// image). Prefer [removeBackgroundOrThrow] where the failure reason can be
  /// surfaced to the user.
  static Future<Uint8List?> removeBackground(Uint8List image) async {
    try {
      return await removeBackgroundOrThrow(image);
    } catch (_) {
      return null;
    }
  }

  /// Returns the foreground as PNG bytes (alpha-matted, cropped to the
  /// subject). Throws [SegmentationException] with the actual reason when the
  /// model can't be downloaded or inference fails.
  static Future<Uint8List> removeBackgroundOrThrow(Uint8List image) async {
    final model = await _ensureModel();
    final session = _ensureSession(model);
    // Decode + tensor prep chew through multi-megapixel bitmaps — keep them
    // off the UI isolate. ORT's Run() itself goes through runAsync, which the
    // plugin executes on its own helper isolate.
    final prep = await Isolate.run(() => decodeAndPreprocess(image));
    if (prep == null) {
      throw SegmentationException(
          'inference failed: the image could not be decoded');
    }
    final mask = await _runModel(session, prep.tensor);
    return Isolate.run(() => postprocessToPng(prep, mask));
  }

  static Future<String> _modelPath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'segmentation', 'u2netp.onnx');
  }

  /// Cheap corruption check: minimum size plus the leading protobuf byte.
  /// ONNX models always start with field 1 (ir_version), whose varint tag is
  /// 0x08 — this catches HTML error pages and zero-length files.
  static Future<bool> _looksLikeOnnxModel(File file) async {
    try {
      if (!await file.exists() || await file.length() < _minModelBytes) {
        return false;
      }
      final raf = await file.open();
      try {
        final head = await raf.read(1);
        return head.isNotEmpty && head[0] == 0x08;
      } finally {
        await raf.close();
      }
    } on IOException {
      return false;
    }
  }

  static Future<File> _ensureModel() async {
    final file = File(await _modelPath());
    if (await _looksLikeOnnxModel(file)) return file;
    // Corrupt or missing → (re)download. Concurrent callers share one
    // download instead of racing on the same file.
    return _inflightDownload ??=
        _downloadModel(file).whenComplete(() => _inflightDownload = null);
  }

  static Future<File> _downloadModel(File dest) async {
    final client = http.Client();
    // Stream into a temp file, then rename: a crash mid-download can never
    // leave a half-written file at the path _looksLikeOnnxModel trusts.
    final tmp = File('${dest.path}.part');
    try {
      await dest.parent.create(recursive: true);
      final response =
          await client.send(http.Request('GET', Uri.parse(modelUrl)));
      if (response.statusCode != 200) {
        throw SegmentationException(
            'model download failed: HTTP ${response.statusCode} from $modelUrl');
      }
      final total = response.contentLength ?? 0;
      var received = 0;
      final sink = tmp.openWrite();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) _progress.add(received / total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      await tmp.rename(dest.path);
      if (!await _looksLikeOnnxModel(dest)) {
        await dest.delete();
        throw SegmentationException(
            'model download failed: server did not return a valid ONNX model');
      }
      _progress.add(1.0);
      return dest;
    } on SegmentationException {
      rethrow;
    } catch (e) {
      throw SegmentationException('model download failed: $e');
    } finally {
      client.close();
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } on IOException {
          // Best effort — a stale .part file is harmless and gets overwritten.
        }
      }
    }
  }

  static OrtSession _ensureSession(File model) {
    final cached = _session;
    if (cached != null) return cached;
    OrtSessionOptions? options;
    try {
      OrtEnv.instance.init();
      options = OrtSessionOptions()
        ..setIntraOpNumThreads(2)
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
      return _session = OrtSession.fromFile(model, options);
    } catch (e) {
      // A file that passed the byte sniff can still be truncated mid-graph;
      // drop it so the next attempt redownloads instead of failing forever.
      try {
        model.deleteSync();
      } on IOException {
        // Best effort.
      }
      throw SegmentationException(
          'inference failed: could not load the segmentation model: $e');
    } finally {
      // ORT copies the options into the session at creation, so releasing
      // here is safe even on the success path.
      options?.release();
    }
  }

  static Future<Float32List> _runModel(
      OrtSession session, Float32List tensor) async {
    OrtValueTensor? input;
    OrtRunOptions? runOptions;
    List<OrtValue?>? outputs;
    try {
      input = OrtValueTensor.createTensorWithDataList(
        tensor,
        [1, 3, kSegmentationModelSide, kSegmentationModelSide],
      );
      runOptions = OrtRunOptions();
      // Introspect IO names instead of hardcoding: u2netp uses 'input.1' and
      // 'd0'…'d6' (d0 = the fused mask), but other exports rename them.
      final inputName =
          session.inputNames.isNotEmpty ? session.inputNames.first : 'input.1';
      final outputNames = session.outputNames.isNotEmpty
          ? <String>[session.outputNames.first]
          : null;
      outputs =
          await session.runAsync(runOptions, {inputName: input}, outputNames) ??
              const [];
      final first = outputs.isNotEmpty ? outputs.first : null;
      if (first is! OrtValueTensor) {
        throw SegmentationException(
            'inference failed: the model produced no tensor output');
      }
      final mask = flattenTensorValue(first.value);
      const expected = kSegmentationModelSide * kSegmentationModelSide;
      if (mask.length != expected) {
        throw SegmentationException(
            'inference failed: unexpected mask size ${mask.length} (expected $expected)');
      }
      return mask;
    } on SegmentationException {
      rethrow;
    } catch (e) {
      throw SegmentationException('inference failed: $e');
    } finally {
      input?.release();
      runOptions?.release();
      if (outputs != null) {
        for (final o in outputs) {
          o?.release();
        }
      }
    }
  }
}
