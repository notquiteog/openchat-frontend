class LinkPreview {
  final String url;
  final String resolvedUrl;
  final String siteName;
  final String title;
  final String description;
  final String imageUrl;
  final DateTime fetchedAt;

  const LinkPreview({
    required this.url,
    required this.resolvedUrl,
    this.siteName = '',
    this.title = '',
    this.description = '',
    this.imageUrl = '',
    required this.fetchedAt,
  });

  factory LinkPreview.fromJson(Map<String, dynamic> json) => LinkPreview(
    url: json['url'] as String? ?? '',
    resolvedUrl: json['resolved_url'] as String? ?? '',
    siteName: json['site_name'] as String? ?? '',
    title: json['title'] as String? ?? '',
    description: json['description'] as String? ?? '',
    imageUrl: json['image_url'] as String? ?? '',
    fetchedAt: DateTime.parse(json['fetched_at'] as String),
  );

  factory LinkPreview.local({
    required String url,
    String? resolvedUrl,
    String siteName = '',
    String title = '',
    String description = '',
    String imageUrl = '',
    DateTime? fetchedAt,
  }) => LinkPreview(
    url: url,
    resolvedUrl: resolvedUrl ?? url,
    siteName: siteName,
    title: title,
    description: description,
    imageUrl: imageUrl,
    fetchedAt: fetchedAt ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'url': url,
    'resolved_url': resolvedUrl,
    if (siteName.isNotEmpty) 'site_name': siteName,
    if (title.isNotEmpty) 'title': title,
    if (description.isNotEmpty) 'description': description,
    if (imageUrl.isNotEmpty) 'image_url': imageUrl,
    'fetched_at': fetchedAt.toUtc().toIso8601String(),
  };

  String get displayHost {
    final host = Uri.tryParse(resolvedUrl)?.host;
    if (host != null && host.isNotEmpty) return host;
    return Uri.tryParse(url)?.host ?? '';
  }
}
