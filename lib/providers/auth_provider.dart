import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../crypto/pgp_service.dart';
import '../models/key_trust_pin.dart';
import '../models/user.dart';
import '../services/api_service.dart';
import '../services/call_history_service.dart';
import '../services/key_cache_service.dart';
import '../services/local_private_state_service.dart';
import '../services/push_notification_service.dart';
import '../services/secure_storage_service.dart';

enum AuthState { unknown, unauthenticated, authenticated }

class AuthProvider extends ChangeNotifier {
  final ApiService _api;
  final SecureStorageService _storage;
  // Device-global stores wiped at logout so the next account on this device
  // can't inherit the previous one's call log or drafts/private local state.
  // Inject the app's shared instances where available (main.dart passes the
  // live CallHistoryService) so their cached key material is reset too.
  final CallHistoryService _callHistory;
  final LocalPrivateStateService _privateState;

  AuthState _state = AuthState.unknown;
  User? _currentUser;
  String? _error;
  String? _storageWarning;
  bool _twoFactorRequired = false;
  bool _isLoading = false;

  AuthState get state => _state;
  User? get currentUser => _currentUser;
  String? get error => _error;
  String? get storageWarning => _storageWarning;
  bool get twoFactorRequired => _twoFactorRequired;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _state == AuthState.authenticated;

  AuthProvider(
    this._api,
    this._storage, {
    CallHistoryService? callHistoryService,
    LocalPrivateStateService? localPrivateStateService,
  }) : _callHistory = callHistoryService ?? CallHistoryService(_storage),
       _privateState =
           localPrivateStateService ??
           LocalPrivateStateService(storage: _storage);

  Future<void> initialize() async {
    try {
      _storageWarning = null;
      final storageStatus = await _storage.checkAvailability();
      if (!storageStatus.available) {
        _storageWarning = storageStatus.warning;
        _currentUser = null;
        _state = AuthState.unauthenticated;
        return;
      }

      final loggedIn = await _storage.isLoggedIn();
      if (!loggedIn) {
        _state = AuthState.unauthenticated;
        return;
      }
      try {
        _currentUser = await _api.getMe();
        _state = AuthState.authenticated;
      } catch (_) {
        try {
          await _api.refreshTokens();
          _currentUser = await _api.getMe();
          _state = AuthState.authenticated;
        } catch (_) {
          await _storage.clearSession();
          _state = AuthState.unauthenticated;
        }
      }
    } on PlatformException catch (error) {
      if (!SecureStorageService.isRecoverableReadFailure(error)) rethrow;
      _storageWarning = SecureStorageService.warningFor(error);
      _currentUser = null;
      _state = AuthState.unauthenticated;
    } finally {
      notifyListeners();
    }
  }

