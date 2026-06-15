const openChatPackScheme = 'openchat';
const openChatStickerPackHost = 'addstickers';
const openChatEmojiPackHost = 'addemoji';

enum PackKind { sticker, customEmoji }

class PackLink {
  final PackKind kind;
  final String packId;

  const PackLink({required this.kind, required this.packId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PackLink && other.kind == kind && other.packId == packId;

  @override
  int get hashCode => Object.hash(kind, packId);
}

String packDeepLink({required PackKind kind, required String packId}) => Uri(
  scheme: openChatPackScheme,
  host: switch (kind) {
    PackKind.sticker => openChatStickerPackHost,
    PackKind.customEmoji => openChatEmojiPackHost,
  },
  pathSegments: [packId],
).toString();

PackLink? packLinkFromUri(Uri uri) {
  if (uri.scheme.toLowerCase() != openChatPackScheme) return null;
  final kind = switch (uri.host.toLowerCase()) {
    openChatStickerPackHost => PackKind.sticker,
    openChatEmojiPackHost => PackKind.customEmoji,
    _ => null,
  };
  if (kind == null) return null;

  final rawPackId = uri.pathSegments.isNotEmpty
      ? uri.pathSegments.first
      : uri.queryParameters['id'] ?? uri.queryParameters['pack'];
  final packId = rawPackId?.trim();
  if (packId == null || packId.isEmpty || packId.length > 128) return null;
  return PackLink(kind: kind, packId: packId);
}
