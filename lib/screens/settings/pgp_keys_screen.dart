import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../crypto/pgp_service.dart';
import '../../providers/auth_provider.dart';
import '../../providers/key_provider.dart';
import '../../services/api_service.dart';
import '../../services/secure_storage_service.dart';
import '../../utils/identity_qr.dart';
import '../../widgets/glass.dart';
import 'identity_qr_scanner_screen.dart';

class PgpKeysScreen extends StatelessWidget {
  const PgpKeysScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final keys = context.watch<KeyProvider>();
    final user = context.watch<AuthProvider>().currentUser;
    final expiresAt = user?.publicKeyExpiresAt;
    final isExpired = user?.isKeyExpired ?? false;
    final hasFiniteExpiry = expiresAt != null;

    final scheme = Theme.of(context).colorScheme;

    final Color statusColor;
    final IconData statusIcon;
    final String statusTitle;
    if (isExpired) {
      statusColor = scheme.error;
      statusIcon = Icons.lock_clock;
      statusTitle = 'Active Key — EXPIRED';
    } else if (keys.hasKey) {
      statusColor = Colors.green;
      statusIcon = Icons.verified_user;
      statusTitle = 'Active Key Pair';
    } else {
      statusColor = Colors.orange;
      statusIcon = Icons.warning_amber;
      statusTitle = 'No Key Found';
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('PGP Key Management')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
          16,
          MediaQuery.paddingOf(context).bottom + 16,
        ),
        children: [
          GlassCard(
            tint: isExpired ? scheme.error.withValues(alpha: 0.10) : null,
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: statusColor.withValues(alpha: 0.14),
                      ),
                      child: Icon(statusIcon, size: 18, color: statusColor),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      statusTitle,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: isExpired ? scheme.error : null,
                      ),
                    ),
                  ],
                ),
                if (keys.hasKey && keys.fingerprint != null) ...[
                  const SizedBox(height: 14),
                  _FingerprintDisplay(fingerprint: keys.fingerprint!),
                ],
                if (hasFiniteExpiry) ...[
                  const SizedBox(height: 12),
                  Text(
                    isExpired
                        ? 'Expired on ${expiresAt.toLocal().toString().split(".").first}. '
                              'Until you rotate to a fresh key, you cannot send or receive '
                              'messages and other users will exclude you from group encryption.'
                        : 'Expires on ${expiresAt.toLocal().toString().split(".").first}. '
                              'Rotate before that date to avoid disruption — keys generated '
                              'by OpenChat have no expiry, so this only applies to imported keys.',
                    style: TextStyle(
                      fontSize: 12,
                      color: isExpired ? scheme.error : Colors.orange,
                    ),
                  ),
                ],
                if (!keys.hasKey)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'No PGP key found on this device. '
                      'Import an existing key or generate a new one.',
                      style: TextStyle(color: Colors.orange, fontSize: 13),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          if (keys.hasKey) ...[
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _ActionTile(
                    icon: Icons.copy,
                    title: 'Copy Public Key',
                    subtitle:
                        'Share this with anyone who wants to verify your messages',
                    onTap: () async {
                      final pub = await keys.exportPublicKey();
                      if (pub != null) {
                        await Clipboard.setData(ClipboardData(text: pub));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Public key copied to clipboard'),
                            ),
                          );
                        }
                      }
                    },
                  ),
                  const _PgpDivider(),
                  _ActionTile(
                    icon: Icons.download_outlined,
                    title: 'Export Private Key (Backup)',
                    subtitle: 'Save your private key for use on another device',
                    onTap: () => _showExportPrivateKey(context, keys),
                  ),
                  const _PgpDivider(),
                  _ActionTile(
                    icon: Icons.autorenew,
                    title: 'Rotate PGP Key',
                    subtitle:
                        'Generate and register a new key pair. Back up your old '
                        'private key first — it is needed to read messages sent before rotation.',
                    onTap: () => _showRotateKey(context, keys),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            GlassCard(
              tint: scheme.error.withValues(alpha: 0.06),
              padding: EdgeInsets.zero,
              child: _ActionTile(
                icon: Icons.delete_forever,
                title: 'Delete Local Keys',
                subtitle:
                    'WARNING: Permanently removes keys from this device. '
                    'Encrypted messages will become unreadable.',
                isDestructive: true,
                onTap: () => _confirmDeleteKeys(context, keys),
              ),
            ),
            const SizedBox(height: 8),
          ],

          GlassCard(
            padding: EdgeInsets.zero,
            child: _ActionTile(
              icon: Icons.upload_outlined,
              title: 'Import Key Pair',
              subtitle:
                  'Import an existing PGP key pair from clipboard or file',
              onTap: () => _showImportKeys(context, keys),
            ),
          ),
          const SizedBox(height: 8),
          GlassCard(
            padding: EdgeInsets.zero,
            child: _ActionTile(
              icon: Icons.qr_code_scanner_rounded,
              title: 'Scan Fingerprint QR',
              subtitle:
                  'Scan another person’s OpenChat QR to validate their identity',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const IdentityQrScannerScreen(),
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),
          GlassCard(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.primary.withValues(alpha: 0.12),
                  ),
                  child: Icon(
                    Icons.info_outline,
                    size: 17,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'About PGP Encryption',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'OpenChat uses OpenPGP (RFC 4880) for end-to-end encryption. '
                        'Your private key is stored only on this device using the system keychain. '
                        'It is never transmitted to any server.\n\n'
                        'All messages are encrypted using your recipients\' public keys before '
                        'being sent. Only the intended recipients can decrypt them.',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurface.withValues(alpha: 0.70),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _showExportPrivateKey(
    BuildContext context,
    KeyProvider keys,
  ) async {
    // Require biometric if enabled. Route through KeyProvider so platform
    // exceptions are caught consistently on iOS and Android.
    if (await context.read<SecureStorageService>().getBiometricEnabled()) {
      final ok = await keys.authenticateAndUnlockKey();
      if (!ok) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Biometric authentication failed')),
          );
        }
        return;
      }
    }

    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Export Private Key'),
        content: const Text(
          'Your private key will be copied to the clipboard in plain text.\n\n'
          'SECURITY WARNING: Anyone with your private key can decrypt your messages '
          'and impersonate you. Store it securely and never share it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Export'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      final priv = await keys.exportPrivateKey();
      if (priv != null) {
        await Clipboard.setData(ClipboardData(text: priv));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Private key copied. Store it very safely.'),
            ),
          );
        }
      }
    }
  }

  Future<void> _confirmDeleteKeys(
    BuildContext context,
    KeyProvider keys,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text(
          'Delete Local Keys?',
          style: TextStyle(color: Colors.red),
        ),
        content: const Text(
          'This will permanently delete your PGP keys from this device.\n\n'
          'ALL encrypted messages will become permanently unreadable.\n\n'
          'Make sure you have a backup before proceeding.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await keys.deleteLocalKeys();
    }
  }

  Future<void> _showRotateKey(BuildContext context, KeyProvider keys) async {
    final api = context.read<ApiService>();
    final passCtrl = TextEditingController();
    KeyType selectedKeyType = KeyType.defaultType;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => GlassAlertDialog(
          title: const Text('Rotate PGP Key?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '• New messages use your new key\n'
                '• Messages sent before rotation require your old key backup\n'
                '• Others\' key caches refresh within 24 hours\n\n'
                'Export and save your current private key before continuing.',
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<KeyType>(
                initialValue: selectedKeyType,
                decoration: const InputDecoration(
                  labelText: 'New key algorithm',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final keyType in KeyType.accountCreationOptions)
                    DropdownMenuItem(
                      value: keyType,
                      child: Text(keyType.dropdownLabel),
                    ),
                ],
                onChanged: (v) => setDialogState(() => selectedKeyType = v!),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Passphrase for new key (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.orange),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Rotate'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true && context.mounted) {
      final ok = await keys.rotateKey(
        api: api,
        passphrase: passCtrl.text,
        keyType: selectedKeyType,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ok
                  ? 'Key rotated. Back up your new private key!'
                  : 'Rotation failed — check your connection and try again',
            ),
            backgroundColor: ok ? Colors.green : Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _showImportKeys(BuildContext context, KeyProvider keys) async {
    final privateCtrl = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Import Private Key'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Paste your PGP private key. Your public key is derived from it '
                'automatically — you don\'t need to paste it separately.',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: privateCtrl,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText:
                      'PGP Private Key (-----BEGIN PGP PRIVATE KEY BLOCK-----)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final ok = await keys.importKeyPair(
                privateKeyArmored: privateCtrl.text.trim(),
              );
              if (ctx.mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(
                    content: Text(
                      ok ? 'Key imported successfully' : 'Invalid private key',
                    ),
                  ),
                );
              }
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }
}

