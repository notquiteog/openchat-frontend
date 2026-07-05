import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/link_preview.dart';

enum LinkPreviewFetchMode { direct, privacyProxy }

class LinkPreviewService {
  LinkPreviewService({
    http.Client? client,
    this.mode = LinkPreviewFetchMode.direct,
    this.privacyProxyEndpoint,
  }) : _client = client ?? http.Client();

  static const maxUrlLength = 2048;
  static const maxBytes = 256 * 1024;
  static const timeout = Duration(seconds: 5);

  /// Maximum number of redirect hops to follow manually. Each hop is
  /// re-validated (scheme + SSRF host guard) before it is fetched.
  static const maxRedirects = 3;

  /// DNS resolution budget for the SSRF host guard. Kept short so a slow or
  /// hostile resolver cannot stall the preview fetch; on timeout we fail closed.
  static const _dnsLookupTimeout = Duration(seconds: 3);

  final http.Client _client;
  final LinkPreviewFetchMode mode;
  final Uri? privacyProxyEndpoint;

  Future<LinkPreview?> fetch(String rawUrl) async {
    final url = _validatedUrl(rawUrl);
    if (url == null) return null;
    final requestUrl = switch (mode) {
      LinkPreviewFetchMode.direct => url,
      LinkPreviewFetchMode.privacyProxy => _privacyProxyUrl(url),
    };
    if (requestUrl == null) return null;

    // Anything thrown while probing DNS, connecting, or streaming (including
    // timeouts and socket errors) is swallowed here: `fetch` must never throw
    // and must return null on any rejection, including SSRF-guard rejections.
    try {
      return await _fetchWithGuardedRedirects(url, requestUrl);
    } catch (_) {
      return null;
    }
  }

  /// Fetches [requestUrl] with redirects disabled at the HTTP layer, following
  /// up to [maxRedirects] hops by hand. Every target — the initial request and
  /// each `Location` — is passed through [_hostIsSafe] before it is contacted,
  /// which closes the DNS-rebinding hole that automatic redirect-following (with
  /// no per-hop revalidation) would otherwise leave open.
  Future<LinkPreview?> _fetchWithGuardedRedirects(
    Uri requestedUrl,
    Uri firstTarget,
  ) async {
    var target = firstTarget;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      // Re-run the SSRF guard on every hop. A 30x pointing at an internal host
      // must be aborted before we ever open the connection to it.
      if (!await _hostIsSafe(target)) return null;

      final request = http.Request('GET', target)
        ..followRedirects = false
        ..headers['Accept'] = 'text/html,application/xhtml+xml'
        ..headers['User-Agent'] = 'OpenChatLocalPreview/1.0';
      final response = await _client.send(request).timeout(timeout);

      // Manual redirect handling: resolve the Location against the current
      // target, re-validate its scheme, and loop to re-run the host guard.
      if (response.statusCode >= 300 && response.statusCode < 400) {
        // Drain/discard the redirect body so the connection can be released.
        await response.stream.drain<void>();
        final location = response.headers['location'];
        if (location == null || location.isEmpty) return null;
        final next = _validatedUrl(target.resolve(location).toString());
        if (next == null) return null;
        target = next;
        continue;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      if (contentType.isNotEmpty &&
          !contentType.contains('text/html') &&
          !contentType.contains('application/xhtml')) {
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(timeout)) {
        final remaining = maxBytes - bytes.length;
        if (remaining <= 0) break;
        bytes.addAll(chunk.length > remaining ? chunk.take(remaining) : chunk);
      }
      if (bytes.isEmpty) return null;
      final html = utf8.decode(bytes, allowMalformed: true);
      return parseLocalLinkPreviewHtml(
        html,
        requestedUrl: requestedUrl,
        resolvedUrl: target,
      );
    }
    // Ran out of redirect budget without reaching a final response.
    return null;
  }

  void close() => _client.close();

  Uri? _privacyProxyUrl(Uri url) {
    final endpoint = privacyProxyEndpoint;
    if (endpoint == null) return null;
    return endpoint.replace(
      queryParameters: {...endpoint.queryParameters, 'url': url.toString()},
    );
  }

