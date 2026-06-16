import 'package:flutter/material.dart';

class SecureStorageWarning extends StatelessWidget {
  final String message;

  const SecureStorageWarning({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    const borderColor = Color(0xFFD6A100);
    const backgroundColor = Color(0xFFFFF8E1);
    const textColor = Color(0xFF5D4300);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.key_off_outlined, color: textColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'System keyring unavailable',
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 4),
                _WarningMessage(message: message),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WarningMessage extends StatelessWidget {
  final String message;

  const _WarningMessage({required this.message});

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      style: const TextStyle(color: Color(0xFF5D4300), fontSize: 13),
    );
  }
}
