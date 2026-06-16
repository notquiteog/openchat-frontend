import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Pure image pipeline for the sticker creator's background removal.
///
/// Everything here is deliberately free of dart:io / ONNX Runtime so it can
/// run on any platform (and in host unit tests, where the ORT native library
/// doesn't exist). The ORT call itself lives in segmentation_service_native.dart;
/// this file owns the CPU-heavy decode → tensor → mask → PNG work that runs
/// off the UI isolate.

/// Thrown by `SegmentationService.removeBackgroundOrThrow` with a
/// human-readable reason ("model download failed: …", "inference failed: …").
class SegmentationException implements Exception {
  final String message;
  SegmentationException(this.message);

  @override
  String toString() => 'SegmentationException: $message';
}

/// u2netp takes a 320×320 input; its saliency output has the same shape.
const int kSegmentationModelSide = 320;

/// Output of [decodeAndPreprocess]: the model input tensor plus the decoded
/// original kept as plain RGBA8 bytes, so the postprocess isolate doesn't have
/// to pay for a second JPEG/PNG decode.
class PreprocessedImage {
  final Float32List tensor; // [1, 3, side, side] CHW, u2net-normalized
  final Uint8List rgba; // original-size RGBA8, row-major
  final int width;
  final int height;
  PreprocessedImage(this.tensor, this.rgba, this.width, this.height);
}

/// Decodes [encoded] and builds the u2netp input tensor. Returns null when the
/// bytes aren't a decodable image.
PreprocessedImage? decodeAndPreprocess(Uint8List encoded) {
  final decoded = img.decodeImage(encoded);
  if (decoded == null) return null;
  // Normalize exotic decodes (palette PNG, 16-bit, no alpha channel) to plain
  // RGBA8 once — both the tensor prep and the final compositing assume it.
  final rgba = (decoded.format == img.Format.uint8 && decoded.numChannels == 4)
      ? decoded
      : decoded.convert(format: img.Format.uint8, numChannels: 4);
  return PreprocessedImage(
    preprocessForU2Net(rgba),
    rgba.getBytes(order: img.ChannelOrder.rgba),
    rgba.width,
    rgba.height,
  );
}

/// Resize to [side]×[side] and normalize per the u2net convention: RGB / 255,
/// then ImageNet mean [0.485, 0.456, 0.406] and std [0.229, 0.224, 0.225],
/// laid out as CHW planes. Assumes 8-bit channels (see [decodeAndPreprocess]).
@visibleForTesting
Float32List preprocessForU2Net(
  img.Image source, {
  int side = kSegmentationModelSide,
}) {
  final resized = (source.width == side && source.height == side)
      ? source
      : img.copyResize(
          source,
          width: side,
          height: side,
          interpolation: img.Interpolation.linear,
        );
  final plane = side * side;
  final out = Float32List(3 * plane);
  var i = 0;
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++, i++) {
      final px = resized.getPixel(x, y);
      out[i] = (px.r / 255.0 - 0.485) / 0.229;
      out[plane + i] = (px.g / 255.0 - 0.456) / 0.224;
      out[2 * plane + i] = (px.b / 255.0 - 0.406) / 0.225;
    }
  }
  return out;
}

