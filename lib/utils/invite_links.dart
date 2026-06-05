const openChatInviteScheme = 'openchat';
const openChatInviteHost = 'invite';

String inviteDeepLink({required String token}) => Uri(
  scheme: openChatInviteScheme,
  host: openChatInviteHost,
  pathSegments: [token],
).toString();

String? inviteTokenFromUri(Uri uri) {
  if (uri.scheme.toLowerCase() != openChatInviteScheme) return null;
  if (uri.host.toLowerCase() != openChatInviteHost) return null;

  final token = uri.pathSegments.isNotEmpty
      ? uri.pathSegments.first
      : uri.queryParameters['token'];
  final trimmed = token?.trim();
  if (trimmed == null || trimmed.isEmpty || trimmed.length > 128) {
    return null;
  }
  return trimmed;
}
