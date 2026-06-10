import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/chat_provider.dart';
import 'glass.dart';

/// Shared "New game" launcher used from both the chat screen and the channel
/// screen so there is one provably-fair game-creation flow. [convID] is the
/// conversation or channel id; set [isChannel] so the resulting API calls route
/// to the /channels surface.
Future<void> showGameLauncher(
  BuildContext context, {
  required String convID,
  required bool isChannel,
}) async {
  const games = ['🎲', '🎯', '🏀', '⚽', '🎳', '🎰', '🪙'];
  final chat = context.read<ChatProvider>();
  final anteCtrl = TextEditingController();
  String selected = '🎲';
  bool realMoney = false;
  String provider = 'btc';

  Future<void> start(BuildContext ctx, String mode) async {
    final useReal = mode == 'betting' && realMoney;
    final ante = useReal ? double.tryParse(anteCtrl.text.trim()) : null;
    if (useReal && (ante == null || ante <= 0)) {
      showAppToast(ctx, 'Enter a positive ante amount.', isError: true);
      return;
    }
    Navigator.pop(ctx);
    try {
      await chat.createGame(
        convID,
        gameType: selected,
        mode: mode,
        provider: useReal ? provider : 'fun',
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
            const GlassSheetHeader(
              icon: Icons.casino_outlined,
              title: 'New game',
              subtitle: 'Provably fair — verify every result yourself.',
            ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 6,
              children: [
                for (final g in games)
                  GlassChip(
                    label: g,
                    selected: selected == g,
                    onTap: () => setSheet(() => selected = g),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            GlassListTile(
              title: const Text('Play for real money'),
              subtitle: const Text(
                'Players ante from their wallet; winners split the pot',
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
                decoration: const InputDecoration(labelText: 'Ante per player'),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                if (!realMoney) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.bolt_outlined),
                      label: const Text('Quick roll'),
                      onPressed: () => start(sheetCtx, 'quick'),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.verified_outlined),
                    label: Text(
                      realMoney ? 'Start real-money game' : 'Betting game',
                    ),
                    onPressed: () => start(sheetCtx, 'betting'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    ),
  );
  anteCtrl.dispose();
}
