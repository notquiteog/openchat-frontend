import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:openchat/services/segmentation_service.dart';

// Pure pre/post-processing tests for the sticker background remover. ORT
// inference itself can't run in CI (no native library), so these cover the
// deterministic pipeline around it: u2net normalization, mask scaling, alpha
// matting and the bbox crop.
void main() {
  group('preprocessForU2Net', () {
    test('normalizes RGB with the u2net mean/std convention', () {
      final image = img.Image(width: 8, height: 8, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(255, 128, 0, 255));
      final tensor = preprocessForU2Net(image, side: 8);
      expect(tensor.length, 3 * 8 * 8);
      // CHW planes: first value of each plane is the (0,0) pixel.
      expect(tensor[0], closeTo((255 / 255 - 0.485) / 0.229, 1e-4));
      expect(tensor[64], closeTo((128 / 255 - 0.456) / 0.224, 1e-4));
      expect(tensor[128], closeTo((0 / 255 - 0.406) / 0.225, 1e-4));
    });

    test('resizes any input to side x side', () {
      final image = img.Image(width: 64, height: 32, numChannels: 4);
      final tensor = preprocessForU2Net(image, side: 8);
      expect(tensor.length, 3 * 8 * 8);
    });
  });

  group('minMaxNormalizeMask', () {
    test('rescales to [0, 1]', () {
      final mask = Float32List.fromList([2.0, 4.0, 6.0]);
      final out = minMaxNormalizeMask(mask);
      expect(out[0], 0.0);
      expect(out[1], closeTo(0.5, 1e-6));
      expect(out[2], 1.0);
    });

    test('flat mask maps to all zeros instead of NaN', () {
      final out = minMaxNormalizeMask(Float32List.fromList([3.0, 3.0, 3.0]));
      expect(out, everyElement(0.0));
    });
  });

  group('resizeMaskBilinear', () {
    test('interpolates a horizontal gradient', () {
      final src = Float32List.fromList([0.0, 1.0]);
      final out = resizeMaskBilinear(src, 2, 1, 5, 1);
      expect(out[0], 0.0);
      expect(out[2], closeTo(0.5, 1e-6));
      expect(out[4], 1.0);
    });

    test('identity when dimensions match', () {
      final src = Float32List.fromList([0.1, 0.2, 0.3, 0.4]);
      expect(resizeMaskBilinear(src, 2, 2, 2, 2), src);
    });
  });

  group('applyMaskAlpha', () {
    test('zero mask makes the image fully transparent', () {
      final image = img.Image(width: 8, height: 8, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(200, 100, 50, 255));
      final out = applyMaskAlpha(image, Float32List(64), 8, 8);
      for (final px in out) {
        expect(px.a, 0);
        // Color is preserved — only alpha is matted out.
        expect(px.r, 200);
      }
    });

    test('hard-zeroes faint halo values below the cutoff', () {
      final image = img.Image(width: 8, height: 8, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(255, 255, 255, 255));
      // After min-max normalization: pixel 0 → 0.0, pixel 1 → 0.03 (< 0.05
      // cutoff → hard zero), the rest → 1.0 (fully opaque).
      final mask = Float32List(64);
      mask[0] = 0.0;
      mask[1] = 3.0;
      for (var i = 2; i < 64; i++) {
        mask[i] = 100.0;
      }
      final out = applyMaskAlpha(image, mask, 8, 8);
      expect(out.getPixel(0, 0).a, 0);
      expect(out.getPixel(1, 0).a, 0); // would be ~8/255 without the cutoff
      expect(out.getPixel(2, 0).a, 255);
    });
  });

  group('cropToAlphaBounds', () {
    test('crops to the opaque square plus padding', () {
      final image = img.Image(width: 40, height: 40, numChannels: 4);
      // Transparent canvas with a known bright square at (16..23, 16..23).
      for (var y = 16; y <= 23; y++) {
        for (var x = 16; x <= 23; x++) {
          image.setPixelRgba(x, y, 255, 0, 0, 255);
        }
      }
      final out = cropToAlphaBounds(image, padding: 12);
      // bbox 16..23 padded by 12 → 4..35 → 32x32.
      expect(out.width, 32);
      expect(out.height, 32);
      // The square survives the crop, shifted by the new origin (4, 4).
      expect(out.getPixel(16 - 4, 16 - 4).a, 255);
      expect(out.getPixel(16 - 4, 16 - 4).r, 255);
      expect(out.getPixel(23 - 4, 23 - 4).a, 255);
      // Padding ring stays transparent.
      expect(out.getPixel(0, 0).a, 0);
    });

    test('padding is clamped at the canvas edge', () {
      final image = img.Image(width: 10, height: 10, numChannels: 4);
      image.setPixelRgba(1, 1, 0, 255, 0, 255);
      final out = cropToAlphaBounds(image, padding: 12);
      expect(out.width, 10);
      expect(out.height, 10);
    });

    test('fully transparent image is returned unchanged', () {
      final image = img.Image(width: 6, height: 6, numChannels: 4);
      final out = cropToAlphaBounds(image, padding: 12);
      expect(identical(out, image), isTrue);
    });
  });

  group('flattenTensorValue', () {
    test('flattens the nested [1][1][H][W] ORT output', () {
      final value = [
        [
          [
            [0.1, 0.2],
            [0.3, 0.4],
          ],
        ],
      ];
      final out = flattenTensorValue(value);
      expect(out.length, 4);
      expect(out[3], closeTo(0.4, 1e-6));
    });
  });
}
