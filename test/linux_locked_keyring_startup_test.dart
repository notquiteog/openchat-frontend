import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/auth_provider.dart';
import 'package:openchat/providers/key_provider.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';

void main() {
  test('auth startup shows logged-out state when Linux keyring is locked',
      () async {
    final storage = _LockedStartupStorage();
    final auth = AuthProvider(ApiService(storage), storage);

    await auth.initialize();

    expect(auth.state, AuthState.unauthenticated);
    expect(auth.storageWarning, contains('Linux keyring'));
  });

  test('login reports locked keyring before continuing', () async {
    final storage = _LockedStartupStorage();
    final auth = AuthProvider(ApiService(storage), storage);

    await auth.initialize();
    await auth.login(username: 'alice', password: 'password123');

    expect(auth.state, AuthState.unauthenticated);
    expect(auth.error, contains('Linux keyring'));
    expect(auth.storageWarning, contains('Linux keyring'));
  });

  test('register reports locked keyring before continuing', () async {
    final storage = _LockedStartupStorage();
    final auth = AuthProvider(ApiService(storage), storage);

    await auth.initialize();
    await auth.register(username: 'alice', password: 'password123');

    expect(auth.state, AuthState.unauthenticated);
    expect(auth.error, contains('Linux keyring'));
    expect(auth.storageWarning, contains('Linux keyring'));
  });

  test('key startup ignores unavailable Linux keyring', () async {
    final keys = KeyProvider(_LockedStartupStorage());

    await expectLater(keys.load(), completes);

    expect(keys.hasKey, isFalse);
    expect(keys.fingerprint, isNull);
    expect(keys.publicKey, isNull);
  });

  test('auth startup surfaces unexpected secure storage failures', () async {
    final storage = _BrokenStartupStorage();
    final auth = AuthProvider(ApiService(storage), storage);

    await expectLater(
      auth.initialize(),
      throwsA(isA<PlatformException>()),
    );
  });

  test('key startup surfaces unexpected secure storage failures', () async {
    final keys = KeyProvider(_BrokenStartupStorage());

    await expectLater(
      keys.load(),
      throwsA(isA<PlatformException>()),
    );
  });
}

class _LockedStartupStorage extends SecureStorageService {
  static PlatformException get _locked => PlatformException(
        code: 'KeyringLocked',
        message: 'KeyringLocked',
      );

  @override
  Future<bool> isLoggedIn() => Future<bool>.error(_locked);

  @override
  Future<SecureStorageStatus> checkAvailability() async {
    return const SecureStorageStatus.unavailable(
      SecureStorageService.linuxKeyringWarning,
    );
  }

  @override
  Future<String?> getFingerprint() => Future<String?>.error(_locked);

  @override
  Future<String?> getPublicKey() => Future<String?>.error(_locked);
}

class _BrokenStartupStorage extends SecureStorageService {
  static PlatformException get _broken => PlatformException(
        code: 'StorageError',
        message: 'unexpected storage failure',
      );

  @override
  Future<bool> isLoggedIn() => Future<bool>.error(_broken);

  @override
  Future<SecureStorageStatus> checkAvailability() async {
    return const SecureStorageStatus.available();
  }

  @override
  Future<String?> getFingerprint() => Future<String?>.error(_broken);
}
