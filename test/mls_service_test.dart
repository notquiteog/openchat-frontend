import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/mls_service.dart';
import 'package:openmls/openmls.dart';

void main() {
  test('OpenMLS binding supports the default X-Wing ciphersuite', () async {
    final libraryPath = _bundledOpenMlsLibraryPath();
    expect(
      libraryPath,
      isNotNull,
      reason: 'OpenMLS build hook did not provide a native library.',
    );

    await Openmls.init(libraryPath: libraryPath);
    addTearDown(Openmls.cleanup);

    expect(supportedCiphersuites(), contains(MlsService.defaultCiphersuite));
  });
}

String? _bundledOpenMlsLibraryPath() {
  final fileName = switch (Platform.operatingSystem) {
    'linux' => 'libopenmls_frb.so',
    'macos' => 'libopenmls_frb.dylib',
    'windows' => 'openmls_frb.dll',
    _ => null,
  };
  if (fileName == null) return null;

  for (final rootPath in const [
    'build/native_assets',
    '.dart_tool/hooks_runner/shared/openmls',
  ]) {
    final root = Directory(rootPath);
    if (!root.existsSync()) continue;
    for (final entity in root.listSync(recursive: true)) {
      if (entity is File && entity.uri.pathSegments.last == fileName) {
        return entity.absolute.path;
      }
    }
  }
  return null;
}
