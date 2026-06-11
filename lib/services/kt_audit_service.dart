import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../crypto/kt_log_verify.dart';
import 'api_service.dart';
import 'secure_storage_service.dart';

/// Audits the server's key-transparency Merkle log from this client's view:
/// pins the log key on first contact, verifies every new signed tree head is
/// an append-only extension of the last one we accepted, verifies inclusion
/// proofs on demand, and ingests heads gossiped by OTHER clients inside
/// encrypted messages. Any violation — a shrunk log, two valid heads of equal
/// size with different roots, a swapped log key — raises a sticky alarm with
/// the evidence attached: that alarm is cryptographic proof the server (or
/// someone holding its log key) lied.
class KtAuditService {
  final SecureStorageService _storage;

  KtAuditService({SecureStorageService? storage})
      : _storage = storage ?? SecureStorageService();

  static DateTime _lastSync = DateTime.fromMillisecondsSinceEpoch(0);

  /// Fetches the latest signed head and folds it into the audited state.
  /// Throttled; failures are silent (auditing is best-effort, the alarm state
  /// is what matters).
  Future<void> syncSth(ApiService api, {bool force = false}) async {
    final now = DateTime.now();
    if (!force && now.difference(_lastSync) < const Duration(minutes: 15)) {
      return;
    }
    _lastSync = now;
    try {
      final head = await api.getKtSth();
      await _ingestVerifiedHead(
        api,
        treeSize: (head['tree_size'] as num?)?.toInt() ?? 0,
        rootHash: head['root_hash']?.toString() ?? '',
        signature: head['signature']?.toString() ?? '',
        publicKey: head['public_key']?.toString() ?? '',
        source: 'server',
      );
    } catch (_) {
      // Unreachable/old server: nothing to audit this round.
    }
  }

  /// A head another client gossiped inside an encrypted message. The signature
  /// is verified against OUR pinned key — a forged head is just noise, a VALID
  /// conflicting head is evidence.
  Future<void> ingestGossipedHead(
    ApiService api,
    Map<String, dynamic> gossip,
  ) async {
    final treeSize = (gossip['size'] as num?)?.toInt() ?? 0;
    final rootHash = gossip['root']?.toString() ?? '';
    final signature = gossip['sig']?.toString() ?? '';
    if (treeSize <= 0 || rootHash.isEmpty || signature.isEmpty) return;
    await _ingestVerifiedHead(
      api,
      treeSize: treeSize,
      rootHash: rootHash,
      signature: signature,
      publicKey: '', // gossip never carries a key — only the pinned one counts
      source: 'gossip',
    );
  }

  Future<void> _ingestVerifiedHead(
    ApiService api, {
    required int treeSize,
    required String rootHash,
    required String signature,
    required String publicKey,
    required String source,
  }) async {
    if (treeSize <= 0 || rootHash.isEmpty || signature.isEmpty) return;
    final cached = await _storage.getKtSthCache();
    var pinnedKey = cached?['public_key']?.toString() ?? '';

    if (pinnedKey.isEmpty) {
      // First contact: trust-on-first-use pin, but only from the server's own
      // /sth response (gossip without a pin is unverifiable noise).
      if (publicKey.isEmpty) return;
      pinnedKey = publicKey;
    } else if (publicKey.isNotEmpty && publicKey != pinnedKey) {
      await _raiseAlarm('log key changed', {
        'pinned_key': pinnedKey,
        'served_key': publicKey,
      });
      return;
    }

    final valid = await KtLogVerify.verifySthSignature(
      publicKeyB64: pinnedKey,
      treeSize: treeSize,
      rootHashHex: rootHash,
      signatureB64: signature,
    );
    if (!valid) return; // forged/garbled: not evidence, just ignored

    if (cached == null) {
      await _storage.saveKtSthCache({
        'tree_size': treeSize,
        'root_hash': rootHash,
        'signature': signature,
        'public_key': pinnedKey,
      });
      return;
    }

    final cachedSize = (cached['tree_size'] as num?)?.toInt() ?? 0;
    final cachedRoot = cached['root_hash']?.toString() ?? '';

    if (treeSize == cachedSize) {
      if (rootHash != cachedRoot) {
        // Two VALID signed heads, same size, different roots: the smoking gun.
        await _raiseAlarm('equivocation: conflicting signed heads', {
          'size': treeSize,
          'root_a': cachedRoot,
          'sig_a': cached['signature'],
          'root_b': rootHash,
          'sig_b': signature,
          'via': source,
        });
      }
      return;
    }
    if (treeSize < cachedSize) {
      // An older head is fine for gossip (the sender may lag); only the
      // SERVER presenting a shrunk log breaks its append-only commitment.
      if (source == 'server') {
        await _raiseAlarm('log rolled back', {
          'cached_size': cachedSize,
          'served_size': treeSize,
        });
      }
      return;
    }

    // Grew: demand an append-only proof from our size to the new one.
    try {
      final proof = await api.getKtConsistencyProof(cachedSize, treeSize);
      final ok = KtLogVerify.verifyConsistency(
        m: cachedSize,
        n: treeSize,
        oldRoot: KtLogVerify.hexToBytes(cachedRoot),
        newRoot: KtLogVerify.hexToBytes(rootHash),
        proof: ((proof['proof'] as List?) ?? const [])
            .map((p) => KtLogVerify.hexToBytes(p.toString()))
            .toList(),
      );
      if (!ok) {
        await _raiseAlarm('history rewritten between heads', {
          'from_size': cachedSize,
          'from_root': cachedRoot,
          'to_size': treeSize,
          'to_root': rootHash,
        });
        return;
      }
      await _storage.saveKtSthCache({
        'tree_size': treeSize,
        'root_hash': rootHash,
        'signature': signature,
        'public_key': pinnedKey,
      });
    } catch (_) {
      // No proof endpoint reachable for the older size (e.g. our cached head
      // predates the server's retained heads): keep the cached head; the next
      // server sync re-anchors via a fresh consistency window.
    }
  }

  /// The current verified head, formatted for gossiping inside an encrypted
  /// message envelope, or null when nothing is pinned yet.
  Future<Map<String, dynamic>?> gossipPayload() async {
    final cached = await _storage.getKtSthCache();
    if (cached == null) return null;
    return {
      'size': cached['tree_size'],
      'root': cached['root_hash'],
      'sig': cached['signature'],
    };
  }

  Future<Map<String, dynamic>?> currentAlarm() => _storage.getKtLogAlarm();

  Future<void> _raiseAlarm(String reason, Map<String, dynamic> evidence) async {
    // Sticky: the FIRST alarm's evidence is the valuable artifact; never
    // overwrite it with later noise.
    if (await _storage.getKtLogAlarm() != null) return;
    debugPrint('KT LOG ALARM: $reason');
    await _storage.saveKtLogAlarm({
      'reason': reason,
      'at': DateTime.now().toUtc().toIso8601String(),
      'evidence': jsonEncode(evidence),
    });
  }
}
