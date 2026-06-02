import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../../config/api_config.dart';
import '../../providers/call_provider.dart';
import '../../services/call_service.dart';
import '../../widgets/glass.dart';

/// Full-screen audio/video call UI.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  bool _micMuted = false;
  bool _cameraOff = false;
  bool _renderersReady = false;

  @override
  void initState() {
    super.initState();
    _initRenderers();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<CallProvider>().refreshAudioOutputs();
    });
  }

  Future<void> _initRenderers() async {
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();
    } catch (_) {
      if (mounted) setState(() => _renderersReady = false);
      return;
    }
    if (!mounted) return;
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
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  void _toggleMic() {
    final callProvider = context.read<CallProvider>();
    setState(() => _micMuted = !_micMuted);
    callProvider.setMicMuted(_micMuted);
  }

  void _toggleCamera() {
    final callProvider = context.read<CallProvider>();
    setState(() => _cameraOff = !_cameraOff);
    callProvider.setCameraEnabled(!_cameraOff);
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
    final outputs = cp.audioOutputs;
    if (outputs.isEmpty) return;
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

    // Keep renderers in sync whenever streams change (guard: must be initialized first)
    if (_renderersReady) {
      if (callProvider.localStream != null) {
        _localRenderer.srcObject = callProvider.localStream;
      }
      if (callProvider.remoteStream != null) {
        _remoteRenderer.srcObject = callProvider.remoteStream;
      }
    }

    final isVideo = session.isVideo;
    final statusText = callProvider.callStatusText;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Audio-only calls still attach the remote stream to a renderer so
          // platforms that route audio through RTCVideoRenderer will play it.
          if (!isVideo && _renderersReady)
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
          if (isVideo && _renderersReady)
            Positioned.fill(
              child: RTCVideoView(
                _remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
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
          if (isVideo && _renderersReady)
            Positioned(
              top: 60,
              right: 16,
              width: 100,
              height: 140,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: RTCVideoView(
                  _localRenderer,
                  mirror: true,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
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
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                    Positioned(
                      left: 8,
                      child: IconButton(
                        key: const Key('minimize-call-button'),
                        tooltip: 'Minimize call',
                        onPressed: _minimize,
                        icon: const Icon(Icons.expand_more,
                            color: Colors.white70),
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
                      icon: _micMuted ? Icons.mic_off : Icons.mic,
                      label: _micMuted ? 'Unmute' : 'Mute',
                      onTap: _toggleMic,
                    ),

                    _ControlButton(
                      icon: Icons.volume_up,
                      label: 'Audio',
                      onTap: _pickAudioOutput,
                    ),

                    // Camera toggle (video calls only)
                    if (isVideo)
                      _ControlButton(
                        icon: _cameraOff ? Icons.videocam_off : Icons.videocam,
                        label: _cameraOff ? 'Camera on' : 'Camera off',
                        onTap: _toggleCamera,
                      ),

                    // Hang up
                    _ControlButton(
                      icon: Icons.call_end,
                      label: 'End',
                      onTap: _hangup,
                      color: Colors.red,
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

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color ?? Colors.white24,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 6),
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
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
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(top: kToolbarHeight),
        child: Align(
          alignment: Alignment.topCenter,
          child: Material(
            key: const Key('minimized-call-overlay'),
            color: Theme.of(context).colorScheme.surface,
            elevation: 3,
            child: InkWell(
              onTap: () => cp.setCallMinimized(false),
              child: SizedBox(
                height: 48,
                width: double.infinity,
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    IconButton(
                      key: const Key('expand-call-button'),
                      tooltip: 'Expand call',
                      onPressed: () => cp.setCallMinimized(false),
                      icon: const Icon(Icons.open_in_full),
                    ),
                    Expanded(
                      child: Text(
                        '$name · ${cp.callStatusText}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      tooltip: 'End call',
                      onPressed: cp.hangup,
                      icon: const Icon(Icons.call_end, color: Colors.red),
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
    final kind =
        incoming.isVideo ? 'Incoming video call' : 'Incoming voice call';
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
                          ApiConfig.resolveMedia(avatarUrl))
                      : null,
                  child: avatarUrl == null
                      ? Text(initial, style: const TextStyle(fontSize: 48))
                      : null,
                ),
                const SizedBox(height: 20),
                Text(name,
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(kind,
                    style: TextStyle(
                        fontSize: 15,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CallAction(
                      icon: Icons.call_end,
                      label: 'Decline',
                      color: Colors.red,
                      onTap: cp.rejectIncomingCall,
                    ),
                    _CallAction(
                      icon: Icons.close,
                      label: 'Dismiss',
                      color: Colors.grey,
                      onTap: cp.dismissIncomingCall,
                    ),
                    _CallAction(
                      icon: incoming.isVideo ? Icons.videocam : Icons.call,
                      label: 'Answer',
                      color: Colors.green,
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
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 30),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}
