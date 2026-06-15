import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/desktop_autostart_service.dart';
import 'package:openchat/services/desktop_startup_service.dart';

void main() {
  tearDown(() {
    DesktopAutostartService.debugSupportedOverride = null;
    DesktopAutostartService.debugSandboxedOverride = null;
  });

  test('supported mirrors desktop startup support', () {
    expect(DesktopAutostartService.supported, DesktopStartupService.supported);
  });

  test('sandboxed autostart calls are non-fatal no-ops', () async {
    DesktopAutostartService.debugSupportedOverride = true;
    DesktopAutostartService.debugSandboxedOverride = true;

    await expectLater(DesktopAutostartService.setup(), completes);
    await expectLater(DesktopAutostartService.enable(), completes);
    await expectLater(DesktopAutostartService.disable(), completes);
    await expectLater(DesktopAutostartService.isEnabled(), completion(false));
  });
}