  Uri? _validatedUrl(String rawUrl) {
    if (rawUrl.trim().isEmpty || rawUrl.length > maxUrlLength) return null;
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      return null;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri;
  }

  /// SSRF gate: reports whether every address [uri]'s host will resolve to is a
  /// globally-routable public address. This is the async companion to the
  /// synchronous scheme/length checks in [_validatedUrl].
  ///
  /// - If the host is a literal IP, it is parsed and classified directly.
  /// - If the host is a DNS name, it is resolved and REJECTED if *any* resolved
  ///   address is non-public. That "any" is deliberate: it closes the
  ///   DNS-rebinding case where a name returns one public and one internal
  ///   address (or flips between fetches).
  ///
  /// Fails closed: unparseable literals, lookup failures, empty results, and
  /// lookup timeouts all return false.
  Future<bool> _hostIsSafe(Uri uri) async {
    final host = uri.host;
    if (host.isEmpty) return false;

    // Uri keeps IPv6 literals bracketed (e.g. "[::1]"); strip the brackets
    // before handing the text to InternetAddress.
    final literal = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;

    // Literal IP: classify directly, no DNS involved.
    final literalAddr = InternetAddress.tryParse(literal);
    if (literalAddr != null) {
      return _isPublicHostAddress(literalAddr);
    }

    // DNS host: resolve and require *every* answer to be public.
    try {
      final addresses = await InternetAddress.lookup(
        host,
      ).timeout(_dnsLookupTimeout);
      if (addresses.isEmpty) return false;
      for (final addr in addresses) {
        if (!_isPublicHostAddress(addr)) return false;
      }
      return true;
    } catch (_) {
      // Resolution failure or timeout — fail closed.
      return false;
    }
  }

  /// Reports whether [addr] is a globally-routable public unicast address.
  ///
  /// Mirrors `isPublicUnicast` in the Go reference
  /// (backend/internal/botwebhook/dialer.go): rejects loopback, unspecified,
  /// multicast, RFC1918/link-local/unique-local ranges, IPv4-mapped IPv6 of any
  /// of those, and the reserved IPv4 ranges that a plain "private" check misses
  /// (0.0.0.0/8, 100.64.0.0/10 CGNAT, 192.0.0.0/24, 198.18.0.0/15, broadcast).
  bool _isPublicHostAddress(InternetAddress addr) {
    // Fast paths Dart classifies for us.
    if (addr.isLoopback || addr.isLinkLocal || addr.isMulticast) return false;

    final bytes = addr.rawAddress;

    if (addr.type == InternetAddressType.IPv6) {
      // Unwrap IPv4-mapped (::ffff:0:0/96) and IPv4-compatible (::/96, e.g.
      // "::a.b.c.d") IPv6 so an attacker can't smuggle an internal IPv4 through
      // an IPv6 literal. Classify the embedded IPv4 with the v4 rules below.
      if (bytes.length == 16) {
        final firstTenZero = bytes.take(10).every((b) => b == 0);
        final isMapped = firstTenZero && bytes[10] == 0xff && bytes[11] == 0xff;
        final isCompat =
            firstTenZero &&
            bytes[10] == 0 &&
            bytes[11] == 0 &&
            // Guard against ::/96 catching ::1 / :: themselves.
            !(bytes[12] == 0 && bytes[13] == 0 && bytes[14] == 0);
        if (isMapped || isCompat) {
          return _isPublicIPv4(bytes.sublist(12));
        }
      }
      return _isPublicIPv6(bytes);
    }

    return _isPublicIPv4(bytes);
  }
}

