import 'package:flutter/material.dart';

import '../models/key_trust_pin.dart';
import 'glass.dart';

class KeyVerificationBadge extends StatelessWidget {
  final KeyTrustPin? pin;
  final bool compact;

  const KeyVerificationBadge({
    super.key,
    required this.pin,
    this.compact = false,
  });

  static bool shouldShow(KeyTrustPin? pin) {
    if (pin == null) return false;
    if (pin.warning?.trim().isNotEmpty == true) return true;
    return pin.isVerified;
  }

  @override
  Widget build(BuildContext context) {
    final pin = this.pin;
    if (!shouldShow(pin)) return const SizedBox.shrink();

    final warning = pin!.warning?.trim().isNotEmpty == true;
    final scheme = Theme.of(context).colorScheme;
    final color = warning ? scheme.error : Colors.green;
    final label = warning ? 'Key changed' : 'Verified';
    final icon = warning ? Icons.gpp_bad_rounded : Icons.verified_user_rounded;
    return GlassContainer(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 4,
      ),
      shape: const LiquidRoundedSuperellipse(borderRadius: 999),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 11 : 14, color: color),
          SizedBox(width: compact ? 3 : 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: compact ? 10 : 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
