import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/link_preview.dart';
import 'package:openchat/utils/link_preview_utils.dart';

void main() {
  test('firstLinkPreviewUrl extracts http and www links', () {
    expect(
      firstLinkPreviewUrl('Read https://example.com/post, please'),
      'https://example.com/post',
    );
    expect(
      firstLinkPreviewUrl('Visit www.example.com now'),
      'https://www.example.com',
    );
  });

  test('firstLinkPreviewUrl ignores unsupported schemes', () {
    expect(firstLinkPreviewUrl('ftp://example.com/file'), isNull);
    expect(firstLinkPreviewUrl('just words'), isNull);
  });

  test('LinkPreview parses backend response', () {
    final preview = LinkPreview.fromJson({
      'url': 'https://example.com/a',
      'resolved_url': 'https://example.com/final',
      'site_name': 'Example',
      'title': 'Title',
      'description': 'Description',
      'image_url': 'https://example.com/cover.jpg',
      'fetched_at': '2026-01-02T03:04:05Z',
    });

    expect(preview.displayHost, 'example.com');
    expect(preview.title, 'Title');
    expect(preview.fetchedAt.toUtc(), DateTime.utc(2026, 1, 2, 3, 4, 5));
  });
}
