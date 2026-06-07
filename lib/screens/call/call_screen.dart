import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../../config/api_config.dart';
import '../../providers/call_provider.dart';
import '../../services/call_service.dart';
import '../../widgets/glass.dart';

const _callEndColor = Color(0xFFFF453A);
const _callAnswerColor = Color(0xFF30D158);
const _callDismissColor = Color(0xFF8E8E93);

@visibleForTesting
bool shouldUseCallVideoRenderersForTesting(CallSession? session) {
  return session?.isVideo == true;
}

bool _isDesktopCallLayout(BuildContext context) {
  if (MediaQuery.sizeOf(context).width >= 720) return true;
  if (kIsWeb) return false;
  return switch (defaultTargetPlatform) {
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    _ => false,
  };
}

bool _isMobileCallPlatform() {
  if (kIsWeb) return false;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };
}

/// Full-screen audio/video call UI in iOS 26 Liquid Glass style.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  bool _audioPickerOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<CallProvider>().refreshAudioOutputs();
    });
  }

  void _toggleMic() {
    final cp = context.read<CallProvider>();
    cp.setMicMuted(!cp.isMicMuted);
  }

  void _toggleCamera() {
    final cp = context.read<CallProvider>();
    cp.setCameraEnabled(!cp.isCameraEnabled);
  }

  void _switchCamera() {
    unawaited(context.read<CallProvider>().switchCamera());
  }

  void _toggleScreenShare() {
    final cp = context.read<CallProvider>();
    if (cp.isScreenSharing) {
      unawaited(cp.stopScreenShare());
    } else {
      unawaited(_startScreenShare(cp));
    }
  }

  Future<void> _startScreenShare(CallProvider cp) async {
    try {
      await cp.startScreenShare();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Screen share failed: $e')),
      );
    }
  }

  void _hangup() => context.read<CallProvider>().hangup();
  void _minimize() => context.read<CallProvider>().setCallMinimized(true);

  Future<void> _pickAudioOutput() async {
    final cp = context.read<CallProvider>();
    await cp.refreshAudioOutputs();
    if (!mounted) return;
    if (cp.audioOutputs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No audio outputs are available')),
      );
      return;
    }
    // CallScreen lives in CallOverlay, mounted in MaterialApp.builder ABOVE the
    // app's Navigator, so routed popups (showGlassActionSheet / Navigator.of)
    // either throw "no Navigator" or render on the root overlay BENEATH the call
    // UI (visible only after the call ends) without a Material ancestor (yellow
    // underline). Render the picker inline in this screen's own Stack instead.
    setState(() => _audioPickerOpen = true);
  }

  void _closeAudioPicker() {
    if (!_audioPickerOpen) return;
    setState(() => _audioPickerOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final cp = context.watch<CallProvider>();
    final session = cp.session;
    if (session == null) return const SizedBox.shrink();

    final isVideo = session.isVideo;
    final statusText = cp.callStatusText;
    final micMuted = cp.isMicMuted;
    final cameraOff = !cp.isCameraEnabled;
    final avatarUrl = session.remoteAvatarUrl;
    final username = session.remoteUsername ?? 'Unknown';
    final participants = _callParticipantsFor(
      localRenderer: cp.localRenderer,
      remoteRenderers: cp.remoteRenderers,
      session: session,
      mirrorLocalVideo: cp.isFrontCamera,
    );
    final hasLiveVideo = isVideo && participants.any((p) => p.renderer != null);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final desktopLayout = _isDesktopCallLayout(context);
    final compactLayout = !desktopLayout && screenWidth < 430;
    final buttonSize = compactLayout ? 48.0 : 56.0;
    final controlsMaxWidth = desktopLayout
        ? (screenWidth * 0.45).clamp(
            isVideo ? 520.0 : 420.0,
            isVideo ? 800.0 : 680.0,
          )
        : double.infinity;
    final controlsPadding = EdgeInsets.fromLTRB(
      desktopLayout ? 32 : 24,
      0,
      desktopLayout ? 32 : 24,
      desktopLayout ? 28 : 24,
    );

    final secondaryControls = <Widget>[
      _ControlButton(
        key: const Key('call-control-mute'),
        icon: micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
        label: micMuted ? 'Unmute' : 'Mute',
        active: micMuted,
        activeColor: _callEndColor,
        onTap: _toggleMic,
        size: buttonSize,
      ),
      _ControlButton(
        key: const Key('call-control-audio-output'),
        icon: Icons.volume_up_rounded,
        label: 'Audio',
        onTap: _pickAudioOutput,
        size: buttonSize,
      ),
      if (isVideo)
        _ControlButton(
          key: const Key('call-control-camera'),
          icon: cameraOff ? Icons.videocam_off_rounded : Icons.videocam_rounded,
          label: cameraOff ? 'Camera on' : 'Camera off',
          active: cameraOff,
          onTap: _toggleCamera,
          size: buttonSize,
        ),
      if (isVideo && _isMobileCallPlatform())
        _ControlButton(
          key: const Key('call-control-switch-camera'),
          icon: Icons.cameraswitch_rounded,
          label: 'Flip',
          onTap: _switchCamera,
          size: buttonSize,
        ),
      if (isVideo && cp.canScreenShare)
        _ControlButton(
          key: const Key('call-control-screenshare'),
          icon: cp.isScreenSharing
              ? Icons.stop_screen_share_rounded
              : Icons.screen_share_rounded,
          label: cp.isScreenSharing ? 'Stop' : 'Share',
          active: cp.isScreenSharing,
          onTap: _toggleScreenShare,
          size: buttonSize,
        ),
    ];

    final controlsBottomInset = desktopLayout ? 188.0 : 208.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Background ─────────────────────────────────────────────────────
          if (!hasLiveVideo)
            Positioned.fill(
              child: _CallBackground(avatarUrl: avatarUrl, username: username),
            ),

          Positioned.fill(
            child: _ParticipantStage(
              participants: participants,
              isVideo: isVideo,
              controlsBottomInset: controlsBottomInset,
            ),
          ),

          // ── Top bar ────────────────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        // Minimize button
                        GlassIconButton(
                          key: const Key('minimize-call-button'),
                          icon: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                          ),
                          onPressed: _minimize,
                          useOwnLayer: true,
                          quality: GlassQuality.standard,
                          size: 44,
                        ),
                        const Spacer(),
                        // Status chip (shows duration once connected)
                        GlassContainer(
                          shape: const LiquidRoundedSuperellipse(
                            borderRadius: 999,
                          ),
                          useOwnLayer: true,
                          quality: GlassQuality.standard,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 7,
                          ),
                          child: Text(
                            statusText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const Spacer(),
                        const SizedBox(width: 44),
                      ],
                    ),
                    // Caller name + call type (shown when no live video stream)
                    if (!hasLiveVideo) ...[
                      const SizedBox(height: 10),
                      Text(
                        username,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isVideo ? 'Video call' : 'Voice call',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          // ── Controls panel ─────────────────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: controlsPadding,
                child: Center(
                  child: ConstrainedBox(
                    key: const Key('call-controls-bar'),
                    constraints: BoxConstraints(maxWidth: controlsMaxWidth),
                    child: _CallControlsPanel(
                      secondaryControls: secondaryControls,
                      onHangup: _hangup,
                      buttonSize: buttonSize,
                      desktopLayout: desktopLayout,
                      compactLayout: compactLayout,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ── Audio output picker ────────────────────────────────────────────
          // Rendered inline (not via the Navigator) because CallScreen sits
          // above the app's Navigator — see _pickAudioOutput.
          if (_audioPickerOpen)
            Positioned.fill(
              child: _AudioOutputSheet(
                outputs: cp.audioOutputs,
                selectedId: cp.selectedAudioOutputId,
                onSelected: (id) {
                  unawaited(cp.selectAudioOutput(id));
                  _closeAudioPicker();
                },
                onDismiss: _closeAudioPicker,
              ),
            ),
        ],
      ),
    );
  }
}

