import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

const openChatFingerprintQrPrefix = 'openchat:fingerprint:';
const _openChatLogoAsset = 'assets/images/logo.png';

String identityFingerprintQrPayload(String fingerprint) =>
    '$openChatFingerprintQrPrefix${normalizeIdentityFingerprint(fingerprint)}';

String normalizeIdentityFingerprint(String value) {
  var raw = value.trim();
  if (raw.isEmpty) return '';

  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      raw =
          decoded['fingerprint']?.toString() ??
          decoded['key_fingerprint']?.toString() ??
          raw;
    }
  } catch (_) {}

  final lower = raw.toLowerCase();
  if (lower.startsWith(openChatFingerprintQrPrefix)) {
    raw = raw.substring(openChatFingerprintQrPrefix.length);
  }

  return raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
}

bool isValidIdentityFingerprint(String fingerprint) =>
    RegExp(r'^[0-9A-F]{40,64}$').hasMatch(fingerprint);

String formatIdentityFingerprint(String fingerprint) {
  final normalized = normalizeIdentityFingerprint(fingerprint);
  final groups = <String>[];
  for (var i = 0; i < normalized.length; i += 4) {
    groups.add(normalized.substring(i, (i + 4).clamp(0, normalized.length)));
  }
  return groups.join(' ');
}

class IdentityQrView extends StatefulWidget {
  final String data;
  final double size;

  const IdentityQrView({super.key, required this.data, this.size = 220});

  @override
  State<IdentityQrView> createState() => _IdentityQrViewState();
}

class _IdentityQrViewState extends State<IdentityQrView> {
  late QrImage _qrImage;

  @override
  void initState() {
    super.initState();
    _qrImage = _createQrImage(widget.data);
  }

  @override
  void didUpdateWidget(covariant IdentityQrView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _qrImage = _createQrImage(widget.data);
    }
  }

  static QrImage _createQrImage(String data) {
    final qrCode = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.H,
    );
    return QrImage(qrCode);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: PrettyQrView(
        qrImage: _qrImage,
        decoration: const PrettyQrDecoration(
          image: PrettyQrDecorationImage(
            image: AssetImage(_openChatLogoAsset),
            scale: 0.18,
            padding: EdgeInsets.all(8),
          ),
          quietZone: PrettyQrQuietZone.standard,
        ),
      ),
    );
  }
}
