import 'dart:async';
import 'dart:convert';

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

    final request = http.Request('GET', requestUrl)
      ..followRedirects = true
      ..maxRedirects = 3
      ..headers['Accept'] = 'text/html,application/xhtml+xml'
      ..headers['User-Agent'] = 'OpenChatLocalPreview/1.0';
    final response = await _client.send(request).timeout(timeout);
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
    final resolved = response.request?.url ?? url;
    return parseLocalLinkPreviewHtml(
      html,
      requestedUrl: url,
      resolvedUrl: resolved,
    );
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
