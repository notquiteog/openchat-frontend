final _linkPreviewUrlPattern = RegExp(
  r'(?:(?:https?):\/\/|www\.)[^\s<>()]+',
  caseSensitive: false,
);

String? firstLinkPreviewUrl(String text) {
  final match = _linkPreviewUrlPattern.firstMatch(text);
  if (match == null) return null;
  var raw = match.group(0) ?? '';
  raw = raw.replaceAll(RegExp(r'[.,!?;:]+$'), '');
  if (raw.isEmpty) return null;
  if (raw.toLowerCase().startsWith('www.')) {
    raw = 'https://$raw';
  }
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri.toString();
}
