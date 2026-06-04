// Server coordinates are injected at build time via --dart-define:
//   --dart-define=OPENCHAT_HOST=chat.example.com
//   --dart-define=OPENCHAT_PORT=443
//   --dart-define=OPENCHAT_HTTPS=true
//   --dart-define=MAPBOX_ACCESS_TOKEN=pk...
//   --dart-define=MAPBOX_STYLE=mapbox/streets-v12
//
// Defaults (localhost:8080 over HTTP) are used for local development.
class ApiConfig {
  static const String _host = String.fromEnvironment(
    'OPENCHAT_HOST',
    defaultValue: 'localhost',
  );
  static const int _port = int.fromEnvironment(
    'OPENCHAT_PORT',
    defaultValue: 8080,
  );
  static const bool _https = bool.fromEnvironment(
    'OPENCHAT_HTTPS',
    defaultValue: false,
  );
  static const String mapboxAccessToken = String.fromEnvironment(
    'MAPBOX_ACCESS_TOKEN',
    defaultValue: '',
  );
  static const String mapboxStyle = String.fromEnvironment(
    'MAPBOX_STYLE',
    defaultValue: 'mapbox/streets-v12',
  );

  static bool get hasMapbox => mapboxAccessToken.trim().isNotEmpty;

  static String get baseUrl {
    final scheme = _https ? 'https' : 'http';
    final isDefaultPort = (_https && _port == 443) || (!_https && _port == 80);
    return isDefaultPort ? '$scheme://$_host' : '$scheme://$_host:$_port';
  }

  static String get wsUrl {
    final scheme = _https ? 'wss' : 'ws';
    final isDefaultPort = (_https && _port == 443) || (!_https && _port == 80);
    return isDefaultPort ? '$scheme://$_host/ws' : '$scheme://$_host:$_port/ws';
  }

  /// Resolves a media URL that the server may return as an absolute URL
  /// (production, behind nginx) or as a host-relative path like
  /// "/media/avatars/x.webp" (local/dev, or records stored before a public
  /// base URL was configured). Relative paths are joined onto [baseUrl] so the
  /// image loader always receives a URL with a host.
  static String resolveMedia(String raw) {
    if (raw.isEmpty) return raw;
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    return raw.startsWith('/') ? '$baseUrl$raw' : '$baseUrl/$raw';
  }
}

/// A STUN or TURN server for WebRTC.
class IceServer {
  final String url;
  final String? username;
  final String? credential;

  const IceServer({required this.url, this.username, this.credential});

  factory IceServer.fromJson(Map<String, dynamic> json) => IceServer(
    url: json['url'] as String,
    username: json['username'] as String?,
    credential: json['credential'] as String?,
  );

  /// Returns the map format expected by flutter_webrtc's createPeerConnection.
  Map<String, dynamic> toRtcMap() => {
    'urls': url,
    if (username != null) 'username': username,
    if (credential != null) 'credential': credential,
  };
}
