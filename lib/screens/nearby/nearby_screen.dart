import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/chat_provider.dart';
import '../../services/mesh/mesh_session.dart';
import '../../services/mesh/nearby_mesh_service.dart';
import '../../services/secure_storage_service.dart';
import '../../widgets/glass.dart';

/// Nearby (offline mesh DMs over BLE, Android-only MVP).
///
/// The radio runs ONLY while this screen is open: no background beaconing,
/// no tracking beacon. Advertising carries a random session tag; identity is
/// proven inside the encrypted handshake after connecting. Messages written
/// in a DM while offline queue as usual — this screen delivers that queue to
/// the verified peer over BLE, and receives theirs into the same DM.
class NearbyScreen extends StatefulWidget {
  const NearbyScreen({super.key});

  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen> {
  NearbyMeshService? _mesh;

  @override
  void initState() {
    super.initState();
    if (!NearbyMeshService.isSupported) return;
    final chat = context.read<ChatProvider>();
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
    mesh.start();
  }

  void _onMeshChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    // Foreground-only guarantee: leaving the screen silences the radio.
    _mesh?.removeListener(_onMeshChanged);
    _mesh?.dispose();
    super.dispose();
  }

  String _shortFingerprint(String? fp) {
    if (fp == null || fp.length < 16) return fp ?? '';
    final tail = fp.substring(fp.length - 16);
    return tail.replaceAllMapped(
      RegExp('....'),
      (m) => '${m.group(0)} ',
    ).trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mesh = _mesh;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Nearby')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
          16,
          16,
        ),
        children: [
          Text(
            'Exchange queued messages with contacts over Bluetooth — no '
            'internet needed. Active only while this screen is open. Write '
            'messages in the chat as usual; they deliver here when the '
            'contact is in range.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
          const SizedBox(height: 16),
          if (!NearbyMeshService.isSupported)
            GlassListTile(
              leading: const Icon(Icons.bluetooth_disabled_rounded),
              title: const Text('Not available'),
              subtitle: const Text(
                'Nearby mesh is Android-only in this release.',
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
          else ...[
            Row(
              children: [
                GlassProgressIndicator.circular(size: 14),
                const SizedBox(width: 10),
                Text(
                  'Looking for nearby devices…',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if ((mesh?.peers ?? const []).isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
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
              for (final peer in mesh!.peers) _peerTile(theme, mesh, peer),
          ],
        ],
      ),
    );
  }

  Widget _peerTile(ThemeData theme, NearbyMeshService mesh, NearbyPeer peer) {
    final (icon, status) = switch (peer.state) {
      MeshSessionState.authenticated when peer.matchedContactName != null => (
          Icons.verified_user_rounded,
          'Verified contact',
        ),
      MeshSessionState.authenticated => (
          Icons.help_outline_rounded,
          'Key verified, but not a contact — compare fingerprints in person',
        ),
      MeshSessionState.failed => (
          Icons.gpp_bad_rounded,
          'Verification failed: ${peer.session.failure ?? 'unknown'}',
        ),
      _ => (Icons.bluetooth_searching_rounded, 'Verifying identity…'),
    };
    final title = peer.matchedContactName ??
        (peer.advertisedName?.isNotEmpty == true
            ? peer.advertisedName!
            : 'Nearby device');
    return GlassListTile(
      leading: Icon(
        icon,
        color: peer.state == MeshSessionState.failed
            ? theme.colorScheme.error
            : null,
      ),
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status),
          if (peer.fingerprint != null)
            Text(
              _shortFingerprint(peer.fingerprint),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          if (peer.deliveredCount > 0 || peer.receivedCount > 0)
            Text(
              'Delivered ${peer.deliveredCount} · received ${peer.receivedCount}',
            ),
        ],
      ),
      trailing: peer.session.authenticated && peer.matchedContactName != null
          ? IconButton(
              tooltip: 'Deliver queued messages',
              icon: const Icon(Icons.send_rounded),
              onPressed: () => mesh.deliverQueuedTo(peer),
            )
          : null,
    );
  }
}
