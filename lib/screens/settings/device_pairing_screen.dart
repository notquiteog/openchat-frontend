import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../providers/key_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/encrypted_backup_service.dart';
import '../../services/local_private_state_service.dart';
import '../../services/secure_storage_service.dart';
import '../../utils/identity_qr.dart';
import '../../widgets/glass.dart';

enum DevicePairingMode { create, scan }

class DevicePairingScreen extends StatefulWidget {
  final DevicePairingMode initialMode;

  const DevicePairingScreen({
    super.key,
    this.initialMode = DevicePairingMode.create,
  });

  @override
  State<DevicePairingScreen> createState() => _DevicePairingScreenState();
}

class _DevicePairingScreenState extends State<DevicePairingScreen> {
  late DevicePairingMode _mode = widget.initialMode;
  MobileScannerController? _scanner;
  bool _busy = false;
  String? _qrPayload;
  DateTime? _expiresAt;
  String? _status;

  @override
  void initState() {
    super.initState();
    if (_mode == DevicePairingMode.scan) _startScanner();
  }

  @override
  void dispose() {
    _scanner?.dispose();
    super.dispose();
  }

  void _setMode(DevicePairingMode mode) {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _status = null;
    });
    if (mode == DevicePairingMode.scan) {
      _startScanner();
    } else {
      _scanner?.dispose();
      _scanner = null;
    }
  }

  void _startScanner() {
    _scanner ??= MobileScannerController(
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
  }

  Future<void> _createPairingBundle() async {
    final passphrase = await _promptPassphrase(confirm: true);
    if (passphrase == null || !mounted) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final token = _randomToken();
      final tokenHash = _tokenHash(token);
      final storage = context.read<SecureStorageService>();
      final api = context.read<ApiService>();
      final backup = await EncryptedBackupService(
        storage: storage,
        privateState: LocalPrivateStateService(storage: storage),
      ).exportBackup(passphrase: passphrase);
      final expiresAt = await api.createDevicePairingBundle(
        tokenHash: tokenHash,
        encryptedPayload: backup,
      );
      if (!mounted) return;
      setState(() {
        _qrPayload = 'openchat-pair:v1:$token';
        _expiresAt = expiresAt?.toLocal();
        _status = 'Pairing bundle ready';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Pairing failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleScan(BarcodeCapture capture) async {
    if (_busy) return;
    final raw = capture.barcodes
        .map((barcode) => barcode.rawValue)
        .whereType<String>()
        .firstWhere((value) => value.trim().isNotEmpty, orElse: () => '');
    final token = _tokenFromPayload(raw);
    if (token == null) {
      setState(() => _status = 'That QR code is not an OpenChat pairing code');
      return;
    }
    await _scanner?.stop();
    if (!mounted) return;
    final passphrase = await _promptPassphrase(confirm: false);
    if (passphrase == null || !mounted) {
      await _scanner?.start();
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Claiming encrypted bundle';
    });
    try {
      final api = context.read<ApiService>();
      final storage = context.read<SecureStorageService>();
      final keyProvider = context.read<KeyProvider>();
      final settingsProvider = context.read<SettingsProvider>();
      final encrypted = await api.claimDevicePairingBundle(
        tokenHash: _tokenHash(token),
      );
      await EncryptedBackupService(
        storage: storage,
        privateState: LocalPrivateStateService(storage: storage),
      ).importBackup(encodedBackup: encrypted, passphrase: passphrase);
      await keyProvider.load();
      await settingsProvider.reload();
      if (!mounted) return;
      setState(() => _status = 'Device data imported');
    } catch (e) {
      if (mounted) {
        setState(() => _status = 'Import failed: $e');
        await _scanner?.start();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _promptPassphrase({required bool confirm}) async {
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;
    try {
      return showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDlg) => GlassAlertDialog(
            title: Text(confirm ? 'Pairing passphrase' : 'Bundle passphrase'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: first,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Passphrase'),
                ),
                if (confirm) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: second,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Confirm'),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    error!,
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final value = first.text;
                  if (value.trim().length < 12) {
                    setDlg(() => error = 'Use at least 12 characters');
                    return;
                  }
                  if (confirm && value != second.text) {
                    setDlg(() => error = 'Passphrases do not match');
                    return;
                  }
                  Navigator.pop(ctx, value);
                },
                child: const Text('Continue'),
              ),
            ],
          ),
        ),
      );
    } finally {
      first.dispose();
      second.dispose();
    }
  }

  String _randomToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String _tokenHash(String token) =>
      crypto.sha256.convert(utf8.encode(token.trim())).toString();

  String? _tokenFromPayload(String raw) {
    final value = raw.trim();
    const prefix = 'openchat-pair:v1:';
    if (!value.startsWith(prefix)) return null;
    final token = value.substring(prefix.length).trim();
    return token.isEmpty ? null : token;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Link Device')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
          16,
          MediaQuery.paddingOf(context).bottom + 32,
        ),
        children: [
          SegmentedButton<DevicePairingMode>(
            segments: const [
              ButtonSegment(
                value: DevicePairingMode.create,
                icon: Icon(Icons.qr_code_rounded),
                label: Text('Show QR'),
              ),
              ButtonSegment(
                value: DevicePairingMode.scan,
                icon: Icon(Icons.qr_code_scanner_rounded),
                label: Text('Scan QR'),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (value) => _setMode(value.first),
          ),
          const SizedBox(height: 16),
          if (_mode == DevicePairingMode.create) _buildCreate(scheme),
          if (_mode == DevicePairingMode.scan) _buildScan(),
          if (_status != null) ...[
            const SizedBox(height: 12),
            GlassCard(child: Text(_status!)),
          ],
        ],
      ),
    );
  }

  Widget _buildCreate(ColorScheme scheme) {
    return GlassCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_qrPayload == null) ...[
            const Icon(Icons.phonelink_lock_outlined, size: 42),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.qr_code_rounded),
              label: const Text('Create pairing QR'),
              onPressed: _busy ? null : _createPairingBundle,
            ),
          ] else ...[
            IdentityQrView(data: _qrPayload!),
            const SizedBox(height: 12),
            Text(
              _expiresAt == null
                  ? 'Expires soon'
                  : 'Expires ${_expiresAt!.hour.toString().padLeft(2, '0')}:${_expiresAt!.minute.toString().padLeft(2, '0')}',
              style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.62)),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('New QR'),
              onPressed: _busy ? null : _createPairingBundle,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildScan() {
    final controller = _scanner;
    return GlassCard(
      padding: EdgeInsets.zero,
      child: SizedBox(
        height: 340,
        child: controller == null
            ? const Center(child: GlassProgressIndicator.circular())
            : ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: MobileScanner(
                  controller: controller,
                  onDetect: _handleScan,
                ),
              ),
      ),
    );
  }
}
