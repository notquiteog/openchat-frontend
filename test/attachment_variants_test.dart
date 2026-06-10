import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/screens/chat/chat_screen.dart';

// The attachment sheet was consolidated: Photo/Video/File/Location are single
// tiles; view-once, spoiler, and live-location moved to long-press variants.
// The variant choices must map onto the SAME choice strings the old dedicated
// tiles produced, so the send plumbing (viewOnce/hasSpoiler flags derived from
// the choice prefix) stays untouched.
void main() {
  test('photo long-press offers view-once and spoiler', () {
    final (title, actions) = attachmentVariantActions('photo_variants');
    expect(title, 'Send photo');
    expect(actions, [
      ('View-once photo', 'view_once_image'),
      ('Spoiler photo', 'spoiler_image'),
    ]);
  });

  test('video long-press offers view-once and spoiler', () {
    final (title, actions) = attachmentVariantActions('video_variants');
    expect(title, 'Send video');
    expect(actions, [
      ('View-once video', 'view_once_video'),
      ('Spoiler video', 'spoiler_video'),
    ]);
  });

  test('file long-press offers view-once', () {
    final (title, actions) = attachmentVariantActions('file_variants');
    expect(title, 'Send file');
    expect(actions, [('View-once file', 'view_once_file')]);
  });

  test('every variant choice keeps the flag-bearing prefix', () {
    for (final variants in [
      'photo_variants',
      'video_variants',
      'file_variants',
    ]) {
      final (_, actions) = attachmentVariantActions(variants);
      for (final (_, choice) in actions) {
        expect(
          choice.startsWith('view_once_') || choice.startsWith('spoiler_'),
          isTrue,
          reason: '$choice must carry the view-once/spoiler prefix',
        );
      }
    }
  });

  test('unknown variants resolve to nothing', () {
    final (title, actions) = attachmentVariantActions('bogus');
    expect(title, isEmpty);
    expect(actions, isEmpty);
  });
}
