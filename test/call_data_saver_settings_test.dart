import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/services/network_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('call data-saver defaults preserve current behavior', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider();
    await settings.load();

    expect(settings.callDataSaverMode, CallDataSaverMode.off);
    expect(settings.callVoiceOnlyOnMobile, isFalse);
    expect(settings.dataSaverActive(NetworkClass.wifi), isFalse);
    expect(settings.dataSaverActive(NetworkClass.mobile), isFalse);
    expect(settings.voiceOnlyForNetwork(NetworkClass.mobile), isFalse);
  });

  test('call data-saver auto mode and voice-only mobile persist', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider();
    await settings.load();
    await settings.setCallDataSaverMode(CallDataSaverMode.auto);
    await settings.setCallVoiceOnlyOnMobile(true);

    expect(settings.dataSaverActive(NetworkClass.wifi), isFalse);
    expect(settings.dataSaverActive(NetworkClass.mobile), isTrue);
    expect(settings.voiceOnlyForNetwork(NetworkClass.wifi), isFalse);
    expect(settings.voiceOnlyForNetwork(NetworkClass.mobile), isTrue);

    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.callDataSaverMode, CallDataSaverMode.auto);
    expect(reloaded.callVoiceOnlyOnMobile, isTrue);
  });
}