/// Classifies a 4-byte IPv4 address, returning true only for public unicast.
/// Blocks 0.0.0.0/8 "this network", 10/8, 100.64/10 CGNAT, 127/8 loopback,
/// 169.254/16 link-local, 172.16/12 & 192.168/16 private, 192.0.0/24, 198.18/15
/// benchmarking, multicast (224/4), and the 255.255.255.255 broadcast address.
bool _isPublicIPv4(List<int> b) {
  if (b.length != 4) return false;
  final a = b[0], c = b[1], d = b[2], e = b[3];
  if (a == 0) return false; // 0.0.0.0/8 "this network" (incl. unspecified)
  if (a == 10) return false; // 10.0.0.0/8 private
  if (a == 100 && (c & 0xc0) == 64) return false; // 100.64.0.0/10 CGNAT
  if (a == 127) return false; // 127.0.0.0/8 loopback
  if (a == 169 && c == 254) return false; // 169.254.0.0/16 link-local
  if (a == 172 && (c & 0xf0) == 16) return false; // 172.16.0.0/12 private
  if (a == 192 && c == 0 && d == 0) return false; // 192.0.0.0/24 IETF protocol
  if (a == 192 && c == 168) return false; // 192.168.0.0/16 private
  if (a == 198 && (c & 0xfe) == 18) return false; // 198.18.0.0/15 benchmarking
  if (a >= 224) return false; // 224.0.0.0/4 multicast + 240/4 reserved
  if (a == 255 && c == 255 && d == 255 && e == 255) return false; // broadcast
  return true;
}

/// Classifies a 16-byte IPv6 address, returning true only for public unicast.
/// Blocks :: (unspecified), ::1 (loopback), fc00::/7 unique-local, fe80::/10
/// link-local, and ff00::/8 multicast. IPv4-mapped/compatible forms are handled
/// by the caller before this is reached.
bool _isPublicIPv6(List<int> b) {
  if (b.length != 16) return false;
  if (b.every((x) => x == 0)) return false; // :: unspecified
  if (b.take(15).every((x) => x == 0) && b[15] == 1) return false; // ::1
  if ((b[0] & 0xfe) == 0xfc) return false; // fc00::/7 unique-local
  // fe80::/10 link-local
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return false;
  if (b[0] == 0xff) return false; // ff00::/8 multicast
  return true;
}

LinkPreview? parseLocalLinkPreviewHtml(
  String html, {
  required Uri requestedUrl,
  required Uri resolvedUrl,
}) {
  final document = html_parser.parse(html);
  final fields = <String, String>{};
  for (final element in document.getElementsByTagName('meta')) {
    final key =
        element.attributes['property']?.trim().toLowerCase() ??
        element.attributes['name']?.trim().toLowerCase() ??
        '';
    final content = element.attributes['content'] ?? '';
    if (content.isEmpty || fields.containsKey(key)) continue;
    switch (key) {
      case 'og:site_name':
      case 'og:title':
      case 'twitter:title':
      case 'description':
      case 'og:description':
      case 'twitter:description':
      case 'og:image':
      case 'twitter:image':
        fields[key] = content;
    }
  }

  final titleElement = document.getElementsByTagName('title').firstOrNull;
  if (titleElement != null) {
    fields['title'] = titleElement.text;
  }

  final preview = LinkPreview.local(
    url: requestedUrl.toString(),
    resolvedUrl: resolvedUrl.toString(),
    siteName: _cleanPreviewText(
      _firstNonEmpty([fields['og:site_name'], requestedUrl.host]),
    ),
    title: _cleanPreviewText(
      _firstNonEmpty([
        fields['og:title'],
        fields['twitter:title'],
        fields['title'],
      ]),
    ),
    description: _cleanPreviewText(
      _firstNonEmpty([
        fields['og:description'],
        fields['twitter:description'],
        fields['description'],
      ]),
    ),
    imageUrl: _resolvePreviewUrl(
      _firstNonEmpty([fields['og:image'], fields['twitter:image']]),
      resolvedUrl,
    ),
  );
  if (preview.title.isEmpty &&
      preview.description.isEmpty &&
      preview.siteName.isEmpty) {
    return null;
  }
  return preview;
}

String _resolvePreviewUrl(String rawUrl, Uri baseUrl) {
  if (rawUrl.trim().isEmpty) return '';
  return baseUrl.resolve(rawUrl.trim()).toString();
}

String _cleanPreviewText(String value) {
  final cleaned = value
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .join(' ');
  if (cleaned.length <= 500) return cleaned;
  return cleaned.substring(0, 500);
}

String _firstNonEmpty(List<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
  }
  return '';
}
