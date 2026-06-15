import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/conversation.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/smp_provider.dart';
import '../../widgets/glass.dart';

/// Trust Center → "Verify a contact (shared secret)". Runs the Socialist
/// Millionaire Protocol: both sides answer a shared question; matching answers
/// upgrade the contact to verified without ever revealing the answer.
class SmpVerifyScreen extends StatefulWidget {
  final Conversation? initialConversation;

  const SmpVerifyScreen({super.key, this.initialConversation});

  @override
  State<SmpVerifyScreen> createState() => _SmpVerifyScreenState();
}

class _SmpVerifyScreenState extends State<SmpVerifyScreen> {
  Conversation? _selected;
  final _questionCtrl = TextEditingController();
  final _answerCtrl = TextEditingController();
  final _respondCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selected = widget.initialConversation;
  }

  @override
  void dispose() {
    _questionCtrl.dispose();
    _answerCtrl.dispose();
    _respondCtrl.dispose();
    super.dispose();
  }

  String _peerFingerprint(Conversation conv, String myId) =>
      conv.otherUser(myId)?.keyFingerprint ?? '';

  String _peerName(Conversation conv, String myId) => conv.displayName(myId);

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final smp = context.watch<SmpProvider>();
    final myId = context.read<AuthProvider>().currentUser?.id ?? '';
    final dms = chat.conversations.where((c) => c.isDM).toList();
    Conversation? selected = _selected;
    if (selected != null) {
      final selectedId = selected.id;
      for (final c in dms) {
        if (c.id == selectedId) {
          selected = c;
          break;
        }
      }
      if (!dms.any((c) => c.id == selectedId)) dms.insert(0, selected!);
    }

    // Incoming challenges awaiting an answer from this user.
    final incoming = [
      for (final c in dms)
        if (smp.sessionFor(c.id)?.status == SmpStatus.awaitingAnswer) c,
    ];

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Verify a contact')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
          16,
          16,
        ),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pick a shared secret only the two of you know (not the '
                  'answer to a security question a stranger could guess). '
                  'Matching answers prove there is no man-in-the-middle.',
                  style: TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
          if (incoming.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Incoming requests',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            for (final c in incoming)
              _IncomingCard(
                conversation: c,
                myId: myId,
                question:
                    smp.sessionFor(c.id)?.question ?? 'Verify this contact',
                controller: _respondCtrl,
                onRespond: (answer) {
                  smp.answerChallenge(
                    conversationId: c.id,
                    peerFingerprint: _peerFingerprint(c, myId),
                    answer: answer,
                  );
                },
              ),
          ],
          const SizedBox(height: 16),
          Text(
            'Start a verification',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButton<Conversation>(
                  isExpanded: true,
                  value: selected,
                  hint: const Text('Choose a contact'),
                  items: [
                    for (final c in dms)
                      DropdownMenuItem(
                        value: c,
                        child: Text(_peerName(c, myId)),
                      ),
                  ],
                  onChanged: (c) => setState(() => _selected = c),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _questionCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Question (sent to them)',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _answerCtrl,
                  decoration: const InputDecoration(labelText: 'Shared answer'),
                ),
                const SizedBox(height: 12),
                GlassButtonWidget(
                  onPressed: _selected == null
                      ? null
                      : () {
                          final conv = _selected!;
                          final fp = _peerFingerprint(conv, myId);
                          if (fp.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Contact has no key on file'),
                              ),
                            );
                            return;
                          }
                          smp.startVerification(
                            conversationId: conv.id,
                            peerUserId: conv.otherUser(myId)?.id ?? '',
                            peerFingerprint: fp,
                            question: _questionCtrl.text.trim().isEmpty
                                ? 'Verify our chat'
                                : _questionCtrl.text.trim(),
                            answer: _answerCtrl.text,
                          );
                        },
                  child: const Text('Start verification'),
                ),
              ],
            ),
          ),
          if (_selected != null) ...[
            const SizedBox(height: 16),
            _StatusCard(session: smp.sessionFor(_selected!.id)),
          ],
        ],
      ),
    );
  }
}

class _IncomingCard extends StatelessWidget {
  const _IncomingCard({
    required this.conversation,
    required this.myId,
    required this.question,
    required this.controller,
    required this.onRespond,
  });

  final Conversation conversation;
  final String myId;
  final String question;
  final TextEditingController controller;
  final ValueChanged<String> onRespond;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${conversation.displayName(myId)} wants to verify',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text('Q: $question'),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: 'Your answer'),
          ),
          const SizedBox(height: 8),
          GlassButtonWidget(
            onPressed: () => onRespond(controller.text),
            child: const Text('Respond'),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.session});
  final SmpSessionState? session;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (session == null) return const SizedBox.shrink();
    final (icon, color, label) = switch (session!.status) {
      SmpStatus.awaitingPeer => (
        Icons.hourglass_top_rounded,
        scheme.primary,
        'Waiting for the other person…',
      ),
      SmpStatus.awaitingAnswer => (
        Icons.question_answer_outlined,
        scheme.primary,
        'Answer the incoming request above',
      ),
      SmpStatus.success => (
        Icons.verified_rounded,
        Colors.green,
        'Verified! This contact is now trusted.',
      ),
      SmpStatus.failed => (
        Icons.error_outline_rounded,
        scheme.error,
        session!.error ?? 'Verification failed',
      ),
      SmpStatus.idle => (Icons.info_outline, scheme.primary, 'Idle'),
    };
    return GlassCard(
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}
