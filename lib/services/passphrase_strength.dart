import 'dart:math' as math;

enum PassphraseStrengthLevel { tooShort, weak, fair, good, strong }

class PassphraseStrength {
  const PassphraseStrength._();

  static const int minLength = 12;
  static const double minServerUploadBits = 40;
  static const double _strongBits = 72;

  static double estimateBits(String passphrase) {
    final value = passphrase.trim();
    if (value.isEmpty) return 0;
    final pool = _characterPool(value);
    var bits = value.length * _log2(pool);
    bits -= _repeatedCharacterPenalty(value, pool);
    bits -= _sequentialPenalty(value, pool);
    bits -= _obviousTokenPenalty(value, pool);

    if (_isSingleClass(value)) bits *= 0.66;
    return bits.clamp(0, double.infinity).toDouble();
  }

  static PassphraseStrengthLevel level(String passphrase) {
    final value = passphrase.trim();
    if (value.length < minLength) return PassphraseStrengthLevel.tooShort;
    final bits = estimateBits(value);
    if (bits < minServerUploadBits) return PassphraseStrengthLevel.weak;
    if (bits < 56) return PassphraseStrengthLevel.fair;
    if (bits < _strongBits) return PassphraseStrengthLevel.good;
    return PassphraseStrengthLevel.strong;
  }

  static bool isStrongEnoughForServer(String passphrase) =>
      passphrase.trim().length >= minLength &&
      estimateBits(passphrase) >= minServerUploadBits;

  static double fraction(String passphrase) {
    final value = passphrase.trim();
    if (value.isEmpty) return 0;
    final lengthFraction = (value.length / minLength).clamp(0.0, 1.0) * 0.18;
    final entropyFraction = (estimateBits(value) / _strongBits).clamp(0.0, 1.0);
    return math.max(lengthFraction, entropyFraction);
  }

  static String label(String passphrase) => switch (level(passphrase)) {
    PassphraseStrengthLevel.tooShort => 'Too short',
    PassphraseStrengthLevel.weak => 'Weak',
    PassphraseStrengthLevel.fair => 'Fair',
    PassphraseStrengthLevel.good => 'Good',
    PassphraseStrengthLevel.strong => 'Strong',
  };

  static String generate({int length = 22}) {
    final effectiveLength = math.max(length, 20);
    final random = math.Random.secure();
    const lower = 'abcdefghijkmnopqrstuvwxyz';
    const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    const digits = '23456789';
    const symbols = '!@#%^&*-_=+?';
    const all = '$lower$upper$digits$symbols';
    final chars = <String>[
      _pick(lower, random),
      _pick(upper, random),
      _pick(digits, random),
      _pick(symbols, random),
      for (var i = 4; i < effectiveLength; i++) _pick(all, random),
    ];
    for (var i = chars.length - 1; i > 0; i--) {
      final j = random.nextInt(i + 1);
      final tmp = chars[i];
      chars[i] = chars[j];
      chars[j] = tmp;
    }
    return chars.join();
  }

  static String _pick(String alphabet, math.Random random) =>
      alphabet[random.nextInt(alphabet.length)];

  static int _characterPool(String value) {
    var pool = 0;
    if (RegExp(r'[a-z]').hasMatch(value)) pool += 26;
    if (RegExp(r'[A-Z]').hasMatch(value)) pool += 26;
    if (RegExp(r'[0-9]').hasMatch(value)) pool += 10;
    if (RegExp(r'[^a-zA-Z0-9\s]').hasMatch(value)) pool += 33;
    if (RegExp(r'\s').hasMatch(value)) pool += 8;
    return math.max(pool, 1);
  }

  static bool _isSingleClass(String value) {
    var classes = 0;
    if (RegExp(r'^[a-z]+$').hasMatch(value)) classes++;
    if (RegExp(r'^[A-Z]+$').hasMatch(value)) classes++;
    if (RegExp(r'^[0-9]+$').hasMatch(value)) classes++;
    if (RegExp(r'^[^a-zA-Z0-9\s]+$').hasMatch(value)) classes++;
    return classes == 1;
  }

  static double _repeatedCharacterPenalty(String value, int pool) {
    var repeated = 0;
    for (var i = 1; i < value.length; i++) {
      if (value[i].toLowerCase() == value[i - 1].toLowerCase()) repeated++;
    }
    return repeated * _log2(pool) * 0.92;
  }

  static double _sequentialPenalty(String value, int pool) {
    final lower = value.toLowerCase();
    var penaltyChars = 0;
    const sequences = [
      'abcdefghijklmnopqrstuvwxyz',
      '0123456789',
      'qwertyuiop',
      'asdfghjkl',
      'zxcvbnm',
    ];
    for (final sequence in sequences) {
      penaltyChars += _longestContainedRun(lower, sequence);
      penaltyChars += _longestContainedRun(
        lower,
        sequence.split('').reversed.join(),
      );
    }
    return penaltyChars * _log2(pool) * 0.82;
  }

  static int _longestContainedRun(String value, String sequence) {
    var longest = 0;
    final maxRun = math.min(value.length, sequence.length);
    for (var run = maxRun; run >= 4; run--) {
      for (var start = 0; start <= sequence.length - run; start++) {
        if (value.contains(sequence.substring(start, start + run))) {
          longest = math.max(longest, run);
          break;
        }
      }
      if (longest != 0) break;
    }
    return longest;
  }

  static double _obviousTokenPenalty(String value, int pool) {
    final lower = value.toLowerCase();
    const tokens = [
      'password',
      'passphrase',
      'qwerty',
      'letmein',
      'welcome',
      'openchat',
      'backup',
      'secret',
      'admin',
      '12345',
      '0000',
      '1111',
    ];
    var tokenChars = 0;
    for (final token in tokens) {
      if (lower.contains(token)) tokenChars += token.length;
    }
    return tokenChars * _log2(pool) * 0.9;
  }

  static double _log2(num value) => math.log(value) / math.ln2;
}
