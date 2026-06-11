import 'dart:async';

import 'package:flutter/foundation.dart';

import 'segmentation_pipeline.dart';

/// Web stand-in for `SegmentationService` (selected by the conditional export
/// in segmentation_service.dart). ONNX Runtime is dart:ffi-based, so there is
/// no in-browser inference path — the API shape is preserved and every call
/// reports "unsupported" instead of breaking the web compile.
class SegmentationService {
  SegmentationService._();

  static bool get isSupported => false;

  static Stream<double> get downloadProgress => const Stream<double>.empty();

  static Future<bool> isModelCached() async => false;

  static Future<int> cachedModelSizeBytes() async => 0;

  static Future<void> deleteModel() async {}

  static Future<Uint8List?> removeBackground(Uint8List image) async => null;

  static Future<Uint8List> removeBackgroundOrThrow(Uint8List image) async {
    throw SegmentationException('background removal is not supported on web');
  }
}
