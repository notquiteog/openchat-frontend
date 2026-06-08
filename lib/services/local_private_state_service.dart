import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/broadcast_list.dart';
import '../models/chat_folder.dart';
import '../models/contact_bundle.dart';
import '../utils/local_conversation_preferences.dart';
import 'secure_storage_service.dart';

const localPrivateStatePreferenceKey = 'local_private_state_v1';
const privateStateConversationNotificationPreferencesKey =
    'conversation_notification_preferences';
const privateStateChatFoldersKey = 'chat_folders';
const privateStateBroadcastListsKey = 'broadcast_lists';
// Maps opaque push route tokens -> conversation ids, so the (foreground and
// background-isolate) push handlers can resolve a notification's `route` to a
// conversation without the real id ever passing through FCM/APNs.
const privateStatePushRouteMapKey = 'push_route_map';
const privateStateCloseFriendsKey = 'close_friends';
const privateStateNotificationSettingsKey = 'notification_settings';
const privateStateMessageDraftsKey = 'message_drafts';
const privateStatePinnedChannelMessagesKey = 'pinned_channel_messages';
const privateStatePinnedConversationsKey = 'pinned_conversations';
const privateStateArchivedConversationsKey = 'archived_conversations';
const privateStateUnreadMentionMessageIdsKey = 'unread_mention_message_ids';
const privateStatePrivateContactsKey = 'private_contacts';
const privateStatePrivacyOnboardingViewedUserIdsKey =
    'privacy_onboarding_viewed_user_ids';
const privateStateMessageRemindersKey = 'message_reminders';
const privateStateViewedOnceMediaKey = 'viewed_once_media_message_ids';

class PrivateNotificationSettings {
  final bool pushEnabled;
  final bool wsBackgroundEnabled;
  final bool sensitiveContent;

  const PrivateNotificationSettings({
    this.pushEnabled = false,
    this.wsBackgroundEnabled = false,
    this.sensitiveContent = false,
  });
}

PrivateNotificationSettings decodePrivateNotificationSettings(Object? raw) {
  if (raw is! Map) return const PrivateNotificationSettings();
  return PrivateNotificationSettings(
    pushEnabled: raw['push_enabled'] as bool? ?? false,
    wsBackgroundEnabled: raw['ws_background_enabled'] as bool? ?? false,
    sensitiveContent: raw['sensitive_content'] as bool? ?? false,
  );
}

Map<String, dynamic> encodePrivateNotificationSettings({
  required bool pushEnabled,
  required bool wsBackgroundEnabled,
  required bool sensitiveContent,
}) => {
  'push_enabled': pushEnabled,
  'ws_background_enabled': wsBackgroundEnabled,
  'sensitive_content': sensitiveContent,
};

Map<String, ConversationNotificationPreference>
decodePrivateConversationNotificationPreferences(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, ConversationNotificationPreference>{};
  for (final entry in raw.entries) {
    final conversationId = entry.key.toString();
    if (conversationId.isEmpty || entry.value is! Map) continue;
    final preference = ConversationNotificationPreference.fromJson(
      Map<String, dynamic>.from(entry.value as Map),
    );
    if (!preference.isDefault) out[conversationId] = preference;
  }
  return out;
}

Map<String, dynamic> encodePrivateConversationNotificationPreferences(
  Map<String, ConversationNotificationPreference> preferences,
) {
  final normalized = <String, dynamic>{};
  for (final entry in preferences.entries) {
    if (entry.key.isEmpty || entry.value.isDefault) continue;
    normalized[entry.key] = entry.value.toJson();
  }
  return normalized;
}

List<ChatFolder> decodePrivateChatFolders(Object? raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((item) => ChatFolder.fromJson(Map<String, dynamic>.from(item)))
      .where((folder) => folder.id.isNotEmpty && folder.name.trim().isNotEmpty)
      .toList();
}

List<BroadcastList> decodePrivateBroadcastLists(Object? raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((item) => BroadcastList.fromJson(Map<String, dynamic>.from(item)))
      .where((list) => list.id.isNotEmpty && list.name.trim().isNotEmpty)
      .toList();
}

