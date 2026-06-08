import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// On-device subject segmentation (background removal) for the sticker creator.
///
/// Calls the native `openchat/segmentation` channel — Android ML Kit Subject
/// Segmentation / iOS Vision `VNGenerateForegroundInstanceMaskRequest`. Returns
/// foreground-only PNG bytes, or null when the platform can't segment (caller
/// falls back to the original image; a manual eraser is the other fallback).
class SegmentationService {
  static const MethodChannel _channel = MethodChannel('openchat/segmentation');

  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static Future<Uint8List?> removeBackground(Uint8List image) async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<Uint8List>('removeBackground', {
        'image': image,
      });
    } catch (_) {
      return null;
    }
  }
}
