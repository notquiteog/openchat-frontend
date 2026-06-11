import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/chat_provider.dart';
import '../../services/api_service.dart';
import '../../services/secure_storage_service.dart';
import '../../services/social_recovery_service.dart';
import '../../widgets/glass.dart';

/// Requester side of a Shamir social-recovery ceremony (normally run on a
/// keyless device after a password sign-in).
///
/// Opens a ceremony via [SocialRecoveryService.startCeremony], displays the
/// verification code LARGE (guardians must hear it from the user out-of-band
/// before approving — the code derives from the ephemeral key, so a server
/// substituting its own key changes it), and live-updates share progress via
/// [ChatProvider.recoveryEvents] plus a poll fallback. The [RecoveryCeremony]
/// — including the ephemeral private key — lives in screen state ONLY and is
/// never persisted: losing it just means starting a new ceremony.
class SocialRecoveryScreen extends StatefulWidget {
  const SocialRecoveryScreen({
    super.key,
    this.service,
    this.initialCeremony,
    this.pollInterval = const Duration(seconds: 10),
  });

  /// Test seam — defaults to a real service over the ambient storage.
  final SocialRecoveryService? service;

  /// Test seam: skips [SocialRecoveryService.startCeremony], which mints an
  /// ephemeral PGP keypair on the native bridge (unavailable in widget tests).
  final RecoveryCeremony? initialCeremony;

  /// Poll fallback period for when the WS share event is missed.
  final Duration pollInterval;

  @override
  State<SocialRecoveryScreen> createState() => _SocialRecoveryScreenState();
}

class _SocialRecoveryScreenState extends State<SocialRecoveryScreen> {
  late final SocialRecoveryService _service;
  late final ApiService _api;

  // Ephemeral by design — never persisted (see class doc).
  RecoveryCeremony? _ceremony;
  bool _starting = true;
  bool _done = false;
  bool _checking = false;
  bool _cancelling = false;
  String? _error;
  int _sharesReceived = 0;
  int _threshold = 0;
  Timer? _pollTimer;
  StreamSubscription<Map<String, dynamic>>? _eventsSub;

