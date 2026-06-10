import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/conversation.dart';
import '../../providers/stage_room_provider.dart';
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<StageRoomProvider>().join(widget.conversation.id);
    });
  }

  String _nameFor(String userId) {
    final m = widget.conversation.members
        .where((m) => m.userId == userId)
        .firstOrNull;
    return m?.user?.displayName ?? m?.user?.username ?? 'Member';
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
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
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
                  ],
                ),
              ),
            )
          : null,
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
            Text(
              'Host',
              style: TextStyle(fontSize: 10, color: scheme.primary),
            ),
        ],
      ),
    );
  }
}
