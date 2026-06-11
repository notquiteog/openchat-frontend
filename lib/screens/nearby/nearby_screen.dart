import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/chat_provider.dart';
import '../../services/mesh/mesh_platform.dart';
import '../../services/mesh/mesh_session.dart';
import '../../services/mesh/nearby_mesh_service.dart';
import '../../services/secure_storage_service.dart';
import '../../widgets/glass.dart';

/// Nearby (offline mesh DMs over BLE).
///
/// The radio runs ONLY while this screen is open: no background beaconing,
/// no tracking beacon. Advertising carries a random session tag; identity is
/// proven inside the signed handshake after connecting. Messages written in
/// a DM while offline queue as usual — this screen delivers that queue to
/// the verified peer over BLE (live, as you type new ones) and receives
/// theirs into the same DM.
class NearbyScreen extends StatefulWidget {
  const NearbyScreen({super.key});

  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen> {
  NearbyMeshService? _mesh;
  ChatProvider? _chat;

  @override
  void initState() {
    super.initState();
    if (!NearbyMeshService.isSupported) return;
    final chat = context.read<ChatProvider>();
    _chat = chat;
    final mesh = NearbyMeshService(
      storage: context.read<SecureStorageService>(),
      onEnvelope: (envelope, fingerprint) =>
          chat.ingestMeshMessage(envelope, fingerprint),
      envelopesForPeer: chat.meshEnvelopesForFingerprint,
      contactNameForFingerprint: (fingerprint) {
        final convID = chat.dmConversationIdForFingerprint(fingerprint);
        if (convID == null) return null;
        final conv = chat.conversations.where((c) => c.id == convID).firstOrNull;
        return conv?.displayName('');
      },
    );
    _mesh = mesh;
    mesh.addListener(_onMeshChanged);
    // Live delivery: a message queued in any DM while this screen is open
    // re-drains to whoever is connected and verified.
    chat.addListener(_onChatChanged);
    mesh.start();
  }

  void _onMeshChanged() {
    if (mounted) setState(() {});
  }

  void _onChatChanged() => _mesh?.notifyOutboxMaybeChanged();

  @override
  void dispose() {
    // Foreground-only guarantee: leaving the screen silences the radio.
    _chat?.removeListener(_onChatChanged);
    _mesh?.removeListener(_onMeshChanged);
    _mesh?.dispose();
    super.dispose();
  }

  void _showPrivacyInfo() {
    GlassDialog.show(
      context: context,
      title: 'How Nearby protects you',
      message:
          'The radio is on only while this screen is open — never in the '
          'background. The Bluetooth beacon carries a random session tag, '
          'not your identity. After two devices connect, each proves its '
          'PGP key with a signed challenge before a single message moves, '
          'and messages stay end-to-end encrypted exactly as they are '
          'online.',
      actions: [
        GlassDialogAction(
          label: 'OK',
          isPrimary: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mesh = _mesh;
    final peers = mesh?.peers ?? const <NearbyPeer>[];
    final searching = mesh != null && mesh.isRunning && mesh.error == null;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: const Text('Nearby'),
        actions: [
          IconButton(
            tooltip: 'About Nearby privacy',
            icon: const Icon(Icons.lock_outline_rounded),
            onPressed: _showPrivacyInfo,
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
          16,
          MediaQuery.paddingOf(context).bottom + 16,
        ),
        children: [
          _RadarHero(
            active: searching,
            peerCount: peers.length,
          ),
          const SizedBox(height: 14),
          if (mesh != null && mesh.isRunning) _statusChips(mesh),
          const SizedBox(height: 14),
          Text(
            'Exchange queued messages with contacts over Bluetooth — no '
            'internet needed. Active only while this screen is open. Write '
            'messages in the chat as usual; they deliver here the moment '
            'the contact is in range.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
          if (NearbyMeshService.role == MeshRole.centralOnly) ...[
            const SizedBox(height: 8),
            Text(
              'Linux can search but cannot be discovered — keep the Nearby '
              'screen open on the other device (Android, Windows, macOS, or '
              'iOS) so this one can find it.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (!NearbyMeshService.isSupported)
            const GlassListTile(
              leading: Icon(Icons.bluetooth_disabled_rounded),
              title: Text('Not available'),
              subtitle: Text(
                'Nearby mesh needs a Bluetooth LE radio — it is not '
                'available in web builds.',
              ),
            )
          else if (mesh?.error != null)
            GlassListTile(
              leading: Icon(
                Icons.error_outline_rounded,
                color: theme.colorScheme.error,
              ),
              title: const Text('Could not start'),
              subtitle: Text(mesh!.error!),
              trailing: IconButton(
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () => mesh.start(),
              ),
            )
          else if (peers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text(
                  'No one in range yet.\nBoth devices need this screen open.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
            )
          else
            for (final peer in peers)
              _PeerCard(
                key: ValueKey(peer.linkId),
                peer: peer,
                onDeliver: () => mesh!.deliverQueuedTo(peer),
              ),
        ],
      ),
    );
  }

  Widget _statusChips(NearbyMeshService mesh) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        GlassChip(
          label: 'Scanning',
          icon: const Icon(Icons.radar_rounded),
        ),
        GlassChip(
          label: mesh.isDiscoverable ? 'Discoverable' : 'Not discoverable',
          icon: Icon(
            mesh.isDiscoverable
                ? Icons.wifi_tethering_rounded
                : Icons.wifi_tethering_off_rounded,
          ),
        ),
        if (mesh.peers.isNotEmpty)
          GlassChip(
            label:
                '${mesh.peers.length} ${mesh.peers.length == 1 ? 'device' : 'devices'}',
            icon: const Icon(Icons.devices_rounded),
          ),
      ],
    );
  }
}

// ── Radar hero ───────────────────────────────────────────────────────────────

/// iOS-26-style sonar: breathing concentric rings and a rotating sweep
/// around a glass Bluetooth core. Pure Flutter painting — safe to layer with
/// glass (no platform textures underneath).
class _RadarHero extends StatefulWidget {
  const _RadarHero({required this.active, required this.peerCount});

  final bool active;
  final int peerCount;

  @override
  State<_RadarHero> createState() => _RadarHeroState();
}

class _RadarHeroState extends State<_RadarHero>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _RadarHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: SizedBox(
        height: 190,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) => CustomPaint(
            painter: _RadarPainter(
              progress: _controller.value,
              color: scheme.primary,
              active: widget.active,
              blips: widget.peerCount,
            ),
            child: child,
          ),
          child: Center(
            child: GlassCircleIconButton(
              onPressed: null,
              tooltip: widget.active ? 'Searching' : 'Idle',
              size: 58,
              icon: Icon(
                widget.active
                    ? Icons.bluetooth_searching_rounded
                    : Icons.bluetooth_disabled_rounded,
                color: scheme.primary,
                size: 26,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.progress,
    required this.color,
    required this.active,
    required this.blips,
  });

  final double progress;
  final Color color;
  final bool active;
  final int blips;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.height / 2 - 4;

    // Static guide rings.
    final guide = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.10);
    for (var i = 1; i <= 3; i++) {
      canvas.drawCircle(center, maxRadius * i / 3, guide);
    }

    if (!active) return;

    // Two breathing pulses, half a cycle apart, fading as they expand.
    for (final phase in [progress, (progress + 0.5) % 1.0]) {
      final pulse = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color.withValues(alpha: 0.30 * (1 - phase));
      canvas.drawCircle(center, 30 + (maxRadius - 30) * phase, pulse);
    }

    // Rotating sweep: a soft gradient wedge, like a sonar trace.
    final angle = progress * 2 * math.pi;
    final sweep = Paint()
      ..shader = SweepGradient(
        colors: [
          color.withValues(alpha: 0.0),
          color.withValues(alpha: 0.16),
        ],
        stops: const [0.72, 1.0],
        startAngle: 0,
        endAngle: 2 * math.pi,
        transform: GradientRotation(angle),
      ).createShader(Rect.fromCircle(center: center, radius: maxRadius));
    canvas.drawCircle(center, maxRadius, sweep);

    // One blip per connected peer, parked on the rings at stable angles.
    final blip = Paint()..color = color.withValues(alpha: 0.85);
    for (var i = 0; i < blips; i++) {
      final a = -math.pi / 2 + i * 2 * math.pi / math.max(blips, 3);
      final r = maxRadius * (i.isEven ? 2 : 2.6) / 3;
      canvas.drawCircle(
        center + Offset(math.cos(a) * r, math.sin(a) * r),
        3.5,
        blip,
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.progress != progress ||
      old.active != active ||
      old.blips != blips ||
      old.color != color;
}

// ── Peer card ────────────────────────────────────────────────────────────────

class _PeerCard extends StatelessWidget {
  const _PeerCard({super.key, required this.peer, required this.onDeliver});

  final NearbyPeer peer;
  final VoidCallback onDeliver;

  String _shortFingerprint(String? fp) {
    if (fp == null || fp.length < 16) return fp ?? '';
    final tail = fp.substring(fp.length - 16);
    return tail
        .replaceAllMapped(RegExp('....'), (m) => '${m.group(0)} ')
        .trim();
  }

  (IconData, Color?, String) _status(ThemeData theme) {
    return switch (peer.state) {
      MeshSessionState.authenticated when peer.matchedContactName != null => (
          Icons.verified_user_rounded,
          Colors.green,
          'Verified contact',
        ),
      MeshSessionState.authenticated => (
          Icons.help_outline_rounded,
          Colors.amber,
          'Key verified, but not a contact — compare fingerprints in person',
        ),
      MeshSessionState.failed => (
          Icons.gpp_bad_rounded,
          theme.colorScheme.error,
          'Verification failed: ${peer.session.failure ?? 'unknown'}',
        ),
      _ => (
          Icons.bluetooth_searching_rounded,
          null,
          'Verifying identity…',
        ),
    };
  }

  IconData? _signalIcon() {
    final rssi = peer.rssi;
    if (rssi == null) return null;
    if (rssi >= -60) return Icons.signal_cellular_alt_rounded;
    if (rssi >= -75) return Icons.signal_cellular_alt_2_bar_rounded;
    return Icons.signal_cellular_alt_1_bar_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, iconColor, status) = _status(theme);
    final title = peer.matchedContactName ??
        (peer.advertisedName?.isNotEmpty == true
            ? peer.advertisedName!
            : 'Nearby device');
    final signalIcon = _signalIcon();
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - t)),
          child: child,
        ),
      ),
      child: GlassCard(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PeerAvatar(title: title, accent: iconColor ?? theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: theme.textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (signalIcon != null) ...[
                        Icon(signalIcon, size: 15, color: muted),
                        const SizedBox(width: 4),
                      ],
                      Icon(icon, size: 17, color: iconColor),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    status,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                  if (peer.fingerprint != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      _shortFingerprint(peer.fingerprint),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        letterSpacing: 0.5,
                        color: muted,
                      ),
                    ),
                  ],
                  if (peer.sentCount > 0 ||
                      peer.receivedCount > 0 ||
                      peer.rejectedCount > 0) ...[
                    const SizedBox(height: 8),
                    _statsRow(theme, muted),
                  ],
                ],
              ),
            ),
            if (peer.session.authenticated &&
                peer.matchedContactName != null) ...[
              const SizedBox(width: 10),
              GlassCircleIconButton(
                onPressed: onDeliver,
                tooltip: 'Deliver queued messages',
                size: 40,
                icon: Icon(
                  Icons.send_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statsRow(ThemeData theme, Color muted) {
    Widget stat(IconData icon, String label, {Color? color}) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color ?? muted),
            const SizedBox(width: 3),
            Text(
              label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontSize: 11.5, color: color ?? muted),
            ),
          ],
        );
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        if (peer.sentCount > 0)
          stat(Icons.north_rounded, 'Sent ${peer.sentCount}'),
        if (peer.confirmedCount > 0)
          stat(
            Icons.done_all_rounded,
            'Confirmed ${peer.confirmedCount}',
            color: Colors.green,
          ),
        if (peer.receivedCount > 0)
          stat(Icons.south_rounded, 'Received ${peer.receivedCount}'),
        if (peer.rejectedCount > 0)
          stat(
            Icons.block_rounded,
            'Refused ${peer.rejectedCount}',
            color: theme.colorScheme.error,
          ),
      ],
    );
  }
}

class _PeerAvatar extends StatelessWidget {
  const _PeerAvatar({required this.title, required this.accent});

  final String title;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final initial = title.isEmpty ? '?' : title.characters.first.toUpperCase();
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.55),
            accent.withValues(alpha: 0.25),
          ],
        ),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}
