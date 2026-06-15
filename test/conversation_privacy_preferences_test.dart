import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/services/local_private_state_service.dart';
import 'package:openchat/utils/local_conversation_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('conversation privacy preference json and helpers round-trip', () {
    const defaults = ConversationPrivacyPreference();
    const explicit = ConversationPrivacyPreference(
      shareTyping: false,
      shareReadReceipts: true,
    );

    expect(defaults.isDefault, isTrue);
    expect(defaults.toJson(), isEmpty);
    expect(explicit.toJson(), {
      'share_typing': false,
      'share_read_receipts': true,
    });
    expect(ConversationPrivacyPreference.fromJson(explicit.toJson()), explicit);
    expect(
      explicit.copyWith(clearShareTyping: true),
      const ConversationPrivacyPreference(shareReadReceipts: true),
    );

    final encoded = encodeConversationPrivacyPreferences({
      'conv-1': explicit,
      'conv-2': defaults,
    });
    final decoded = decodeConversationPrivacyPreferences(encoded);

    expect(decoded.keys, ['conv-1']);
    expect(decoded['conv-1'], explicit);
  });

  test(
    'conversation privacy resolution prefers per-chat over global strict',
    () {
      expect(resolveShareTyping(perChat: null, globalStrict: false), isTrue);
      expect(resolveShareTyping(perChat: null, globalStrict: true), isFalse);
      expect(resolveShareTyping(perChat: true, globalStrict: true), isTrue);
      expect(resolveShareTyping(perChat: false, globalStrict: false), isFalse);

      expect(
        resolveShareReadReceipts(perChat: null, globalStrict: false),
        isTrue,
      );
      expect(
        resolveShareReadReceipts(perChat: null, globalStrict: true),
        isFalse,
      );
      expect(
        resolveShareReadReceipts(perChat: true, globalStrict: true),
        isTrue,
      );
      expect(
        resolveShareReadReceipts(perChat: false, globalStrict: false),
        isFalse,
      );
    },
  );

  test(
    'settings provider persists privacy overrides in encrypted state',
    () async {
      SharedPreferences.setMockInitialValues({});

      final provider = SettingsProvider();
      await provider.load();

      expect(
        provider.privacyPreferenceForConversation('conv-1').isDefault,
        isTrue,
      );
      expect(provider.shareTypingForConversation('conv-1'), isTrue);

      await provider.setConversationShareTyping('conv-1', false);
      await provider.setConversationShareReadReceipts('conv-1', true);

      final prefs = await SharedPreferences.getInstance();
      final encrypted = prefs.getString(localPrivateStatePreferenceKey);
      expect(encrypted, isNotNull);
      expect(encrypted, isNot(contains('conv-1')));

      var state = await LocalPrivateStateService().readState();
      var decoded = decodeConversationPrivacyPreferences(
        state[privateStateConversationPrivacyPreferencesKey],
      );

      expect(decoded['conv-1']?.shareTyping, isFalse);
      expect(decoded['conv-1']?.shareReadReceipts, isTrue);

      final reloaded = SettingsProvider();
      await reloaded.load();

      expect(reloaded.shareTypingForConversation('conv-1'), isFalse);
      expect(reloaded.shareReadReceiptsForConversation('conv-1'), isTrue);

      await reloaded.setConversationShareTyping('conv-1', null);
      await reloaded.setConversationShareReadReceipts('conv-1', null);

      state = await LocalPrivateStateService().readState();
      decoded = decodeConversationPrivacyPreferences(
        state[privateStateConversationPrivacyPreferencesKey],
      );

      expect(decoded.containsKey('conv-1'), isFalse);
    },
  );
}
