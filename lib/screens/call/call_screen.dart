import 'dart:async';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
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

/// Full-screen audio/video call UI in iOS 26 Liquid Glass style.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;
  bool _renderersInitialized = false;

  @override
  void initState() {
    super.initState();
    if (_shouldUseVideoRenderers(context.read<CallProvider>().session)) {
      _initRenderers();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<CallProvider>().refreshAudioOutputs();
    });
  }

  Future<void> _initRenderers() async {
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();
      _renderersInitialized = true;
    } catch (_) {
      await _disposeRenderer(_localRenderer);
      await _disposeRenderer(_remoteRenderer);
      if (mounted) setState(() => _renderersReady = false);
      return;
    }
    if (!mounted) {
      await _disposeRenderers();
      return;
    }
    final ready =
        _localRenderer.textureId != null && _remoteRenderer.textureId != null;
    if (ready) {
      final cp = context.read<CallProvider>();
      if (cp.localStream != null) _localRenderer.srcObject = cp.localStream;
      if (cp.remoteStream != null) _remoteRenderer.srcObject = cp.remoteStream;
    }
    setState(() => _renderersReady = ready);
  }

  @override
  void dispose() {
    unawaited(_disposeRenderers());
    super.dispose();
  }

  bool _shouldUseVideoRenderers(CallSession? session) {
    return shouldUseCallVideoRenderersForTesting(session);
  }

  Future<void> _disposeRenderers() async {
    if (!_renderersInitialized) return;
    _renderersInitialized = false;
    _renderersReady = false;
    await _clearRenderer(_localRenderer);
    await _clearRenderer(_remoteRenderer);
    await _disposeRenderer(_localRenderer);
    await _disposeRenderer(_remoteRenderer);
  }

  Future<void> _clearRenderer(RTCVideoRenderer renderer) async {
    if (renderer.textureId == null) return;
    try {
      await renderer.setSrcObject(stream: null);
    } catch (_) {}
  }

  Future<void> _disposeRenderer(RTCVideoRenderer renderer) async {
    try {
      await renderer.dispose();
    } catch (_) {}
  }

  void _toggleMic() {
    final cp = context.read<CallProvider>();
    cp.setMicMuted(!cp.isMicMuted);
  }

  void _toggleCamera() {
    final cp = context.read<CallProvider>();
    cp.setCameraEnabled(!cp.isCameraEnabled);
  }

  void _hangup() => context.read<CallProvider>().hangup();
  void _minimize() => context.read<CallProvider>().setCallMinimized(true);

  Future<void> _pickAudioOutput() async {
    final cp = context.read<CallProvider>();
    await cp.refreshAudioOutputs();
    if (!mounted) return;
    final outputs = cp.audioOutputs;
    if (outputs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No audio outputs are available')),
      );
      return;
    }
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: LiquidGlass(
            blur: 56,
            borderRadius: const BorderRadius.all(Radius.circular(28)),
            padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Audio Output',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 12),
                for (final output in outputs)
                  _AudioOutputTile(
                    label: output.label,
                    selected: cp.selectedAudioOutputId == output.deviceId,
                    onTap: () => Navigator.of(ctx).pop(output.deviceId),
                  ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected != null) {
      await cp.selectAudioOutput(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cp = context.watch<CallProvider>();
    final session = cp.session;
    if (session == null) return const SizedBox.shrink();

    final isVideo = session.isVideo;
    final useVideoRenderers = _shouldUseVideoRenderers(session);

    if (_renderersReady && useVideoRenderers) {
      if (cp.localStream != null) _localRenderer.srcObject = cp.localStream;
      if (cp.remoteStream != null) _remoteRenderer.srcObject = cp.remoteStream;
    }

    final statusText = cp.callStatusText;
    final micMuted = cp.isMicMuted;
    final cameraOff = !cp.isCameraEnabled;
    final avatarUrl = session.remoteAvatarUrl;
    final username = session.remoteUsername ?? 'Unknown';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Background ─────────────────────────────────────────────────────
          if (!isVideo || !_renderersReady || !useVideoRenderers)
            Positioned.fill(
              child: _CallBackground(avatarUrl: avatarUrl, username: username),
            ),

          // Hidden audio renderer
          if (!isVideo && useVideoRenderers && _renderersReady)
            Positioned(
              left: 0,
              top: 0,
              width: 1,
              height: 1,
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0,
                  child: RTCVideoView(_remoteRenderer),
                ),
              ),
            ),

          // Remote video
          if (isVideo && useVideoRenderers && _renderersReady)
            Positioned.fill(
              child: IgnorePointer(
                child: RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            ),

          // Local PiP
          if (isVideo && useVideoRenderers && _renderersReady)
            Positioned(
              top: 72,
              right: 16,
              width: 104,
              height: 148,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: IgnorePointer(
                  child: RTCVideoView(
                    _localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
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
                child: Row(
                  children: [
                    _CallIconButton(
                      key: const Key('minimize-call-button'),
                      tooltip: 'Minimize call',
                      icon: Icons.keyboard_arrow_down_rounded,
                      onTap: _minimize,
                    ),
                    const Spacer(),
                    // Status chip
                    LiquidGlass.capsule(
                      blur: 36,
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
                    const SizedBox(width: 44), // balance the minimize button
                  ],
                ),
              ),
            ),
          ),

          // ── Audio-only: name + status centered ─────────────────────────────
          if (!isVideo || !_renderersReady || !useVideoRenderers)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 60),
                  // Avatar with glass ring
                  _GlowAvatar(avatarUrl: avatarUrl, username: username),
                  const SizedBox(height: 22),
                  Text(
                    username,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                    ),
                  ),
                ],
              ),
            ),

          // ── Controls bar ───────────────────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: LiquidGlass(
                  blur: 56,
                  borderRadius: const BorderRadius.all(Radius.circular(36)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 20,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _ControlButton(
                        key: const Key('call-control-mute'),
                        icon: micMuted
                            ? Icons.mic_off_rounded
                            : Icons.mic_rounded,
                        label: micMuted ? 'Unmute' : 'Mute',
                        active: micMuted,
                        onTap: _toggleMic,
                      ),
                      _ControlButton(
                        key: const Key('call-control-audio-output'),
                        icon: Icons.volume_up_rounded,
                        label: 'Audio',
                        onTap: _pickAudioOutput,
                      ),
                      if (isVideo)
                        _ControlButton(
                          key: const Key('call-control-camera'),
                          icon: cameraOff
                              ? Icons.videocam_off_rounded
                              : Icons.videocam_rounded,
                          label: cameraOff ? 'Camera on' : 'Camera off',
                          active: cameraOff,
                          onTap: _toggleCamera,
                        ),
                      _ControlButton(
                        key: const Key('call-control-end'),
                        icon: Icons.call_end_rounded,
                        label: 'End',
                        onTap: _hangup,
                        color: _callEndColor,
                      ),
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

// ── Background ────────────────────────────────────────────────────────────────

class _CallBackground extends StatelessWidget {
  final String? avatarUrl;
  final String username;

  const _CallBackground({this.avatarUrl, required this.username});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Deep gradient base
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
        // Avatar blurred behind everything (gives a "bokeh" call background)
        if (avatarUrl != null)
          Positioned.fill(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
              child: Opacity(
                opacity: 0.22,
                child: CachedNetworkImage(
                  imageUrl: ApiConfig.resolveMedia(avatarUrl!),
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
        // Radial glow accent
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

  const _GlowAvatar({this.avatarUrl, required this.username});

  @override
  Widget build(BuildContext context) {
    final initial = username.isNotEmpty
        ? username.substring(0, 1).toUpperCase()
        : '?';
    return Container(
      width: 120,
      height: 120,
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
                    style: const TextStyle(
                      fontSize: 48,
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

// ── Icon button ───────────────────────────────────────────────────────────────

class _CallIconButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  const _CallIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: LiquidGlass(
          blur: 36,
          borderRadius: BorderRadius.circular(22),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, color: Colors.white70, size: 22),
          ),
        ),
      ),
    );
  }
}

// ── Control button ────────────────────────────────────────────────────────────

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final bool active;

  const _ControlButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final tint = active ? Colors.white : (color ?? Colors.white);
    final iconColor = active
        ? Colors.black87
        : color != null
        ? Colors.white
        : Colors.white;

    return Tooltip(
      message: label,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LiquidGlass(
              blur: 40,
              borderRadius: BorderRadius.circular(30),
              tint: tint,
              boxShadow: [
                BoxShadow(
                  color: (color ?? Colors.white).withValues(
                    alpha: color != null ? 0.42 : 0.10,
                  ),
                  blurRadius: color != null ? 22 : 12,
                  spreadRadius: -4,
                  offset: const Offset(0, 8),
                ),
              ],
              child: SizedBox(
                width: 60,
                height: 60,
                child: Icon(icon, color: iconColor, size: 26),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
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
      return const IncomingCallModal();
    }
    final session = cp.session;
    if (session != null && session.state != CallState.ended) {
      if (cp.isCallMinimized) {
        return const _MinimizedCallOverlay();
      }
      return const CallScreen();
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

    // The bar anchors inside the AppBar zone — top of SafeArea, not below the
    // toolbar. Body content (messages, lists) starts below the AppBar and is
    // therefore never covered by the bar regardless of which screen is open.
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
            child: LiquidGlass.capsule(
              blur: 50,
              tint: scheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 24,
                  spreadRadius: -4,
                  offset: const Offset(0, 8),
                ),
              ],
              child: SizedBox(
                height: CallProvider.minimizedCallBarHeight,
                width: double.infinity,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    // Green pulse dot — shows call is live
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
                    // Expand button
                    GestureDetector(
                      key: const Key('expand-call-button'),
                      onTap: () => cp.setCallMinimized(false),
                      child: LiquidGlass(
                        blur: 36,
                        borderRadius: BorderRadius.circular(18),
                        child: const SizedBox(
                          width: 32,
                          height: 32,
                          child: Icon(
                            Icons.open_in_full_rounded,
                            color: Colors.white70,
                            size: 15,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // End call button
                    GestureDetector(
                      onTap: cp.hangup,
                      child: LiquidGlass(
                        blur: 36,
                        borderRadius: BorderRadius.circular(18),
                        tint: _callEndColor,
                        boxShadow: [
                          BoxShadow(
                            color: _callEndColor.withValues(alpha: 0.40),
                            blurRadius: 12,
                            spreadRadius: -3,
                            offset: const Offset(0, 4),
                          ),
                        ],
                        child: const SizedBox(
                          width: 32,
                          height: 32,
                          child: Icon(
                            Icons.call_end_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
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

/// Full-screen, frosted-glass incoming-call prompt with the caller's avatar
/// centered and Answer / Decline / Dismiss actions.
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

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // Blurred + tinted background
          Positioned.fill(
            child: _CallBackground(
              avatarUrl: avatarUrl,
              username: incoming.remoteUsername ?? '',
            ),
          ),
          // Glass overlay
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Container(color: Colors.black.withValues(alpha: 0.20)),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
              child: Column(
                children: [
                  const Spacer(),
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
                      letterSpacing: -0.3,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  LiquidGlass.capsule(
                    blur: 36,
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
                  const Spacer(),
                  // Action buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
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
                        icon: incoming.isVideo
                            ? Icons.videocam_rounded
                            : Icons.call_rounded,
                        label: 'Answer',
                        color: _callAnswerColor,
                        onTap: cp.acceptIncomingCall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AudioOutputTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _AudioOutputTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      fontSize: 15,
                    ),
                  ),
                ),
                if (selected)
                  const Icon(
                    Icons.check_rounded,
                    color: _callAnswerColor,
                    size: 20,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LiquidGlass(
            blur: 44,
            borderRadius: BorderRadius.circular(38),
            tint: color,
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.44),
                blurRadius: 26,
                spreadRadius: -4,
                offset: const Offset(0, 12),
              ),
            ],
            child: SizedBox(
              width: 72,
              height: 72,
              child: Icon(icon, color: Colors.white, size: 30),
            ),
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
      ),
    );
  }
}
