class ChannelAnalytics {
  final String conversationId;
  final int subscribers;
  final int subscriberGrowth7d;
  final int subscriberGrowth30d;
  final int posts;
  final int posts7d;
  final int posts30d;
  final int reactions;
  final int reactions7d;
  final int reactions30d;
  final int views;
  final int viewsOnPosts7d;
  final int viewsOnPosts30d;
  final double avgReactionsPerPost;
  final double avgViewsPerPost;
  final List<ChannelTopPost> topPosts;
  final DateTime? generatedAt;

  const ChannelAnalytics({
    required this.conversationId,
    required this.subscribers,
    required this.subscriberGrowth7d,
    required this.subscriberGrowth30d,
    required this.posts,
    required this.posts7d,
    required this.posts30d,
    required this.reactions,
    required this.reactions7d,
    required this.reactions30d,
    required this.views,
    required this.viewsOnPosts7d,
    required this.viewsOnPosts30d,
    required this.avgReactionsPerPost,
    required this.avgViewsPerPost,
    required this.topPosts,
    required this.generatedAt,
  });

  factory ChannelAnalytics.fromJson(Map<String, dynamic> json) =>
      ChannelAnalytics(
        conversationId: json['conversation_id'] as String? ?? '',
        subscribers: _asInt(json['subscribers']),
        subscriberGrowth7d: _asInt(json['subscriber_growth_7d']),
        subscriberGrowth30d: _asInt(json['subscriber_growth_30d']),
        posts: _asInt(json['posts']),
        posts7d: _asInt(json['posts_7d']),
        posts30d: _asInt(json['posts_30d']),
        reactions: _asInt(json['reactions']),
        reactions7d: _asInt(json['reactions_7d']),
        reactions30d: _asInt(json['reactions_30d']),
        views: _asInt(json['views']),
        viewsOnPosts7d: _asInt(json['views_on_posts_7d']),
        viewsOnPosts30d: _asInt(json['views_on_posts_30d']),
        avgReactionsPerPost: _asDouble(json['avg_reactions_per_post']),
        avgViewsPerPost: _asDouble(json['avg_views_per_post']),
        topPosts: (json['top_posts'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (item) =>
                  ChannelTopPost.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList(growable: false),
        generatedAt: _parseDate(json['generated_at']),
      );
}

class ChannelTopPost {
  final String messageId;
  final String messageType;
  final DateTime createdAt;
  final int views;
  final int reactions;

  const ChannelTopPost({
    required this.messageId,
    required this.messageType,
    required this.createdAt,
    required this.views,
    required this.reactions,
  });

  factory ChannelTopPost.fromJson(Map<String, dynamic> json) => ChannelTopPost(
    messageId: json['message_id'] as String? ?? '',
    messageType: json['message_type'] as String? ?? 'text',
    createdAt:
        _parseDate(json['created_at']) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    views: _asInt(json['views']),
    reactions: _asInt(json['reactions']),
  );
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

double _asDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

DateTime? _parseDate(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
}
