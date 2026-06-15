import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:socks5_proxy/socks_client.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'secure_storage_service.dart';

enum ProxyMode { off, http, socks5, tor }

extension ProxyModeApi on ProxyMode {
  String get wire => switch (this) {
    ProxyMode.off => 'off',
    ProxyMode.http => 'http',
    ProxyMode.socks5 => 'socks5',
    ProxyMode.tor => 'tor',
  };

  String get label => switch (this) {
    ProxyMode.off => 'Off',
    ProxyMode.http => 'HTTP',
    ProxyMode.socks5 => 'SOCKS5',
    ProxyMode.tor => 'Tor',
  };
}

ProxyMode _modeFromWire(String? raw) => switch (raw) {
  'http' => ProxyMode.http,
  'socks5' => ProxyMode.socks5,
  'tor' => ProxyMode.tor,
  _ => ProxyMode.off,
};

/// Immutable proxy configuration. Tor is SOCKS5 with a conventional default of
/// 127.0.0.1:9050 (a running Orbot / Tor daemon is assumed — not bundled).
@immutable
class ProxyConfig {
  final ProxyMode mode;
  final String host;
  final int port;

  /// When true, voice/video calls are blocked while the proxy is on, because
  /// WebRTC/LiveKit media is UDP and cannot be tunnelled through a TCP SOCKS
  /// proxy (it would leak the real IP).
  final bool blockCallsWhenActive;

  /// When true, an active proxy that cannot be applied (e.g. a SOCKS/Tor host
  /// that is not a literal IP) refuses every connection instead of silently
  /// falling back to a direct route that would leak the real IP. The UI seeds
  /// this true and keeps it on for Tor; it defaults on for stored configs that
  /// predate the field.
  final bool failClosed;

  const ProxyConfig({
    this.mode = ProxyMode.off,
    this.host = '127.0.0.1',
    this.port = 9050,
    this.blockCallsWhenActive = true,
    this.failClosed = true,
  });

  bool get isActive => mode != ProxyMode.off;

  /// Effective host/port — Tor defaults to 127.0.0.1:9050 when left blank.
  String get effectiveHost => host.trim().isEmpty ? '127.0.0.1' : host.trim();
  int get effectivePort {
    if (port > 0) return port;
    return mode == ProxyMode.tor ? 9050 : 1080;
  }

  ProxyConfig copyWith({
    ProxyMode? mode,
    String? host,
    int? port,
    bool? blockCallsWhenActive,
    bool? failClosed,
  }) => ProxyConfig(
    mode: mode ?? this.mode,
    host: host ?? this.host,
    port: port ?? this.port,
    blockCallsWhenActive: blockCallsWhenActive ?? this.blockCallsWhenActive,
    failClosed: failClosed ?? this.failClosed,
  );

  Map<String, dynamic> toJson() => {
    'mode': mode.wire,
    'host': host,
    'port': port,
    'block_calls': blockCallsWhenActive,
    'fail_closed': failClosed,
  };

  factory ProxyConfig.fromJson(Map<String, dynamic> json) => ProxyConfig(
    mode: _modeFromWire(json['mode'] as String?),
    host: json['host'] as String? ?? '127.0.0.1',
    port: json['port'] as int? ?? 9050,
    blockCallsWhenActive: json['block_calls'] as bool? ?? true,
    // Default on so configs stored before this field existed fail closed
    // rather than fail open.
    failClosed: json['fail_closed'] as bool? ?? true,
  );
}

/// Routes the app's network traffic through an HTTP or SOCKS5/Tor proxy.
///
/// Installs an [HttpOverrides] so `package:http`, `cached_network_image`, the
/// raw [HttpClient]s in attachment uploads, and the link-preview fetcher all go
/// through the proxy with a single switch. WebSockets are proxied per-connection
/// via [newHttpClient] passed as `WebSocket.connect`'s `customClient`.
///
/// Out of scope (documented in the UI): WebRTC/LiveKit media is UDP and not
/// SOCKS-routable; FCM push is proprietary and follows OS-level proxy settings.
class ProxyService {
  ProxyService._();
  static final ProxyService instance = ProxyService._();

  ProxyConfig _config = const ProxyConfig(mode: ProxyMode.off);
  ProxyConfig get config => _config;

  bool get isActive => _config.isActive;

