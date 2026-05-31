import 'package:flutter/foundation.dart';
import '../crypto/pgp_service.dart';
import '../models/user.dart';
import '../services/api_service.dart';
import '../services/secure_storage_service.dart';

enum AuthState { unknown, unauthenticated, authenticated }

class AuthProvider extends ChangeNotifier {
  final ApiService _api;
  final SecureStorageService _storage;

  AuthState _state = AuthState.unknown;
  User? _currentUser;
  String? _error;
  bool _isLoading = false;

  AuthState get state => _state;
  User? get currentUser => _currentUser;
  String? get error => _error;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _state == AuthState.authenticated;

  AuthProvider(this._api, this._storage);

  Future<void> initialize() async {
    final loggedIn = await _storage.isLoggedIn();
    if (!loggedIn) {
      _state = AuthState.unauthenticated;
      notifyListeners();
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
    notifyListeners();
  }

  /// Register: generates PGP key pair, registers with server, saves keys locally.
  Future<void> register({
    required String username,
    required String password,
    KeyType keyType = KeyType.curve25519,
    String? keyPassphrase,
  }) async {
    _setLoading(true);
    try {
      final keyPair = switch (keyType) {
        KeyType.rsa4096 => await PgpService.generateRsaKeyPair(username: username, passphrase: keyPassphrase),
        KeyType.pqc     => await PgpService.generatePqcKeyPair(username: username, passphrase: keyPassphrase),
        _               => await PgpService.generateKeyPair(username: username, passphrase: keyPassphrase),
      };

      final auth = await _api.register(
        username: username,
        password: password,
        publicKey: keyPair.publicKeyArmored,
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

      _currentUser = auth.user;
      _state = AuthState.authenticated;
      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> login({
    required String username,
    required String password,
  }) async {
    _error = null;
    _setLoading(true);
    try {
      final hasKeys = await _storage.hasKeyPair();
      if (!hasKeys) {
        _error = 'No PGP key found on this device. '
            'Import your key in Settings or register a new account.';
        _setLoading(false);
        return;
      }

      final auth = await _api.login(username: username, password: password);

      await _storage.saveSession(
        userID: auth.user.id,
        username: auth.user.username,
        accessToken: auth.accessToken,
        refreshToken: auth.refreshToken,
      );

      _currentUser = auth.user;
      _state = AuthState.authenticated;
      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _setLoading(false);
    }
  }

  /// Reload the current user's profile from the server (e.g. after editing bio/avatar).
  Future<void> refreshCurrentUser() async {
    try {
      _currentUser = await _api.getMe();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> logout() async {
    await _storage.clearSession();
    _currentUser = null;
    _state = AuthState.unauthenticated;
    _error = null;
    notifyListeners();
  }

  void _setLoading(bool v) {
    _isLoading = v;
    notifyListeners();
  }
}

