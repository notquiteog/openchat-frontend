import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/moderation_report.dart';
import '../../models/operator_metrics.dart';
import '../../models/system_admin_audit_event.dart';
import '../../models/user.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';

bool canShowAdminHome(User? user) => user?.isSystemAdmin ?? false;

enum _AdminSection { csam, moderation, health }

class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  _AdminSection _section = _AdminSection.csam;
  Future<_ModerationAdminData>? _moderationFuture;
  Future<OperatorMetrics>? _metricsFuture;

  void _selectSection(int index) {
    setState(() => _section = _AdminSection.values[index]);
  }

  Future<_ModerationAdminData> _fetchModeration(ApiService api) async {
    final reportsFuture = api.listAdminReportsGlobal(limit: 50);
    final auditFuture = api.listSystemAdminAuditEvents(limit: 30);
    return _ModerationAdminData(
      reports: await reportsFuture,
      auditEvents: await auditFuture,
    );
  }

  Future<_ModerationAdminData> _moderationData() {
    return _moderationFuture ??= _fetchModeration(context.read<ApiService>());
  }

  Future<OperatorMetrics> _metricsData() {
    return _metricsFuture ??= context.read<ApiService>().getAdminMetrics();
  }

  void _refresh() {
    setState(() {
      switch (_section) {
        case _AdminSection.csam:
          break;
        case _AdminSection.moderation:
          _moderationFuture = _fetchModeration(context.read<ApiService>());
        case _AdminSection.health:
          _metricsFuture = context.read<ApiService>().getAdminMetrics();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: const Text('Admin'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: GlassCircleIconButton(
              tooltip: 'Refresh',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ),
        ],
      ),
      body: LiquidMeshBackground(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.paddingOf(context).top + kToolbarHeight + 16,
            16,
            MediaQuery.paddingOf(context).bottom + 28,
          ),
          children: [
            GlassSegmentedControl(
              segments: const ['CSAM', 'Moderation', 'Health'],
              selectedIndex: _section.index,
              onSegmentSelected: _selectSection,
            ),
            const SizedBox(height: 18),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: switch (_section) {
                _AdminSection.csam => const _CsamSection(key: ValueKey('csam')),
                _AdminSection.moderation => _ModerationSection(
                  key: const ValueKey('moderation'),
                  future: _moderationData(),
                  onRetry: _refresh,
                ),
                _AdminSection.health => _HealthSection(
                  key: const ValueKey('health'),
                  future: _metricsData(),
                  onRetry: _refresh,
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _CsamSection extends StatefulWidget {
  const _CsamSection({super.key});

  @override
  State<_CsamSection> createState() => _CsamSectionState();
}

class _CsamSectionState extends State<_CsamSection> {
  Future<List<Map<String, dynamic>>>? _future;

  Future<List<Map<String, dynamic>>> _load() {
    return _future ??= context.read<ApiService>().listCsamReports(
      status: 'open',
    );
  }

  void _reload() {
    setState(() {
      _future = context.read<ApiService>().listCsamReports(status: 'open');
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassCard(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              _CircleIcon(
                icon: Icons.verified_user_outlined,
                color: scheme.error,
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CSAM Reports',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Anonymous, provable reports. Opening one deanonymizes the '
                      'sender — this is recorded in the system-admin audit log.',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _load(),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: GlassProgressIndicator.circular()),
              );
            }
            if (snap.hasError) {
              return _CsamError(onRetry: _reload, error: '${snap.error}');
            }
            final reports = snap.data ?? const [];
            if (reports.isEmpty) {
              return const GlassCard(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    'No open CSAM reports.',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              );
            }
            return GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final r in reports)
                    GlassListTile(
                      leading: Icon(
                        Icons.report_gmailerrorred_outlined,
                        color: scheme.error,
                      ),
                      title: Text('Report ${_csamShortId(r['id'])}'),
                      subtitle: Text('Reported ${_shortTime(r['created_at'])}'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _openReport(r['id'] as String),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Future<void> _openReport(String reportID) async {
    final api = context.read<ApiService>();
    Map<String, dynamic> detail;
    try {
      detail = await api.inspectCsamReport(reportID);
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, 'Inspect failed: $e', isError: true);
      return;
    }
    if (!mounted) return;
    final verified = detail['verified'] == true;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text(verified ? 'Reported sender' : 'Unverifiable report'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (verified) ...[
              Text(
                'Sender: ${detail['sender_username'] ?? '(unknown)'}\n'
                'ID: ${detail['sender_id']}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text('Type: ${detail['message_type'] ?? ''}'),
              const SizedBox(height: 8),
              Text(
                'Reported content:\n${detail['payload'] ?? ''}',
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
            ] else
              const Text(
                'This report’s franking proof did not verify and cannot be '
                'acted on. No sender identity was recovered.',
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'dismiss'),
            child: const Text('Dismiss'),
          ),
          if (verified)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'ban'),
              child: const Text('Ban sender'),
            ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    try {
      await api.resolveCsamReport(reportID, action);
      if (!mounted) return;
      showAppToast(context, action == 'ban' ? 'Sender banned' : 'Report dismissed');
      _reload();
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, 'Failed to resolve: $e', isError: true);
    }
  }
}

String _csamShortId(Object? id) {
  final s = id?.toString() ?? '';
  return s.length > 8 ? s.substring(0, 8) : s;
}

String _shortTime(Object? iso) {
  final parsed = DateTime.tryParse(iso?.toString() ?? '');
  if (parsed == null) return 'recently';
  final d = DateTime.now().difference(parsed.toLocal());
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

class _CsamError extends StatelessWidget {
  final VoidCallback onRetry;
  final String error;
  const _CsamError({required this.onRetry, required this.error});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Text('Could not load reports.\n$error', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          GlassButtonWidget(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _ModerationSection extends StatelessWidget {
  final Future<_ModerationAdminData> future;
  final VoidCallback onRetry;

  const _ModerationSection({
    super.key,
    required this.future,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_ModerationAdminData>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const _LoadingCard(label: 'Loading moderation queue');
        }
        if (snapshot.hasError) {
          return _ErrorCard(
            label: 'Moderation queue unavailable',
            onRetry: onRetry,
          );
        }
        final data = snapshot.data!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _AdminSectionHeader('Global moderation'),
            if (data.reports.isEmpty)
              const _EmptyCard(
                icon: Icons.shield_outlined,
                title: 'No open reports',
                subtitle: 'Conversation and channel reports appear here.',
              )
            else
              for (final report in data.reports) _ReportCard(report: report),
            const SizedBox(height: 18),
            const _AdminSectionHeader('System-admin audit'),
            if (data.auditEvents.isEmpty)
              const _EmptyCard(
                icon: Icons.history_toggle_off_rounded,
                title: 'No audit events',
                subtitle: 'Privileged actions will appear in this feed.',
              )
            else
              for (final event in data.auditEvents)
                _AuditEventCard(event: event),
          ],
        );
      },
    );
  }
}

class _HealthSection extends StatelessWidget {
  final Future<OperatorMetrics> future;
  final VoidCallback onRetry;

  const _HealthSection({
    super.key,
    required this.future,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<OperatorMetrics>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const _LoadingCard(label: 'Loading server health');
        }
        if (snapshot.hasError) {
          return _ErrorCard(
            label: 'Server health unavailable',
            onRetry: onRetry,
          );
        }
        final metrics = snapshot.data!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _HealthHero(metrics: metrics),
            const SizedBox(height: 18),
            const _AdminSectionHeader('Push delivery'),
            _PushMetricsCard(push: metrics.push),
            const SizedBox(height: 18),
            const _AdminSectionHeader('Database pool'),
            _DatabaseMetricsCard(db: metrics.db),
            const SizedBox(height: 18),
            const _AdminSectionHeader('Realtime hub'),
            _HubMetricsCard(hub: metrics.hub),
          ],
        );
      },
    );
  }
}

class _ModerationAdminData {
  final List<ModerationReport> reports;
  final List<SystemAdminAuditEvent> auditEvents;

  const _ModerationAdminData({
    required this.reports,
    required this.auditEvents,
  });
}

class _ReportCard extends StatelessWidget {
  final ModerationReport report;

  const _ReportCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final reported = report.reportedUsername == null
        ? _shortId(report.reportedUserId)
        : '@${report.reportedUsername}';
    final reporter = report.reporterUsername == null
        ? _shortId(report.reporterUserId)
        : '@${report.reporterUsername}';
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CircleIcon(icon: Icons.report_outlined, color: Colors.orange),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  report.messageId == null
                      ? 'Conversation report'
                      : 'Reported message ${_shortId(report.messageId)}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'By $reporter · Target $reported · ${_relativeAge(report.createdAt)}',
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.62),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (report.reason.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    report.reason.trim(),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          _StatusPill(label: report.status, color: _statusColor(report.status)),
        ],
      ),
    );
  }
}