/// Min-max rescale of the raw saliency map to [0, 1] (u2net's output range is
/// unbounded-ish, so this is how rembg & friends binarize it too).
@visibleForTesting
Float32List minMaxNormalizeMask(Float32List mask) {
  var lo = double.infinity;
  var hi = double.negativeInfinity;
  for (final v in mask) {
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  final range = hi - lo;
  final out = Float32List(mask.length);
  // Flat mask (the model saw nothing salient) → fully transparent, not NaN.
  if (range <= 0 || !range.isFinite) return out;
  for (var i = 0; i < mask.length; i++) {
    out[i] = (mask[i] - lo) / range;
  }
  return out;
}

/// Bilinear upscale of a single-channel float mask from src to dst dimensions.
/// Hand-rolled because package:image only resizes its own Image type and the
/// mask is a bare Float32List.
@visibleForTesting
Float32List resizeMaskBilinear(
  Float32List src,
  int srcW,
  int srcH,
  int dstW,
  int dstH,
) {
  final out = Float32List(dstW * dstH);
  if (srcW == dstW && srcH == dstH) {
    out.setAll(0, src);
    return out;
  }
  final xRatio = srcW > 1 ? (srcW - 1) / math.max(1, dstW - 1) : 0.0;
  final yRatio = srcH > 1 ? (srcH - 1) / math.max(1, dstH - 1) : 0.0;
  for (var y = 0; y < dstH; y++) {
    final sy = y * yRatio;
    final y0 = sy.floor();
    final y1 = math.min(y0 + 1, srcH - 1);
    final fy = sy - y0;
    for (var x = 0; x < dstW; x++) {
      final sx = x * xRatio;
      final x0 = sx.floor();
      final x1 = math.min(x0 + 1, srcW - 1);
      final fx = sx - x0;
      final top = src[y0 * srcW + x0] * (1 - fx) + src[y0 * srcW + x1] * fx;
      final bot = src[y1 * srcW + x0] * (1 - fx) + src[y1 * srcW + x1] * fx;
      out[y * dstW + x] = top * (1 - fy) + bot * fy;
    }
  }
  return out;
}

/// Normalizes [mask], upscales it to [original]'s size and writes it into the
/// alpha channel. Values under [alphaCutoff] are hard-zeroed: u2net leaves a
/// dim halo around the subject that would otherwise survive as a ghost in the
/// sticker. Mutates [original] in place when it is already RGBA8.
@visibleForTesting
img.Image applyMaskAlpha(
  img.Image original,
  Float32List mask,
  int maskWidth,
  int maskHeight, {
  double alphaCutoff = 0.05,
}) {
  final out = original.numChannels == 4
      ? original
      : original.convert(numChannels: 4);
  final resized = resizeMaskBilinear(
    minMaxNormalizeMask(mask),
    maskWidth,
    maskHeight,
    out.width,
    out.height,
  );
  var i = 0;
  for (var y = 0; y < out.height; y++) {
    for (var x = 0; x < out.width; x++, i++) {
      final a = resized[i] < alphaCutoff ? 0.0 : resized[i];
      final px = out.getPixel(x, y);
      out.setPixelRgba(x, y, px.r, px.g, px.b, (a * 255).round().clamp(0, 255));
    }
  }
  return out;
}

/// Crops to the bounding box of non-transparent pixels plus [padding] px, so
/// stickers don't carry a huge invisible canvas. A fully transparent image is
/// returned unchanged (nothing to anchor a crop on).
@visibleForTesting
img.Image cropToAlphaBounds(img.Image image, {int padding = 12}) {
  var minX = image.width, minY = image.height, maxX = -1, maxY = -1;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      if (image.getPixel(x, y).a > 0) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return image;
  final x0 = math.max(0, minX - padding);
  final y0 = math.max(0, minY - padding);
  final x1 = math.min(image.width - 1, maxX + padding);
  final y1 = math.min(image.height - 1, maxY + padding);
  if (x0 == 0 && y0 == 0 && x1 == image.width - 1 && y1 == image.height - 1) {
    return image;
  }
  return img.copyCrop(
    image,
    x: x0,
    y: y0,
    width: x1 - x0 + 1,
    height: y1 - y0 + 1,
  );
}

/// Full postprocess: saliency mask → alpha matte → bbox crop → PNG bytes.
Uint8List postprocessToPng(PreprocessedImage prep, Float32List mask) {
  final original = img.Image.fromBytes(
    width: prep.width,
    height: prep.height,
    bytes: prep.rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  final masked = applyMaskAlpha(
    original,
    mask,
    kSegmentationModelSide,
    kSegmentationModelSide,
  );
  return img.encodePng(cropToAlphaBounds(masked));
}

/// Flattens ORT's nested-list tensor value ([1][1][320][320] of double) into a
/// flat Float32List. Shape-agnostic on purpose: different u2net exports wrap
/// the mask in different singleton dims.
Float32List flattenTensorValue(Object? value) {
  final out = <double>[];
  void walk(Object? v) {
    if (v is num) {
      out.add(v.toDouble());
    } else if (v is List) {
      for (final e in v) {
        walk(e);
      }
    }
  }

  walk(value);
  return Float32List.fromList(out);
}
