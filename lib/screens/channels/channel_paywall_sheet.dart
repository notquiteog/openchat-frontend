import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../widgets/glass.dart';

/// Shows the paid-access paywall for a gated channel. Returns true if the caller
/// became subscribed (instant wallet payment); on-chain payments resolve later
/// once the deposit confirms, so they return false here.
Future<bool> showChannelPaywall(
  BuildContext context, {
  required String channelId,
  required String channelName,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ChannelPaywallSheet(
      channelId: channelId,
      channelName: channelName,
    ),
  );
  return result ?? false;
}

class _ChannelPaywallSheet extends StatefulWidget {
  final String channelId;
  final String channelName;
  const _ChannelPaywallSheet({
    required this.channelId,
    required this.channelName,
  });

  @override
  State<_ChannelPaywallSheet> createState() => _ChannelPaywallSheetState();
}

class _ChannelPaywallSheetState extends State<_ChannelPaywallSheet> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _plans = const [];
  bool _busy = false;
  Map<String, dynamic>? _deposit; // set after an on-chain "pay" tap

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await context.read<ApiService>().getChannelSubscription(
        widget.channelId,
      );
      if (!mounted) return;
      setState(() {
        _plans = ((data['plans'] as List?) ?? const [])
            .cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _pay(String provider, String source) async {
    setState(() => _busy = true);
    try {
      final data = await context.read<ApiService>().subscribePaidChannel(
        widget.channelId,
        provider: provider,
        source: source,
      );
      if (!mounted) return;
      if (source == 'wallet') {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _deposit = data['deposit'] as Map<String, dynamic>?;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Payment failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassBottomSheetFrame(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const GlassSheetGrabber(),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.workspace_premium_outlined,
                  color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Subscribe to ${widget.channelName}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: GlassProgressIndicator.circular()),
            )
          else if (_error != null)
            Text('Could not load plans: $_error',
                style: TextStyle(color: theme.colorScheme.error))
          else if (_deposit != null)
            _depositInstructions(theme)
          else if (_plans.isEmpty)
            const Text('This channel has no subscription plan.')
          else
            ..._plans.map((p) => _planTile(theme, p)),
        ],
      ),
    );
  }

  Widget _planTile(ThemeData theme, Map<String, dynamic> plan) {
    final provider = (plan['provider'] as String? ?? '').toUpperCase();
    final price = (plan['price'] as num?)?.toString() ?? '0';
    final days = plan['period_days'] as int? ?? 30;
    // Opaque card — this tile lives inside an already-glass sheet; nesting
    // another glass surface stacks a second backdrop pass for no visual gain.
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$price $provider · $days days',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GlassButtonWidget(
                  onPressed: _busy
                      ? null
                      : () => _pay(plan['provider'] as String, 'wallet'),
                  child: const Text('Pay from wallet'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GlassButtonWidget(
                  onPressed: _busy
                      ? null
                      : () => _pay(plan['provider'] as String, 'external'),
                  child: const Text('Pay on-chain'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _depositInstructions(ThemeData theme) {
    final dep = _deposit!;
    final address = dep['crypto_address'] as String? ?? '';
    final amount = (dep['expected_amount'] as num?)?.toString() ?? '';
    final provider = (dep['provider'] as String? ?? '').toUpperCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Send $amount $provider to:',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  address,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: address));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Address copied')),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Access unlocks automatically once the payment confirms on-chain.',
          style: TextStyle(
            fontSize: 13,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 16),
        GlassButtonWidget(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