/// Inline audio-output picker. Rendered inside CallScreen's own Scaffold/Stack
/// (which is above the app Navigator) rather than via a route, so it always
/// paints over the call UI and inherits a Material ancestor from the Scaffold
/// (no yellow debug underline). Uses the shader-backed GlassContainer + a plain
/// color scrim, both safe over an active RTCVideoView.
class _AudioOutputSheet extends StatelessWidget {
  const _AudioOutputSheet({
    required this.outputs,
    required this.selectedId,
    required this.onSelected,
    required this.onDismiss,
  });

  final List<CallAudioOutput> outputs;
  final String? selectedId;
  final ValueChanged<String> onSelected;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: const ColoredBox(color: Color(0x99000000)),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: GlassContainer(
                    shape: const LiquidRoundedSuperellipse(borderRadius: 28),
                    useOwnLayer: true,
                    quality: GlassQuality.standard,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
                          child: Text(
                            'Audio Output',
                            style: TextStyle(
                              color: Color(0x8CFFFFFF),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.1,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                        for (final output in outputs)
                          _AudioOutputRow(
                            label: output.label,
                            selected: output.deviceId == selectedId,
                            onTap: () => onSelected(output.deviceId),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AudioOutputRow extends StatelessWidget {
  const _AudioOutputRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            if (selected)
              const Icon(Icons.check_rounded, color: Colors.white, size: 20),
          ],
        ),
      ),
    );
  }
}

