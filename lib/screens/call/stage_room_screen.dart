import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/conversation.dart';
import '../../providers/stage_room_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';

/// Voice Stage Room: host + speakers on stage, a listen-only audience, and a
/// raise-hand queue the host can promote from (Batch 7.1).
class StageRoomScreen extends StatefulWidget {
  final Conversation conversation;
  const StageRoomScreen({super.key, required this.conversation});

  @override
  State<StageRoomScreen> createState() => _StageRoomScreenState();
}

class _StageRoomScreenState extends State<StageRoomScreen> {
  StreamSubscription<StageSuperchat>? _superchatSub;
  final List<StageSuperchat> _bannerQueue = [];
  StageSuperchat? _activeBanner;
  Timer? _bannerTimer;

  @override
  void initState() {
    super.initState();
    _superchatSub = context
        .read<StageRoomProvider>()
        .superchatAnnouncements
        .listen(_enqueueBanner);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<StageRoomProvider>().join(widget.conversation.id);
    });
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _superchatSub?.cancel();
    super.dispose();
  }

  void _enqueueBanner(StageSuperchat sc) {
    _bannerQueue.add(sc);
    if (_activeBanner == null) _advanceBanner();
  }

  void _advanceBanner() {
    _bannerTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _activeBanner = _bannerQueue.isEmpty ? null : _bannerQueue.removeAt(0);
    });
    if (_activeBanner != null) {
      _bannerTimer = Timer(const Duration(seconds: 8), _advanceBanner);
    }
  }

  String _nameFor(String userId) {
    final m = widget.conversation.members
        .where((m) => m.userId == userId)
        .firstOrNull;
    return m?.user?.displayName ?? m?.user?.username ?? 'Member';
  }

  /// Compose-and-pay sheet. Hidden for the host (the server rejects
  /// self-super-chats anyway — the money would go to themselves).
  Future<void> _showSuperchatSheet() async {
    final api = context.read<ApiService>();
    var providers = <String>['btc', 'xmr'];
    try {
      final status = await api.getBillingStatus();
      if (status['enabled'] != true) {
        if (mounted) {
          showAppToast(
            context,
            'Payments are not enabled on this server',
            isError: true,
          );
        }
        return;
      }
      final enabled = ((status['providers'] as List?) ?? const [])
          .whereType<String>()
          .where((p) => p == 'btc' || p == 'xmr')
          .toList();
      if (enabled.isNotEmpty) providers = enabled;
    } catch (_) {}
    if (!mounted) return;

    var provider = providers.first;
    var submitting = false;
    final amountCtrl = TextEditingController();
    final messageCtrl = TextEditingController();
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (sheetCtx) => StatefulBuilder(
          builder: (sheetCtx, setSheet) {
            Future<void> submit() async {
              if (submitting) return;
              final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
              if (amount <= 0) {
                showAppToast(context, 'Enter an amount', isError: true);
                return;
              }
              setSheet(() => submitting = true);
              try {
                await context.read<StageRoomProvider>().sendSuperchat(
                  provider: provider,
                  amount: amount,
                  message: messageCtrl.text.trim(),
                );
                if (sheetCtx.mounted) Navigator.pop(sheetCtx);
              } catch (e) {
                if (mounted) showAppToast(context, e.toString(), isError: true);
              } finally {
                if (sheetCtx.mounted) setSheet(() => submitting = false);
              }
            }

            return GlassBottomSheetFrame(
              padding: EdgeInsets.fromLTRB(
                12,
                0,
                12,
                14 + MediaQuery.viewInsetsOf(sheetCtx).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const GlassSheetGrabber(),
                  GlassSheetHeader(
                    icon: Icons.campaign_rounded,
                    title: 'Send a super-chat',
                    subtitle:
                        'Pays the host from your app wallet. Your name shows on the stage.',
                    onClose: () => Navigator.pop(sheetCtx),
                  ),
                  GlassSegmentedControl(
                    segments: [for (final p in providers) p.toUpperCase()],
                    selectedIndex: providers
                        .indexOf(provider)
                        .clamp(0, providers.length - 1),
                    onSegmentSelected: (i) =>
                        setSheet(() => provider = providers[i]),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: amountCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Amount (${provider.toUpperCase()})',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: messageCtrl,
                    maxLength: 200,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Message (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: submitting ? null : submit,
                    icon: const Icon(Icons.campaign_rounded),
                    label: Text(submitting ? 'Sending…' : 'Send super-chat'),
                  ),
                ],
              ),
            );
          },
        ),
      );
    } finally {
      amountCtrl.dispose();
      messageCtrl.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final stage = context.watch<StageRoomProvider>();
    final scheme = Theme.of(context).colorScheme;
    final onStage = <String>[
      if (stage.hostId != null) stage.hostId!,
      ...stage.speakerIds.where((s) => s != stage.hostId),
    ];

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: Text(widget.conversation.displayName('')),
        actions: [
          IconButton(
            tooltip: 'Leave',
            icon: const Icon(Icons.logout_rounded),
            onPressed: () async {
              await context.read<StageRoomProvider>().leave();
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: stage.connecting && !stage.isActive
          ? const Center(child: GlassProgressIndicator.circular())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
                16,
                16,
              ),
              children: [
                if (_activeBanner != null)
                  _SuperchatBanner(superchat: _activeBanner!),
                if (stage.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      stage.error!,
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                Text(
                  'On stage',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    for (final id in onStage)
                      _StageAvatar(
                        name: _nameFor(id),
                        isHost: id == stage.hostId,
                        onTap: stage.isHost && id != stage.hostId
                            ? () => stage.removeSpeaker(id)
                            : null,
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                if (stage.raisedHands.isNotEmpty) ...[
                  Text(
                    'Raised hands (${stage.raisedHands.length})',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final id in stage.raisedHands)
                    GlassListTile(
                      leading: const Icon(Icons.front_hand_rounded),
                      title: Text(_nameFor(id)),
                      trailing: stage.isHost
                          ? GlassButtonWidget(
                              onPressed: () => stage.inviteSpeaker(id),
                              child: const Text('Invite'),
                            )
                          : null,
                    ),
                  const SizedBox(height: 24),
                ],
                if (stage.superchats.isNotEmpty) ...[
                  Text(
                    'Super-chats',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final sc in stage.superchats.take(5))
                    GlassListTile(
                      leading: const Icon(Icons.campaign_rounded),
                      title: Text(
                        '${sc.name} · ${sc.amount} ${sc.provider.toUpperCase()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: sc.message.isEmpty ? null : Text(sc.message),
                    ),
                  const SizedBox(height: 24),
                ],
                Text(
                  '${stage.listenerCount} listening',
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
      bottomNavigationBar: stage.isActive
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (stage.canSpeak)
                      GlassButtonWidget.icon(
                        icon: Icon(
                          stage.micEnabled ? Icons.mic : Icons.mic_off,
                        ),
                        label: Text(stage.micEnabled ? 'Mute' : 'Unmute'),
                        onPressed: stage.toggleMic,
                      )
                    else ...[
                      GlassButtonWidget.icon(
                        icon: const Icon(Icons.front_hand_outlined),
                        label: const Text('Raise hand'),
                        onPressed: stage.raiseHand,
                      ),
                      const SizedBox(width: 12),
                      GlassButtonWidget.icon(
                        icon: const Icon(Icons.do_not_disturb_on_outlined),
                        label: const Text('Lower'),
                        onPressed: stage.lowerHand,
                      ),
                    ],
                    if (!stage.isHost) ...[
                      const SizedBox(width: 12),
                      GlassButtonWidget.icon(
                        icon: const Icon(Icons.campaign_rounded),
                        label: const Text('Super-chat'),
                        onPressed: _showSuperchatSheet,
                      ),
                    ],
                  ],
                ),
              ),
            )
          : null,
    );
  }
}

/// Transient highlight for a freshly-arrived super-chat (the host reads these
/// out). Opaque accent card — the screen body isn't a glass surface.
class _SuperchatBanner extends StatelessWidget {
  final StageSuperchat superchat;
  const _SuperchatBanner({required this.superchat});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            scheme.tertiaryContainer,
            scheme.tertiaryContainer.withValues(alpha: 0.7),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.tertiary.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.campaign_rounded, color: scheme.tertiary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${superchat.name} · ${superchat.amount} ${superchat.provider.toUpperCase()}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: scheme.onTertiaryContainer,
                  ),
                ),
              ),
            ],
          ),
          if (superchat.message.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              superchat.message,
              style: TextStyle(color: scheme.onTertiaryContainer),
            ),
          ],
        ],
      ),
    );
  }
}

class _StageAvatar extends StatelessWidget {
  final String name;
  final bool isHost;
  final VoidCallback? onTap;
  const _StageAvatar({required this.name, required this.isHost, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 30,
            backgroundColor: scheme.primary.withValues(alpha: 0.18),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: 72,
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          if (isHost)
            Text('Host', style: TextStyle(fontSize: 10, color: scheme.primary)),
        ],
      ),
    );
  }
}
