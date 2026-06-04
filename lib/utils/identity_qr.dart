import 'dart:convert';

const openChatFingerprintQrPrefix = 'openchat:fingerprint:';

String identityFingerprintQrPayload(String fingerprint) =>
    '$openChatFingerprintQrPrefix${normalizeIdentityFingerprint(fingerprint)}';

String normalizeIdentityFingerprint(String value) {
  var raw = value.trim();
  if (raw.isEmpty) return '';

  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      raw =
          decoded['fingerprint']?.toString() ??
          decoded['key_fingerprint']?.toString() ??
          raw;
    }
  } catch (_) {}

  final lower = raw.toLowerCase();
  if (lower.startsWith(openChatFingerprintQrPrefix)) {
    raw = raw.substring(openChatFingerprintQrPrefix.length);
  }

  return raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
}

bool isValidIdentityFingerprint(String fingerprint) =>
    RegExp(r'^[0-9A-F]{40,64}$').hasMatch(fingerprint);

String formatIdentityFingerprint(String fingerprint) {
  final normalized = normalizeIdentityFingerprint(fingerprint);
  final groups = <String>[];
  for (var i = 0; i < normalized.length; i += 4) {
    groups.add(normalized.substring(i, (i + 4).clamp(0, normalized.length)));
  }
  return groups.join(' ');
}
