final _linkPreviewUrlPattern = RegExp(
  r'(?:(?:https?):\/\/|www\.)[^\s<>()]+',
  caseSensitive: false,
);

class LinkTextMatch {
  final int start;
  final int end;
  final String url;

  const LinkTextMatch({
    required this.start,
    required this.end,
    required this.url,
  });
}

String? firstLinkPreviewUrl(String text) {
  final matches = linkTextMatches(text);
  if (matches.isEmpty) return null;
  return matches.first.url;
}

List<LinkTextMatch> linkTextMatches(String text) {
  final matches = <LinkTextMatch>[];
  for (final match in _linkPreviewUrlPattern.allMatches(text)) {
    final normalized = _normalizeLinkMatch(match.group(0) ?? '');
    if (normalized == null) continue;
    final trimmedLength = _trimTrailingPunctuation(match.group(0) ?? '').length;
    matches.add(
      LinkTextMatch(
        start: match.start,
        end: match.start + trimmedLength,
        url: normalized,
      ),
    );
  }
  return matches;
}

String? _normalizeLinkMatch(String raw) {
  raw = _trimTrailingPunctuation(raw);
  if (raw.isEmpty) return null;
  if (raw.toLowerCase().startsWith('www.')) {
    raw = 'https://$raw';
  }
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri.toString();
}

String _trimTrailingPunctuation(String raw) =>
    raw.replaceAll(RegExp(r'[.,!?;:]+$'), '');