class _AuditEventCard extends StatelessWidget {
  final SystemAdminAuditEvent event;

  const _AuditEventCard({required this.event});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CircleIcon(icon: _auditIcon(event.action), color: Colors.indigo),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _actionLabel(event.action),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${event.actorLabel} · ${event.targetLabel} · ${_relativeAge(event.createdAt)}',
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.62),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HealthHero extends StatelessWidget {
  final OperatorMetrics metrics;

  const _HealthHero({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final push = metrics.push;
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          const _CircleIcon(
            icon: Icons.monitor_heart_outlined,
            color: Colors.green,
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Server Health',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                ),
                SizedBox(height: 4),
                Text(
                  'Operator counters',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          _StatusPill(
            label: push.enabled ? 'Push on' : 'Push off',
            color: push.enabled ? Colors.green : Colors.orange,
          ),
        ],
      ),
    );
  }
}

class _PushMetricsCard extends StatelessWidget {
  final PushOperatorMetrics push;

  const _PushMetricsCard({required this.push});

  @override
  Widget build(BuildContext context) {
    final queueFill = push.queueFill;
    final queueColor = _queueColor(push);
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          _MetricRow(
            icon: Icons.send_rounded,
            label: 'Sent',
            value: _formatInt(push.sent),
            color: Colors.green,
          ),
          const _MetricDivider(),
          _MetricRow(
            icon: Icons.report_gmailerrorred_rounded,
            label: 'Failed',
            value: _formatInt(push.failed),
            color: push.failed > 0 ? Colors.orange : Colors.green,
          ),
          const _MetricDivider(),
          _MetricRow(
            icon: Icons.playlist_remove_rounded,
            label: 'Dropped',
            value: _formatInt(push.dropped),
            color: push.dropped > 0 ? Colors.red : Colors.green,
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Queue',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
              Text(
                '${_formatInt(push.queueDepth)} / ${_formatInt(push.queueCapacity)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GlassProgressIndicator.linear(
            value: queueFill ?? 0,
            color: queueColor,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.10),
          ),
        ],
      ),
    );
  }
}