  /// True if a call should be refused right now due to the strict toggle.
  bool get callsBlocked => _config.isActive && _config.blockCallsWhenActive;

  Future<void> load(SecureStorageService storage) async {
    final raw = await storage.getProxyConfig();
    if (raw != null && raw.isNotEmpty) {
      try {
        _config = ProxyConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        _config = const ProxyConfig(mode: ProxyMode.off);
      }
    }
    _apply();
  }

  Future<void> save(SecureStorageService storage, ProxyConfig config) async {
    _config = config;
    await storage.setProxyConfig(jsonEncode(config.toJson()));
    _apply();
  }

  void _apply() {
    if (!_config.isActive) {
      HttpOverrides.global = null;
      return;
    }
    HttpOverrides.global = _ProxyHttpOverrides(_config);
  }

  /// Builds an [HttpClient] configured with the active proxy, for callers that
  /// need their own client (e.g. WebSocket `customClient`). Returns null when no
  /// proxy is active so callers can use the platform default.
  HttpClient? newHttpClient() {
    if (!_config.isActive) return null;
    final client = HttpClient();
    configureClient(client, _config);
    return client;
  }

  /// Opens a WebSocket through the active proxy. Returns null ONLY when no proxy
  /// is active, so the caller's `?? WebSocketChannel.connect` fallback opens a
  /// direct socket exclusively in the off case. When the proxy is active but
  /// misconfigured, [newHttpClient] returns a deny-all client and this throws —
  /// the throw must propagate (never caught into a null) so the caller never
  /// silently reconnects direct.
  Future<WebSocketChannel?> connectWebSocket(
    Uri url, {
    Iterable<String>? protocols,
  }) async {
    final client = newHttpClient();
    if (client == null) return null;
    final socket = await WebSocket.connect(
      url.toString(),
      protocols: protocols,
      customClient: client,
    );
    return IOWebSocketChannel(socket);
  }

  /// Applies [config] to an existing [HttpClient].
  ///
  /// Fail-closed invariant: when a proxy is active but cannot be applied, this
  /// installs a deny-all [connectionFactory] (it never returns a plain direct
  /// client). It must never *throw* — `_ProxyHttpOverrides.createHttpClient`
  /// runs for ALL app traffic, so a throw here would crash unrelated requests
  /// at client construction. Only actual connection attempts may fail.
  static void configureClient(HttpClient client, ProxyConfig config) {
    switch (config.mode) {
      case ProxyMode.off:
        return;
      case ProxyMode.http:
        // An HTTP PROXY directive fails closed on its own: if the proxy is
        // unreachable the request errors, it does not fall back to direct.
        client.findProxy = (uri) =>
            'PROXY ${config.effectiveHost}:${config.effectivePort}';
      case ProxyMode.socks5:
      case ProxyMode.tor:
        final addr = InternetAddress.tryParse(config.effectiveHost);
        if (addr == null) {
          // Active proxy whose host is not a literal IP: it cannot be applied.
          // Refuse every connection instead of silently going direct — a
          // direct fallback would leak the real IP, which is the entire thing
          // the proxy exists to prevent. This is enforced regardless of
          // [ProxyConfig.failClosed]; there is no toggle that re-opens the leak.
          _installDenyAll(client);
          return;
        }
        SocksTCPClient.assignToHttpClient(client, [
          ProxySettings(addr, config.effectivePort),
        ]);
    }
  }

  /// Wires [client] to refuse every connection. Uses the same
  /// `connectionFactory` hook the SOCKS client uses, so it must be the only
  /// factory set on the client (do not also call `assignToHttpClient`). The
  /// failure surfaces at connect time as a [SocketException] whose message
  /// contains "traffic blocked" so the settings UI can recognise it.
  static void _installDenyAll(HttpClient client) {
    client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) =>
        Future<ConnectionTask<Socket>>.error(
          const SocketException(
            'Proxy unreachable - traffic blocked (fail-closed)',
          ),
        );
  }
}

class _ProxyHttpOverrides extends HttpOverrides {
  _ProxyHttpOverrides(this.config);
  final ProxyConfig config;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    // configureClient installs a deny-all connectionFactory (never throws) when
    // the proxy can't be applied, so construction here stays exception-free for
    // ALL app traffic and only real connection attempts fail closed.
    ProxyService.configureClient(client, config);
    return client;
  }
}
