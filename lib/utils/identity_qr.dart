import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import '../models/contact_bundle.dart';

const openChatFingerprintQrPrefix = 'openchat:fingerprint:';
const openChatContactBundlePrefix = 'openchat:contact-bundle:';
const openChatContactScheme = 'openchat';
const openChatContactHost = 'contact';
const _openChatLogoAsset = 'assets/images/logo.png';

String identityFingerprintQrPayload(String fingerprint) =>
    '$openChatFingerprintQrPrefix${normalizeIdentityFingerprint(fingerprint)}';

String contactBundleQrPayload(ContactBundle bundle) {
  final encoded = base64UrlEncode(utf8.encode(jsonEncode(bundle.toJson())));
  return '$openChatContactBundlePrefix$encoded';
}

ContactBundle? contactBundleFromQrPayload(String raw) {
  final trimmed = raw.trim();
  if (!trimmed.startsWith(openChatContactBundlePrefix)) return null;
  final encoded = trimmed.substring(openChatContactBundlePrefix.length);
  try {
    final normalized = base64Url.normalize(encoded);
    final decoded = jsonDecode(utf8.decode(base64Url.decode(normalized)));
    if (decoded is! Map) return null;
    final bundle = ContactBundle.fromJson(Map<String, dynamic>.from(decoded));
    return bundle.isUsable ? bundle : null;
  } catch (_) {
    return null;
  }
}

String contactLinkDeepLink({required String token}) => Uri(
  scheme: openChatContactScheme,
  host: openChatContactHost,
  pathSegments: [token],
).toString();

String? contactLinkTokenFromUri(Uri uri) {
  if (uri.scheme.toLowerCase() != openChatContactScheme) return null;
  if (uri.host.toLowerCase() != openChatContactHost) return null;
  final token = uri.pathSegments.isNotEmpty
      ? uri.pathSegments.first
      : uri.queryParameters['token'];
  final trimmed = token?.trim();
  if (trimmed == null || trimmed.isEmpty || trimmed.length > 128) {
    return null;
  }
  return trimmed;
}

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
    final qrColor = MediaQuery.platformBrightnessOf(context) == Brightness.dark
        ? Colors.white
        : Colors.black;

    return SizedBox.square(
      dimension: widget.size,
      child: PrettyQrView(
        qrImage: _qrImage,
        decoration: PrettyQrDecoration(
          shape: PrettyQrSmoothSymbol(color: qrColor),
          image: const PrettyQrDecorationImage(
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
