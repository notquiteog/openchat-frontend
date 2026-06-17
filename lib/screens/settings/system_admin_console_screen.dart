import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/operator_metrics.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';

class SystemAdminConsoleScreen extends StatefulWidget {
  const SystemAdminConsoleScreen({super.key});

  @override
  State<SystemAdminConsoleScreen> createState() =>
      _SystemAdminConsoleScreenState();
}

class _SystemAdminConsoleScreenState extends State<SystemAdminConsoleScreen> {
  Future<OperatorMetrics>? _metricsFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _metricsFuture ??= context.read<ApiService>().getAdminMetrics();
  }

  void _refresh({bool toast = false}) {
    final future = context.read<ApiService>().getAdminMetrics();
    setState(() => _metricsFuture = future);
    if (toast) {
      future
          .then((_) {
            if (mounted) showAppToast(context, 'Metrics refreshed');
          })
          .catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassScreenScaffold(
      title: const Text('System Admin'),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: GlassCircleIconButton(
            tooltip: 'Refresh metrics',
            onPressed: () => _refresh(toast: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
      ],
      body: FutureBuilder<OperatorMetrics>(
        future: _metricsFuture,
        builder: (context, snapshot) {
          return ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.paddingOf(context).top + kToolbarHeight + 16,
              16,
              MediaQuery.paddingOf(context).bottom + 28,
            ),
            children: [
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData)
                const _LoadingCard()
              else if (snapshot.hasError)
                _ErrorCard(onRetry: () => _refresh())
              else if (snapshot.hasData)
                ..._MetricsContent(metrics: snapshot.data!).build(context),
            ],
          );
        },
      ),
    );
  }
}

class _MetricsContent {
  final OperatorMetrics metrics;

  const _MetricsContent({required this.metrics});

  List<Widget> build(BuildContext context) {
    return [
      _HealthHero(metrics: metrics),
      const SizedBox(height: 18),
      const _AdminSectionHeader('Push Delivery'),
      _PushMetricsCard(push: metrics.push),
      const SizedBox(height: 18),
      const _AdminSectionHeader('Database Pool'),
      _DatabaseMetricsCard(db: metrics.db),
      const SizedBox(height: 18),
      const _AdminSectionHeader('Realtime Hub'),
      _HubMetricsCard(hub: metrics.hub),
    ];
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return const GlassCard(
      padding: EdgeInsets.all(22),
      child: Row(
        children: [
          GlassProgressIndicator.circular(size: 22, strokeWidth: 2),
          SizedBox(width: 14),
          Text(
            'Loading operator metrics',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final VoidCallback onRetry;

  const _ErrorCard({required this.onRetry});

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
              const Expanded(
                child: Text(
                  'Metrics unavailable',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
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

class _HealthHero extends StatelessWidget {
  final OperatorMetrics metrics;

  const _HealthHero({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final push = metrics.push;
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: 0.13),
            ),
            child: Icon(
              Icons.monitor_heart_outlined,
              color: scheme.primary,
              size: 25,
            ),
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
                SizedBox(height: 3),
                Text(
                  'Operator counters',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
        crossAxisAlignment: CrossAxisAlignment.start,
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
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: tint.withValues(alpha: 0.13),
          ),
          child: Icon(icon, color: tint, size: 18),
        ),
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
