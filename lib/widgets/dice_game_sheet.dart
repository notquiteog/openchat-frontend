import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import 'glass.dart';

/// Provably-fair dice game (fun mode, Batch 8.2). A round publishes a commitment
/// hash up front; after betting the server reveals the seed and outcome, and the
/// commitment can be verified with SHA-256(seed). No stakes — real-money play is
/// gated pending legal / responsible-gaming sign-off.
Future<void> showDiceGameSheet(
  BuildContext context, {
  required String conversationId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _DiceGameSheet(conversationId: conversationId),
  );
}

class _DiceGameSheet extends StatefulWidget {
  final String conversationId;
  const _DiceGameSheet({required this.conversationId});

  @override
  State<_DiceGameSheet> createState() => _DiceGameSheetState();
}

class _DiceGameSheetState extends State<_DiceGameSheet> {
  Map<String, dynamic>? _round;
  int? _selection;
  bool _busy = false;
  String? _error;

  bool get _revealed => _round?['status'] == 'revealed';
  String get _convId => widget.conversationId;

  Future<void> _newRound() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final round = await context.read<ApiService>().createGameRound(_convId);
      setState(() {
        _round = round;
        _selection = null;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _bet(int n) async {
    final round = _round;
    if (round == null) return;
    setState(() => _busy = true);
    try {
      final updated = await context.read<ApiService>().placeGameBet(
        _convId,
        round['id'] as String,
        n,
      );
      setState(() {
        _round = updated;
        _selection = n;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reveal() async {
    final round = _round;
    if (round == null) return;
    setState(() => _busy = true);
    try {
      final updated = await context.read<ApiService>().revealGameRound(
        _convId,
        round['id'] as String,
      );
      setState(() => _round = updated);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final round = _round;
    return GlassBottomSheetFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const GlassSheetGrabber(),
          const GlassSheetHeader(
            icon: Icons.casino_rounded,
            title: 'Provably-fair dice',
            subtitle: 'Fair by design — verify the result yourself. No stakes.',
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
          if (round == null)
            GlassButtonWidget(
              onPressed: _busy ? null : _newRound,
              child: const Text('Start a round'),
            )
          else ...[
            _CommitRow(
              label: 'Commitment',
              value: round['server_seed_hash'] as String? ?? '',
            ),
            const SizedBox(height: 12),
            if (!_revealed) ...[
              const Text('Pick a number (1–6):'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (var n = 1; n <= 6; n++)
                    ChoiceChip(
                      label: Text('$n'),
                      selected: _selection == n,
                      onSelected: _busy ? null : (_) => _bet(n),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              GlassButtonWidget(
                onPressed: _busy || _selection == null ? null : _reveal,
                child: const Text('Reveal outcome'),
              ),
            ] else ...[
              Center(
                child: Column(
                  children: [
                    Text(
                      '🎲 ${round['outcome']}',
                      style: const TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      _selection == round['outcome']
                          ? 'You won!'
                          : 'Better luck next time',
                      style: TextStyle(color: scheme.primary),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              _CommitRow(
                label: 'Revealed seed',
                value: round['server_seed'] as String? ?? '',
              ),
              const SizedBox(height: 6),
              Text(
                'Verify: SHA-256(seed) must equal the commitment above.',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 12),
              GlassButtonWidget(
                onPressed: _busy ? null : _newRound,
                child: const Text('Play again'),
              ),
            ],
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _CommitRow extends StatelessWidget {
  final String label;
  final String value;
  const _CommitRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: scheme.primary,
          ),
        ),
        const SizedBox(height: 2),
        SelectableText(
          value,
          maxLines: 2,
          style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
        ),
      ],
    );
  }
}