class _DatabaseMetricsCard extends StatelessWidget {
  final DatabaseOperatorMetrics db;

  const _DatabaseMetricsCard({required this.db});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          _MetricRow(
            icon: Icons.storage_rounded,
            label: 'Connections',
            value:
                '${_formatInt(db.acquiredConnections)} / ${_formatInt(db.maxConnections)}',
          ),
          const _MetricDivider(),
          _MetricRow(
            icon: Icons.layers_outlined,
            label: 'Total',
            value: _formatInt(db.totalConnections),
          ),
          const _MetricDivider(),
          _MetricRow(
            icon: Icons.hourglass_empty_rounded,
            label: 'Idle',
            value: _formatInt(db.idleConnections),
          ),
          const _MetricDivider(),
          _MetricRow(
            icon: Icons.timeline_rounded,
            label: 'Acquire count',
            value: _formatInt(db.acquireCount),
          ),
          const _MetricDivider(),
          _MetricRow(
            icon: Icons.warning_amber_rounded,
            label: 'Empty acquires',
            value: _formatInt(db.emptyAcquireCount),
            color: db.emptyAcquireCount > 0 ? Colors.orange : Colors.green,
          ),
        ],
      ),
    );
  }
}

class _HubMetricsCard extends StatelessWidget {
  final HubOperatorMetrics hub;

  const _HubMetricsCard({required this.hub});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          _MetricRow(
            icon: Icons.people_alt_outlined,
            label: 'Users',
            value: _formatInt(hub.users),
          ),
          const _MetricDivider(),
          _MetricRow(
            icon: Icons.hub_outlined,
            label: 'Connections',
            value: _formatInt(hub.connections),
          ),
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  const _MetricRow({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? scheme.primary;
    return Row(
      children: [
        _CircleIcon(icon: icon, color: tint, size: 34, iconSize: 18),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
        ),
      ],
    );
  }
}

class _CircleIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final double iconSize;

  const _CircleIcon({
    required this.icon,
    required this.color,
    this.size = 44,
    this.iconSize = 22,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.13),
      ),
      child: Icon(icon, color: color, size: iconSize),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.24), width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w800,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  final String label;

  const _LoadingCard({required this.label});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          const GlassProgressIndicator.circular(size: 22, strokeWidth: 2),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String label;
  final VoidCallback onRetry;

  const _ErrorCard({required this.label, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded, color: scheme.error),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          GlassButtonWidget.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          ),
        ],
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _EmptyCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          _CircleIcon(icon: icon, color: scheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.62),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminSectionHeader extends StatelessWidget {
  final String label;

  const _AdminSectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.62),
          fontSize: 12,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _MetricDivider extends StatelessWidget {
  const _MetricDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Divider(
        height: 1,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
      ),
    );
  }
}

Color _queueColor(PushOperatorMetrics push) {
  final fill = push.queueFill;
  if (fill == null) return Colors.green;
  if (fill >= 0.9) return Colors.red;
  if (fill >= 0.65) return Colors.orange;
  return Colors.green;
}

Color _statusColor(String status) {
  return switch (status) {
    'open' => Colors.orange,
    'resolved' => Colors.green,
    'dismissed' => Colors.blueGrey,
    _ => Colors.blueGrey,
  };
}

IconData _auditIcon(String action) {
  if (action.contains('ban')) return Icons.block_rounded;
  if (action.contains('premium')) return Icons.workspace_premium_outlined;
  if (action.contains('scammer')) return Icons.flag_outlined;
  return Icons.admin_panel_settings_outlined;
}

String _actionLabel(String action) {
  return action
      .split('_')
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
}

String _shortId(String? id) {
  if (id == null || id.isEmpty) return 'unknown';
  return id.length <= 8 ? id : id.substring(0, 8);
}

String _relativeAge(DateTime at) {
  final age = DateTime.now().difference(at);
  if (age.inMinutes < 1) return 'now';
  if (age.inHours < 1) return '${age.inMinutes}m ago';
  if (age.inDays < 1) return '${age.inHours}h ago';
  return '${age.inDays}d ago';
}

String _formatInt(int value) {
  final text = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final remaining = text.length - i;
    buffer.write(text[i]);
    if (remaining > 1 && remaining % 3 == 1) {
      buffer.write(',');
    }
  }
  return buffer.toString();
}
