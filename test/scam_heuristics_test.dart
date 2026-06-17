import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/scam_heuristics.dart';

void main() {
  group('ScamHeuristics.scanUrl', () {
    test('flags punycode / xn-- hosts as high severity', () {
      final v = ScamHeuristics.scanUrl('https://xn--80ak6aa92e.com/login');
      expect(v, isNotNull);
      expect(v!.severity, ScamSeverity.high);
    });

    test('flags mixed-script homograph hosts', () {
      // "аpple.com" — the leading 'а' is Cyrillic (U+0430), the rest ASCII.
      final v = ScamHeuristics.scanUrl('https://аpple.com');
      expect(v, isNotNull);
      expect(v!.severity, ScamSeverity.high);
    });

    test('flags crypto-drainer URL shapes', () {
      final v = ScamHeuristics.scanUrl(
        'https://airdrop-portal.com/connect-wallet',
      );
      expect(v, isNotNull);
      expect(v!.severity, ScamSeverity.high);
    });

    test('flags suspicious TLDs as soft caution', () {
      final v = ScamHeuristics.scanUrl('https://invoice.zip/download');
      expect(v, isNotNull);
      expect(v!.severity, ScamSeverity.caution);
    });

    test('does not flag ordinary https links', () {
      expect(ScamHeuristics.scanUrl('https://example.com/path'), isNull);
      expect(ScamHeuristics.scanUrl('https://github.com/openchat'), isNull);
    });

    test('does not flag an all-Latin brand domain', () {
      expect(ScamHeuristics.scanUrl('https://apple.com'), isNull);
    });
  });

  group('ScamHeuristics.scan', () {
    test('finds a flagged link inside prose', () {
      final v = ScamHeuristics.scan('hey check this out https://invoice.zip ok');
      expect(v, isNotNull);
      expect(v!.severity, ScamSeverity.caution);
    });

    test('prefers the high-severity link when several are present', () {
      final v = ScamHeuristics.scan(
        'safe https://example.com and bad https://xn--80ak6aa92e.com',
      );
      expect(v, isNotNull);
      expect(v!.severity, ScamSeverity.high);
    });

    test('returns null for plain text with no links', () {
      expect(ScamHeuristics.scan('just a normal message, nothing here'), isNull);
    });

    test('returns null for a clean link', () {
      expect(ScamHeuristics.scan('see https://example.com please'), isNull);
    });
  });
}
