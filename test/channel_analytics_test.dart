import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/channel_analytics.dart';

void main() {
  test('channel analytics parses growth averages and top posts', () {
    final analytics = ChannelAnalytics.fromJson({
      'conversation_id': 'channel-1',
      'subscribers': 1200,
      'subscriber_growth_7d': 18,
      'subscriber_growth_30d': 84,
      'posts': 44,
      'posts_7d': 6,
      'posts_30d': 19,
      'reactions': 310,
      'reactions_7d': 42,
      'reactions_30d': 140,
      'views': 9800,
      'views_on_posts_7d': 1600,
      'views_on_posts_30d': 4400,
      'avg_reactions_per_post': 7.04,
      'avg_views_per_post': 222.72,
      'generated_at': '2026-06-04T19:20:00Z',
      'top_posts': [
        {
          'message_id': 'msg-1',
          'message_type': 'image',
          'created_at': '2026-06-03T18:00:00Z',
          'views': 2400,
          'reactions': 91,
        },
      ],
    });

    expect(analytics.conversationId, 'channel-1');
    expect(analytics.subscriberGrowth7d, 18);
    expect(analytics.viewsOnPosts30d, 4400);
    expect(analytics.avgReactionsPerPost, 7.04);
    expect(analytics.generatedAt?.toUtc(), DateTime.utc(2026, 6, 4, 19, 20));
    expect(analytics.topPosts.single.messageType, 'image');
    expect(analytics.topPosts.single.views, 2400);
  });

  test('channel analytics tolerates older minimal stats responses', () {
    final analytics = ChannelAnalytics.fromJson({
      'conversation_id': 'channel-1',
      'subscribers': '5',
      'posts': 2,
      'reactions': 1,
      'views': 12,
    });

    expect(analytics.subscribers, 5);
    expect(analytics.posts7d, 0);
    expect(analytics.avgViewsPerPost, 0);
    expect(analytics.topPosts, isEmpty);
    expect(analytics.generatedAt, isNull);
  });
}
