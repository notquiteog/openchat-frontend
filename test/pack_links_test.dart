import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/utils/pack_links.dart';

void main() {
  test('sticker pack links round-trip through path form', () {
    final link = packDeepLink(kind: PackKind.sticker, packId: 'p1');

    expect(link, 'openchat://addstickers/p1');
    final parsed = packLinkFromUri(Uri.parse(link));
    expect(parsed?.kind, PackKind.sticker);
    expect(parsed?.packId, 'p1');
  });

  test('custom emoji pack links round-trip through path form', () {
    final link = packDeepLink(kind: PackKind.customEmoji, packId: 'emoji-1');

    expect(link, 'openchat://addemoji/emoji-1');
    final parsed = packLinkFromUri(Uri.parse(link));
    expect(parsed?.kind, PackKind.customEmoji);
    expect(parsed?.packId, 'emoji-1');
  });

  test('query forms parse id or pack parameters', () {
    expect(
      packLinkFromUri(Uri.parse('openchat://addstickers?id=p2'))?.packId,
      'p2',
    );
    expect(
      packLinkFromUri(Uri.parse('openchat://addemoji?pack=p3'))?.packId,
      'p3',
    );
  });

  test('unrelated or oversized links are rejected', () {
    expect(packLinkFromUri(Uri.parse('openchat://invite/x')), isNull);
    expect(packLinkFromUri(Uri.parse('openchat://contact/x')), isNull);
    expect(
      packLinkFromUri(Uri.parse('https://example.com/addstickers/p1')),
      isNull,
    );
    expect(
      packLinkFromUri(Uri.parse('openchat://addstickers/${'x' * 129}')),
      isNull,
    );
  });
}