  /// Register: generates PGP key pair, registers with server, saves keys locally.
  Future<void> register({
    required String username,
    String? displayName,
    required String password,
    bool publicDiscovery = true,
    KeyType keyType = KeyType.defaultType,
    String? keyPassphrase,
  }) async {
    _error = null;
    _storageWarning = null;
    _twoFactorRequired = false;
    _setLoading(true);
    try {
      final storageStatus = await _storage.checkAvailability();
      if (!_requireSecureStorage(storageStatus)) return;

      final keyPair = await PgpService.generateKeyPairForType(
        username: username,
        keyType: keyType,
        passphrase: keyPassphrase,
      );

      final auth = await _api.register(
        username: username,
        displayName: displayName,
        password: password,
        publicKey: keyPair.publicKeyArmored,
        publicDiscovery: publicDiscovery,
      );

      await _storage.saveKeyPair(
        privateKeyArmored: keyPair.privateKeyArmored,
        publicKeyArmored: keyPair.publicKeyArmored,
        fingerprint: keyPair.fingerprint,
      );

      await _storage.saveSession(
        userID: auth.user.id,
        username: auth.user.username,
        accessToken: auth.accessToken,
        refreshToken: auth.refreshToken,
      );
      await _pinUserKey(auth.user, keyPair.publicKeyArmored);

      _currentUser = auth.user;
      _state = AuthState.authenticated;
      _error = null;
      _storageWarning = null;
    } on PlatformException catch (error) {
      _setStorageError(error);
    } catch (e) {
      _error = e.toString();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> login({
    required String identifier,
    required String password,
    String? twoFactorPassword,
  }) async {
    _error = null;
    _storageWarning = null;
    _setLoading(true);
    try {
      final storageStatus = await _storage.checkAvailability();
      if (!_requireSecureStorage(storageStatus)) return;

      final hasKeys = await _storage.hasKeyPair();
      if (!hasKeys) {
        final currentStatus = await _storage.checkAvailability();
        if (!_requireSecureStorage(currentStatus)) return;

        _error =
            'No PGP key found on this device. '
            'Import your key in Settings or register a new account.';
        _setLoading(false);
        return;
      }

      final auth = await _api.login(
        identifier: identifier,
        password: password,
        twoFactorPassword: twoFactorPassword,
      );

      await _storage.saveSession(
        userID: auth.user.id,
        username: auth.user.username,
        accessToken: auth.accessToken,
        refreshToken: auth.refreshToken,
      );

      // Warn when the local key doesn't match the server's registered key.
      // This happens when a user restores an old key backup after a rotation —
      // messages encrypted to the newer server key will be undecryptable.
      final localFp = await _storage.getFingerprint() ?? '';
      final serverFp = auth.user.keyFingerprint;
      if (localFp.isNotEmpty &&
          serverFp.isNotEmpty &&
          localFp.toUpperCase() != serverFp.toUpperCase()) {
        _error =
            'Key mismatch: the key on this device (…${localFp.length >= 8 ? localFp.substring(localFp.length - 8) : localFp}) '
            'does not match your account key (…${serverFp.length >= 8 ? serverFp.substring(serverFp.length - 8) : serverFp}). '
            'Messages encrypted to your current account key will not decrypt. '
            'Import the correct key in Settings → PGP Keys.';
        // Still authenticate — the user may intentionally be using an old device.
      }
      final localPublicKey = await _storage.getPublicKey();
      if (localPublicKey != null &&
          localPublicKey.isNotEmpty &&
          localFp.toUpperCase() == serverFp.toUpperCase()) {
        await _pinUserKey(auth.user, localPublicKey);
      }

      _currentUser = auth.user;
      _state = AuthState.authenticated;
      _storageWarning = null;
      _twoFactorRequired = false;
    } on PlatformException catch (error) {
      _setStorageError(error);
    } on ApiException catch (e) {
      if (e.code == 'TWO_FACTOR_REQUIRED') {
        _twoFactorRequired = true;
        _error = 'Enter your 2FA password.';
      } else {
        _error = e.toString();
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> _pinUserKey(User user, String publicKey) async {
    if (user.id.isEmpty || user.keyFingerprint.isEmpty || publicKey.isEmpty) {
      return;
    }
    await _storage.saveKeyTrustPin(
      KeyTrustPin(
        userId: user.id,
        fingerprint: user.keyFingerprint.toUpperCase(),
        publicKeyHash: crypto.sha256
            .convert(utf8.encode(publicKey.trim()))
            .toString()
            .toUpperCase(),
        pinnedAt: DateTime.now(),
      ),
    );
  }

  /// Reload the current user's profile from the server (e.g. after editing bio/avatar).
  Future<void> refreshCurrentUser() async {
    try {
      _currentUser = await _api.getMe();
      notifyListeners();
    } catch (_) {}
  }

  /// Clears the session plus every device-global plaintext store the next
  /// account must not inherit. Each wipe is individually best-effort: one
  /// failing store must never leave the user stuck logged in (the duress /
  /// remote-wipe path additionally runs LocalWipeService.wipeEverything()
  /// BEFORE calling this, which destroys keys and files wholesale).
  /// ChatProvider.clearState() — invoked by the app shell when this state
  /// change lands — wipes the remaining stores it owns: decrypted-message
  /// cache (+ its at-rest key), search index, and offline outbox.
  Future<void> logout() async {
    // Revoke the session server-side and deregister THIS device's push token
    // while the access token is still valid — otherwise sign-out is local-only:
    // the session stays usable and the device keeps receiving push. Best-effort
    // so a network failure still completes the local wipe below.
    try {
      await PushNotificationService.disable(api: _api);
    } catch (_) {}
    try {
      await _api.logout();
    } catch (_) {}
    await _storage.clearSession();
    // Clear the public-key cache so stale entries from this session can't
    // affect the next login (different user, or same user with a new key).
    try {
      await KeyCacheService.clear();
    } catch (_) {}
    // Local call log: rows are not user-scoped.
    try {
      await _callHistory.clear();
    } catch (_) {}
    // Encrypted private local state: drafts, folders, private contacts,
    // hidden conversations — all belong to the account logging out.
    try {
      await _privateState.clearState();
    } catch (_) {}
    _currentUser = null;
    _state = AuthState.unauthenticated;
    _error = null;
    _storageWarning = null;
    _twoFactorRequired = false;
    notifyListeners();
  }

  bool _requireSecureStorage(SecureStorageStatus status) {
    if (status.available) return true;
    _storageWarning = status.warning;
    _error = status.warning;
    return false;
  }

  void _setStorageError(PlatformException error) {
    final warning = SecureStorageService.warningFor(error);
    if (warning != null) {
      _storageWarning = warning;
      _error = warning;
      return;
    }
    _error = error.toString();
  }

  void _setLoading(bool v) {
    _isLoading = v;
    notifyListeners();
  }
}
