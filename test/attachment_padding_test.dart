import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/attachment_service.dart';

/// Attachment size-bucket padding: AES-GCM preserves plaintext length, so the
/// stored ciphertext size fingerprints files unless padded. The frame must
/// round-trip exactly, bucket sizes must collapse, overhead must stay bounded,
/// and pre-padding (legacy) attachments must pass through untouched.
void main() {
  Uint8List bytesOf(int n, {int seed = 7}) =>
      Uint8List.fromList(List<int>.generate(n, (i) => (i * seed + 13) & 0xFF));

  test('pad/strip round-trips exactly', () {
    for (final size in [0, 1, 100, 4095, 4096, 70000, 1 << 20]) {
      final original = bytesOf(size);
      final padded = AttachmentService.padAttachmentPlaintext(original);
      final stripped = AttachmentService.stripAttachmentPadding(padded);
      expect(stripped, equals(original), reason: 'size $size');
    }
  });

  test('padded sizes land on shared buckets, hiding exact length', () {
    final a = AttachmentService.padAttachmentPlaintext(bytesOf(100_000));
    final b = AttachmentService.padAttachmentPlaintext(bytesOf(101_500));
    expect(a.length, b.length,
        reason: 'nearby sizes must collapse into the same bucket');
  });

  test('small files pad to at least the 4KB floor', () {
    expect(AttachmentService.padAttachmentPlaintext(bytesOf(10)).length, 4096);
    expect(AttachmentService.padAttachmentPlaintext(bytesOf(0)).length, 4096);
  });

  test('overhead stays bounded (~12.5% + frame) above the floor', () {
    // Below ~32KB the 4KB floor dominates (deliberately: tiny files need
    // proportionally MORE padding to share buckets); above it the dynamic
    // block keeps overhead under ~12.5% + frame.
    for (final size in [100_000, 250_000, 5_000_000]) {
      final padded = AttachmentService.padAttachmentPlaintext(bytesOf(size));
      final overhead = (padded.length - size) / size;
      expect(overhead, lessThan(0.14), reason: 'size $size');
    }
  });

  test('legacy unpadded bytes pass through unchanged', () {
    final legacy = bytesOf(5000, seed: 3); // no magic header
    expect(AttachmentService.stripAttachmentPadding(legacy), same(legacy));
    final tiny = bytesOf(4);
    expect(AttachmentService.stripAttachmentPadding(tiny), same(tiny));
  });

  test('corrupt length field fails open to raw bytes, never throws', () {
    final padded = AttachmentService.padAttachmentPlaintext(bytesOf(100));
    // Claim a length far beyond the buffer.
    padded.setRange(8, 16, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]);
    final out = AttachmentService.stripAttachmentPadding(padded);
    expect(out.length, padded.length);
  });
}
