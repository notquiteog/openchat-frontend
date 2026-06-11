import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/contact_bundle.dart';
import '../../providers/settings_provider.dart';
import '../../services/mesh/mesh_platform.dart';
import '../../services/mesh/mesh_session.dart';
import '../../services/mesh/nearby_mesh_service.dart';
import '../../utils/identity_qr.dart';
import '../../widgets/glass.dart';

/// Nearby (offline mesh DMs over BLE).
///
/// The radio runs ONLY while this screen is open (or, with the explicit
/// keep-alive opt-in, while the app stays foregrounded): no background
/// beaconing, no tracking beacon. Advertising carries a random session tag;
/// identity is proven inside the signed handshake after connecting.
/// Messages written in a DM while offline queue as usual — the mesh
/// delivers that queue to the verified peer over BLE (live, as you type new
/// ones) and receives theirs into the same DM.
class NearbyScreen extends StatefulWidget {
  const NearbyScreen({super.key});

  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen> {
  NearbyMeshService? _mesh;
  Set<String> _knownLinkIds = {};
  int _pulseToken = 0;

  @override
  void initState() {
    super.initState();
    if (!NearbyMeshService.isSupported) return;
    final mesh = context.read<NearbyMeshService>();
    _mesh = mesh;
    _knownLinkIds = mesh.peers.map((p) => p.linkId).toSet();
    mesh.addListener(_onMeshChanged);
    mesh.attachScreen();
  }

  void _onMeshChanged() {
    if (!mounted) return;
    final mesh = _mesh;
    if (mesh != null) {
      final ids = mesh.peers.map((p) => p.linkId).toSet();
      if (ids.difference(_knownLinkIds).isNotEmpty) {
        // Someone surfaced on the radar: a soft tick + a sonar pulse.
        HapticFeedback.lightImpact();
        _pulseToken++;
      }
      _knownLinkIds = ids;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _mesh?.removeListener(_onMeshChanged);
    // Foreground-only guarantee: without the keep-alive opt-in, leaving the
    // screen silences the radio.
    _mesh?.detachScreen();
    super.dispose();
  }

  void _showPrivacyInfo() {
    GlassDialog.show(
      context: context,
      title: 'How Nearby protects you',
      message:
          'The radio is on only while this screen is open — or, if you '
          'choose, while the app itself is — never in the background. The '
          'Bluetooth beacon carries a random session tag, not your '
          'identity. After two devices connect, each proves its PGP key '
          'with a signed challenge before a single message moves, and '
          'messages stay end-to-end encrypted exactly as they are online.',
      actions: [
        GlassDialogAction(
          label: 'OK',
          isPrimary: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  void _scrollToPeer(int index) {
    final mesh = _mesh;
    if (mesh == null || index < 0 || index >= mesh.peers.length) return;
    final key = GlobalObjectKey('nearby-peer-${mesh.peers[index].linkId}');
    final ctx = key.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.2,
      );
    }
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
            pulseToken: _pulseToken,
            onBlipTap: _scrollToPeer,
          ),
          const SizedBox(height: 14),
          if (mesh != null && mesh.isRunning) ...[
            _statusChips(mesh),
            const SizedBox(height: 12),
            GlassListTile(
              leading: const Icon(Icons.all_inclusive_rounded),
              title: const Text('Keep exchanging while the app is open'),
              subtitle: const Text(
                'Chat elsewhere in the app without dropping nearby links. '
                'Always stops when the app leaves the foreground.',
              ),
              trailing: GlassSwitch(
                value: mesh.keepAliveWhileAppOpen,
                onChanged: (value) => mesh.keepAliveWhileAppOpen = value,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Text(
            'Exchange queued messages with contacts over Bluetooth or your '
            'local network — no internet needed. Write messages in the chat '
            'as usual; they deliver here the moment the contact is in '
            'range.',
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
                key: GlobalObjectKey('nearby-peer-${peer.linkId}'),
                peer: peer,
                onDeliver: () => mesh!.deliverQueuedTo(peer),
                onCompareFingerprints: () =>
                    _showFingerprintSheet(context, mesh!, peer),
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
        if (mesh.lanActive)
          GlassChip(
            label: 'Local network',
            icon: const Icon(Icons.lan_rounded),
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

  /// The in-person verification sheet for a key-verified stranger: both
  /// fingerprints large, a QR of our key for them to scan, and — when their
  /// build shared a user id in the handshake — a save-as-contact action so a
  /// DM can start the moment both come online.
  void _showFingerprintSheet(
    BuildContext context,
    NearbyMeshService mesh,
    NearbyPeer peer,
  ) {
    final peerInfo = peer.session.peer;
    final myFp = mesh.selfFingerprint;
    if (peerInfo == null || myFp == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) => GlassBottomSheetFrame(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: _FingerprintCompareSheet(peer: peerInfo, selfFingerprint: myFp),
      ),
    );
  }
}

class _FingerprintCompareSheet extends StatefulWidget {
  const _FingerprintCompareSheet({
    required this.peer,
    required this.selfFingerprint,
  });

  final MeshPeer peer;
  final String selfFingerprint;

  @override
  State<_FingerprintCompareSheet> createState() =>
      _FingerprintCompareSheetState();
}

class _FingerprintCompareSheetState extends State<_FingerprintCompareSheet> {
  bool _saved = false;

  Future<void> _saveContact() async {
    final peer = widget.peer;
    await context.read<SettingsProvider>().upsertPrivateContact(
          ContactBundle(
            userId: peer.userId,
            displayName: peer.displayName.isNotEmpty
                ? peer.displayName
                : 'Nearby contact',
            publicKey: peer.publicKeyArmored,
            keyFingerprint: peer.fingerprint,
            safetyNumber: peer.fingerprint,
            mailboxBootstrap: {
              'type': 'openchat_user',
              'user_id': peer.userId,
              'public_key_endpoint':
                  '/api/v1/users/${peer.userId}/public-key',
            },
            addedAt: DateTime.now(),
          ),
        );
    if (mounted) setState(() => _saved = true);
  }

  Widget _fingerprintBlock(
    ThemeData theme,
    String label,
    String fingerprint,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 4),
        SelectableText(
          formatIdentityFingerprint(fingerprint),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            letterSpacing: 0.5,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peer = widget.peer;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GlassSheetGrabber(),
        const SizedBox(height: 12),
        Text(
          peer.displayName.isNotEmpty ? peer.displayName : 'Nearby device',
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          'This key proved itself cryptographically, but it isn\'t one of '
          'your contacts yet. Read the fingerprints aloud to each other — '
          'every group must match.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        _fingerprintBlock(theme, 'Their key', peer.fingerprint),
        const SizedBox(height: 14),
        _fingerprintBlock(theme, 'Your key', widget.selfFingerprint),
        const SizedBox(height: 18),
        Center(
          child: IdentityQrView(
            data: identityFingerprintQrPayload(widget.selfFingerprint),
            size: 180,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'They can scan this to double-check your key.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        if (peer.userId.isNotEmpty)
          GlassButtonWidget(
            onPressed: _saved ? null : _saveContact,
            child: Text(_saved ? 'Saved to contacts' : 'Save as contact'),
          )
        else
          Text(
            'Their app version doesn\'t share a contact id over the mesh — '
            'add them online or by QR instead.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
            textAlign: TextAlign.center,
          ),
      ],
    );
  }
}

// ── Radar hero ───────────────────────────────────────────────────────────────

/// iOS-26-style sonar: breathing concentric rings and a rotating sweep
/// around a glass Bluetooth core. Pure Flutter painting — safe to layer with
/// glass (no platform textures underneath). Blips are tappable and jump to
/// the matching peer card; a discovery fires a one-shot pulse ring.
class _RadarHero extends StatefulWidget {
  const _RadarHero({
    required this.active,
    required this.peerCount,
    required this.pulseToken,
    required this.onBlipTap,
  });

  final bool active;
  final int peerCount;

  /// Increment to fire a one-shot discovery pulse.
  final int pulseToken;
  final ValueChanged<int> onBlipTap;

  @override
  State<_RadarHero> createState() => _RadarHeroState();
}

class _RadarHeroState extends State<_RadarHero> with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
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
    if (widget.pulseToken != oldWidget.pulseToken) {
      _pulse.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _handleTap(TapDownDetails details, Size size) {
    for (var i = 0; i < widget.peerCount; i++) {
      final blip = _RadarPainter.blipOffset(i, widget.peerCount, size);
      if ((details.localPosition - blip).distance <= 18) {
        widget.onBlipTap(i);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: SizedBox(
        height: 190,
        child: LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) =>
                _handleTap(details, constraints.biggest),
            child: AnimatedBuilder(
              animation: Listenable.merge([_controller, _pulse]),
              builder: (context, child) => CustomPaint(
                painter: _RadarPainter(
                  progress: _controller.value,
                  color: scheme.primary,
                  active: widget.active,
                  blips: widget.peerCount,
                  pulse: _pulse.isAnimating ? _pulse.value : null,
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
    this.pulse,
  });

  final double progress;
  final Color color;
  final bool active;
  final int blips;

  /// One-shot discovery pulse progress (null = idle).
  final double? pulse;

  /// Where blip [i] of [blips] sits — shared with the tap hit test.
  static Offset blipOffset(int i, int blips, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.height / 2 - 4;
    final a = -math.pi / 2 + i * 2 * math.pi / math.max(blips, 3);
    final r = maxRadius * (i.isEven ? 2 : 2.6) / 3;
    return center + Offset(math.cos(a) * r, math.sin(a) * r);
  }

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
      final breath = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color.withValues(alpha: 0.30 * (1 - phase));
      canvas.drawCircle(center, 30 + (maxRadius - 30) * phase, breath);
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
      canvas.drawCircle(blipOffset(i, blips, size), 3.5, blip);
    }

    // Discovery pulse: an expanding ring around the newest blip.
    final p = pulse;
    if (p != null && blips > 0) {
      final origin = blipOffset(blips - 1, blips, size);
      canvas.drawCircle(
        origin,
        4 + 22 * p,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: 0.55 * (1 - p)),
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.progress != progress ||
      old.active != active ||
      old.blips != blips ||
      old.pulse != pulse ||
      old.color != color;
}

// ── Peer card ────────────────────────────────────────────────────────────────

class _PeerCard extends StatelessWidget {
  const _PeerCard({
    super.key,
    required this.peer,
    required this.onDeliver,
    required this.onCompareFingerprints,
  });

  final NearbyPeer peer;
  final VoidCallback onDeliver;
  final VoidCallback onCompareFingerprints;

  String _shortFingerprint(String? fp) {
    if (fp == null || fp.length < 16) return fp ?? '';
    final tail = fp.substring(fp.length - 16);
    return tail
        .replaceAllMapped(RegExp('....'), (m) => '${m.group(0)} ')
        .trim();
  }

  bool get _isUnknownVerified =>
      peer.session.authenticated && peer.matchedContactName == null;

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
          'Key verified, but not a contact — tap to compare fingerprints',
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
    if (peer.isLan) return Icons.lan_rounded;
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

    final card = GlassCard(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PeerAvatar(
            title: title,
            accent: iconColor ?? theme.colorScheme.primary,
          ),
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
    );

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
      child: _isUnknownVerified
          ? GestureDetector(onTap: onCompareFingerprints, child: card)
          : card,
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