List<_CallParticipantView> _callParticipantsFor({
  required RTCVideoRenderer? localRenderer,
  required Map<String, RTCVideoRenderer> remoteRenderers,
  required CallSession session,
  required bool mirrorLocalVideo,
}) {
  final views = <_CallParticipantView>[];

  for (final entry in remoteRenderers.entries) {
    final userId = entry.key;
    final isPrimaryRemote = userId == session.remoteUserId;
    views.add(
      _CallParticipantView(
        id: userId,
        name: isPrimaryRemote
            ? (session.remoteUsername ?? _shortUserId(userId))
            : _shortUserId(userId),
        avatarUrl: isPrimaryRemote ? session.remoteAvatarUrl : null,
        isLocal: false,
        audioMuted: false,
        isSpeaking: false,
        renderer: entry.value,
        mirrorVideo: false,
      ),
    );
  }

  // Show a placeholder tile while waiting for remote track
  if (views.isEmpty) {
    views.add(
      _CallParticipantView(
        id: session.remoteUserId,
        name: session.remoteUsername ?? 'Unknown',
        avatarUrl: session.remoteAvatarUrl,
        isLocal: false,
        audioMuted: false,
        isSpeaking: false,
        mirrorVideo: false,
      ),
    );
  }

  if (localRenderer != null) {
    views.add(
      _CallParticipantView(
        id: 'local',
        name: 'You',
        isLocal: true,
        audioMuted: false,
        isSpeaking: false,
        renderer: localRenderer,
        mirrorVideo: mirrorLocalVideo,
      ),
    );
  }

  return views;
}

String _shortUserId(String userId) {
  final trimmed = userId.trim();
  if (trimmed.isEmpty) return 'Unknown';
  if (trimmed.length <= 8) return trimmed;
  return trimmed.substring(0, 8);
}

class _CallParticipantView {
  final String id;
  final String name;
  final String? avatarUrl;
  final bool isLocal;
  final bool audioMuted;
  final bool isSpeaking;
  final RTCVideoRenderer? renderer;
  final bool mirrorVideo;

  const _CallParticipantView({
    required this.id,
    required this.name,
    this.avatarUrl,
    required this.isLocal,
    required this.audioMuted,
    required this.isSpeaking,
    this.renderer,
    required this.mirrorVideo,
  });
}

