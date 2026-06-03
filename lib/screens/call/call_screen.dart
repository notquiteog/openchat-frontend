import 'dart:async';

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
const _callDismissColor = Color(0xFFE5E5EA);

@visibleForTesting
bool shouldUseCallVideoRenderersForTesting(CallSession? session) {
  return session != null;
}

/// Full-screen audio/video call UI.
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
    final callProvider = context.read<CallProvider>();
    callProvider.setMicMuted(!callProvider.isMicMuted);
  }

  void _toggleCamera() {
    final callProvider = context.read<CallProvider>();
    callProvider.setCameraEnabled(!callProvider.isCameraEnabled);
  }

  void _hangup() {
    // The root CallOverlay shows/hides this screen off the session state, so we
    // just end the call — no Navigator.pop (this isn't a pushed route anymore).
    context.read<CallProvider>().hangup();
  }

  void _minimize() {
    context.read<CallProvider>().setCallMinimized(true);
  }

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
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              const Text(
                'Audio output',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              for (final output in outputs)
                ListTile(
                  title: Text(output.label),
                  trailing: cp.selectedAudioOutputId == output.deviceId
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.of(context).pop(output.deviceId),
                ),
            ],
          ),
        );
      },
    );
    if (selected != null) {
      await cp.selectAudioOutput(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final callProvider = context.watch<CallProvider>();
    final session = callProvider.session;
    if (session == null) {
      return const SizedBox.shrink();
    }

    final isVideo = session.isVideo;
    final useVideoRenderers = _shouldUseVideoRenderers(session);

    // Keep renderers in sync whenever streams change (guard: must be initialized first)
    if (_renderersReady && useVideoRenderers) {
      if (callProvider.localStream != null) {
        _localRenderer.srcObject = callProvider.localStream;
      }
      if (callProvider.remoteStream != null) {
        _remoteRenderer.srcObject = callProvider.remoteStream;
      }
    }

    final statusText = callProvider.callStatusText;
    final micMuted = callProvider.isMicMuted;
    final cameraOff = !callProvider.isCameraEnabled;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Audio-only calls still attach the remote stream to a renderer so
          // platforms that route audio through RTCVideoRenderer will play it.
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

          // Remote video (full screen) or avatar for audio call
          if (isVideo && useVideoRenderers && _renderersReady)
            Positioned.fill(
              child: IgnorePointer(
                child: RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            )
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 60,
                    backgroundColor: Colors.grey[800],
                    child: Text(
                      session.remoteUsername?.substring(0, 1).toUpperCase() ??
                          '?',
                      style: const TextStyle(fontSize: 48, color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    session.remoteUsername ?? 'Unknown',
                    style: const TextStyle(color: Colors.white, fontSize: 24),
                  ),
                ],
              ),
            ),

          // Local video (picture-in-picture)
          if (isVideo && useVideoRenderers && _renderersReady)
            Positioned(
              top: 60,
              right: 16,
              width: 100,
              height: 140,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: IgnorePointer(
                  child: RTCVideoView(
                    _localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),

          // Status banner
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: SizedBox(
                height: 56,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Text(
                      statusText,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                      ),
                    ),
                    Positioned(
                      left: 8,
                      child: _CallIconButton(
                        buttonKey: const Key('minimize-call-button'),
                        tooltip: 'Minimize call',
                        icon: Icons.expand_more,
                        iconColor: Colors.white70,
                        onTap: _minimize,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Controls bar
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Mic toggle
                    _ControlButton(
                      buttonKey: const Key('call-control-mute'),
                      icon: micMuted ? Icons.mic_off : Icons.mic,
                      label: micMuted ? 'Unmute' : 'Mute',
                      active: micMuted,
                      onTap: _toggleMic,
                    ),

                    _ControlButton(
                      buttonKey: const Key('call-control-audio-output'),
                      icon: Icons.volume_up,
                      label: 'Audio',
                      onTap: _pickAudioOutput,
                    ),

                    // Camera toggle (video calls only)
                    if (isVideo)
                      _ControlButton(
                        buttonKey: const Key('call-control-camera'),
                        icon: cameraOff ? Icons.videocam_off : Icons.videocam,
                        label: cameraOff ? 'Camera on' : 'Camera off',
                        active: cameraOff,
                        onTap: _toggleCamera,
                      ),

                    // Hang up
                    _ControlButton(
                      buttonKey: const Key('call-control-end'),
                      icon: Icons.call_end,
                      label: 'End',
                      onTap: _hangup,
                      color: _callEndColor,
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

class _CallIconButton extends StatelessWidget {
  final Key? buttonKey;
  final String tooltip;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;

  const _CallIconButton({
    this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.iconColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _GlassCircleButton(
      buttonKey: buttonKey,
      tooltip: tooltip,
      icon: icon,
      iconColor: iconColor,
      onTap: onTap,
      size: 44,
      iconSize: 24,
      blur: 24,
      tint: Colors.white,
      boxShadow: const [
        BoxShadow(
          color: Color(0x33000000),
          blurRadius: 14,
          offset: Offset(0, 6),
        ),
      ],
    );
  }
}

class _GlassCircleButton extends StatelessWidget {
  final Key? buttonKey;
  final String tooltip;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;
  final double size;
  final double iconSize;
  final double blur;
  final Color tint;
  final List<BoxShadow>? boxShadow;

  const _GlassCircleButton({
    required this.tooltip,
    required this.icon,
    required this.iconColor,
    required this.onTap,
    required this.size,
    required this.iconSize,
    required this.tint,
    this.buttonKey,
    this.blur = 26,
    this.boxShadow,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: GestureDetector(
          key: buttonKey,
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: SizedBox(
              width: size,
              height: size,
              child: LiquidGlass(
                blur: blur,
                borderRadius: BorderRadius.circular(size / 2),
                tint: tint,
                boxShadow: boxShadow,
                child: Center(
                  child: Icon(icon, color: iconColor, size: iconSize),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// When set, renders a solid semantic circle (e.g. red for End) instead of
  /// glass so vivid, irreversible actions stay unmistakable.
  final Color? color;

  /// Toggled-on state (muted, camera off). The glass inverts to a bright solid
  /// fill with a dark glyph so the active state reads at a glance.
  final bool active;
  final Key? buttonKey;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.active = false,
    this.buttonKey,
  });

  @override
  Widget build(BuildContext context) {
    const double size = 60;
    final tint = active ? Colors.white : color ?? Colors.white;
    final iconColor = active ? Colors.black87 : Colors.white;
    final shadowColor =
        color?.withValues(alpha: 0.42) ?? const Color(0x38000000);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _GlassCircleButton(
          buttonKey: buttonKey,
          tooltip: label,
          icon: icon,
          iconColor: iconColor,
          onTap: onTap,
          size: size,
          iconSize: 26,
          tint: tint,
          boxShadow: [
            BoxShadow(
              color: shadowColor,
              blurRadius: color == null ? 18 : 22,
              spreadRadius: color == null ? 0 : -2,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }
}

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

class _MinimizedCallOverlay extends StatelessWidget {
  const _MinimizedCallOverlay();

  @override
  Widget build(BuildContext context) {
    final cp = context.watch<CallProvider>();
    final session = cp.session;
    if (session == null) return const SizedBox.shrink();
    final name = session.remoteUsername ?? 'Unknown';
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(
          left: 12,
          top: kToolbarHeight,
          right: 12,
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: GestureDetector(
            key: const Key('minimized-call-overlay'),
            behavior: HitTestBehavior.opaque,
            onTap: () => cp.setCallMinimized(false),
            child: LiquidGlass.capsule(
              blur: 28,
              tint: scheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 22,
                  spreadRadius: -4,
                  offset: const Offset(0, 10),
                ),
              ],
              child: SizedBox(
                height: CallProvider.minimizedCallBarHeight,
                width: double.infinity,
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    _GlassCircleButton(
                      buttonKey: const Key('expand-call-button'),
                      tooltip: 'Expand call',
                      icon: Icons.open_in_full,
                      iconColor: scheme.onSurface,
                      onTap: () => cp.setCallMinimized(false),
                      size: 40,
                      iconSize: 20,
                      blur: 22,
                      tint: Colors.white,
                      boxShadow: const [],
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '$name · ${cp.callStatusText}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    _GlassCircleButton(
                      tooltip: 'End call',
                      icon: Icons.call_end,
                      iconColor: Colors.white,
                      onTap: cp.hangup,
                      size: 40,
                      iconSize: 21,
                      blur: 22,
                      tint: _callEndColor,
                      boxShadow: [
                        BoxShadow(
                          color: _callEndColor.withValues(alpha: 0.34),
                          blurRadius: 16,
                          spreadRadius: -3,
                          offset: const Offset(0, 7),
                        ),
                      ],
                    ),
                    const SizedBox(width: 8),
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
    final initial = (incoming.remoteUsername?.isNotEmpty ?? false)
        ? incoming.remoteUsername!.substring(0, 1).toUpperCase()
        : '?';

    return Material(
      type: MaterialType.transparency,
      child: GlassSurface(
        blur: 30,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
            child: Column(
              children: [
                const Spacer(),
                CircleAvatar(
                  radius: 64,
                  backgroundImage: avatarUrl != null
                      ? CachedNetworkImageProvider(
                          ApiConfig.resolveMedia(avatarUrl),
                        )
                      : null,
                  child: avatarUrl == null
                      ? Text(initial, style: const TextStyle(fontSize: 48))
                      : null,
                ),
                const SizedBox(height: 20),
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  kind,
                  style: TextStyle(
                    fontSize: 15,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CallAction(
                      icon: Icons.call_end,
                      label: 'Decline',
                      color: _callEndColor,
                      onTap: cp.rejectIncomingCall,
                    ),
                    _CallAction(
                      icon: Icons.close,
                      label: 'Dismiss',
                      color: _callDismissColor,
                      iconColor: Colors.black87,
                      onTap: cp.dismissIncomingCall,
                    ),
                    _CallAction(
                      icon: incoming.isVideo ? Icons.videocam : Icons.call,
                      label: 'Answer',
                      color: _callAnswerColor,
                      onTap: cp.acceptIncomingCall,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
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
  final Color iconColor;
  final VoidCallback onTap;

  const _CallAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.iconColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _GlassCircleButton(
          tooltip: label,
          icon: icon,
          iconColor: iconColor,
          onTap: onTap,
          size: 66,
          iconSize: 30,
          blur: 28,
          tint: color,
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.36),
              blurRadius: 22,
              spreadRadius: -3,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}