class _FingerprintDisplay extends StatelessWidget {
  final String fingerprint;
  const _FingerprintDisplay({required this.fingerprint});

  @override
  Widget build(BuildContext context) {
    final groups = <String>[];
    for (var i = 0; i < fingerprint.length; i += 4) {
      groups.add(
        fingerprint.substring(i, (i + 4).clamp(0, fingerprint.length)),
      );
    }
    final formatted = groups.join(' ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Fingerprint',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: fingerprint));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Fingerprint copied')),
                  );
                },
                child: Text(
                  formatted,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.qr_code, size: 20),
              tooltip: 'Show QR code for out-of-band verification',
              onPressed: () => _showQR(context, fingerprint),
            ),
          ],
        ),
        const Text(
          'Tap fingerprint to copy  •  QR for out-of-band verify',
          style: TextStyle(fontSize: 10, color: Colors.grey),
        ),
      ],
    );
  }

  void _showQR(BuildContext context, String fp) {
    showDialog<void>(
      context: context,
      builder: (_) => GlassAlertDialog(
        title: const Text('Your PGP Fingerprint'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IdentityQrView(data: identityFingerprintQrPayload(fp)),
            const SizedBox(height: 12),
            Text(
              fp
                  .toUpperCase()
                  .replaceAllMapped(RegExp(r'.{4}'), (m) => '${m[0]} ')
                  .trim(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Show this to the other person so they can scan and verify your identity.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool isDestructive;

  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isDestructive ? scheme.error : scheme.primary;
    return GlassListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.12),
        ),
        child: Icon(icon, size: 18, color: color),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: isDestructive ? color : null,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: 12,
          color: scheme.onSurface.withValues(alpha: 0.55),
        ),
      ),
      trailing: Icon(
        Icons.chevron_right,
        size: 18,
        color: scheme.onSurface.withValues(alpha: 0.35),
      ),
      onTap: onTap,
    );
  }
}

class _PgpDivider extends StatelessWidget {
  const _PgpDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 0.5,
      indent: 66,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.10),
    );
  }
}
