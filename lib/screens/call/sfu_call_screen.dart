import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:provider/provider.dart';

import '../../services/sfu_call_controller.dart';
import '../../widgets/glass.dart';
import 'call_glass.dart';

/// Full-screen UI for a LiveKit SFU group call, in the same iOS-26 / FaceTime
/// Liquid Glass style as the P2P CallScreen (shared widgets from
/// call_glass.dart). Reads [SfuCallController] and pops itself when the call
/// ends. During a live video call, tapping the stage hides the chrome.
class SfuCallScreen extends StatefulWidget {
  const SfuCallScreen({super.key});

  @override
  State<SfuCallScreen> createState() => _SfuCallScreenState();
}

class _SfuCallScreenState extends State<SfuCallScreen> {
  bool _chromeVisible = true;

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  bool get _supportsScreenShare =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static bool _participantHasLiveVideo(lk.Participant p) {
    final pubs = p.videoTrackPublications;
    if (pubs.isEmpty) return false;
    final pub = pubs.first;
    return pub.track is lk.VideoTrack && !pub.muted;
  }

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
    final mq = MediaQuery.of(context);
    final width = mq.size.width;
    final desktopLayout = width >= 720;
    final compactLayout = width < 430;
    final buttonSize = compactLayout ? 52.0 : 56.0;
    final connecting = sfu.isConnecting && participants.length <= 1;
    final hasLiveVideo =
        sfu.isVideo && participants.any(_participantHasLiveVideo);
    final chromeHideable = hasLiveVideo;
    final showChrome = !chromeHideable || _chromeVisible;

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
          icon: sfu.isScreenSharing
              ? Icons.stop_screen_share
              : Icons.screen_share,
          label: 'Share',
          active: sfu.isScreenSharing,
          activeColor: callAnswerColor,
          size: buttonSize,
          onTap: () => sfu.toggleScreenShare(),
        ),
    ];

    final topInset = mq.padding.top + 84;
    final bottomInset = mq.padding.bottom + (desktopLayout ? 188.0 : 208.0);

    final stage = connecting
        ? _Connecting(title: sfu.title ?? 'Group call')
        : _SfuGrid(
            participants: participants,
            isVideo: sfu.isVideo,
            topInset: topInset,
            bottomInset: bottomInset,
          );

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (!hasLiveVideo)
            Positioned.fill(
              child: CallBackground(username: sfu.title ?? 'Group call'),
            ),

          Positioned.fill(
            child: chromeHideable
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleChrome,
                    child: stage,
                  )
                : stage,
          ),

          // ── Edge scrims (control legibility over bright video) ──────────────
          if (hasLiveVideo) ...[
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 168,
              child: AnimatedSlide(
                offset: showChrome ? Offset.zero : const Offset(0, -1),
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOut,
                child: const IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x80000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: 260,
              child: AnimatedSlide(
                offset: showChrome ? Offset.zero : const Offset(0, 1),
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOut,
                child: const IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0x8C000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],

          // ── Header ─────────────────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedSlide(
              offset: showChrome ? Offset.zero : const Offset(0, -1),
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
              child: IgnorePointer(
                ignoring: !showChrome,
                child: SafeArea(
                  bottom: false,
                  child: _SfuHeader(
                    title: sfu.title ?? 'Group call',
                    connecting: sfu.isConnecting,
                    count: participants.length,
                    mediaE2EE: sfu.isMediaE2EE,
                  ),
                ),
              ),
            ),
          ),

          // ── Controls ───────────────────────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: AnimatedSlide(
              offset: showChrome ? Offset.zero : const Offset(0, 1.3),
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
              child: IgnorePointer(
                ignoring: !showChrome,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      desktopLayout ? 40 : 16,
                      8,
                      desktopLayout ? 40 : 16,
                      16,
                    ),
                    child: Center(
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
                  ),
                ),
              ),
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
    this.mediaE2EE = false,
  });

  final String title;
  final bool connecting;
  final int count;
  final bool mediaE2EE;

  @override
  Widget build(BuildContext context) {
    final subtitle = connecting
        ? 'Connecting…'
        : '$count ${count == 1 ? 'person' : 'people'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 21,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          // Glass status capsule (people count / connecting), plus the media
          // E2EE lock — frames are encrypted with the conversation's call key
          // and the SFU only ever routes ciphertext.
          GlassContainer(
            shape: const LiquidRoundedSuperellipse(borderRadius: 999),
            useOwnLayer: true,
            quality: GlassQuality.standard,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  connecting ? Icons.cloud_sync_rounded : Icons.groups_rounded,
                  color: Colors.white70,
                  size: 14,
                ),
                const SizedBox(width: 6),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (mediaE2EE) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Media is end-to-end encrypted',
                    child: Icon(
                      Icons.lock_rounded,
                      color: Colors.greenAccent.shade100,
                      size: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Connecting extends StatelessWidget {
  const _Connecting({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PulsingGlowAvatar(username: title, size: 132),
          const SizedBox(height: 30),
          const Text(
            'Connecting…',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _SfuGrid extends StatelessWidget {
  const _SfuGrid({
    required this.participants,
    required this.isVideo,
    this.topInset = 96,
    this.bottomInset = 208,
  });

  final List<lk.Participant> participants;
  final bool isVideo;
  final double topInset;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final n = participants.length;
    final width = MediaQuery.sizeOf(context).width;
    final cols = n <= 1
        ? 1
        : n <= 4
        ? 2
        : (width >= 900 ? 4 : 3);
    return GridView.builder(
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.fromLTRB(12, topInset, 12, bottomInset),
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
    final speaking = participant.isSpeaking;
    final name = participant.name.isNotEmpty
        ? participant.name
        : participant.identity;

    Widget content;
    if (isVideo && track is lk.VideoTrack && !videoMuted) {
      content = lk.VideoTrackRenderer(track);
    } else {
      content = Center(child: GlowAvatar(username: name, size: 96));
    }

    final radius = BorderRadius.circular(20);
    return ClipRRect(
      borderRadius: radius,
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
          // Hairline ring, or a green ring while the participant is speaking.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(
                    color: speaking
                        ? callAnswerColor.withValues(alpha: 0.85)
                        : Colors.white.withValues(alpha: 0.14),
                    width: speaking ? 2.5 : 1,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
