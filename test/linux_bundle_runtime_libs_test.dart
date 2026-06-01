import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bundles Linux tray runtime libraries from ldconfig', () async {
    final temp = await Directory.systemTemp.createTemp('openchat-linux-libs-');
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final bundle = Directory('${temp.path}/bundle');
    final bundleLib = Directory('${bundle.path}/lib');
    final systemLib = Directory('${temp.path}/system-lib');
    await bundleLib.create(recursive: true);
    await systemLib.create(recursive: true);

    const sonames = [
      'libayatana-appindicator3.so.1',
      'libayatana-indicator3.so.7',
      'libayatana-ido3-0.4.so.0',
      'libdbusmenu-glib.so.4',
      'libdbusmenu-gtk3.so.4',
    ];
    for (final soname in sonames) {
      await File('${systemLib.path}/$soname').writeAsString('fake $soname');
    }

    final fakeLdconfig = File('${temp.path}/ldconfig');
    await fakeLdconfig.writeAsString('''
#!/usr/bin/env bash
cat <<'EOF'
${sonames.map((soname) => '\t$soname (libc6,x86-64) => ${systemLib.path}/$soname').join('\n')}
EOF
''');
    final chmod = await Process.run('chmod', ['+x', fakeLdconfig.path]);
    expect(chmod.exitCode, 0, reason: '${chmod.stderr}\n${chmod.stdout}');

    final result = await Process.run(
      'bash',
      ['packaging/linux/bundle_tray_libs.sh', bundle.path],
      environment: {'LDCONFIG': fakeLdconfig.path},
    );

    expect(result.exitCode, 0, reason: '${result.stderr}\n${result.stdout}');
    for (final soname in sonames) {
      expect(await File('${bundleLib.path}/$soname').exists(), isTrue);
    }
  });
}
