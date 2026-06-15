import 'dart:convert';
import 'dart:typed_data';

import '../crypto/amf_service.dart';
import 'api_service.dart';
import 'secure_storage_service.dart';

/// The AMF key bundle could not be obtained or trusted. Callers verifying a
/// franked message must FAIL CLOSED (drop the message) on this — never display
/// a message whose franking can't be checked against trusted keys.
class AmfKeyException implements Exception {
  final String message;
  const AmfKeyException(this.message);
  @override
  String toString() => 'AmfKeyException: $message';
}

/// The server's AMF public keys differ from the pinned set — a possible key
/// swap / MITM. Surfaced (not silently re-pinned) so it can be treated as an
/// integrity alarm, exactly like a KT log key change.
class AmfKeyChangedException extends AmfKeyException {
  const AmfKeyChangedException()
    : super('AMF public keys changed from the pinned set');
}

/// Fetches, verifies, and trust-on-first-use pins the AMF (Hecate) moderator +
/// platform public keys from `/.well-known/amf-keys`. Mirrors the KT-log key
/// pinning stance: keys come ONLY from the server's own endpoint, the bundle
/// self-signature (platform signs modPub‖platPub) is verified before trust, and
/// a change from the pinned set is refused rather than silently accepted.
class AmfKeyService {
  AmfKeyService(this._api, this._storage);

  final ApiService _api;
  final SecureStorageService _storage;

  AmfPublicKeys? _cached;

  /// Returns the pinned keys, fetching+pinning on first use. Prefers a verified
  /// fresh fetch, falls back to the pinned cache offline, and throws (fail
  /// closed) when nothing trustworthy is available or the server's keys differ
  /// from what was pinned.
  Future<AmfPublicKeys> pinnedKeys() async {
    if (_cached != null) return _cached!;

    final pinned = await _storage.getAmfKeysCache();

    Map<String, dynamic>? fetched;
    try {
      fetched = await _api.getAmfKeys();
    } catch (_) {
      fetched = null; // offline / transient — fall back to the pinned copy
    }

    if (fetched != null) {
      final modB64 = fetched['moderator_public_key'] as String?;
      final platB64 = fetched['platform_public_key'] as String?;
      final sigB64 = fetched['signature'] as String?;
      if (modB64 != null && platB64 != null && sigB64 != null) {
        final mod = base64.decode(modB64);
        final plat = base64.decode(platB64);
        final ok = await AmfService.verifyKeyBundle(
          moderatorPub: mod,
          platformPub: plat,
          signature: base64.decode(sigB64),
        );
        if (ok) {
          if (pinned == null) {
            // Trust-on-first-use: pin the verified bundle.
            await _storage.saveAmfKeysCache({
              'moderator_public_key': modB64,
              'platform_public_key': platB64,
              'signature': sigB64,
            });
            return _hold(mod, plat);
          }
          // Already pinned: a change is an integrity alarm, not a re-pin.
          if (pinned['moderator_public_key'] != modB64 ||
              pinned['platform_public_key'] != platB64) {
            throw const AmfKeyChangedException();
          }
          return _hold(mod, plat);
        }
        // A bundle that fails its own signature is never trusted.
        if (pinned == null) {
          throw const AmfKeyException('AMF key bundle signature invalid');
        }
      }
    }

    // No usable fresh fetch: use the previously-pinned keys if we have them.
    if (pinned != null) {
      return _hold(
        base64.decode(pinned['moderator_public_key'] as String),
        base64.decode(pinned['platform_public_key'] as String),
      );
    }
    throw const AmfKeyException('AMF keys unavailable');
  }

  AmfPublicKeys _hold(Uint8List mod, Uint8List plat) {
    final keys = AmfPublicKeys(
      moderatorPublicKey: mod,
      platformPublicKey: plat,
    );
    _cached = keys;
    return keys;
  }
}
