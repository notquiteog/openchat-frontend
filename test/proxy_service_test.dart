import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/proxy_service.dart';

/// #23 — the proxy must fail closed. The historical leak: configureClient bailed
/// with a bare `return` when an active SOCKS/Tor host was not a literal IP,
/// leaving a fully unproxied HttpClient that sent traffic direct over the real
/// IP. The fix installs a deny-all connectionFactory so every connection fails
/// at connect time instead of silently going direct.
void main() {
  group('ProxyConfig json round-trip', () {
    test('fromJson without fail_closed defaults to true (fail-closed)', () {
      final cfg = ProxyConfig.fromJson(const {
        'mode': 'tor',
        'host': '127.0.0.1',
        'port': 9050,
      });
      expect(
        cfg.failClosed,
        isTrue,
        reason:
            'a config stored before the field existed must upgrade to '
            'fail-closed, not fail-open',
      );
    });

    test('toJson includes fail_closed', () {
      expect(
        const ProxyConfig(mode: ProxyMode.socks5).toJson()['fail_closed'],
        isTrue,
      );
    });

    test('round-trip preserves failClosed for both values', () {
      for (final v in [true, false]) {
        final cfg = ProxyConfig(mode: ProxyMode.socks5, failClosed: v);
        final back = ProxyConfig.fromJson(cfg.toJson());
        expect(back.failClosed, v);
      }
    });
  });

  group('configureClient deny-all (fail-closed)', () {
    test('tor/socks5 with a non-literal host refuses connections instead of '
        'going direct', () async {
      for (final mode in [ProxyMode.tor, ProxyMode.socks5]) {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        ProxyService.configureClient(
          client,
          ProxyConfig(mode: mode, host: 'tor.example.com', port: 9050),
        );

        await expectLater(
          client.getUrl(Uri.parse('http://example.invalid/')),
          throwsA(
            predicate(
              (e) => e.toString().contains('traffic blocked'),
              'a deny-all SocketException',
            ),
          ),
          reason:
              '$mode with a non-literal host must fail closed, never reach '
              'the network directly',
        );
      }
    });

    test(
      'mode=off leaves the client untouched (direct is correct only off)',
      () {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        // Should not throw, and should not install any proxy/deny-all behavior.
        ProxyService.configureClient(client, const ProxyConfig());
      },
    );

    test(
      'tor with a literal IP host does not install the deny-all factory',
      () async {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        ProxyService.configureClient(
          client,
          const ProxyConfig(mode: ProxyMode.tor, host: '127.0.0.1', port: 9050),
        );

        // The SOCKS factory is assigned (not the deny-all one): a connection to a
        // dead local port fails with a connect error that is NOT our deny-all
        // marker. If the deny-all factory had been installed we'd see
        // 'traffic blocked' instead.
        await expectLater(
          client.getUrl(Uri.parse('http://example.invalid/')),
          throwsA(
            predicate(
              (e) => !e.toString().contains('traffic blocked'),
              'a connect error that is NOT the deny-all marker',
            ),
          ),
        );
      },
    );
  });

  group('inactive invariant (null only when off)', () {
    test('an off proxy yields a null client / null websocket', () async {
      final svc = ProxyService.instance;
      // Default singleton config is off.
      expect(svc.isActive, isFalse);
      expect(svc.newHttpClient(), isNull);
      expect(
        await svc.connectWebSocket(Uri.parse('ws://example.invalid/')),
        isNull,
        reason:
            'only an off proxy returns null, letting the caller fall back '
            'to a direct websocket',
      );
    });
  });
}
