import '../offline_outbox_service.dart';

/// Mesh wire protocol, layer 3 helper: which queued outbox items can be
/// delivered to a verified nearby peer, and what travels on the wire.
///
/// The mesh is a SECOND delivery path, not a replacement: items stay queued
/// for the normal server drain, the server send reuses the same client nonce,
/// and the receiver dedups the eventual server copy against the mesh copy by
/// payload — so nothing here mutates the outbox.

/// Queued encrypted sendMessage items addressed to [dmConversationId] (the
/// existing DM with the verified peer), oldest first. Failed items are
/// excluded — if the server path classified them as permanently broken,
/// re-broadcasting them over BLE won't fix the payload.
List<OfflineOutboxItem> meshDeliverableItems(
  List<OfflineOutboxItem> items,
  String dmConversationId,
) {
  final out = items
      .where((item) =>
          item.action == OfflineOutboxAction.sendMessage &&
          item.conversationId == dmConversationId &&
          item.status != OfflineOutboxStatus.failed &&
          (item.data['encrypted_payload'] as String? ?? '').isNotEmpty &&
          // Plaintext conversations don't exist between two PGP contacts; a
          // non-encrypted queued item here means it isn't a sealed DM payload
          // and the peer's mesh ingest (PGP-only) couldn't read it anyway.
          (item.data['is_encrypted'] as bool? ?? false))
      .toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return out;
}

/// The mesh `message` frame payload for one outbox item: exactly the fields
/// the receiver needs to run the envelope through its normal decrypt path.
Map<String, dynamic> meshEnvelopeForItem(OfflineOutboxItem item) => {
      'conversation_id': item.conversationId,
      'encrypted_payload': item.data['encrypted_payload'],
      'signature': item.data['signature'] ?? '',
      'message_type': item.data['message_type'] ?? 'text',
      'client_nonce': item.data['pending_message_id'] ?? item.id,
      'created_at': item.data['created_at'] ??
          item.createdAt.toUtc().toIso8601String(),
    };
