import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:provider/provider.dart';

import '../../services/sfu_call_controller.dart';
import 'call_glass.dart';

/// Full-screen UI for a LiveKit SFU group call, in the same iOS-26 Liquid Glass
/// style as the P2P CallScreen (shared widgets from call_glass.dart). Reads
/// [SfuCallController] and pops itself when the call ends.
class SfuCallScreen extends StatelessWidget {
  const SfuCallScreen({super.key});

  bool get _supportsScreenShare =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    final sfu = context.watch<SfuCallController>();
    if (!sfu.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final nav = Navigator.of(context);
        if (nav.canPop()) nav.pop();
      });
      return const SizedBox.shrink();
    }

    final participants = sfu.participants;
    final width = MediaQuery.of(context).size.width;
    final desktopLayout = width >= 720;
    final compactLayout = width < 430;
    final buttonSize = compactLayout ? 52.0 : 56.0;

    final secondary = <Widget>[
      CallControlButton(
        icon: sfu.isMicEnabled ? Icons.mic : Icons.mic_off,
        label: 'Mute',
        active: !sfu.isMicEnabled,
        activeColor: callEndColor,
        size: buttonSize,
        onTap: () => sfu.toggleMic(),
      ),
      if (sfu.isVideo)
        CallControlButton(
          icon: sfu.isCameraEnabled ? Icons.videocam : Icons.videocam_off,
          label: 'Camera',
          active: !sfu.isCameraEnabled,
          activeColor: callEndColor,
          size: buttonSize,
          onTap: () => sfu.toggleCamera(),
        ),
      if (sfu.isVideo && _isMobile)
        CallControlButton(
          icon: Icons.cameraswitch_rounded,
          label: 'Flip',
          size: buttonSize,
          onTap: () => sfu.switchCamera(),
        ),
      if (_supportsScreenShare)
        CallControlButton(
          icon:
              sfu.isScreenSharing ? Icons.stop_screen_share : Icons.screen_share,
          label: 'Share',
          active: sfu.isScreenSharing,
          activeColor: callAnswerColor,
          size: buttonSize,
          onTap: () => sfu.toggleScreenShare(),
        ),
    ];

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: CallBackground(username: sfu.title ?? 'Group call'),
          ),
          SafeArea(
            child: Column(
              children: [
                _SfuHeader(
                  title: sfu.title ?? 'Group call',
                  connecting: sfu.isConnecting,
                  count: participants.length,
                ),
                Expanded(
                  child: sfu.isConnecting && participants.length <= 1
                      ? const _Connecting()
                      : _SfuGrid(
                          participants: participants,
                          isVideo: sfu.isVideo,
                        ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    desktopLayout ? 40 : 16,
                    8,
                    desktopLayout ? 40 : 16,
                    16,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: desktopLayout ? 560 : double.infinity,
                    ),
                    child: CallControlsPanel(
                      secondaryControls: secondary,
                      onHangup: () => sfu.leave(),
                      buttonSize: buttonSize,
                      desktopLayout: desktopLayout,
                      compactLayout: compactLayout,
                      endLabel: 'Leave',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SfuHeader extends StatelessWidget {
  const _SfuHeader({
    required this.title,
    required this.connecting,
    required this.count,
  });

  final String title;
  final bool connecting;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            connecting ? 'Connecting…' : '$count in call · SFU',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _Connecting extends StatelessWidget {
  const _Connecting();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Connecting…', style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}

class _SfuGrid extends StatelessWidget {
  const _SfuGrid({required this.participants, required this.isVideo});

  final List<lk.Participant> participants;
  final bool isVideo;

  @override
  Widget build(BuildContext context) {
    final n = participants.length;
    final cols = n <= 1 ? 1 : (n <= 4 ? 2 : 3);
    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        childAspectRatio: 0.82,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: n,
      itemBuilder: (_, i) =>
          _SfuTile(participant: participants[i], isVideo: isVideo),
    );
  }
}

class _SfuTile extends StatelessWidget {
  const _SfuTile({required this.participant, required this.isVideo});

  final lk.Participant participant;
  final bool isVideo;

  @override
  Widget build(BuildContext context) {
    final pubs = participant.videoTrackPublications;
    final pub = pubs.isNotEmpty ? pubs.first : null;
    final track = pub?.track;
    final videoMuted = pub?.muted ?? true;
    final name =
        participant.name.isNotEmpty ? participant.name : participant.identity;

    Widget content;
    if (isVideo && track is lk.VideoTrack && !videoMuted) {
      content = lk.VideoTrackRenderer(track);
    } else {
      content = Center(child: GlowAvatar(username: name, size: 96));
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFF070D1A)),
          content,
          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: CallParticipantLabel(
              name: name,
              muted: !participant.isMicrophoneEnabled(),
              compact: false,
            ),
          ),
        ],
      ),
    );
  }
}
