import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/channel_analytics.dart';
import '../../models/conversation.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';

class ChannelAnalyticsScreen extends StatefulWidget {
  final Conversation conversation;

  const ChannelAnalyticsScreen({super.key, required this.conversation});

  @override
  State<ChannelAnalyticsScreen> createState() => _ChannelAnalyticsScreenState();
}

class _ChannelAnalyticsScreenState extends State<ChannelAnalyticsScreen> {
  ChannelAnalytics? _analytics;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final analytics = await context.read<ApiService>().getChannelStats(
        widget.conversation.id,
      );
      if (!mounted) return;
      setState(() => _analytics = analytics);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final analytics = _analytics;
    return Scaffold(
      appBar: GlassAppBar(
        title: const Text('Analytics'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading && analytics == null
          ? const Center(child: CircularProgressIndicator())
          : analytics == null
          ? _AnalyticsError(error: _error, onRetry: _load)
          : RefreshIndicator(
              onRefresh: _load,
              child: _AnalyticsContent(
                analytics: analytics,
                channelName: widget.conversation.name ?? 'Channel',
              ),
            ),
    );
  }
}

class _AnalyticsContent extends StatelessWidget {
  final ChannelAnalytics analytics;
  final String channelName;

  const _AnalyticsContent({required this.analytics, required this.channelName});

  @override
  Widget build(BuildContext context) {
    final generatedAt = analytics.generatedAt;
    final generatedLabel = generatedAt == null
        ? null
        : DateFormat('MMM d, h:mm a').format(generatedAt.toLocal());
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        Text(
          channelName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        if (generatedLabel != null) ...[
          const SizedBox(height: 4),
          Text(
            'Updated $generatedLabel',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.58),
            ),
          ),
        ],
        const SizedBox(height: 16),
        _MetricGrid(
          metrics: [
            _MetricData(
              icon: Icons.group_outlined,
              label: 'Subscribers',
              value: analytics.subscribers,
              detail: _signed(analytics.subscriberGrowth7d, '7d'),
            ),
            _MetricData(
              icon: Icons.article_outlined,
              label: 'Posts',
              value: analytics.posts,
              detail: _signed(analytics.posts7d, '7d'),
            ),
            _MetricData(
              icon: Icons.visibility_outlined,
              label: 'Views',
              value: analytics.views,
              detail: '${_compact(analytics.viewsOnPosts7d)} on 7d posts',
            ),
            _MetricData(
              icon: Icons.favorite_border_rounded,
              label: 'Reactions',
              value: analytics.reactions,
              detail: _signed(analytics.reactions7d, '7d'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _TrendPanel(analytics: analytics),
        const SizedBox(height: 14),
        _PerformancePanel(analytics: analytics),
        const SizedBox(height: 14),
        _TopPostsPanel(posts: analytics.topPosts),
      ],
    );
  }
}

class _MetricData {
  final IconData icon;
  final String label;
  final int value;
  final String detail;

  const _MetricData({
    required this.icon,
    required this.label,
    required this.value,
    required this.detail,
  });
}

class _MetricGrid extends StatelessWidget {
  final List<_MetricData> metrics;

  const _MetricGrid({required this.metrics});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 760 ? 4 : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: metrics.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: columns == 4 ? 1.55 : 1.28,
          ),
          itemBuilder: (context, index) => _MetricTile(metric: metrics[index]),
        );
      },
    );
  }
}

class _MetricTile extends StatelessWidget {
  final _MetricData metric;

  const _MetricTile({required this.metric});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: 0.14),
                ),
                child: Icon(metric.icon, color: scheme.primary, size: 18),
              ),
              const Spacer(),
            ],
          ),
          const Spacer(),
          FittedBox(
            alignment: Alignment.centerLeft,
            fit: BoxFit.scaleDown,
            child: Text(
              _compact(metric.value),
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            metric.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            metric.detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.58),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrendPanel extends StatelessWidget {
  final ChannelAnalytics analytics;

  const _TrendPanel({required this.analytics});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelTitle(icon: Icons.trending_up_rounded, title: 'Growth'),
          const SizedBox(height: 8),
          _TrendRow(
            label: 'Subscribers',
            sevenDay: analytics.subscriberGrowth7d,
            thirtyDay: analytics.subscriberGrowth30d,
          ),
          _TrendRow(
            label: 'Posts',
            sevenDay: analytics.posts7d,
            thirtyDay: analytics.posts30d,
          ),
          _TrendRow(
            label: 'Reactions',
            sevenDay: analytics.reactions7d,
            thirtyDay: analytics.reactions30d,
          ),
          _TrendRow(
            label: 'Views on posts',
            sevenDay: analytics.viewsOnPosts7d,
            thirtyDay: analytics.viewsOnPosts30d,
          ),
        ],
      ),
    );
  }
}