  @override
  void initState() {
    super.initState();
    _api = context.read<ApiService>();
    _service =
        widget.service ??
        SocialRecoveryService(storage: context.read<SecureStorageService>());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _eventsSub = context.read<ChatProvider>().recoveryEvents.listen(
        _onRecoveryEvent,
      );
      unawaited(_start());
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _eventsSub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final ceremony =
          widget.initialCeremony ?? await _service.startCeremony(api: _api);
      if (!mounted) return;
      setState(() {
        _ceremony = ceremony;
        _starting = false;
      });
      await _refresh();
      _pollTimer = Timer.periodic(
        widget.pollInterval,
        (_) => unawaited(_refresh()),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = 'Could not start a recovery ceremony: $e';
      });
    }
  }

  void _onRecoveryEvent(Map<String, dynamic> event) {
    if (event['kind'] != 'share') return;
    final ceremony = _ceremony;
    if (ceremony == null || _done) return;
    final requestId = event['request_id']?.toString() ?? '';
    if (requestId.isNotEmpty && requestId != ceremony.requestId) return;
    final submitted = (event['shares_submitted'] as num?)?.toInt();
    if (submitted != null && submitted > _sharesReceived && mounted) {
      setState(() => _sharesReceived = submitted);
    }
    unawaited(_refresh());
  }

  /// Pulls ceremony state (threshold + collected shares) and attempts to
  /// finish. [SocialRecoveryService.tryFinishCeremony] is cheap below the
  /// threshold (returns false before any decryption), so calling it on every
  /// event/poll is fine.
  Future<void> _refresh() async {
    final ceremony = _ceremony;
    if (ceremony == null || _done || _checking || _cancelling || !mounted) {
      return;
    }
    _checking = true;
    try {
      final state = await _api.getRecoveryRequest(ceremony.requestId);
      final threshold = (state['threshold'] as num?)?.toInt() ?? 0;
      final received = ((state['encrypted_shares'] as List?) ?? const [])
          .length;
      if (mounted) {
        setState(() {
          if (threshold > 0) _threshold = threshold;
          if (received > _sharesReceived) _sharesReceived = received;
          _error = null;
        });
      }
      final finished = await _service.tryFinishCeremony(
        api: _api,
        ceremony: ceremony,
      );
      if (finished && mounted) {
        _pollTimer?.cancel();
        setState(() => _done = true);
        _promptRestart();
      }
    } catch (e) {
      // Malformed blob, failed reconstruction, network — surface it but keep
      // the ceremony alive (more shares or a retry may still succeed).
      if (mounted) setState(() => _error = e.toString());
    } finally {
      _checking = false;
    }
  }

  void _promptRestart() {
    GlassDialog.show<void>(
      context: context,
      title: 'Identity restored',
      message:
          'Your keys and settings were rebuilt from your guardians\' shares. '
          'Restart OpenChat to finish loading the recovered identity.',
      actions: [
        GlassDialogAction(
          label: 'OK',
          isPrimary: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  Future<void> _cancel() async {
    final ceremony = _ceremony;
    final navigator = Navigator.of(context);
    setState(() => _cancelling = true);
    _pollTimer?.cancel();
    if (ceremony != null && !_done) {
      try {
        await _api.completeRecoveryRequest(
          ceremony.requestId,
          status: 'cancelled',
        );
      } catch (_) {
        // Best effort — the server expires abandoned ceremonies anyway.
      }
    }
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ceremony = _ceremony;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Recover with guardians')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
          16,
          MediaQuery.paddingOf(context).bottom + 32,
        ),
        children: [
          if (_starting)
            const GlassCard(
              child: Row(
                children: [
                  GlassProgressIndicator.circular(size: 20, strokeWidth: 2),
                  SizedBox(width: 12),
                  Expanded(child: Text('Opening a recovery ceremony…')),
                ],
              ),
            )
          else if (_done)
            GlassCard(
              tint: Colors.green.withValues(alpha: 0.08),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.verified_rounded, color: Colors.green),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Identity restored — restart the app to finish',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your keys, trust pins, and settings were rebuilt from '
                    'your guardians\' shares. Close and reopen OpenChat to '
                    'load the recovered identity.',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurface.withValues(alpha: 0.62),
                    ),
                  ),
                ],
              ),
            )
          else if (ceremony != null) ...[
            GlassCard(
              child: Text(
                'Ask each guardian to open Trust Center → You Guard on their '
                'device and approve your request. They will only see your '
                'share after verifying the code below with you directly.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: scheme.onSurface.withValues(alpha: 0.72),
                ),
              ),
            ),
            const SizedBox(height: 16),
            GlassCard(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text(
                    'READ THIS CODE TO YOUR GUARDIANS OVER A CALL',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    ceremony.verificationCode,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'A guardian must hear this code from you — never approve '
                    'from a text message alone.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _threshold > 0
                        ? '$_sharesReceived of $_threshold shares received'
                        : 'Waiting for ceremony status…',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      minHeight: 6,
                      value: _threshold > 0
                          ? (_sharesReceived / _threshold).clamp(0.0, 1.0)
                          : 0,
                      backgroundColor: scheme.onSurface.withValues(
                        alpha: 0.10,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Recovery completes automatically once enough guardians '
                    'have approved.',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            GlassCard(
              tint: scheme.error.withValues(alpha: 0.08),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded, color: scheme.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(fontSize: 13, color: scheme.error),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (!_starting && !_done && ceremony != null) ...[
            const SizedBox(height: 24),
            Center(
              child: GlassButtonWidget(
                onPressed: _cancelling ? null : _cancel,
                child: const Text('Cancel ceremony'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
