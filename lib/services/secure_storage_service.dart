import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../models/key_trust_pin.dart';
import '../models/recent_nearby_peer.dart';
import '../utils/app_lock_grace.dart';

class SecureStorageStatus {
  final bool available;
  final String? warning;

  const SecureStorageStatus.available() : available = true, warning = null;

  const SecureStorageStatus.unavailable(this.warning) : available = false;
}

/// Thrown when secure storage is temporarily unavailable (e.g. the Linux
/// keyring is locked at launch) at the moment a key protecting an *existing*
/// encrypted store is read. Callers must degrade for this session — NOT mint a
/// replacement key, which would orphan the store — and may surface [message].
class SecureStorageUnavailableException implements Exception {
  final String message;

  const SecureStorageUnavailableException(this.message);

  @override
  String toString() => 'SecureStorageUnavailableException: $message';
}

class MlsSignerStorage {
  final String signerBytes;
  final String publicKey;
  final String signature;

  const MlsSignerStorage({
    required this.signerBytes,
    required this.publicKey,
    this.signature = '',
  });
}

/// Manages secure storage of cryptographic keys and session tokens.
///
/// Platform backing:
/// - iOS/macOS: Keychain
/// - Android: EncryptedSharedPreferences + Android Keystore
/// - Windows: Windows Credential Manager
/// - Linux: libsecret (GNOME Keyring / KWallet)
/// How an entered app-lock PIN classified: the real unlock code, the duress
/// code (decoy session or silent wipe per configuration), or wrong.
enum AppLockPinKind { real, duress, invalid }

