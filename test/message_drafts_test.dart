import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/channel_pinned_message.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/services/local_private_state_service.dart';
import 'package:openchat/utils/local_conversation_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('message drafts persist and reload by conversation', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = SettingsProvider();
    await provider.load();

    await provider.setMessageDraft('conv-1', '  see you soon  ');

    final draft = provider.messageDraftFor('conv-1');
    expect(draft?.text, '  see you soon  ');
    expect(draft?.preview, 'see you soon');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('message_draft_conv-1'), isNull);
    final encrypted = prefs.getString(localPrivateStatePreferenceKey);
    expect(encrypted, isNotNull);
    expect(encrypted, isNot(contains('see you soon')));

    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.messageDraftFor('conv-1')?.text, '  see you soon  ');
  });

  test('message drafts persist composer metadata', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = SettingsProvider();
    await provider.load();
    final scheduledFor = DateTime.utc(2026, 6, 5, 18, 30);
    const entity = CustomEmojiEntity(
      offset: 3,
      length: 2,
      customEmojiId: 'emoji-1',
      emoji: '🙂',
      fileUrl: '/emoji.webp',
    );

    await provider.setMessageDraft(
      'conv-1',
      'hi 🙂 later',
      customEmojiEntities: const [entity],
      sendSilent: true,
      scheduledFor: scheduledFor,
    );

    final reloaded = SettingsProvider();
    await reloaded.load();
    final draft = reloaded.messageDraftFor('conv-1');

    expect(draft?.text, 'hi 🙂 later');
    expect(draft?.sendSilent, isTrue);
    expect(draft?.scheduledFor, scheduledFor.toLocal());
    expect(draft?.customEmojiEntities.single.customEmojiId, 'emoji-1');
    expect(draft?.customEmojiEntities.single.fileUrl, '/emoji.webp');
  });

  test('legacy plaintext message draft json is ignored and removed', () async {
    SharedPreferences.setMockInitialValues({
      'message_draft_conv-1':
          '{"text":"old draft","updated_at_ms":1780617600000}',
    });
    final provider = SettingsProvider();
    await provider.load();

    final draft = provider.messageDraftFor('conv-1');

    expect(draft, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('message_draft_conv-1'), isNull);
  });

  test('empty message draft clears stored draft', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = SettingsProvider();
    await provider.load();

    await provider.setMessageDraft('conv-1', 'hello');
    await provider.setMessageDraft('conv-1', '   ');

    expect(provider.messageDraftFor('conv-1'), isNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('message_draft_conv-1'), isNull);
  });

  test('pinned conversations persist in settings', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = SettingsProvider();
    await provider.load();

    await provider.setConversationPinned('conv-2', true);
    await provider.setConversationPinned('conv-1', true);

    expect(provider.isConversationPinned('conv-1'), isTrue);
    expect(provider.isConversationPinned('conv-2'), isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('pinned_conversations'), isNull);
    final encrypted = prefs.getString(localPrivateStatePreferenceKey);
    expect(encrypted, isNotNull);
    expect(encrypted, isNot(contains('conv-1')));
    expect(encrypted, isNot(contains('conv-2')));

    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.pinnedConversationIds, {'conv-1', 'conv-2'});

    await reloaded.setConversationPinned('conv-1', false);
    expect(reloaded.pinnedConversationIds, {'conv-2'});
  });

  test(
    'unread mention targets persist only in encrypted private state',
    () async {
      SharedPreferences.setMockInitialValues({});
      final provider = SettingsProvider();
      await provider.load();

      await provider.setUnreadMentionMessage('conv-1', 'msg-1');

      expect(provider.unreadMentionMessageIdFor('conv-1'), 'msg-1');
      final prefs = await SharedPreferences.getInstance();
      final encrypted = prefs.getString(localPrivateStatePreferenceKey);
      expect(encrypted, isNotNull);
      expect(encrypted, isNot(contains('conv-1')));
      expect(encrypted, isNot(contains('msg-1')));

      final reloaded = SettingsProvider();
      await reloaded.load();
      expect(reloaded.unreadMentionMessageIdFor('conv-1'), 'msg-1');

      await reloaded.clearUnreadMention('conv-1', messageID: 'other');
      expect(reloaded.unreadMentionMessageIdFor('conv-1'), 'msg-1');
      await reloaded.clearUnreadMention('conv-1', messageID: 'msg-1');
      expect(reloaded.unreadMentionMessageIdFor('conv-1'), isNull);
    },
  );

  test('archived conversations persist in settings', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = SettingsProvider();
    await provider.load();

    await provider.setConversationArchived('conv-2', true);
    await provider.setConversationArchived('conv-1', true);

    expect(provider.isConversationArchived('conv-1'), isTrue);
    expect(provider.isConversationArchived('conv-2'), isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('archived_conversations'), isNull);
    final encrypted = prefs.getString(localPrivateStatePreferenceKey);
    expect(encrypted, isNotNull);
    expect(encrypted, isNot(contains('conv-1')));
    expect(encrypted, isNot(contains('conv-2')));

    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.archivedConversationIds, {'conv-1', 'conv-2'});

    await reloaded.setConversationArchived('conv-2', false);
    expect(reloaded.archivedConversationIds, {'conv-1'});
  });

  test('muted conversations persist in settings', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = SettingsProvider();
    await provider.load();

    await provider.setConversationMuted('conv-2', true);
    await provider.setConversationMuted('conv-1', true);

    expect(provider.isConversationMuted('conv-1'), isTrue);
    expect(provider.isConversationMuted('conv-2'), isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('muted_conversations'), isNull);
    final encrypted = prefs.getString(localPrivateStatePreferenceKey);
    expect(encrypted, isNotNull);
    expect(encrypted, isNot(contains('conv-1')));
    expect(encrypted, isNot(contains('conv-2')));

    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.mutedConversationIds, {'conv-1', 'conv-2'});

    await reloaded.setConversationMuted('conv-2', false);
    expect(reloaded.mutedConversationIds, {'conv-1'});
  });

  test('conversation notification modes persist in settings', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = SettingsProvider();
    await provider.load();

    final mutedUntil = DateTime.now().add(const Duration(hours: 2));
    await provider.muteConversationUntil('conv-muted', mutedUntil);
    await provider.setConversationMentionsOnly('conv-mentions');

    expect(provider.isConversationMuted('conv-muted'), isTrue);
    expect(provider.isConversationMentionsOnly('conv-mentions'), isTrue);
    expect(provider.mutedConversationIds, {'conv-muted'});

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('muted_conversations'), isNull);
    expect(prefs.getString('conversation_notification_preferences_v1'), isNull);
    final encrypted = prefs.getString(localPrivateStatePreferenceKey);
    expect(encrypted, isNotNull);
    expect(encrypted, isNot(contains('conv-muted')));
    expect(encrypted, isNot(contains('conv-mentions')));

    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.isConversationMuted('conv-muted'), isTrue);
    expect(reloaded.isConversationMentionsOnly('conv-mentions'), isTrue);

    await reloaded.setConversationNotificationPreference(
      'conv-muted',
      const ConversationNotificationPreference.all(),
    );
    expect(reloaded.isConversationMuted('conv-muted'), isFalse);
  });

  test('pinned channel messages persist in settings', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = SettingsProvider();
    await provider.load();

    await provider.setChannelMessagePinned(
      'channel-1',
      ChannelPinnedMessage(
        messageId: 'msg-1',
        preview: 'First announcement',
        messageCreatedAt: DateTime.utc(2026, 1, 1),
        pinnedAt: DateTime.utc(2026, 1, 2),
        senderUsername: 'alice',
      ),
      true,
    );
    await provider.setChannelMessagePinned(
      'channel-1',
      ChannelPinnedMessage(
        messageId: 'msg-2',
        preview: 'Second announcement',
        messageCreatedAt: DateTime.utc(2026, 1, 3),
        pinnedAt: DateTime.utc(2026, 1, 4),
      ),
      true,
    );

    expect(provider.isChannelMessagePinned('channel-1', 'msg-1'), isTrue);
    expect(provider.isChannelMessagePinned('channel-1', 'msg-2'), isTrue);
    expect(
      provider
          .pinnedMessagesForChannel('channel-1')
          .map((message) => message.messageId),
      ['msg-2', 'msg-1'],
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('pinned_channel_messages_channel-1'), isNull);
    final encrypted = prefs.getString(localPrivateStatePreferenceKey);
    expect(encrypted, isNotNull);
    expect(encrypted, isNot(contains('First announcement')));
    expect(encrypted, isNot(contains('msg-1')));

    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(
      reloaded.pinnedMessagesForChannel('channel-1').first.preview,
      'Second announcement',
    );

    await reloaded.unpinChannelMessage('channel-1', 'msg-2');
    expect(
      reloaded
          .pinnedMessagesForChannel('channel-1')
          .map((message) => message.messageId),
      ['msg-1'],
    );
  });

  test('channel pinned message parses shared server payload', () {
    final pinned = ChannelPinnedMessage.fromJson({
      'conversation_id': 'channel-1',
      'message_id': 'msg-1',
      'pinned_by': 'admin-1',
      'pinned_at': '2026-01-04T12:00:00Z',
      'message': {
        'id': 'msg-1',
        'conversation_id': 'channel-1',
        'sender_id': 'user-1',
        'message_type': 'text',
        'encrypted_payload': 'ciphertext',
        'signature': 'signature',
        'is_encrypted': true,
        'auto_delete_seconds': 0,
        'silent': false,
        'created_at': '2026-01-03T12:00:00Z',
        'sender': {
          'id': 'user-1',
          'username': 'alice',
          'public_key': 'pub',
          'key_fingerprint': 'fp',
          'is_bot': false,
          'role': 'user',
          'is_flagged_scammer': false,
          'is_banned': false,
          'allow_group_add': true,
          'created_at': '2026-01-01T12:00:00Z',
        },
      },
    });

    expect(pinned.conversationId, 'channel-1');
    expect(pinned.messageId, 'msg-1');
    expect(pinned.pinnedBy, 'admin-1');
    expect(pinned.senderUsername, 'alice');
    expect(pinned.message?.encryptedPayload, 'ciphertext');
    expect(pinned.messageCreatedAt.toUtc(), DateTime.utc(2026, 1, 3, 12));
    expect(pinned.pinnedAt.toUtc(), DateTime.utc(2026, 1, 4, 12));
  });
}
