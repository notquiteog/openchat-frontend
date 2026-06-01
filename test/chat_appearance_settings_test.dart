import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('chat appearance stores the current user bubble color for any chat',
      () async {
    SharedPreferences.setMockInitialValues({});
    final provider = SettingsProvider();
    await provider.load();

    await provider.setChatStyle(
      'channel-1',
      const ChatStyle(myBubbleColor: 0xFF26323A),
    );

    expect(provider.chatStyleFor('channel-1').myBubbleColor, 0xFF26323A);
  });
}
