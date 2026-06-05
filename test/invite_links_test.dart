import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/utils/invite_links.dart';

void main() {
  test('inviteDeepLink builds stable OpenChat invite URI', () {
    final link = inviteDeepLink(token: 'abc_123');

    final uri = Uri.parse(link);
    expect(uri.scheme, 'openchat');
    expect(uri.host, 'invite');
    expect(uri.pathSegments, ['abc_123']);
  });

  test('inviteTokenFromUri parses path and query token forms', () {
    expect(
      inviteTokenFromUri(Uri.parse('openchat://invite/token-1')),
      'token-1',
    );
    expect(
      inviteTokenFromUri(Uri.parse('openchat://invite?token=token-2')),
      'token-2',
    );
  });

  test('inviteTokenFromUri rejects non invite links', () {
    expect(inviteTokenFromUri(Uri.parse('openchat://message/abc')), isNull);
    expect(
      inviteTokenFromUri(Uri.parse('https://example.com/invite/a')),
      isNull,
    );
  });
}
