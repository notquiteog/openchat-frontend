import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../providers/auth_provider.dart';
import '../providers/call_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/group_call_presence_provider.dart';
import '../providers/group_ring_provider.dart';
import '../screens/call/sfu_call_screen.dart';
import '../services/call_audio.dart';
import '../services/sfu_call_controller.dart';
import 'glass.dart';

/// Root overlay for ring-all group calls (#9). Shows an incoming-call-style
/// glass card and rings the looping tone while a [GroupRingProvider] ring is
/// active and the user isn't already busy in a call. "Join" enters the SFU
/// room exactly like accepting an escalated call; "Decline" just dismisses the
/// local ring (the call keeps going for everyone else).
class GroupRingOverlay extends StatefulWidget {
  const GroupRingOverlay({super.key});

  @override
  State<GroupRingOverlay> createState() => _GroupRingOverlayState();
}

class _GroupRingOverlayState extends State<GroupRingOverlay> {
  final CallAudio _audio = CallAudio();
  bool _toneOn = false;
  bool _joining = false;

  void _setTone(bool on) {
    if (on == _toneOn) return;
    _toneOn = on;
    if (on) {
      unawaited(_audio.update(incoming: true));
    } else {
      unawaited(_audio.stop());
    }
  }

  @override
  void dispose() {
    _audio.dispose();
    super.dispose();
  }

  // The user is already occupied — in an SFU room or a 1:1 call (active or
  // ringing). Don't ring over the top of it.
  bool _busy(BuildContext context) {
    if (context.watch<SfuCallController>().isActive) return true;
    final call = context.watch<CallProvider>();
    return call.isInCall || call.incomingCall != null;
  }

  Future<void> _join(String convID, String name) async {
    if (_joining) return;
    final auth = context.read<AuthProvider>();
    final ring = context.read<GroupRingProvider>();
    if (auth.currentUser?.isPremium != true) {
      OpenChatApp.scaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(
          content: Text('Joining an SFU group call requires OpenChat Premium'),
        ),
      );
      ring.dismiss();
      return;
    }
    setState(() => _joining = true);
    final sfu = context.read<SfuCallController>();
    final call = context.read<CallProvider>();
    final chat = context.read<ChatProvider>();
    final presence = context.read<GroupCallPresenceProvider>();
    final conv = chat.conversationById(convID);
    try {
      String? e2eeKey;
      if (conv?.isEncrypted == true) {
        // The frame key was sealed to members when the call started; if this
        // device missed it (offline at start), ask a current participant.
        final participantIds =
            presence.infoFor(convID)?.participantIds ?? const <String>[];
        e2eeKey =
            call.sfuKeyFor(convID) ??
            await call.requestSfuKey(convID, fromUserIds: participantIds);
        if (e2eeKey == null) {
          OpenChatApp.scaffoldMessengerKey.currentState?.showSnackBar(
            const SnackBar(
              content: Text(
                'Could not fetch the call\'s encryption key — try again in a moment',
              ),
            ),
          );
          return;
        }
      }
      ring.dismiss();
      unawaited(
        sfu
            .join(
              conversationId: convID,
              title: name,
              isVideo: false,
              e2eeKeyB64: e2eeKey,
            )
            .catchError((Object e) {
              OpenChatApp.scaffoldMessengerKey.currentState?.showSnackBar(
                SnackBar(content: Text('Could not join the group call: $e')),
              );
            }),
      );
      OpenChatApp.navigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => const SfuCallScreen(),
        ),
      );
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ring = context.watch<GroupRingProvider>().active;
    if (ring == null || _busy(context)) {
      _setTone(false);
      return const SizedBox.shrink();
    }
    _setTone(true);

    final conv = context.read<ChatProvider>().conversationById(
      ring.conversationId,
    );
    final name = (conv?.name?.trim().isNotEmpty ?? false)
        ? conv!.name!.trim()
        : 'Group call';
    final cs = Theme.of(context).colorScheme;
    final onGlass = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black87;

    return Positioned.fill(
      child: Stack(
        children: [
          // Scrim absorbs taps so the chat underneath isn't interactable while
          // ringing (matches the 1:1 incoming-call modal).
          const ModalBarrier(color: Colors.black54, dismissible: false),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: GlassContainer(
                padding: const EdgeInsets.fromLTRB(28, 28, 28, 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.groups_rounded, size: 48, color: cs.primary),
                    const SizedBox(height: 14),
                    Text(
                      'Incoming group call',
                      style: TextStyle(
                        color: onGlass.withValues(alpha: 0.7),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: onGlass,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GlassButtonWidget.icon(
                          onPressed: _joining
                              ? null
                              : () =>
                                    context.read<GroupRingProvider>().dismiss(),
                          color: cs.error,
                          icon: const Icon(Icons.call_end_rounded),
                          label: const Text('Decline'),
                        ),
                        const SizedBox(width: 14),
                        GlassButtonWidget.icon(
                          onPressed: _joining
                              ? null
                              : () => _join(ring.conversationId, name),
                          color: const Color(0xFF34C759),
                          icon: const Icon(Icons.videocam_rounded),
                          label: Text(_joining ? 'Joining…' : 'Join'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
