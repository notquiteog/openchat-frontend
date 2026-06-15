import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/chat_provider.dart';
import '../services/api_service.dart';
import 'glass.dart';

/// Shared "New game" launcher used from both the chat screen and the channel
/// screen. Games are skill-based (stop-the-marker timing): dice plays 5
/// stops, darts 3 throws; creating one posts an invite card other members
/// join from, everyone readies up, and the highest total score wins.
///
/// The real-money section only appears when the server reports
/// games_real_money (GAMES_REAL_MONEY env) — and is additionally premium-free:
/// staking is a wallet feature, not a subscription one.
Future<void> showGameLauncher(
  BuildContext context, {
  required String convID,
  required bool isChannel,
  String? initialGameType,
  String? initialProvider,
  double? initialStake,
}) async {
  final chat = context.read<ChatProvider>();
  final api = context.read<ApiService>();
  final anteCtrl = TextEditingController();
  final isRematch =
      initialGameType != null ||
      initialProvider != null ||
      initialStake != null;
  String selected = initialGameType == '🎯' ? '🎯' : '🎲';
  bool realMoney = false;
  String provider = 'btc';
  bool realMoneyAllowed = false;
  List<String> cryptoProviders = const [];

  // Server-side opt-in (GAMES_REAL_MONEY): fetched best-effort before the
  // sheet opens; on failure the stake section simply stays hidden.
  try {
    final status = await api.getBillingStatus();
    realMoneyAllowed = status['games_real_money'] == true;
    cryptoProviders = ((status['providers'] as List?) ?? const [])
        .whereType<String>()
        .where((p) => p == 'btc' || p == 'xmr')
        .toList();
    if (cryptoProviders.isNotEmpty) provider = cryptoProviders.first;
    realMoneyAllowed = realMoneyAllowed && cryptoProviders.isNotEmpty;
  } catch (_) {}
  final normalizedProvider = initialProvider?.toLowerCase();
  if (realMoneyAllowed &&
      normalizedProvider != null &&
      normalizedProvider != 'fun' &&
      cryptoProviders.contains(normalizedProvider) &&
      initialStake != null &&
      initialStake > 0) {
    provider = normalizedProvider;
    realMoney = true;
    anteCtrl.text = _formatInitialStake(initialStake);
  }
  if (!context.mounted) {
    anteCtrl.dispose();
    return;
  }

  Future<void> start(BuildContext ctx) async {
    final ante = realMoney ? double.tryParse(anteCtrl.text.trim()) : null;
    if (realMoney && (ante == null || ante <= 0)) {
      showAppToast(ctx, 'Enter a positive ante amount.', isError: true);
      return;
    }
    Navigator.pop(ctx);
    try {
      await chat.createGame(
        convID,
        gameType: selected,
        provider: realMoney ? provider : 'fun',
        stake: ante,
        isChannel: isChannel,
      );
    } catch (e) {
      // The sheet context was popped before the await — fall back to the
      // launcher's own context.
      if (!context.mounted) return;
      showAppToast(context, 'Could not start game: $e', isError: true);
    }
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (rootCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheet) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const GlassSheetGrabber(),
            GlassSheetHeader(
              icon: Icons.sports_esports_outlined,
              title: isRematch ? 'Rematch' : 'New game',
              subtitle: isRematch
                  ? 'Start a fresh lobby with the previous game settings.'
                  : 'Skill games — stop the marker dead-center, best total wins.',
            ),
            Row(
              children: [
                Expanded(
                  child: _GameTile(
                    emoji: '🎲',
                    name: 'Dice',
                    detail: '5 stops',
                    selected: selected == '🎲',
                    onTap: () => setSheet(() => selected = '🎲'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _GameTile(
                    emoji: '🎯',
                    name: 'Darts',
                    detail: '3 throws',
                    selected: selected == '🎯',
                    onTap: () => setSheet(() => selected = '🎯'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (realMoneyAllowed) ...[
              GlassListTile(
                title: const Text('Play for real money'),
                subtitle: const Text(
                  'Each player antes from their wallet; the best score takes the pot',
                ),
                trailing: GlassSwitch(
                  value: realMoney,
                  onChanged: (v) => setSheet(() => realMoney = v),
                  activeColor: Theme.of(sheetCtx).colorScheme.primary,
                  enableHaptics: true,
                ),
                onTap: () => setSheet(() => realMoney = !realMoney),
              ),
              if (realMoney) ...[
                if (cryptoProviders.length > 1)
                  Row(
                    children: [
                      const Text('Currency:'),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GlassSegmentedControl(
                          segments: const ['BTC', 'XMR'],
                          selectedIndex: provider == 'xmr' ? 1 : 0,
                          onSegmentSelected: (i) =>
                              setSheet(() => provider = i == 1 ? 'xmr' : 'btc'),
                        ),
                      ),
                    ],
                  ),
                TextField(
                  controller: anteCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Ante per player',
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ],
            FilledButton.icon(
              icon: const Icon(Icons.send_rounded),
              label: Text(
                realMoney ? 'Send real-money invite' : 'Send game invite',
              ),
              onPressed: () => start(sheetCtx),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    ),
  );
  anteCtrl.dispose();
}

String _formatInitialStake(double stake) {
  if (stake == stake.roundToDouble()) return stake.toStringAsFixed(0);
  return stake.toString();
}

class _GameTile extends StatelessWidget {
  const _GameTile({
    required this.emoji,
    required this.name,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final String emoji;
  final String name;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: selected
              ? scheme.primary.withValues(alpha: 0.16)
              : scheme.onSurface.withValues(alpha: 0.05),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: 0.55)
                : Colors.transparent,
            width: 1.4,
          ),
        ),
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 34)),
            const SizedBox(height: 6),
            Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(
              detail,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