List<Map<String, dynamic>> encodePrivateBroadcastLists(
  Iterable<BroadcastList> lists,
) => lists
    .where((list) => list.id.isNotEmpty && list.name.trim().isNotEmpty)
    .map((list) => list.toJson())
    .toList();

List<Map<String, dynamic>> encodePrivateChatFolders(
  Iterable<ChatFolder> folders,
) => folders
    .where((folder) => folder.id.isNotEmpty && folder.name.trim().isNotEmpty)
    .map((folder) => folder.toJson())
    .toList();

Map<String, ContactBundle> decodePrivateContacts(Object? raw) {
  if (raw is! List) return const {};
  final contacts = <String, ContactBundle>{};
  for (final item in raw.whereType<Map>()) {
    final contact = ContactBundle.fromJson(Map<String, dynamic>.from(item));
    if (contact.isUsable) contacts[contact.userId] = contact;
  }
  return contacts;
}

List<Map<String, dynamic>> encodePrivateContacts(
  Iterable<ContactBundle> contacts,
) => contacts
    .where((contact) => contact.isUsable)
    .map((contact) => contact.toJson())
    .toList();

/// Decodes the persisted opaque push routing map (route token -> conversation
/// id). Returns an empty map when absent or malformed.
Map<String, String> decodePushRouteMap(Object? raw) {
  if (raw is! Map) return {};
  final out = <String, String>{};
  raw.forEach((key, value) {
    if (key is String && value != null) out[key] = value.toString();
  });
  return out;
}

/// Encrypts small local-only app state that should not be visible to the
/// server or stored as plaintext SharedPreferences.
class LocalPrivateStateService {
  final SecureStorageService _storage;
  final String _preferenceKey;
  final Future<List<int>> Function()? _keyLoader;
  final _cipher = AesGcm.with256bits();

  SecretKey? _secretKey;
  static List<int>? _testFallbackKeyBytes;

  LocalPrivateStateService({
    SecureStorageService? storage,
    String preferenceKey = localPrivateStatePreferenceKey,
    Future<List<int>> Function()? keyLoader,
  }) : this._(storage ?? SecureStorageService(), preferenceKey, keyLoader);

  LocalPrivateStateService._(
    this._storage,
    this._preferenceKey,
    this._keyLoader,
  );

  Future<bool> hasState() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_preferenceKey);
  }

  Future<Map<String, dynamic>> readState() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(_preferenceKey);
    if (encoded == null || encoded.trim().isEmpty) return const {};
    try {
      return await _decryptJson(encoded);
    } catch (_) {
      return const {};
    }
  }

  Future<void> writeState(Map<String, Object?> state) async {
    final prefs = await SharedPreferences.getInstance();
    final encrypted = await _encryptJson({'version': 1, ...state});
    await prefs.setString(_preferenceKey, encrypted);
  }

  Future<void> clearState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_preferenceKey);
  }

  Future<String> _encryptJson(Map<String, Object?> json) async {
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(json)),
      secretKey: await _secret(),
    );
    return base64Encode(box.concatenation());
  }

  Future<Map<String, dynamic>> _decryptJson(String encoded) async {
    final box = SecretBox.fromConcatenation(
      base64Decode(encoded),
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
    );
    final bytes = await _cipher.decrypt(box, secretKey: await _secret());
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    return const {};
  }

  Future<SecretKey> _secret() async {
    final existing = _secretKey;
    if (existing != null) return existing;
    final bytes = await _loadKeyBytes();
    final key = SecretKey(bytes);
    _secretKey = key;
    return key;
  }

  Future<List<int>> _loadKeyBytes() async {
    final loader = _keyLoader;
    if (loader != null) return loader();
    try {
      return base64Decode(await _storage.getOrCreateLocalPrivateStateKey());
    } on FlutterError {
      return _testFallbackKey();
    } on MissingPluginException {
      return _testFallbackKey();
    } on PlatformException catch (error) {
      if (!SecureStorageService.isRecoverableReadFailure(error)) rethrow;
      return _testFallbackKey();
    }
  }

  static List<int> _testFallbackKey() {
    final existing = _testFallbackKeyBytes;
    if (existing != null) return existing;
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    _testFallbackKeyBytes = bytes;
    return bytes;
  }
}
