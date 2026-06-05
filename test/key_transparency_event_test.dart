import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/key_transparency_event.dart';

void main() {
  test('builds the canonical key rotation signature payload', () {
    const publicKey =
        '-----BEGIN PGP PUBLIC KEY BLOCK-----\n'
        'abc\n'
        '-----END PGP PUBLIC KEY BLOCK-----';

    final data = keyRotationSignatureData(
      userId: ' user-a ',
      oldFingerprint: ' old ',
      newFingerprint: ' new ',
      newPublicKey: '$publicKey\n',
    );

    expect(
      data,
      'openchat-key-rotation-v1:user-a:OLD:NEW:'
      'B01E1EB2BEE4071763FF2E81B3267D87D399C70003AF554C6DDA12EA7F9EF6A2',
    );
  });
}
