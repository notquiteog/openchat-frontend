import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/conversation.dart';
import '../providers/chat_provider.dart';
import '../services/api_service.dart';
import '../widgets/glass.dart';

/// Opens a DM, transparently handling a paid-inbox gate.
///
/// If the target charges an inbox price for a first message the server replies
/// 402 PAYMENT_REQUIRED; this shows a confirm sheet and, on accept, pays the
/// price from the wallet (idempotent server-side) and opens the DM. Returns the
/// conversation, or null if the user declines. Any other error rethrows.
///
/// Call sites that open a DM with a potentially-non-contact user should route
/// through this instead of calling ChatProvider.openDM directly.
Future<Conversation?> openDmHandlingInboxPrice(
  BuildContext context,
  String userId,
) async {
  final chat = context.read<ChatProvider>();
  try {
    return await chat.openDM(userId);
  } on ApiException catch (e) {
    if (e.statusCode != 402 || e.code != 'PAYMENT_REQUIRED') rethrow;
    final details = e.details ?? const {};
    final provider = (details['provider'] as String? ?? '').toUpperCase();
    final amount = details['amount'] as String? ?? '';
    if (!context.mounted) return null;
    if (!await _confirmInboxPayment(context, provider, amount)) return null;
    if (!context.mounted) return null;
    await context.read<ApiService>().unlockDm(userId);
    if (!context.mounted) return null;
    // Re-open so ChatProvider caches the now-unlocked conversation + members.
    return context.read<ChatProvider>().openDM(userId);
  }
}

Future<bool> _confirmInboxPayment(
  BuildContext context,
  String provider,
  String amount,
) async {
  var confirmed = false;
  await showGlassActionSheet<void>(
    context: context,
    title: 'Pay to message',
    message: 'This person charges $amount $provider to receive a first '
        'message. The amount comes from your wallet.',
    actions: [
      GlassActionSheetAction(
        label: 'Pay $amount $provider',
        icon: const Icon(Icons.lock_open_rounded),
        onPressed: () => confirmed = true,
      ),
    ],
  );
  return confirmed;
}
