import '../utils/link_preview_utils.dart';

/// Severity of a scam/phishing heuristic hit. [caution] is a soft signal
/// (unusual TLD); [high] is a strong tell (homograph / punycode / drainer).
enum ScamSeverity { caution, high }

class ScamVerdict {
  final ScamSeverity severity;
  final String reason;
  final String matchedUrl;

  const ScamVerdict({
    required this.severity,
    required this.reason,
    required this.matchedUrl,
  });
}

/// Pure, offline, lexical scam/phishing heuristics.
///
/// This is the ONLY place a privacy messenger can do this: a sealed-sender
/// server physically cannot read the message to run server-side spam ML, so
/// detection lives on-device. It inspects only the link text the user can
/// already see and NEVER fetches the URL, resolves redirects, or contacts any
/// reputation/safe-browsing service — doing so would leak the link and the fact
/// of receipt. The verdict is render-only and is never serialized to the wire
/// (so it can never become a server- or peer-provable accusation).
class ScamHeuristics {
  /// Scans every link in [text] and returns the most severe verdict, or null.
  static ScamVerdict? scan(String text) {
    ScamVerdict? worst;
    for (final m in linkTextMatches(text)) {
      final v = scanUrl(m.url);
      if (v == null) continue;
      if (v.severity == ScamSeverity.high) return v;
      worst ??= v;
    }
    return worst;
  }

  /// Scans a single already-normalized http(s) URL.
  static ScamVerdict? scanUrl(String url) {
    // The confusable-script check runs on the raw authority so it survives
    // Dart's URI normalization of non-ASCII hosts.
    final confusable = _hasConfusableAuthority(url);
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      return confusable ? _confusableVerdict(url) : null;
    }
    final host = uri.host.toLowerCase();
    final labels = host.split('.');

    // 1) Punycode / IDN ACE label — the classic homograph tell.
    if (labels.any((l) => l.startsWith('xn--'))) {
      return ScamVerdict(
        severity: ScamSeverity.high,
        reason: 'This link uses a punycode (xn--) domain that can imitate a '
            'real site.',
        matchedUrl: url,
      );
    }

    // 2) Mixed-script host: ASCII letters alongside Latin-look-alike letters
    // from another alphabet (e.g. Cyrillic а/о/е) — a spoofed brand domain.
    if (confusable) return _confusableVerdict(url);

    // 3) Crypto-drainer / fake-airdrop URL shapes.
    final full = '$host${uri.path.toLowerCase()}';
    if (_drainerPattern.hasMatch(full)) {
      return ScamVerdict(
        severity: ScamSeverity.high,
        reason: 'This link looks like a crypto wallet-drainer or fake airdrop.',
        matchedUrl: url,
      );
    }

    // 4) Suspicious TLD — a soft "double-check" signal, not an accusation.
    final tld = labels.length > 1 ? labels.last : '';
    if (_suspiciousTlds.contains(tld)) {
      return ScamVerdict(
        severity: ScamSeverity.caution,
        reason: 'This link uses an unusual .$tld domain often abused for '
            'scams — double-check before tapping.',
        matchedUrl: url,
      );
    }

    return null;
  }

  /// A host is "confusable" when it contains both an ASCII letter and a
  /// non-ASCII letter that imitates a Latin one — i.e. a deliberately mixed
  /// script. An all-non-Latin host (a legitimately localized domain) is NOT
  /// flagged, to stay friendly to non-English users.
  static ScamVerdict _confusableVerdict(String url) => ScamVerdict(
    severity: ScamSeverity.high,
    reason:
        'This domain mixes look-alike characters from different alphabets.',
    matchedUrl: url,
  );

  /// Extracts the host authority straight from the raw URL string (not via
  /// Uri, which may normalize non-ASCII away) and reports whether it mixes an
  /// ASCII letter with a Latin-look-alike letter from another script.
  static bool _hasConfusableAuthority(String url) {
    var s = url;
    final scheme = s.indexOf('://');
    if (scheme >= 0) s = s.substring(scheme + 3);
    final slash = s.indexOf('/');
    if (slash >= 0) s = s.substring(0, slash);
    final at = s.lastIndexOf('@');
    if (at >= 0) s = s.substring(at + 1);
    final colon = s.indexOf(':');
    if (colon >= 0) s = s.substring(0, colon);
    var hasAscii = false;
    var hasConfusable = false;
    for (final rune in s.toLowerCase().runes) {
      if (rune >= 0x61 && rune <= 0x7a) hasAscii = true;
      if (_confusableRunes.contains(rune)) hasConfusable = true;
    }
    return hasAscii && hasConfusable;
  }

  static final RegExp _drainerPattern = RegExp(
    r'(seed.?phrase|wallet.?connect|connect.?wallet|claim.?(airdrop|reward|nft)'
    r'|validate.?wallet|restore.?wallet|sync.?wallet|free.?(eth|btc|crypto|usdt))',
  );

  static const Set<String> _suspiciousTlds = {
    'zip', 'mov', 'top', 'xyz', 'gq', 'tk', 'ml', 'cf', 'click', 'country',
    'kim', 'work', 'rest', 'cyou',
  };

  // Latin-look-alike letters from Cyrillic and Greek used in homograph attacks.
  static const Set<int> _confusableRunes = {
    0x0430, 0x0435, 0x043E, 0x0440, 0x0441, 0x0445, 0x0443, 0x0456, // а е о р с х у і
    0x03BF, 0x03B1, 0x03B5, 0x03C1, // ο α ε ρ
  };
}
