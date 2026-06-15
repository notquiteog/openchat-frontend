import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/passphrase_strength.dart';

void main() {
  test('keeps the 12 character floor separate from entropy', () {
    expect(
      PassphraseStrength.level('short-1!'),
      PassphraseStrengthLevel.tooShort,
    );
    expect(PassphraseStrength.isStrongEnoughForServer('short-1!'), isFalse);
  });

  test('obvious long passphrases remain weak', () {
    const passphrase = 'password1234';
    expect(passphrase.length, 12);
    expect(PassphraseStrength.level(passphrase), PassphraseStrengthLevel.weak);
    expect(
      PassphraseStrength.estimateBits(passphrase),
      lessThan(PassphraseStrength.minServerUploadBits),
    );
  });

  test('mixed long passphrases clear the server upload floor', () {
    const passphrase = 'a-very-long-test-passphrase';
    expect(PassphraseStrength.isStrongEnoughForServer(passphrase), isTrue);
    expect(
      PassphraseStrength.estimateBits(passphrase),
      greaterThanOrEqualTo(PassphraseStrength.minServerUploadBits),
    );
  });

  test('generated passphrases are strong enough for uploaded backups', () {
    final generated = PassphraseStrength.generate();
    expect(generated.length, greaterThanOrEqualTo(20));
    expect(PassphraseStrength.isStrongEnoughForServer(generated), isTrue);
    expect(
      PassphraseStrength.level(generated),
      isNot(PassphraseStrengthLevel.weak),
    );
  });
}
