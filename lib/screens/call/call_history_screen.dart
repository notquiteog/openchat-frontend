import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/call_provider.dart';
import '../../services/call_history_service.dart';
import '../../widgets/glass.dart';

class CallHistoryScreen extends StatefulWidget {
  const CallHistoryScreen({super.key});

  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends State<CallHistoryScreen> {
  bool _loading = true;
  List<CallHistoryEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await context.read<CallHistoryService>().list();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _callBack(CallHistoryEntry e, {required bool video}) async {
    final peer = e.peerUserId;
    final conv = e.conversationId;
    if (peer == null || conv == null) return;
    try {
      await context.read<CallProvider>().startCall(
        targetUserId: peer,
        targetUsername: e.peerUsername,
        conversationId: conv,
        isVideo: video,
      );
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Call failed: $err')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Calls')),
      body: _loading
          ? const Center(child: GlassProgressIndicator.circular())
          : _entries.isEmpty
          ? _empty(theme)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
                  16,
                  MediaQuery.paddingOf(context).bottom + 32,
                ),
                children: _buildSections(theme),
              ),
            ),
    );
  }

  Widget _empty(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.call_outlined,
            size: 48,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 12),
          Text(
            'No calls yet',
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSections(ThemeData theme) {
    final out = <Widget>[];
    String? currentLabel;
    List<CallHistoryEntry> bucket = [];

    void flush() {
      if (bucket.isEmpty) return;
      out.add(
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 8, bottom: 8),
          child: Text(
            currentLabel!.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      );
      out.add(
        GlassCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < bucket.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    indent: 60,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.10),
                  ),
                _row(theme, bucket[i]),
              ],
            ],
          ),
        ),
      );
      bucket = [];
    }

    for (final e in _entries) {
      final label = _dateLabel(e.startedAt);
      if (label != currentLabel) {
        flush();
        currentLabel = label;
      }
      bucket.add(e);
    }
    flush();
    return out;
  }

  Widget _row(ThemeData theme, CallHistoryEntry e) {
    final missed = e.isMissed;
    final incoming = e.direction == CallDirection.incoming;
    final color = missed ? theme.colorScheme.error : theme.colorScheme.primary;
    final title = e.peerUsername != null
        ? '@${e.peerUsername}'
        : (e.peerUserId ?? 'Unknown');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.12),
            ),
            child: Icon(
              incoming ? Icons.call_received : Icons.call_made,
              size: 18,
              color: color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: missed ? theme.colorScheme.error : null,
                  ),
                ),
                Text(
                  _subtitle(e),
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(e.isVideo ? Icons.videocam_outlined : Icons.call,
                size: 20),
            color: theme.colorScheme.primary,
            onPressed: (e.peerUserId != null && e.conversationId != null)
                ? () => _callBack(e, video: e.isVideo)
                : null,
          ),
        ],
      ),
    );
  }

  String _subtitle(CallHistoryEntry e) {
    final kind = e.isVideo ? 'Video' : 'Voice';
    final time = TimeOfDay.fromDateTime(e.startedAt).format(context);
    final state = switch (e.outcome) {
      CallOutcomeKind.missed => 'Missed',
      CallOutcomeKind.declined => 'Declined',
      CallOutcomeKind.answered => _duration(e.durationSecs),
    };
    return '$kind · $state · $time';
  }

  static String _duration(int secs) {
    if (secs <= 0) return 'Answered';
    final m = secs ~/ 60;
    final s = secs % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String _dateLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}
