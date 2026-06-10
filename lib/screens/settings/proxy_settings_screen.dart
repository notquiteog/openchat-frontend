import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/proxy_service.dart';
import '../../services/secure_storage_service.dart';
import '../../widgets/glass.dart';

/// Configures HTTP / SOCKS5 / Tor routing for the app's traffic. REST, image
/// loads, and link previews route through an [HttpOverrides]; WebSockets route
/// per-connection. WebRTC/LiveKit call media (UDP) and FCM push are not proxied.
class ProxySettingsScreen extends StatefulWidget {
  const ProxySettingsScreen({super.key});

  @override
  State<ProxySettingsScreen> createState() => _ProxySettingsScreenState();
}

class _ProxySettingsScreenState extends State<ProxySettingsScreen> {
  static const _modes = [
    ProxyMode.off,
    ProxyMode.http,
    ProxyMode.socks5,
    ProxyMode.tor,
  ];

  late ProxyMode _mode;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  bool _blockCalls = true;
  String? _testResult;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final cfg = ProxyService.instance.config;
    _mode = cfg.mode;
    _hostCtrl = TextEditingController(text: cfg.host);
    _portCtrl = TextEditingController(text: cfg.port > 0 ? '${cfg.port}' : '');
    _blockCalls = cfg.blockCallsWhenActive;
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  ProxyConfig _currentConfig() => ProxyConfig(
    mode: _mode,
    host: _hostCtrl.text.trim().isEmpty ? '127.0.0.1' : _hostCtrl.text.trim(),
    port: int.tryParse(_portCtrl.text.trim()) ?? (_mode == ProxyMode.tor ? 9050 : 1080),
    blockCallsWhenActive: _blockCalls,
  );

  Future<void> _save() async {
    final storage = context.read<SecureStorageService>();
    await ProxyService.instance.save(storage, _currentConfig());
    if (mounted) setState(() {});
  }

  void _onModeSelected(int index) {
    setState(() {
      _mode = _modes[index];
      _testResult = null;
      // Tor: pre-fill the conventional local SOCKS endpoint.
      if (_mode == ProxyMode.tor) {
        if (_hostCtrl.text.trim().isEmpty) _hostCtrl.text = '127.0.0.1';
        if (_portCtrl.text.trim().isEmpty) _portCtrl.text = '9050';
      }
    });
    unawaited(_save());
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final config = _currentConfig();
    String result;
    try {
      final client = HttpClient();
      ProxyService.configureClient(client, config);
      client.connectionTimeout = const Duration(seconds: 12);
      final req = await client
          .getUrl(Uri.parse('https://check.torproject.org/api/ip'))
          .timeout(const Duration(seconds: 15));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      result = resp.statusCode == 200
          ? 'Connected — proxy is reachable'
          : 'Reached proxy, server returned ${resp.statusCode}';
      client.close(force: true);
    } catch (e) {
      result = 'Failed: $e';
    }
    if (mounted) {
      setState(() {
        _testing = false;
        _testResult = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final showFields = _mode != ProxyMode.off;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Proxy & Tor')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
          16,
          16,
        ),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Routing mode',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                GlassSegmentedControl(
                  segments: [for (final m in _modes) m.label],
                  selectedIndex: _modes.indexOf(_mode),
                  onSegmentSelected: _onModeSelected,
                ),
                const SizedBox(height: 8),
                Text(
                  switch (_mode) {
                    ProxyMode.off => 'Traffic goes directly to the network.',
                    ProxyMode.http =>
                      'HTTP/HTTPS CONNECT proxy for REST, media, and sockets.',
                    ProxyMode.socks5 =>
                      'SOCKS5 proxy for REST, media, and sockets.',
                    ProxyMode.tor =>
                      'SOCKS5 via a running Tor / Orbot daemon (not bundled).',
                  },
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          if (showFields) ...[
            const SizedBox(height: 14),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Proxy address',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  GlassTextField(
                    controller: _hostCtrl,
                    placeholder: 'Host (e.g. 127.0.0.1)',
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => _save(),
                  ),
                  const SizedBox(height: 10),
                  GlassTextField(
                    controller: _portCtrl,
                    placeholder: _mode == ProxyMode.tor ? '9050' : 'Port',
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onSubmitted: (_) => _save(),
                  ),
                  if (_mode == ProxyMode.socks5 || _mode == ProxyMode.tor)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Host must be a literal IP address.',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      GlassButtonWidget(
                        onPressed: _testing
                            ? null
                            : () {
                                unawaited(_save());
                                unawaited(_testConnection());
                              },
                        child: _testing
                            ? const GlassProgressIndicator.circular(
                                size: 16,
                                strokeWidth: 2,
                              )
                            : const Text('Test connection'),
                      ),
                      const SizedBox(width: 12),
                      if (_testResult != null)
                        Expanded(
                          child: Text(
                            _testResult!,
                            style: TextStyle(
                              fontSize: 12,
                              color: _testResult!.startsWith('Connected')
                                  ? Colors.green
                                  : scheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            GlassCard(
              padding: EdgeInsets.zero,
              child: GlassListTile(
                leading: const Icon(Icons.call_end_outlined),
                title: const Text('Disable calls while proxy is on'),
                subtitle: const Text(
                  'Call media is UDP and cannot be proxied — recommended on',
                ),
                trailing: GlassSwitch(
                  value: _blockCalls,
                  onChanged: (v) {
                    setState(() => _blockCalls = v);
                    unawaited(_save());
                  },
                ),
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Note: voice/video call media (WebRTC/LiveKit) and push '
                'notifications (FCM) are not routed through the proxy.',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
