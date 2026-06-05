import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/link_preview.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/services/link_preview_service.dart';
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

  test('linkTextMatches normalizes every http and www link', () {
    final matches = linkTextMatches(
      'Read https://example.com/post, then www.openchat.dev.',
    );

    expect(matches.map((match) => match.url), [
      'https://example.com/post',
      'https://www.openchat.dev',
    ]);
  });

  test('LinkPreview serializes for encrypted message content', () {
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
    expect(preview.toJson()['title'], 'Title');
  });

  test('MessageContent carries link previews inside encrypted payloads', () {
    final content = MessageContent.fromJson({
      'text': 'Read https://example.com/a',
      'link_preview': {
        'url': 'https://example.com/a',
        'resolved_url': 'https://example.com/final',
        'site_name': 'Example',
        'title': 'Title',
        'description': 'Description',
        'fetched_at': '2026-01-02T03:04:05Z',
      },
    });

    expect(content.linkPreview?.title, 'Title');
    expect(content.toJson()['link_preview'], isA<Map<String, dynamic>>());
  });

  test('local parser prefers OpenGraph metadata', () {
    final preview = parseLocalLinkPreviewHtml(
      '''
      <html>
        <head>
          <title>Fallback title</title>
          <meta property="og:site_name" content="Example">
          <meta property="og:title" content="OG Title">
          <meta name="description" content="Plain description">
          <meta property="og:description" content="OG Description">
          <meta property="og:image" content="/cover.jpg">
        </head>
      </html>
      ''',
      requestedUrl: Uri.parse('https://example.com/a'),
      resolvedUrl: Uri.parse('https://example.com/final'),
    );

    expect(preview, isNotNull);
    expect(preview!.title, 'OG Title');
    expect(preview.description, 'OG Description');
    expect(preview.siteName, 'Example');
    expect(preview.imageUrl, 'https://example.com/cover.jpg');
  });
}
