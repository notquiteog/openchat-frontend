import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/utils/device_label.dart';

void main() {
  test('openChatDeviceName maps platforms to operating systems', () {
    expect(
      openChatDeviceName(isWeb: false, platform: TargetPlatform.linux),
      'Linux',
    );
    expect(
      openChatDeviceName(isWeb: false, platform: TargetPlatform.windows),
      'Windows',
    );
    expect(
      openChatDeviceName(isWeb: true, platform: TargetPlatform.android),
      'Web',
    );
  });

  test('sessionDeviceDisplayLabel prefers explicit device names', () {
    expect(
      sessionDeviceDisplayLabel({
        'device_name': 'macOS',
        'user_agent': 'Dart/3.12',
      }),
      'macOS',
    );
  });

  test('sessionDeviceDisplayLabel hides raw Dart user agents', () {
    expect(
      sessionDeviceDisplayLabel({'user_agent': 'Dart/3.12'}),
      'OpenChat session',
    );
  });

  test('sessionDeviceDisplayLabel derives an OS from browser user agents', () {
    expect(
      sessionDeviceDisplayLabel({
        'user_agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      }),
      'Windows',
    );
    expect(
      sessionDeviceDisplayLabel({
        'device_name': 'Dart/3.12',
        'user_agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36',
      }),
      'Linux',
    );
  });
}