class _ParticipantStage extends StatelessWidget {
  final List<_CallParticipantView> participants;
  final bool isVideo;
  final double controlsBottomInset;

  const _ParticipantStage({
    required this.participants,
    required this.isVideo,
    required this.controlsBottomInset,
  });

  @override
  Widget build(BuildContext context) {
    final local = participants.where((p) => p.isLocal).firstOrNull;
    final primaryRemote = participants
        .where((p) => !p.isLocal && p.renderer != null)
        .firstOrNull;
    final usePiP =
        isVideo &&
        primaryRemote != null &&
        participants.where((p) => !p.isLocal).length == 1;

    if (usePiP) {
      return Stack(
        children: [
          Positioned.fill(
            child: _ParticipantTile(
              participant: primaryRemote,
              isVideoCall: true,
              fullBleed: true,
            ),
          ),
          if (local != null)
            Positioned(
              top: 72,
              right: 16,
              width: 112,
              height: 152,
              child: _ParticipantTile(
                participant: local,
                isVideoCall: true,
                compact: true,
              ),
            ),
        ],
      );
    }

    return _ParticipantGrid(
      participants: participants,
      isVideoCall: isVideo,
      controlsBottomInset: controlsBottomInset,
    );
  }
}

class _ParticipantGrid extends StatelessWidget {
  final List<_CallParticipantView> participants;
  final bool isVideoCall;
  final double controlsBottomInset;

