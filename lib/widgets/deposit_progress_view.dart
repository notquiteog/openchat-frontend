import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/chat_provider.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';

/// Live on-chain confirmation progress for one deposit: a ring filling from
/// `confirmations / required_confirmations` plus a status line.
///
/// Primary feed is the user-scoped `deposit_progress` WS event; while the
/// socket is down it falls back to polling the deposit every 20s (matching the
/// server's poller cadence), so the ring keeps moving on flaky connections.
class DepositProgressView extends StatefulWidget {
  final String depositId;
  final int initialConfirmations;
  final int requiredConfirmations;
  final String initialStatus;

  /// Invoked once when the deposit reaches `confirmed`.
  final VoidCallback? onConfirmed;

  /// Test seam: progress events normally come from ChatProvider (whose
  /// constructor is too heavy for widget tests — it opens sockets).
  @visibleForTesting
  final Stream<Map<String, dynamic>>? progressStream;

  const DepositProgressView({
    super.key,
    required this.depositId,
    this.initialConfirmations = 0,
    this.requiredConfirmations = 0,
    this.initialStatus = 'nothing_sent',
    this.onConfirmed,
    this.progressStream,
  });

  @override
  State<DepositProgressView> createState() => _DepositProgressViewState();
}

class _DepositProgressViewState extends State<DepositProgressView> {
  late int _confirmations = widget.initialConfirmations;
  late int _required = widget.requiredConfirmations;
  late String _status = widget.initialStatus;
  bool _confirmedNotified = false;

  StreamSubscription<Map<String, dynamic>>? _wsSub;
  Timer? _pollTimer;
  late final WebSocketService _ws;

  @override
  void initState() {
    super.initState();
    final stream =
        widget.progressStream ?? context.read<ChatProvider>().depositProgress;
    _wsSub = stream.listen(_onWsEvent);
    _ws = context.read<WebSocketService>();
    _ws.addListener(_syncPolling);
    _syncPolling();
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _pollTimer?.cancel();
    _ws.removeListener(_syncPolling);
    super.dispose();
  }

  void _onWsEvent(Map<String, dynamic> data) {
    if (data['deposit_id']?.toString() != widget.depositId) return;
    _apply(
      status: data['status']?.toString(),
      confirmations: (data['confirmations'] as num?)?.toInt(),
      required: (data['required_confirmations'] as num?)?.toInt(),
    );
  }

  /// Poll only while the WebSocket is down — when it's connected the server
  /// pushes every change and polling would be wasted traffic.
  void _syncPolling() {
    if (!mounted) return;
    final connected = _ws.connectionStatus == WsConnectionStatus.connected;
    final donePolling = _status == 'confirmed' || _status == 'expired';
    if (connected || donePolling) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    _pollTimer ??= Timer.periodic(const Duration(seconds: 20), (_) async {
      try {
        final dep = await context.read<ApiService>().getPaymentDeposit(
          widget.depositId,
        );
        if (!mounted) return;
        _apply(
          status: dep['status']?.toString(),
          confirmations: (dep['confirmations'] as num?)?.toInt(),
          required: (dep['required_confirmations'] as num?)?.toInt(),
        );
      } catch (_) {}
    });
  }

  void _apply({String? status, int? confirmations, int? required}) {
    if (!mounted) return;
    setState(() {
      if (status != null && status.isNotEmpty) _status = status;
      if (confirmations != null) _confirmations = confirmations;
      if (required != null && required > 0) _required = required;
    });
    if (_status == 'confirmed' && !_confirmedNotified) {
      _confirmedNotified = true;
      widget.onConfirmed?.call();
    }
    _syncPolling();
  }

  String get _statusLabel => switch (_status) {
    'nothing_sent' => 'Waiting for your payment…',
    'unconfirmed' => 'Payment detected — waiting for the first confirmation',
    'confirming' => 'Confirming: $_confirmations of $_required',
    'confirmed' => 'Confirmed — access unlocked',
    'expired' => 'This deposit window expired',
    _ => _status,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = _status == 'confirmed';
    final expired = _status == 'expired';
    final progress = _required <= 0
        ? null
        : (_confirmations / _required).clamp(0.0, 1.0);
    final ringColor = expired
        ? scheme.error
        : confirmed
        ? Colors.green
        : scheme.primary;

    return Row(
      children: [
        SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                // Indeterminate while nothing is on-chain yet; determinate
                // ring once confirmations start counting.
                value: _status == 'nothing_sent'
                    ? null
                    : (confirmed ? 1.0 : progress ?? 0),
                strokeWidth: 4,
                color: ringColor,
                backgroundColor: scheme.onSurface.withValues(alpha: 0.10),
              ),
              if (confirmed)
                Icon(Icons.check_rounded, size: 20, color: ringColor)
              else if (expired)
                Icon(Icons.close_rounded, size: 20, color: ringColor)
              else if (_required > 0 && _status != 'nothing_sent')
                Text(
                  '$_confirmations',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            _statusLabel,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface.withValues(
                alpha: confirmed || expired ? 0.9 : 0.7,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