class _TrendRow extends StatelessWidget {
  final String label;
  final int sevenDay;
  final int thirtyDay;

  const _TrendRow({
    required this.label,
    required this.sevenDay,
    required this.thirtyDay,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          _PeriodValue(label: '7d', value: sevenDay, color: scheme.primary),
          const SizedBox(width: 8),
          _PeriodValue(label: '30d', value: thirtyDay, color: scheme.tertiary),
        ],
      ),
    );
  }
}

class _PeriodValue extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _PeriodValue({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 82,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              _compact(value),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class _PerformancePanel extends StatelessWidget {
  final ChannelAnalytics analytics;

  const _PerformancePanel({required this.analytics});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelTitle(icon: Icons.insights_outlined, title: 'Post performance'),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _AverageBlock(
                  label: 'Views per post',
                  value: analytics.avgViewsPerPost,
                  icon: Icons.visibility_outlined,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _AverageBlock(
                  label: 'Reactions per post',
                  value: analytics.avgReactionsPerPost,
                  icon: Icons.favorite_border_rounded,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AverageBlock extends StatelessWidget {
  final String label;
  final double value;
  final IconData icon;

  const _AverageBlock({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 86),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.20),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.28),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.secondary),
          const SizedBox(height: 8),
          FittedBox(
            alignment: Alignment.centerLeft,
            fit: BoxFit.scaleDown,
            child: Text(
              _average(value),
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.60),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopPostsPanel extends StatelessWidget {
  final List<ChannelTopPost> posts;

  const _TopPostsPanel({required this.posts});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelTitle(icon: Icons.leaderboard_outlined, title: 'Top posts'),
          const SizedBox(height: 8),
          if (posts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text(
                  'No posts yet',
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.58),
                  ),
                ),
              ),
            )
          else
            for (final (index, post) in posts.indexed) ...[
              _TopPostRow(rank: index + 1, post: post),
              if (index != posts.length - 1) const Divider(height: 1),
            ],
        ],
      ),
    );
  }
}

class _TopPostRow extends StatelessWidget {
  final int rank;
  final ChannelTopPost post;

  const _TopPostRow({required this.rank, required this.post});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final date = DateFormat('MMM d, h:mm a').format(post.createdAt.toLocal());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.secondary.withValues(alpha: 0.14),
            ),
            child: Text(
              '#$rank',
              style: TextStyle(
                color: scheme.secondary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _messageTypeLabel(post.messageType),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  date,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.58),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _TinyStat(icon: Icons.visibility_outlined, value: post.views),
          const SizedBox(width: 8),
          _TinyStat(icon: Icons.favorite_border_rounded, value: post.reactions),
        ],
      ),
    );
  }
}

class _TinyStat extends StatelessWidget {
  final IconData icon;
  final int value;

  const _TinyStat({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 58,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Icon(icon, size: 15, color: scheme.onSurface.withValues(alpha: 0.54)),
          const SizedBox(width: 3),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _compact(value),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelTitle extends StatelessWidget {
  final IconData icon;
  final String title;

  const _PanelTitle({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 20, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}

class _AnalyticsError extends StatelessWidget {
  final Object? error;
  final VoidCallback onRetry;

  const _AnalyticsError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.query_stats_outlined, size: 42),
            const SizedBox(height: 12),
            Text(
              'Analytics unavailable',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              error?.toString() ?? 'Try again in a moment.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

String _compact(num value) => NumberFormat.compact().format(value);

String _signed(int value, String period) {
  final prefix = value > 0 ? '+' : '';
  return '$prefix${_compact(value)} $period';
}

String _average(double value) {
  if (value >= 100) return NumberFormat.compact().format(value);
  return value.toStringAsFixed(value >= 10 ? 1 : 2);
}

String _messageTypeLabel(String type) => switch (type) {
  'image' => 'Image post',
  'video' => 'Video post',
  'voice' => 'Voice post',
  'audio' => 'Audio post',
  'file' => 'File post',
  'poll' => 'Poll',
  'checklist' => 'Checklist',
  'payment_request' => 'Payment request',
  'payment_transfer' => 'Payment transfer',
  'location' => 'Location',
  'venue' => 'Venue',
  'contact' => 'Contact',
  'sticker' => 'Sticker',
  _ => 'Text post',
};
