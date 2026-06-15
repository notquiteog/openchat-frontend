class StoryViewer {
  final String userId;
  final String username;
  final String? displayName;
  final String? avatarUrl;
  final String? reaction;
  final DateTime viewedAt;

  const StoryViewer({
    required this.userId,
    required this.username,
    this.displayName,
    this.avatarUrl,
    this.reaction,
    required this.viewedAt,
  });

  factory StoryViewer.fromJson(Map<String, dynamic> json) => StoryViewer(
    userId: json['user_id'] as String,
    username: json['username'] as String? ?? '',
    displayName: json['display_name'] as String?,
    avatarUrl: json['avatar_url'] as String?,
    reaction: json['reaction'] as String?,
    viewedAt: DateTime.parse(json['viewed_at'] as String),
  );
}
