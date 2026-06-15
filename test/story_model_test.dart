import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/story.dart';

void main() {
  test('Story parses text background and decrypted metadata overrides it', () {
    final expires = DateTime.utc(2026, 6, 16);
    final created = DateTime.utc(2026, 6, 15, 12);
    final story = Story.fromJson({
      'id': 'story-1',
      'user_id': 'user-1',
      'caption': 'public text',
      'background': 'solid:#112233',
      'media_type': 'text',
      'privacy': 'public',
      'expires_at': expires.toIso8601String(),
      'created_at': created.toIso8601String(),
      'updated_at': created.toIso8601String(),
    });

    expect(story.isText, isTrue);
    expect(story.background, 'solid:#112233');

    final decrypted = story.withDecryptedMeta({
      'caption': 'private text',
      'background': 'gradient:#111827,#2563EB',
      'entities': const [],
    });

    expect(decrypted.caption, 'private text');
    expect(decrypted.background, 'gradient:#111827,#2563EB');
    expect(decrypted.isText, isTrue);
  });
}
