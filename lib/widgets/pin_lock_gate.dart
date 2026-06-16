import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/security_service.dart';
import 'glass.dart';

/// Full-screen PIN gate shown over a locked conversation. Verifies the entered
/// PIN via [onVerify]; an optional [onBiometric] offers a biometric bypass.
class PinLockGate extends StatefulWidget {
  final String title;
  final Future<bool> Function(String pin) onVerify;
  final VoidCallback onUnlocked;
  final Future<bool> Function()? onBiometric;

  const PinLockGate({
    super.key,
    required this.title,
    required this.onVerify,
    required this.onUnlocked,
    this.onBiometric,
  });

  @override
  State<PinLockGate> createState() => _PinLockGateState();
}

class _PinLockGateState extends State<PinLockGate> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _error;
  VoidCallback? _releaseSecure;

  @override
  void initState() {
    super.initState();
    // A PIN entry screen is sensitive — force screenshot blocking while shown.
    unawaited(
      SecurityService.instance.pushForceSecure().then((release) {
        if (mounted) {
          _releaseSecure = release;
        } else {
          release();
        }
      }),
    );
    if (widget.onBiometric != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
    }
  }

  @override
  void dispose() {
    _releaseSecure?.call();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _tryBiometric() async {
    final fn = widget.onBiometric;
    if (fn == null) return;
    try {
      if (await fn()) widget.onUnlocked();
    } catch (_) {}
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.onVerify(_ctrl.text);
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
    } else {
      setState(() {
        _busy = false;
        _error = 'Incorrect PIN';
        _ctrl.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_rounded, size: 48, color: scheme.primary),
              const SizedBox(height: 16),
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'This chat is locked',
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: 200,
                child: TextField(
                  controller: _ctrl,
                  autofocus: widget.onBiometric == null,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    hintText: 'PIN',
                    errorText: _error,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(height: 16),
              GlassButtonWidget(
                onPressed: _busy ? null : _submit,
                child: const Text('Unlock'),
              ),
              if (widget.onBiometric != null) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  icon: const Icon(Icons.fingerprint_rounded),
                  label: const Text('Use biometrics'),
                  onPressed: _tryBiometric,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
