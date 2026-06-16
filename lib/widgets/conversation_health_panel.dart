import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/conversation.dart';
import '../models/key_trust_pin.dart';
import '../services/secure_storage_service.dart';
import 'glass.dart';

/// Per-conversation security "health" panel — makes the encryption model legible:
/// encryption mode, forward secrecy, metadata exposure, per-member key
/// verification, and key-expiry warnings. Read-only aggregation of existing data.
Future<void> showConversationHealth(
  BuildContext context, {
  required Conversation conversation,
  required String currentUserId,
}) async {
  final pins = await context.read<SecureStorageService>().getKeyTrustPins();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ConversationHealthSheet(
      conversation: conversation,
      currentUserId: currentUserId,
      pins: pins,
    ),
  );
}

class _ConversationHealthSheet extends StatelessWidget {
  final Conversation conversation;
  final String currentUserId;
  final Map<String, KeyTrustPin> pins;

  const _ConversationHealthSheet({
    required this.conversation,
    required this.currentUserId,
    required this.pins,
  });

  @override
  Widget build(BuildContext context) {
    final mode = conversation.encryptionMode;
    final others = conversation.members
        .where((m) => m.userId != currentUserId)
        .toList();
    final verified = others.where((m) => pins.containsKey(m.userId)).length;
    final expired = others.where((m) => m.user?.isKeyExpired ?? false).length;

    final (fsLabel, fsColor) = switch (mode) {
      EncryptionMode.mls => ('Full — MLS ratchet', Colors.green),
      EncryptionMode.pgp => ('Limited — PGP', Colors.orange),
      EncryptionMode.plaintext => ('None', Colors.red),
    };

    return GlassBottomSheetFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const GlassSheetGrabber(),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 8, 4, 12),
            child: Text(
              'Conversation health',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          _row(
            icon: Icons.lock_outline,
            label: 'Encryption',
            value: mode.shortLabel,
            color: mode.isEncrypted ? Colors.green : Colors.red,
          ),
          _row(
            icon: Icons.fast_rewind_outlined,
            label: 'Forward secrecy',
            value: fsLabel,
            color: fsColor,
          ),
          _row(
            icon: Icons.visibility_off_outlined,
            label: 'Metadata exposure',
            value: mode.isEncrypted
                ? 'Minimal — sealed sender'
                : 'Server-readable',
            color: mode.isEncrypted ? Colors.green : Colors.orange,
          ),
          if (conversation.isGroup || conversation.isChannel)
            _row(
              icon: conversation.isWebOfTrust
                  ? Icons.hub_outlined
                  : Icons.public,
              label: 'Membership',
              value: conversation.isWebOfTrust ? 'Web of trust' : 'Open',
              color: conversation.isWebOfTrust ? Colors.green : Colors.orange,
            ),
          if (others.isNotEmpty)
            _row(
              icon: Icons.verified_user_outlined,
              label: 'Verified members',
              value: '$verified / ${others.length}',
              color: verified == others.length ? Colors.green : Colors.orange,
            ),
          if (expired > 0)
            _row(
              icon: Icons.warning_amber_rounded,
              label: 'Expired keys',
              value: '$expired',
              color: Colors.red,
            ),
          if (others.isNotEmpty && verified < others.length) ...[
            const SizedBox(height: 8),
            Text(
              'Unverified members',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            for (final m in others.where((m) => !pins.containsKey(m.userId)))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('@${m.user?.username ?? m.userId}'),
              ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
          Text(
            value,
            style: TextStyle(fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}
