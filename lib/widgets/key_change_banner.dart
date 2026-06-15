import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/conversation.dart';
import '../models/key_trust_pin.dart';
import '../providers/smp_provider.dart';
import '../screens/settings/smp_verify_screen.dart';
import '../services/secure_storage_service.dart';
import 'glass.dart';

class KeyChangeBanner extends StatefulWidget {
  final Conversation conversation;
  final String currentUserId;

  const KeyChangeBanner({
    super.key,
    required this.conversation,
    required this.currentUserId,
  });

  @override
  State<KeyChangeBanner> createState() => _KeyChangeBannerState();
}

class _KeyChangeBannerState extends State<KeyChangeBanner> {
  KeyTrustPin? _pin;
  String? _loadedPeerId;
  bool _dismissed = false;
  bool _loading = false;
  int? _lastRefreshToken;

  String? _otherUserIdFor(Conversation conversation, String currentUserId) =>
      conversation.isDM ? conversation.otherUser(currentUserId)?.id : null;

  @override
  void didUpdateWidget(covariant KeyChangeBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPeerId = _otherUserIdFor(
      oldWidget.conversation,
      oldWidget.currentUserId,
    );
    final peerId = _otherUserIdFor(widget.conversation, widget.currentUserId);
    if (oldWidget.conversation.id != widget.conversation.id ||
        oldPeerId != peerId) {
      _pin = null;
      _loadedPeerId = null;
      _dismissed = false;
      _loading = false;
      _lastRefreshToken = null;
    }
  }

  void _scheduleLoad(String peerId, SmpStatus? status) {
    final refreshToken = Object.hash(peerId, status);
    if (_lastRefreshToken == refreshToken && _loadedPeerId == peerId) return;
    _lastRefreshToken = refreshToken;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_loadPin(peerId));
    });
  }

  Future<void> _loadPin(String peerId) async {
    if (_loading && _loadedPeerId == peerId) return;
    _loading = true;
    final pin = await context.read<SecureStorageService>().getKeyTrustPin(
      peerId,
    );
    if (!mounted) return;
    setState(() {
      _pin = pin;
      _loadedPeerId = peerId;
      _loading = false;
    });
  }

  bool get _shouldShow {
    final pin = _pin;
    return !_dismissed &&
        pin != null &&
        (pin.warning?.isNotEmpty ?? false) &&
        !pin.isVerified;
  }

  @override
  Widget build(BuildContext context) {
    final peerId = _otherUserIdFor(widget.conversation, widget.currentUserId);
    if (peerId == null || peerId.isEmpty) return const SizedBox.shrink();

    final smpStatus = context
        .watch<SmpProvider>()
        .sessionFor(widget.conversation.id)
        ?.status;
    _scheduleLoad(peerId, smpStatus);

    if (!_shouldShow) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final name = widget.conversation.displayName(widget.currentUserId);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: GlassContainer(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.gpp_maybe_rounded, size: 20, color: scheme.error),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '$name\'s safety number changed - verify before sending',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => SmpVerifyScreen(
                      initialConversation: widget.conversation,
                    ),
                  ),
                );
              },
              child: const Text('Verify'),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => setState(() => _dismissed = true),
            ),
          ],
        ),
      ),
    );
  }
}
