import 'dart:async';

import 'package:flutter/foundation.dart';

import '../crypto/smp_service.dart';
import '../models/key_trust_pin.dart';
import '../services/secure_storage_service.dart';
import 'chat_provider.dart';

enum SmpStatus {
  idle,
  awaitingPeer, // we sent a step, waiting for their reply
  awaitingAnswer, // incoming challenge; user must enter the shared answer
  success,
  failed,
}

/// Live state of an SMP verification in one conversation.
class SmpSessionState {
  SmpSessionState({
    required this.conversationId,
    required this.peerUserId,
    required this.status,
    this.question,
    this.error,
  });

  final String conversationId;
  final String peerUserId;
  SmpStatus status;
  String? question; // shown to the responder
  String? error;
}

/// Drives Socialist-Millionaire verifications and routes their in-band messages
/// over the chat transport. On success it upgrades the contact's [KeyTrustPin]
/// to `verifiedVia: 'smp'`.
class SmpProvider extends ChangeNotifier {
  // Public named params (chat:/storage:) wrap private fields; initializing
  // formals would expose the leading underscore in the API.
  SmpProvider({
    required ChatProvider chat,
    required SecureStorageService storage,
    // ignore: prefer_initializing_formals
  }) : _chat = chat,
       // ignore: prefer_initializing_formals
       _storage = storage {
    _sub = _chat.smpMessages.listen(_onInbound);
  }

  final ChatProvider _chat;
  final SecureStorageService _storage;
  StreamSubscription<SmpInbound>? _sub;

  final _sessions = <String, SmpSessionState>{};
  final _initiators = <String, SmpInitiator>{};
  final _responders = <String, SmpResponder>{};
  // Responder: incoming msg1 awaiting the user's answer.
  final _pendingInit = <String, Map<String, dynamic>>{};
  // Peer fingerprints captured for the pin upgrade.
  final _peerFingerprints = <String, String>{};

  SmpSessionState? sessionFor(String conversationId) =>
      _sessions[conversationId];

  /// Initiator: begin a verification by asking [question] with shared [answer].
  Future<void> startVerification({
    required String conversationId,
    required String peerUserId,
    required String peerFingerprint,
    required String question,
    required String answer,
  }) async {
    final myFp = await _storage.getFingerprint() ?? '';
    if (myFp.isEmpty || peerFingerprint.isEmpty) {
      _fail(conversationId, peerUserId, 'Missing key fingerprints');
      return;
    }
    _peerFingerprints[conversationId] = peerFingerprint;
    final secret = smpSecret(
      myFingerprint: myFp,
      theirFingerprint: peerFingerprint,
      answer: answer,
    );
    final initiator = SmpInitiator(secret);
    _initiators[conversationId] = initiator;
    _sessions[conversationId] = SmpSessionState(
      conversationId: conversationId,
      peerUserId: peerUserId,
      status: SmpStatus.awaitingPeer,
    );
    notifyListeners();
    final m1 = initiator.init();
    await _send(conversationId, 'init', {'question': question, 'data': m1});
  }

  /// Responder: provide the shared [answer] to a pending incoming challenge.
  Future<void> answerChallenge({
    required String conversationId,
    required String peerFingerprint,
    required String answer,
  }) async {
    final init = _pendingInit.remove(conversationId);
    final session = _sessions[conversationId];
    if (init == null || session == null) return;
    final myFp = await _storage.getFingerprint() ?? '';
    if (myFp.isEmpty || peerFingerprint.isEmpty) {
      _fail(conversationId, session.peerUserId, 'Missing key fingerprints');
      return;
    }
    _peerFingerprints[conversationId] = peerFingerprint;
    final secret = smpSecret(
      myFingerprint: myFp,
      theirFingerprint: peerFingerprint,
      answer: answer,
    );
    try {
      final responder = SmpResponder(secret);
      _responders[conversationId] = responder;
      final m1 = (init['data'] as Map).cast<String, String>();
      final m2 = responder.step2(m1);
      session.status = SmpStatus.awaitingPeer;
      notifyListeners();
      await _send(conversationId, 'step2', {'data': m2});
    } catch (e) {
      _fail(conversationId, session.peerUserId, 'Verification failed: $e');
    }
  }

  void dismiss(String conversationId) {
    _sessions.remove(conversationId);
    _initiators.remove(conversationId);
    _responders.remove(conversationId);
    _pendingInit.remove(conversationId);
    _peerFingerprints.remove(conversationId);
    notifyListeners();
  }

  Future<void> _onInbound(SmpInbound inbound) async {
    final convID = inbound.conversationId;
    final step = inbound.payload['step'] as String?;
    final data = (inbound.payload['data'] as Map?)?.cast<String, String>();
    try {
      switch (step) {
        case 'init':
          // Incoming challenge — stash it and ask the user for the answer.
          _pendingInit[convID] = inbound.payload;
          _sessions[convID] = SmpSessionState(
            conversationId: convID,
            peerUserId: inbound.senderId,
            status: SmpStatus.awaitingAnswer,
            question: inbound.payload['question'] as String?,
          );
          notifyListeners();
        case 'step2':
          final initiator = _initiators[convID];
          if (initiator == null || data == null) return;
          final m3 = initiator.step3(data);
          await _send(convID, 'step3', {'data': m3});
        case 'step3':
          final responder = _responders[convID];
          if (responder == null || data == null) return;
          final m4 = responder.step4(data);
          await _send(convID, 'step4', {'data': m4});
          await _settle(convID, responder.matched);
        case 'step4':
          final initiator = _initiators[convID];
          if (initiator == null || data == null) return;
          final matched = initiator.finish(data);
          await _settle(convID, matched);
        case 'abort':
          final s = _sessions[convID];
          if (s != null) _fail(convID, s.peerUserId, 'Peer cancelled');
      }
    } catch (e) {
      final s = _sessions[convID];
      _fail(
        convID,
        s?.peerUserId ?? inbound.senderId,
        'Verification failed: $e',
      );
    }
  }

  Future<void> _settle(String convID, bool matched) async {
    final session = _sessions[convID];
    if (session == null) return;
    if (matched) {
      session.status = SmpStatus.success;
      await _upgradePin(session.peerUserId, convID);
    } else {
      session.status = SmpStatus.failed;
      session.error =
          'The answers did not match — this contact is not verified';
    }
    notifyListeners();
  }

  Future<void> _upgradePin(String peerUserId, String convID) async {
    final fingerprint = _peerFingerprints[convID];
    if (fingerprint == null || fingerprint.isEmpty) return;
    final existing = await _storage.getKeyTrustPin(peerUserId);
    await _storage.saveKeyTrustPin(
      KeyTrustPin(
        userId: peerUserId,
        fingerprint: existing?.fingerprint.isNotEmpty == true
            ? existing!.fingerprint
            : fingerprint.toUpperCase(),
        publicKeyHash: existing?.publicKeyHash ?? '',
        eventHash: existing?.eventHash,
        pinnedAt: existing?.pinnedAt ?? DateTime.now(),
        verifiedVia: 'smp',
        verifiedAt: DateTime.now(),
      ),
    );
  }

  void _fail(String convID, String peerUserId, String error) {
    _sessions[convID] = SmpSessionState(
      conversationId: convID,
      peerUserId: peerUserId,
      status: SmpStatus.failed,
      error: error,
    );
    notifyListeners();
  }

  Future<void> _send(
    String convID,
    String step,
    Map<String, dynamic> body,
  ) async {
    await _chat.sendSmpStep(convID, {'step': step, ...body});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
