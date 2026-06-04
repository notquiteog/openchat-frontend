import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../utils/identity_qr.dart';
import '../../widgets/glass.dart';

class IdentityQrScannerScreen extends StatefulWidget {
  final String? expectedFingerprint;
  final String? expectedUsername;

  const IdentityQrScannerScreen({
    super.key,
    this.expectedFingerprint,
    this.expectedUsername,
  });

  @override
  State<IdentityQrScannerScreen> createState() =>
      _IdentityQrScannerScreenState();
}

class _IdentityQrScannerScreenState extends State<IdentityQrScannerScreen> {
  late final MobileScannerController _controller;
  bool _handling = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleDetect(BarcodeCapture capture) async {
    if (_handling) return;
    final raw = capture.barcodes
        .map((barcode) => barcode.rawValue)
        .whereType<String>()
        .firstWhere((value) => value.trim().isNotEmpty, orElse: () => '');
    if (raw.isEmpty) return;

    final scanned = normalizeIdentityFingerprint(raw);
    if (!isValidIdentityFingerprint(scanned)) {
      setState(() => _message = 'That QR code is not an OpenChat fingerprint.');
      return;
    }

    _handling = true;
    await _controller.stop();
    if (!mounted) return;

    final expected = widget.expectedFingerprint == null
        ? null
        : normalizeIdentityFingerprint(widget.expectedFingerprint!);
    if (expected != null) {
      await _showProfileVerification(scanned, expected);
      return;
    }

    await _showResolvedFingerprint(scanned);
  }

  Future<void> _showProfileVerification(String scanned, String expected) async {
    final match = scanned == expected;
    await showDialog<void>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text(match ? 'Identity verified' : 'Fingerprint mismatch'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              match
                  ? 'The scanned QR matches @${widget.expectedUsername ?? 'this user'}.'
                  : 'The scanned QR does not match @${widget.expectedUsername ?? 'this user'}.',
            ),
            const SizedBox(height: 12),
            Text(
              formatIdentityFingerprint(scanned),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: match ? Colors.green : Theme.of(ctx).colorScheme.error,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text('Done'),
          ),
          if (!match)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _resumeScanning();
              },
              child: const Text('Scan again'),
            ),
        ],
      ),
    );
  }

  Future<void> _showResolvedFingerprint(String scanned) async {
    try {
      final user = await context.read<ApiService>().getUserByFingerprint(
        scanned,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => GlassAlertDialog(
          title: const Text('Identity found'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('This fingerprint belongs to @${user.username}.'),
              const SizedBox(height: 12),
              Text(
                formatIdentityFingerprint(user.keyFingerprint),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.pop(context);
              },
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => GlassAlertDialog(
          title: const Text('Unknown fingerprint'),
          content: Text(formatIdentityFingerprint(scanned)),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _resumeScanning();
              },
              child: const Text('Scan again'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.pop(context);
              },
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }
  }

  void _resumeScanning() {
    if (!mounted) return;
    setState(() {
      _handling = false;
      _message = null;
    });
    _controller.start();
  }

  @override
  Widget build(BuildContext context) {
    final expected = widget.expectedUsername;
    return Scaffold(
      appBar: GlassAppBar(
        title: Text(expected == null ? 'Scan identity QR' : 'Verify identity'),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: MobileScanner(
              controller: _controller,
              onDetect: _handleDetect,
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Camera unavailable: ${error.errorCode.message}',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: SafeArea(
              child: LiquidGlass(
                blur: 40,
                borderRadius: const BorderRadius.all(Radius.circular(24)),
                padding: const EdgeInsets.all(16),
                child: Text(
                  _message ??
                      (expected == null
                          ? 'Scan an OpenChat fingerprint QR to identify the account.'
                          : 'Scan @${widget.expectedUsername}\'s OpenChat fingerprint QR to verify it matches this profile.'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