class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock),
    lOptions: LinuxOptions(),
    wOptions: WindowsOptions(),
  );

  static const _keyPrivateKey = 'pgp_private_key';
  static const _keyPublicKey = 'pgp_public_key';
  static const _keyFingerprint = 'pgp_fingerprint';
  static const _keyUsername = 'username';
  static const _keyUserID = 'user_id';
  static const _keyAccessToken = 'access_token';
  static const _keyRefreshToken = 'refresh_token';
  static const _keyBiometricEnabled = 'biometric_enabled';
  static const _keyAppLockEnabled = 'app_lock_enabled';
  static const _keySendJitter = 'send_jitter_enabled';
  static const _keyAppLockPin = 'app_lock_pin_v1';
  static const _keyDuressPin = 'app_lock_duress_pin_v1';
  static const _keyDuressAction = 'app_lock_duress_action_v1';
  static const _keyAppLockGraceSeconds = 'app_lock_grace_seconds_v1';
  static const _keyDeadmanDays = 'deadman_days_v1';
  static const _keyLastRealUnlockAt = 'last_real_unlock_at_v1';
  static const _keyRecoveryShareHeldPrefix = 'recovery_share_held_v1';
  static const _keyKtSthCache = 'kt_sth_cache_v1';
  static const _keyAmfKeysCache = 'amf_keys_cache_v1';
  static const _keyKtLogAlarm = 'kt_log_alarm_v1';
  static const _keyForceTurn = 'force_turn_calls';
  static const _keyScreenSecurity = 'screen_security_enabled';
  static const _keyProxyConfig = 'proxy_config_v1';
  static const _keyConversationPins = 'conversation_pins_v1';
  static const _keySearchIndexKey = 'search_index_key_v1';
  static const _keyOutboxKey = 'offline_outbox_key_v1';
  static const _keyLocalPrivateStateKey = 'local_private_state_key_v1';
  static const _keyMessageCacheKey = 'message_cache_key_v1';
  static const _keyTrustPins = 'key_trust_pins_v1';
  static const _keyMlsEngineKeyPrefix = 'mls_engine_key_v1';
  static const _keyMlsSignerBytesPrefix = 'mls_signer_bytes_v1';
  static const _keyMlsSignerPublicKeyPrefix = 'mls_signer_public_key_v1';
  static const _keyMlsSignerSignaturePrefix = 'mls_signer_signature_v1';
  static const _keyMlsCredentialIdentityPrefix = 'mls_credential_identity_v1';
  static const _keyPgpPostTokenPrefix = 'pgp_post_token_v1';
  static const _keyPollVoteTokenPrefix = 'poll_vote_token_v1';
  static const _keyPollMyVotesPrefix = 'poll_my_votes_v1';
  static const _keySealedScheduleControlsPrefix = 'sealed_schedule_controls_v1';
  static const _keySealedMessageControlsPrefix = 'sealed_message_controls_v1';
  static const _keyScheduledPlaintextPrefix = 'scheduled_plaintext_v1';
  static const _keySelfStateLogSequence = 'self_state_log_sequence_v1';
  static const _keyRecentNearbyPeers = 'recent_nearby_peers_v1';
  static const _keyRecentNearbyHistoryEnabled =
      'recent_nearby_history_enabled_v1';
  static const _keyStorageProbe = '_openchat_secure_storage_probe';

  static const linuxKeyringWarning =
      'OpenChat cannot access your Linux keyring. Unlock GNOME Keyring or '
      'KWallet and try again. If you use autologin or passwordless login, '
      'sign in with your password so the keyring can unlock.';

  // ---- In-memory session state (kept for migration compatibility) ----

  /// Legacy key-session state. Biometric key unlock now protects only private
  /// key export, but older provider code may still read this value.
  bool _keySessionUnlocked = false;

  bool get isKeySessionUnlocked => _keySessionUnlocked;
  void unlockKeySession() => _keySessionUnlocked = true;
  void lockKeySession() => _keySessionUnlocked = false;

  // ---- PGP keys ----

  Future<SecureStorageStatus> checkAvailability() async {
    try {
      await _storage.write(key: _keyStorageProbe, value: 'ok');
      final value = await _storage.read(key: _keyStorageProbe);
      await _storage.delete(key: _keyStorageProbe);
      if (value == 'ok') return const SecureStorageStatus.available();
      return const SecureStorageStatus.unavailable(linuxKeyringWarning);
    } on PlatformException catch (error) {
      final warning = warningFor(error);
      if (warning != null) return SecureStorageStatus.unavailable(warning);
      rethrow;
    }
  }

  Future<void> saveKeyPair({
    required String privateKeyArmored,
    required String publicKeyArmored,
    required String fingerprint,
  }) async {
    await _storage.write(key: _keyPrivateKey, value: privateKeyArmored);
    await _storage.write(key: _keyPublicKey, value: publicKeyArmored);
    await _storage.write(key: _keyFingerprint, value: fingerprint);
  }

  Future<String?> getPrivateKey() => _readOrNull(_keyPrivateKey);
  Future<String?> getPublicKey() => _readOrNull(_keyPublicKey);
  Future<String?> getFingerprint() => _readOrNull(_keyFingerprint);

  Future<bool> hasKeyPair() async {
    final fp = await getFingerprint();
    return fp != null && fp.isNotEmpty;
  }

  Future<void> deleteKeyPair() async {
    await Future.wait([
      _storage.delete(key: _keyPrivateKey),
      _storage.delete(key: _keyPublicKey),
      _storage.delete(key: _keyFingerprint),
    ]);
  }

  // ---- Session ----

  Future<void> saveSession({
    required String userID,
    required String username,
    required String accessToken,
    required String refreshToken,
  }) async {
    await _storage.write(key: _keyUserID, value: userID);
    await _storage.write(key: _keyUsername, value: username);
    await _storage.write(key: _keyAccessToken, value: accessToken);
    await _storage.write(key: _keyRefreshToken, value: refreshToken);
  }

  Future<String?> getAccessToken() => _readOrNull(_keyAccessToken);
  Future<String?> getRefreshToken() => _readOrNull(_keyRefreshToken);
  Future<String?> getUserID() => _readOrNull(_keyUserID);
  Future<String?> getUsername() => _readOrNull(_keyUsername);

  /// Key for the local full-text search index. Resilient: a locked keyring at
  /// launch returns a throwaway session key rather than overwriting the real
  /// one, so the index DB survives and recovers once the keyring unlocks (the
  /// index just reads empty this session, then rebuilds).
  Future<String> getOrCreateSearchIndexKey() =>
      _getOrCreateResilientKey(_keySearchIndexKey);

  /// Key for the offline outbox. Resilient — see [getOrCreateSearchIndexKey].
  Future<String> getOrCreateOutboxKey() =>
      _getOrCreateResilientKey(_keyOutboxKey);

  /// Key for local private state. Resilient — see [getOrCreateSearchIndexKey].
  Future<String> getOrCreateLocalPrivateStateKey() =>
      _getOrCreateResilientKey(_keyLocalPrivateStateKey);

  /// Key for the at-rest decrypted-message cache. Uses [_getOrCreateProtectedKey]
  /// so a locked keyring at launch cannot mint a fresh key that orphans the
  /// cache DB — which would make every past MLS message show "Unable to decrypt"
  /// after a restart.
  Future<String> getOrCreateMessageCacheKey() =>
      _getOrCreateProtectedKey(_keyMessageCacheKey);

  /// Deletes the at-rest cache key (shared by the message cache and call
  /// history DBs). Called at logout after their rows are cleared so any
  /// residual ciphertext (sqlite free pages, WAL) becomes undecryptable
  /// garbage; the next account mints a fresh key on first use.
  Future<void> deleteMessageCacheKey() =>
      _storage.delete(key: _keyMessageCacheKey);

  Future<Map<String, KeyTrustPin>> getKeyTrustPins() async {
    final raw = await _readOrNull(_keyTrustPins);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((key, value) {
        return MapEntry(
          key.toString(),
          KeyTrustPin.fromJson(Map<String, dynamic>.from(value as Map)),
        );
      });
    } catch (_) {
      return {};
    }
  }

  Future<KeyTrustPin?> getKeyTrustPin(String userId) async {
    final pins = await getKeyTrustPins();
    return pins[userId];
  }

  Future<void> saveKeyTrustPin(KeyTrustPin pin) async {
    final pins = await getKeyTrustPins();
    pins[pin.userId] = pin;
    await _storage.write(
      key: _keyTrustPins,
      value: jsonEncode(
        pins.map((key, value) => MapEntry(key, value.toJson())),
      ),
    );
  }

  /// SQLCipher key for the per-user MLS engine DB (group state + ratchet tree).
  /// Protected: a locked keyring must not mint a new key, which would orphan the
  /// engine DB and lose all group state (and thus all decryptable history).
  Future<String> getOrCreateMlsEngineKey(String userID) =>
      _getOrCreateProtectedKey(_scopedKey(_keyMlsEngineKeyPrefix, userID));

  /// Stable MLS credential identity. Protected so a locked keyring can't mint a
  /// new identity that would diverge from the one baked into existing groups.
  Future<String> getOrCreateMlsCredentialIdentity(String userID) =>
      _getOrCreateProtectedKey(
        _scopedKey(_keyMlsCredentialIdentityPrefix, userID),
      );

  Future<MlsSignerStorage?> getMlsSigner(String userID) async {
    final signer = await _readOrNull(
      _scopedKey(_keyMlsSignerBytesPrefix, userID),
    );
    final publicKey = await _readOrNull(
      _scopedKey(_keyMlsSignerPublicKeyPrefix, userID),
    );
    final signature =
        await _readOrNull(_scopedKey(_keyMlsSignerSignaturePrefix, userID)) ??
        '';
    if (signer == null ||
        signer.isEmpty ||
        publicKey == null ||
        publicKey.isEmpty) {
      return null;
    }
    return MlsSignerStorage(
      signerBytes: signer,
      publicKey: publicKey,
      signature: signature,
    );
  }

  Future<void> saveMlsSigner({
    required String userID,
    required String signerBytes,
    required String publicKey,
    String signature = '',
  }) async {
    await Future.wait([
      _storage.write(
        key: _scopedKey(_keyMlsSignerBytesPrefix, userID),
        value: signerBytes,
      ),
      _storage.write(
        key: _scopedKey(_keyMlsSignerPublicKeyPrefix, userID),
        value: publicKey,
      ),
      _storage.write(
        key: _scopedKey(_keyMlsSignerSignaturePrefix, userID),
        value: signature,
      ),
    ]);
  }

  Future<String?> getPgpPostToken(String conversationID) {
    return _readOrNull(_scopedKey(_keyPgpPostTokenPrefix, conversationID));
  }

  Future<void> savePgpPostToken(String conversationID, String token) {
    return _storage.write(
      key: _scopedKey(_keyPgpPostTokenPrefix, conversationID),
      value: token,
    );
  }

  Future<void> deletePgpPostToken(String conversationID) {
    return _storage.delete(
      key: _scopedKey(_keyPgpPostTokenPrefix, conversationID),
    );
  }

  /// Blind vote token for an anonymous poll. Issued exactly once per poll —
  /// it must be retained to revote, and it is the only link between this
  /// device and its vote (the server stores just the token's hash).
  Future<String?> getPollVoteToken(String pollID) {
    return _readOrNull(_scopedKey(_keyPollVoteTokenPrefix, pollID));
  }

  Future<void> savePollVoteToken(String pollID, String token) {
    return _storage.write(
      key: _scopedKey(_keyPollVoteTokenPrefix, pollID),
      value: token,
    );
  }

  /// The option ids this device voted for in a poll. Refetched anonymous
  /// polls can't carry the viewer's own votes (the server never stores who
  /// voted), so the marked-bubble state survives chat re-entry via here.
  /// Non-anonymous refetches do echo them (`voter_option_ids`).
  Future<List<String>> getPollVoteSelections(String pollID) async {
    final raw = await _readOrNull(_scopedKey(_keyPollMyVotesPrefix, pollID));
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List).whereType<String>().toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> savePollVoteSelections(String pollID, List<String> optionIDs) {
    return _storage.write(
      key: _scopedKey(_keyPollMyVotesPrefix, pollID),
      value: jsonEncode(optionIDs),
    );
  }

  Future<Map<String, String>> getSealedScheduleControlTokens(
    String conversationID,
  ) async {
    final raw = await _readOrNull(
      _scopedKey(_keySealedScheduleControlsPrefix, conversationID),
    );
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      )..removeWhere((key, value) => key.isEmpty || value.isEmpty);
    } catch (_) {
      return {};
    }
  }

  Future<String?> getSealedScheduleControlToken(
    String conversationID,
    String scheduledID,
  ) async {
    final tokens = await getSealedScheduleControlTokens(conversationID);
    return tokens[scheduledID];
  }

  Future<void> saveSealedScheduleControlToken(
    String conversationID,
    String scheduledID,
    String token,
  ) async {
    if (conversationID.isEmpty || scheduledID.isEmpty || token.isEmpty) return;
    final tokens = await getSealedScheduleControlTokens(conversationID);
    tokens[scheduledID] = token;
    await _storage.write(
      key: _scopedKey(_keySealedScheduleControlsPrefix, conversationID),
      value: jsonEncode(tokens),
    );
  }

  Future<void> deleteSealedScheduleControlToken(
    String conversationID,
    String scheduledID,
  ) async {
    final tokens = await getSealedScheduleControlTokens(conversationID);
    tokens.remove(scheduledID);
    final key = _scopedKey(_keySealedScheduleControlsPrefix, conversationID);
    if (tokens.isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: jsonEncode(tokens));
    }
  }

  // ---- Author-local scheduled-message plaintext ----
  // The server-side scheduled payload is ciphertext the author cannot decrypt
  // back (sealed sender / forward-secret MLS), so we keep a local copy of the
  // composed plaintext, scoped per conversation, purely so the schedule list
  // can show the intended message. Removed when the item is sent or canceled.

  Future<Map<String, String>> getScheduledPlaintexts(
    String conversationID,
  ) async {
    final raw = await _readOrNull(
      _scopedKey(_keyScheduledPlaintextPrefix, conversationID),
    );
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      )..removeWhere((key, value) => key.isEmpty || value.isEmpty);
    } catch (_) {
      return {};
    }
  }

  Future<String?> getScheduledPlaintext(
    String conversationID,
    String scheduledID,
  ) async {
    final map = await getScheduledPlaintexts(conversationID);
    return map[scheduledID];
  }

  Future<void> saveScheduledPlaintext(
    String conversationID,
    String scheduledID,
    String plaintext,
  ) async {
    if (conversationID.isEmpty || scheduledID.isEmpty || plaintext.isEmpty) {
      return;
    }
    final map = await getScheduledPlaintexts(conversationID);
    map[scheduledID] = plaintext;
    await _storage.write(
      key: _scopedKey(_keyScheduledPlaintextPrefix, conversationID),
      value: jsonEncode(map),
    );
  }

  Future<void> deleteScheduledPlaintext(
    String conversationID,
    String scheduledID,
  ) async {
    final map = await getScheduledPlaintexts(conversationID);
    map.remove(scheduledID);
    final key = _scopedKey(_keyScheduledPlaintextPrefix, conversationID);
    if (map.isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: jsonEncode(map));
    }
  }

  Future<Map<String, String>> getSealedMessageControlTokens(
    String conversationID,
  ) async {
    final raw = await _readOrNull(
      _scopedKey(_keySealedMessageControlsPrefix, conversationID),
    );
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      )..removeWhere((key, value) => key.isEmpty || value.isEmpty);
    } catch (_) {
      return {};
    }
  }

  Future<String?> getSealedMessageControlToken(
    String conversationID,
    String messageID,
  ) async {
    final tokens = await getSealedMessageControlTokens(conversationID);
    return tokens[messageID];
  }

  Future<void> saveSealedMessageControlToken(
    String conversationID,
    String messageID,
    String token,
  ) async {
    if (conversationID.isEmpty || messageID.isEmpty || token.isEmpty) return;
    final tokens = await getSealedMessageControlTokens(conversationID);
    tokens[messageID] = token;
    await _storage.write(
      key: _scopedKey(_keySealedMessageControlsPrefix, conversationID),
      value: jsonEncode(tokens),
    );
  }

  Future<void> deleteSealedMessageControlToken(
    String conversationID,
    String messageID,
  ) async {
    final tokens = await getSealedMessageControlTokens(conversationID);
    tokens.remove(messageID);
    final key = _scopedKey(_keySealedMessageControlsPrefix, conversationID);
    if (tokens.isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: jsonEncode(tokens));
    }
  }

  Future<List<String>> getAllSealedMessageControlTokens() {
    return _allScopedValues(_keySealedMessageControlsPrefix);
  }

  Future<List<String>> getAllSealedScheduleControlTokens() {
    return _allScopedValues(_keySealedScheduleControlsPrefix);
  }

  Future<int> getSelfStateLogSequence() async {
    final raw = await _readOrNull(_keySelfStateLogSequence);
    return int.tryParse(raw ?? '') ?? 0;
  }

  Future<void> saveSelfStateLogSequence(int sequence) {
    return _storage.write(
      key: _keySelfStateLogSequence,
      value: sequence.toString(),
    );
  }

  String _scopedKey(String prefix, String userID) => '$prefix:$userID';

  Future<String> _createRandomStorageKey(String key) async {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final encoded = base64Encode(bytes);
    await _storage.write(key: key, value: encoded);
    return encoded;
  }

  /// Reads a key that protects an *existing* encrypted store, creating a fresh
  /// random key ONLY when the key is genuinely absent (first run).
  ///
  /// Unlike [_readOrNull], a recoverable keyring failure (e.g. the Linux keyring
  /// locked at launch) is NOT swallowed into `null`: it throws
  /// [SecureStorageUnavailableException]. Returning null here would make this
  /// method mint a brand-new key and overwrite the real one, orphaning the
  /// encrypted store it protects (message cache, MLS engine DB) and destroying
  /// data that is fully recoverable once the keyring unlocks. Failing loudly
  /// lets the caller degrade for this session instead (and the store survives).
  Future<String> _getOrCreateProtectedKey(String key) async {
    String? existing;
    try {
      existing = await _storage.read(key: key);
    } on PlatformException catch (error) {
      if (isRecoverableReadFailure(error)) {
        throw const SecureStorageUnavailableException(linuxKeyringWarning);
      }
      rethrow;
    }
    if (existing != null && existing.isNotEmpty) return existing;
    return _createRandomStorageKey(key);
  }

  /// Like [_getOrCreateProtectedKey] but for lower-stakes derived stores (search
  /// index, offline outbox, local private state). On a recoverable keyring
  /// failure it returns a throwaway session key that is NOT persisted, so the
  /// real key + its encrypted store survive on disk and recover once the keyring
  /// unlocks. The store reads empty for this session — but is never orphaned,
  /// and callers need no special handling (this never throws on a locked
  /// keyring, unlike the protected variant).
  Future<String> _getOrCreateResilientKey(String key) async {
    try {
      final existing = await _storage.read(key: key);
      if (existing != null && existing.isNotEmpty) return existing;
      return await _createRandomStorageKey(key);
    } on PlatformException catch (error) {
      if (isRecoverableReadFailure(error)) {
        final random = Random.secure();
        return base64Encode(List<int>.generate(32, (_) => random.nextInt(256)));
      }
      rethrow;
    }
  }

  Future<bool> isLoggedIn() async {
    final token = await getAccessToken();
    return token != null && token.isNotEmpty;
  }

  Future<void> updateTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _storage.write(key: _keyAccessToken, value: accessToken);
    await _storage.write(key: _keyRefreshToken, value: refreshToken);
  }

  Future<void> clearSession() async {
    await Future.wait([
      _storage.delete(key: _keyUserID),
      _storage.delete(key: _keyUsername),
      _storage.delete(key: _keyAccessToken),
      _storage.delete(key: _keyRefreshToken),
    ]);
  }

  // ---- Biometric preference ----

  Future<bool> getBiometricEnabled() async {
    final v = await _readOrNull(_keyBiometricEnabled);
    return v == 'true';
  }

  Future<void> setBiometricEnabled(bool enabled) => _storage.write(
    key: _keyBiometricEnabled,
    value: enabled ? 'true' : 'false',
  );

  Future<bool> shouldRequireBiometricKeyUnlock() async {
    if (!await getBiometricEnabled()) return false;
    try {
      final auth = LocalAuthentication();
      return await auth.canCheckBiometrics || await auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  // ---- App lock ----

  Future<bool> getAppLockEnabled() async {
    final v = await _readOrNull(_keyAppLockEnabled);
    return v == 'true';
  }

  Future<void> setAppLockEnabled(bool enabled) => _storage.write(
    key: _keyAppLockEnabled,
    value: enabled ? 'true' : 'false',
  );

  Future<int> getAppLockGraceSeconds() async {
    final raw = await _readOrNull(_keyAppLockGraceSeconds);
    return normalizeAppLockGraceSeconds(int.tryParse(raw ?? ''));
  }

  Future<void> setAppLockGraceSeconds(int seconds) => _storage.write(
    key: _keyAppLockGraceSeconds,
    value: normalizeAppLockGraceSeconds(seconds).toString(),
  );

  // Send jitter: random 200–1500ms delay before each message send, so a
  // traffic observer can't correlate keystroke/submit timing with ciphertext
  // departure. The bubble shows immediately (optimistic UI); only the wire
  // send is delayed.
  Future<bool> getSendJitterEnabled() async {
    final v = await _readOrNull(_keySendJitter);
    return v == 'true';
  }

  Future<void> setSendJitterEnabled(bool enabled) =>
      _storage.write(key: _keySendJitter, value: enabled ? 'true' : 'false');

  // Force-TURN: route all call media through the relay so peers never see each
  // other's IP (defeats IP discovery; requires TURN to be configured).
  Future<bool> getForceTurn() async {
    final v = await _readOrNull(_keyForceTurn);
    return v == 'true';
  }

  Future<void> setForceTurn(bool enabled) =>
      _storage.write(key: _keyForceTurn, value: enabled ? 'true' : 'false');

  // Screenshot prevention: global toggle that applies FLAG_SECURE / the iOS
  // secure layer to the whole app. Sensitive screens force it on regardless.
  Future<bool> getScreenSecurity() async {
    final v = await _readOrNull(_keyScreenSecurity);
    return v == 'true';
  }

  Future<void> setScreenSecurity(bool enabled) => _storage.write(
    key: _keyScreenSecurity,
    value: enabled ? 'true' : 'false',
  );

  // Nearby history: an opt-in, encrypted, device-local list of peers whose
  // live mesh handshakes were already verified in person.
  Future<bool> getRecentNearbyEnabled() async {
    final v = await _readOrNull(_keyRecentNearbyHistoryEnabled);
    return v == 'true';
  }

  Future<void> setRecentNearbyEnabled(bool enabled) => _storage.write(
    key: _keyRecentNearbyHistoryEnabled,
    value: enabled ? 'true' : 'false',
  );

  Future<List<RecentNearbyPeer>> getRecentNearbyPeers() async {
    final raw = await _readOrNull(_keyRecentNearbyPeers);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final peers =
          decoded
              .whereType<Map>()
              .map(
                (entry) =>
                    RecentNearbyPeer.fromJson(Map<String, dynamic>.from(entry)),
              )
              .where((peer) => peer.fingerprint.isNotEmpty)
              .toList()
            ..sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
      return peers;
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveRecentNearbyPeers(List<RecentNearbyPeer> peers) =>
      _storage.write(
        key: _keyRecentNearbyPeers,
        value: jsonEncode(peers.map((peer) => peer.toJson()).toList()),
      );

  Future<void> clearRecentNearbyPeers() =>
      _storage.delete(key: _keyRecentNearbyPeers);

  // Proxy / SOCKS5 / Tor routing — stored as a small JSON blob.
  Future<String?> getProxyConfig() => _readOrNull(_keyProxyConfig);

  Future<void> setProxyConfig(String json) =>
      _storage.write(key: _keyProxyConfig, value: json);

  // ── Per-conversation PIN lock ──────────────────────────────────────────────
  // A salted SHA-256 of the PIN per conversation, stored only on this device.
  Future<Map<String, String>> _conversationPins() async {
    final raw = await _readOrNull(_keyConversationPins);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return {};
  }

  Future<bool> hasConversationPin(String convID) async =>
      (await _conversationPins()).containsKey(convID);

  Future<List<String>> lockedConversationIds() async =>
      (await _conversationPins()).keys.toList();

  Future<void> setConversationPin(String convID, String pin) async {
    final pins = await _conversationPins();
    final rand = Random.secure();
    final salt = base64Encode(List<int>.generate(16, (_) => rand.nextInt(256)));
    final hash = sha256.convert(utf8.encode('$salt:$pin')).toString();
    pins[convID] = '$salt:$hash';
    await _storage.write(key: _keyConversationPins, value: jsonEncode(pins));
  }

  Future<bool> verifyConversationPin(String convID, String pin) async {
    final stored = (await _conversationPins())[convID];
    if (stored == null) return false;
    final idx = stored.indexOf(':');
    if (idx < 0) return false;
    final salt = stored.substring(0, idx);
    final hash = stored.substring(idx + 1);
    return sha256.convert(utf8.encode('$salt:$pin')).toString() == hash;
  }

  Future<void> removeConversationPin(String convID) async {
    final pins = await _conversationPins();
    if (pins.remove(convID) != null) {
      await _storage.write(key: _keyConversationPins, value: jsonEncode(pins));
    }
  }

  // ── App-lock PIN + duress PIN ─────────────────────────────────────────────
  // Same salted-SHA-256-at-rest scheme as conversation PINs. The duress PIN is
  // a second, indistinguishable unlock code: classification tells the shell
  // whether to open the real session, the decoy session, or wipe.

  static String _saltedPinRecord(String pin) {
    final rand = Random.secure();
    final salt = base64Encode(List<int>.generate(16, (_) => rand.nextInt(256)));
    final hash = sha256.convert(utf8.encode('$salt:$pin')).toString();
    return '$salt:$hash';
  }

  static bool _pinMatchesRecord(String pin, String? record) {
    if (record == null || record.isEmpty) return false;
    final idx = record.indexOf(':');
    if (idx < 0) return false;
    final salt = record.substring(0, idx);
    final hash = record.substring(idx + 1);
    return sha256.convert(utf8.encode('$salt:$pin')).toString() == hash;
  }

  Future<void> setAppLockPin(String pin) =>
      _storage.write(key: _keyAppLockPin, value: _saltedPinRecord(pin));

  Future<void> clearAppLockPin() => _storage.delete(key: _keyAppLockPin);

  Future<bool> hasAppLockPin() async =>
      ((await _readOrNull(_keyAppLockPin)) ?? '').isNotEmpty;

  Future<void> setDuressPin(String pin) =>
      _storage.write(key: _keyDuressPin, value: _saltedPinRecord(pin));

  Future<void> clearDuressPin() => _storage.delete(key: _keyDuressPin);

  Future<bool> hasDuressPin() async =>
      ((await _readOrNull(_keyDuressPin)) ?? '').isNotEmpty;

  /// 'decoy' (default) or 'wipe'.
  Future<String> getDuressAction() async =>
      (await _readOrNull(_keyDuressAction)) ?? 'decoy';

  Future<void> setDuressAction(String action) =>
      _storage.write(key: _keyDuressAction, value: action);

  /// Classifies an entered PIN: [AppLockPinKind.real], [AppLockPinKind.duress],
  /// or [AppLockPinKind.invalid]. Both hashes are always checked so timing
  /// does not reveal whether a duress PIN exists.
  Future<AppLockPinKind> classifyAppLockPin(String pin) async {
    final realMatch = _pinMatchesRecord(pin, await _readOrNull(_keyAppLockPin));
    final duressMatch = _pinMatchesRecord(
      pin,
      await _readOrNull(_keyDuressPin),
    );
    if (realMatch) return AppLockPinKind.real;
    if (duressMatch) return AppLockPinKind.duress;
    return AppLockPinKind.invalid;
  }

  // ── Dead-man switch ───────────────────────────────────────────────────────

  /// 0 = disabled; otherwise wipe local data when the app hasn't seen a real
  /// unlock for this many days.
  Future<int> getDeadmanDays() async =>
      int.tryParse((await _readOrNull(_keyDeadmanDays)) ?? '') ?? 0;

  Future<void> setDeadmanDays(int days) =>
      _storage.write(key: _keyDeadmanDays, value: days.toString());

  Future<DateTime?> getLastRealUnlockAt() async {
    final raw = await _readOrNull(_keyLastRealUnlockAt);
    final ms = int.tryParse(raw ?? '');
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  Future<void> recordRealUnlock() => _storage.write(
    key: _keyLastRealUnlockAt,
    value: DateTime.now().toUtc().millisecondsSinceEpoch.toString(),
  );

  /// This device's session id, decoded from the access token's `sid` claim —
  /// the remote-wipe target check needs to know which session we are.
  Future<String?> getSessionId() async {
    final token = await getAccessToken();
    if (token == null || token.isEmpty) return null;
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final claims = jsonDecode(payload);
      if (claims is Map) {
        final sid = claims['sid']?.toString();
        return (sid == null || sid.isEmpty) ? null : sid;
      }
    } catch (_) {}
    return null;
  }

  // ── Key-transparency log audit state ──────────────────────────────────────

  /// The last VERIFIED signed tree head + the pinned log public key, JSON:
  /// {tree_size, root_hash, signature, public_key}.
  Future<Map<String, dynamic>?> getKtSthCache() async {
    final raw = await _readOrNull(_keyKtSthCache);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  Future<void> saveKtSthCache(Map<String, dynamic> head) =>
      _storage.write(key: _keyKtSthCache, value: jsonEncode(head));

  /// The pinned AMF (Hecate) public key bundle, JSON:
  /// {moderator_public_key, platform_public_key, signature, pinned_at}.
  /// Trust-on-first-use: pinned from the server's own /.well-known/amf-keys.
  Future<Map<String, dynamic>?> getAmfKeysCache() async {
    final raw = await _readOrNull(_keyAmfKeysCache);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  Future<void> saveAmfKeysCache(Map<String, dynamic> bundle) =>
      _storage.write(key: _keyAmfKeysCache, value: jsonEncode(bundle));

  /// A detected log-integrity violation (equivocation/rollback), JSON with
  /// reason + evidence. Deliberately sticky: only explicit user action in the
  /// Trust Center should ever clear it.
  Future<Map<String, dynamic>?> getKtLogAlarm() async {
    final raw = await _readOrNull(_keyKtLogAlarm);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  Future<void> saveKtLogAlarm(Map<String, dynamic> alarm) =>
      _storage.write(key: _keyKtLogAlarm, value: jsonEncode(alarm));

  // ── Held recovery shares (guardian side) ──────────────────────────────────
  // One Shamir share per account this device guards. Stored verbatim (the
  // share-delivery JSON), keyed by the protected account's user id. These DO
  // ride in encrypted backups — losing your own device must not destroy the
  // shares you hold for friends.

  Future<void> saveHeldRecoveryShare(String ownerUserId, String shareJson) =>
      _storage.write(
        key: _scopedKey(_keyRecoveryShareHeldPrefix, ownerUserId),
        value: shareJson,
      );

  Future<String?> getHeldRecoveryShare(String ownerUserId) =>
      _readOrNull(_scopedKey(_keyRecoveryShareHeldPrefix, ownerUserId));

  Future<void> deleteHeldRecoveryShare(String ownerUserId) => _storage.delete(
    key: _scopedKey(_keyRecoveryShareHeldPrefix, ownerUserId),
  );

  /// owner user id → stored share JSON, for the Trust Center guardian list.
  Future<Map<String, String>> listHeldRecoveryShares() async {
    final all = await _storage.readAll();
    const prefix = '$_keyRecoveryShareHeldPrefix:';
    return {
      for (final entry in all.entries)
        if (entry.key.startsWith(prefix) && entry.value.isNotEmpty)
          entry.key.substring(prefix.length): entry.value,
    };
  }

  /// Message encryption/decryption needs the private key during normal app use.
  /// Biometric key unlock only protects explicit private-key export.
  Future<String?> getPrivateKeyIfUnlocked() async {
    return getPrivateKey();
  }

  /// Full wipe — called on logout or account deletion.
  Future<void> clearAll() => _storage.deleteAll();

  Future<Map<String, String>> exportRecoverySecrets() async {
    final all = await _storage.readAll();
    final blocked = {
      _keyAccessToken,
      _keyRefreshToken,
      _keyBiometricEnabled,
      _keyAppLockEnabled,
      _keyStorageProbe,
      // Device-local security policy never travels in a backup: restoring a
      // bundle on a new device must not silently carry over (or reveal the
      // existence of) lock PINs, the duress configuration, or wipe timers.
      _keyAppLockPin,
      _keyDuressPin,
      _keyDuressAction,
      _keyAppLockGraceSeconds,
      _keyDeadmanDays,
      _keyLastRealUnlockAt,
      _keyRecentNearbyPeers,
      _keyRecentNearbyHistoryEnabled,
    };
    return {
      for (final entry in all.entries)
        if (!blocked.contains(entry.key) && entry.value.isNotEmpty)
          entry.key: entry.value,
    };
  }

  Future<void> importRecoverySecrets(Map<String, String> values) async {
    final blocked = {
      _keyAccessToken,
      _keyRefreshToken,
      _keyBiometricEnabled,
      _keyAppLockEnabled,
      _keyStorageProbe,
      _keyAppLockPin,
      _keyDuressPin,
      _keyDuressAction,
      _keyAppLockGraceSeconds,
      _keyDeadmanDays,
      _keyLastRealUnlockAt,
      _keyRecentNearbyPeers,
      _keyRecentNearbyHistoryEnabled,
    };
    for (final entry in values.entries) {
      if (blocked.contains(entry.key) || entry.value.isEmpty) continue;
      await _storage.write(key: entry.key, value: entry.value);
    }
  }

  static bool isRecoverableReadFailure(PlatformException error) {
    return isLinuxKeyringFailure(error);
  }

  static bool isLinuxKeyringFailure(PlatformException error) {
    final text = _errorText(error);
    return error.code == 'KeyringLocked' ||
        text.contains('keyringlocked') ||
        text.contains('keyring locked') ||
        text.contains('collection is locked') ||
        text.contains('no such secret collection') ||
        text.contains('org.freedesktop.secrets') ||
        text.contains('secret service');
  }

  static String? warningFor(Object error) {
    if (error is PlatformException && isLinuxKeyringFailure(error)) {
      return linuxKeyringWarning;
    }
    return null;
  }

  static String _errorText(PlatformException error) {
    return '${error.code} ${error.message} ${error.details}'.toLowerCase();
  }

  static Future<String?> _readOrNull(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException catch (error) {
      if (!isRecoverableReadFailure(error)) rethrow;
      return null;
    }
  }

  static Future<List<String>> _allScopedValues(String prefix) async {
    try {
      final all = await _storage.readAll();
      final values = <String>[];
      for (final entry in all.entries) {
        if (!entry.key.startsWith('$prefix:')) continue;
        try {
          final decoded = jsonDecode(entry.value);
          if (decoded is! Map) continue;
          values.addAll(
            decoded.values
                .map((value) => value.toString().trim())
                .where((value) => value.isNotEmpty),
          );
        } catch (_) {}
      }
      return values.toSet().toList()..sort();
    } on PlatformException catch (error) {
      if (!isRecoverableReadFailure(error)) rethrow;
      return const [];
    }
  }
}