  const _ParticipantGrid({
    required this.participants,
    required this.isVideoCall,
    required this.controlsBottomInset,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = participants.length;
        final width = constraints.maxWidth;
        final columns = switch (count) {
          <= 1 => 1,
          2 => width >= 620 ? 2 : 1,
          <= 4 => width >= 760 ? 2 : 1,
          _ => width >= 1120 ? 4 : (width >= 760 ? 3 : 2),
        };
        return GridView.count(
          physics: const ClampingScrollPhysics(),
          padding: EdgeInsets.fromLTRB(14, 96, 14, controlsBottomInset),
          crossAxisCount: columns,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: isVideoCall ? 0.82 : 1.05,
          children: [
            for (final participant in participants)
              _ParticipantTile(
                participant: participant,
                isVideoCall: isVideoCall,
              ),
          ],
        );
      },
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  final _CallParticipantView participant;
  final bool isVideoCall;
  final bool compact;
  final bool fullBleed;

  const _ParticipantTile({
    required this.participant,
    required this.isVideoCall,
    this.compact = false,
    this.fullBleed = false,
  });

  @override
  Widget build(BuildContext context) {
    final renderer = isVideoCall ? participant.renderer : null;
    final radius = fullBleed ? BorderRadius.zero : BorderRadius.circular(8);
    final content = renderer != null
        ? IgnorePointer(
            child: RTCVideoView(
              renderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              mirror: participant.mirrorVideo,
            ),
          )
        : _ParticipantAvatarPanel(participant: participant, compact: compact);

    return ClipRRect(
      borderRadius: radius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: const Color(0xFF070D1A), child: content),
          Positioned(
            left: compact ? 8 : 12,
            right: compact ? 8 : 12,
            bottom: compact ? 8 : 12,
            child: _ParticipantLabel(
              participant: participant,
              compact: compact,
            ),
          ),
          if (participant.isSpeaking)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _callAnswerColor.withValues(alpha: 0.78),
                      width: compact ? 2 : 3,
                    ),
                    borderRadius: radius,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ParticipantAvatarPanel extends StatelessWidget {
  final _CallParticipantView participant;
  final bool compact;

  const _ParticipantAvatarPanel({
    required this.participant,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final shortest = constraints.biggest.shortestSide;
        final avatarSize = compact
            ? 54.0
            : shortest.clamp(86.0, 132.0).toDouble();
        final fontSize = compact ? 0.0 : (shortest / 7).clamp(20.0, 28.0);
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _GlowAvatar(
                avatarUrl: participant.avatarUrl,
                username: participant.name,
                size: avatarSize,
              ),
              if (!compact) ...[
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Text(
                    participant.name,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: fontSize,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ParticipantLabel extends StatelessWidget {
  final _CallParticipantView participant;
  final bool compact;

  const _ParticipantLabel({required this.participant, required this.compact});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomLeft,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.54),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.16),
            width: 0.6,
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: compact ? 5 : 7,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (participant.audioMuted) ...[
                Icon(
                  Icons.mic_off_rounded,
                  color: Colors.white70,
                  size: compact ? 12 : 14,
                ),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  participant.name,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 11 : 12,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Background ────────────────────────────────────────────────────────────────

class _CallBackground extends StatelessWidget {
  final String? avatarUrl;
  final String username;

  const _CallBackground({this.avatarUrl, required this.username});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.3),
                radius: 1.4,
                colors: [
                  Color(0xFF1A2340),
                  Color(0xFF070D1A),
                  Color(0xFF000000),
                ],
              ),
            ),
          ),
        ),
        if (avatarUrl != null)
          Positioned.fill(
            child: Opacity(
              opacity: 0.14,
              child: CachedNetworkImage(
                imageUrl: ApiConfig.resolveMedia(avatarUrl!),
                fit: BoxFit.cover,
              ),
            ),
          ),
        Positioned(
          top: -100,
          left: -100,
          right: -100,
          height: 500,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topCenter,
                radius: 1.0,
                colors: [
                  const Color(0xFF3D5AFE).withValues(alpha: 0.18),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Glow avatar ───────────────────────────────────────────────────────────────

class _GlowAvatar extends StatelessWidget {
  final String? avatarUrl;
  final String username;
  final double size;

  const _GlowAvatar({this.avatarUrl, required this.username, this.size = 120});

  @override
  Widget build(BuildContext context) {
    final initial = username.isNotEmpty
        ? username.substring(0, 1).toUpperCase()
        : '?';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF3D5AFE).withValues(alpha: 0.40),
            blurRadius: 48,
            spreadRadius: -4,
          ),
        ],
      ),
      child: ClipOval(
        child: avatarUrl != null
            ? CachedNetworkImage(
                imageUrl: ApiConfig.resolveMedia(avatarUrl!),
                fit: BoxFit.cover,
              )
            : Container(
                color: const Color(0xFF1A2340),
                child: Center(
                  child: Text(
                    initial,
                    style: TextStyle(
                      fontSize: size * 0.4,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

// ── Controls panel ────────────────────────────────────────────────────────────

/// iOS 26-style call controls: secondary actions in a glass pill above a
/// distinct, full-width End Call button.
class _CallControlsPanel extends StatelessWidget {
  final List<Widget> secondaryControls;
  final VoidCallback onHangup;
  final double buttonSize;
  final bool desktopLayout;
  final bool compactLayout;

  const _CallControlsPanel({
    required this.secondaryControls,
    required this.onHangup,
    required this.buttonSize,
    required this.desktopLayout,
    required this.compactLayout,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (secondaryControls.isNotEmpty) ...[
          // Secondary controls pill — shader-based glass, safe over RTCVideoView
          GlassContainer(
            shape: const LiquidRoundedSuperellipse(borderRadius: 36),
            useOwnLayer: true,
            quality: GlassQuality.standard,
            padding: EdgeInsets.symmetric(
              horizontal: desktopLayout ? 20 : 8,
              vertical: desktopLayout ? 18 : 16,
            ),
            child: Wrap(
              alignment: WrapAlignment.center,
              runAlignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: desktopLayout ? 24 : (compactLayout ? 8 : 12),
              runSpacing: 14,
              children: secondaryControls,
            ),
          ),
          const SizedBox(height: 10),
        ],
        // End Call — prominent full-width pill with red glass tint
        LayoutBuilder(
          builder: (ctx, c) => GlassButton.custom(
            key: const Key('call-control-end'),
            onTap: onHangup,
            useOwnLayer: true,
            quality: GlassQuality.standard,
            width: c.maxWidth,
            height: desktopLayout ? 56 : 62,
            shape: const LiquidRoundedSuperellipse(borderRadius: 32),
            settings: LiquidGlassSettings(
              glassColor: _callEndColor.withValues(alpha: 0.62),
            ),
            glowColor: _callEndColor,
            glowRadius: 28,
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.call_end_rounded, color: Colors.white, size: 24),
                SizedBox(width: 10),
                Text(
                  'End Call',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Control button ────────────────────────────────────────────────────────────

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color activeColor;
  final double size;

  const _ControlButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.activeColor = Colors.white,
    this.size = 56.0,
  });

  @override
  Widget build(BuildContext context) {
    // Use a colored glass tint when active (e.g. muted = red fill).
    final settings = active && activeColor != Colors.white
        ? LiquidGlassSettings(glassColor: activeColor.withValues(alpha: 0.45))
        : null;

    // Tooltip is intentionally omitted: on desktop, Tooltip creates a new
    // Overlay compositing layer above the RTCVideoView platform texture, which
    // confuses desktop compositors and causes white-square artifacts on hover.
    // The visible text label below each icon already conveys the action.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GlassIconButton(
          icon: Icon(icon),
          onPressed: onTap,
          size: size,
          useOwnLayer: true,
          quality: GlassQuality.standard,
          glowColor: active ? activeColor : null,
          glowRadius: 18,
          settings: settings,
        ),
        const SizedBox(height: 7),
        Text(
          label,
          style: TextStyle(
            color: active
                ? (activeColor == Colors.white
                    ? Colors.white
                    : activeColor.withValues(alpha: 0.90))
                : Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// ── Call overlay ──────────────────────────────────────────────────────────────

/// Mounted once at the app root (via MaterialApp.builder) so calls surface over
/// any screen. Shows the glassy incoming-call modal while a call is ringing and
/// the full-screen call UI once there's an active session — driven entirely by
/// [CallProvider] state, so there are no pushed routes to leak or get stranded.
class CallOverlay extends StatelessWidget {
  const CallOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final cp = context.watch<CallProvider>();
    if (cp.incomingCall != null) {
      return const SizedBox.expand(child: IncomingCallModal());
    }
    final session = cp.session;
    if (session != null && session.state != CallState.ended) {
      if (cp.isCallMinimized) {
        return const _MinimizedCallOverlay();
      }
      return const SizedBox.expand(child: CallScreen());
    }
    return const SizedBox.shrink();
  }
}

// ── Minimized overlay ─────────────────────────────────────────────────────────

class _MinimizedCallOverlay extends StatelessWidget {
  const _MinimizedCallOverlay();

  @override
  Widget build(BuildContext context) {
    final cp = context.watch<CallProvider>();
    final session = cp.session;
    if (session == null) return const SizedBox.shrink();
    final name = session.remoteUsername ?? 'Unknown';
    final scheme = Theme.of(context).colorScheme;

    return Align(
      alignment: Alignment.topCenter,
      child: SafeArea(
        bottom: false,
        left: false,
        right: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: GestureDetector(
            key: const Key('minimized-call-overlay'),
            onTap: () => cp.setCallMinimized(false),
            child: GlassContainer(
              shape: LiquidRoundedSuperellipse(borderRadius: 999),
              allowElevation: true,
              glowIntensity: 0.10,
              padding: EdgeInsets.zero,
              child: SizedBox(
                height: CallProvider.minimizedCallBarHeight,
                width: double.infinity,
                child: Row(
                  children: [
                    const SizedBox(width: 14),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: _callAnswerColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            cp.callStatusText,
                            style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: 0.55),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      key: const Key('expand-call-button'),
                      onTap: () => cp.setCallMinimized(false),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.14),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.22),
                            width: 0.5,
                          ),
                        ),
                        child: const Icon(
                          Icons.open_in_full_rounded,
                          color: Colors.white70,
                          size: 15,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: cp.hangup,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _callEndColor.withValues(alpha: 0.88),
                          boxShadow: [
                            BoxShadow(
                              color: _callEndColor.withValues(alpha: 0.40),
                              blurRadius: 12,
                              spreadRadius: -3,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.call_end_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Incoming call modal ───────────────────────────────────────────────────────

/// Full-screen, iOS 26 Liquid Glass incoming-call prompt with the caller's
/// avatar centered and Answer / Decline / Dismiss actions.
class IncomingCallModal extends StatelessWidget {
  const IncomingCallModal({super.key});

  @override
  Widget build(BuildContext context) {
    final cp = context.watch<CallProvider>();
    final incoming = cp.incomingCall;
    if (incoming == null) return const SizedBox.shrink();

    final name = incoming.remoteUsername != null
        ? '@${incoming.remoteUsername}'
        : 'Unknown caller';
    final kind = incoming.isVideo
        ? 'Incoming video call'
        : 'Incoming voice call';
    final avatarUrl = incoming.remoteAvatarUrl;
    final desktopLayout = _isDesktopCallLayout(context);
    final panelMaxWidth = desktopLayout ? 480.0 : double.infinity;
    final panelPadding = EdgeInsets.symmetric(
      horizontal: desktopLayout ? 24 : 32,
      vertical: desktopLayout ? 28 : 40,
    );
    final actions = [
      _CallAction(
        icon: Icons.call_end_rounded,
        label: 'Decline',
        color: _callEndColor,
        onTap: cp.rejectIncomingCall,
      ),
      _CallAction(
        icon: Icons.close_rounded,
        label: 'Dismiss',
        color: _callDismissColor,
        onTap: cp.dismissIncomingCall,
      ),
      _CallAction(
        icon: incoming.isVideo ? Icons.videocam_rounded : Icons.call_rounded,
        label: 'Answer',
        color: _callAnswerColor,
        onTap: () async {
          try {
            await cp.acceptIncomingCall();
          } catch (error) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not answer call: $error')),
            );
          }
        },
      ),
    ];

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: _CallBackground(
              avatarUrl: avatarUrl,
              username: incoming.remoteUsername ?? '',
            ),
          ),
          Positioned.fill(
            child: Container(color: Colors.black.withValues(alpha: 0.34)),
          ),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                key: const Key('incoming-call-panel'),
                constraints: BoxConstraints(maxWidth: panelMaxWidth),
                child: SingleChildScrollView(
                  padding: panelPadding,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _GlowAvatar(
                        avatarUrl: avatarUrl,
                        username: incoming.remoteUsername ?? '',
                      ),
                      const SizedBox(height: 22),
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 0,
                        ),
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      const SizedBox(height: 8),
                      // Kind badge — shader-based glass capsule
                      GlassContainer(
                        shape: const LiquidRoundedSuperellipse(
                          borderRadius: 999,
                        ),
                        useOwnLayer: true,
                        quality: GlassQuality.standard,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              incoming.isVideo
                                  ? Icons.videocam_rounded
                                  : Icons.call_rounded,
                              color: Colors.white70,
                              size: 14,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              kind,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: desktopLayout ? 46 : 64),
                      Wrap(
                        alignment: WrapAlignment.center,
                        runAlignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: desktopLayout ? 34 : 24,
                        runSpacing: 18,
                        children: actions,
                      ),
                      const SizedBox(height: 20),
                    ],
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

// ── Incoming call action button ───────────────────────────────────────────────

class _CallAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _CallAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GlassIconButton(
          icon: Icon(icon, size: 30, color: Colors.white),
          onPressed: onTap,
          size: 72,
          useOwnLayer: true,
          quality: GlassQuality.standard,
          glowColor: color,
          glowRadius: 30,
          settings: LiquidGlassSettings(glassColor: color.withValues(alpha: 0.55)),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
