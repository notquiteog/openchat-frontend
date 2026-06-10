import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:openpgp/openpgp.dart';

/// Handles all PGP cryptographic operations via the openpgp package
/// (backed by Go's ProtonMail/go-crypto OpenPGP implementation).
///
/// Key design:
/// - Private key is NEVER sent to the server or stored unencrypted.
/// - All encryption/decryption happens on-device in this service.
/// - Outbound messages are stored as anonymous OpenChat envelope slots with one
///   signed+encrypted PGP ciphertext per recipient key. This keeps
///   decryptability independent of platform-specific multi-key keyring parsing
///   and lets the sender decrypt their own messages after an app restart.
class PgpService {
  static const _envelopeKey = 'pgp_envelope_v1';
  static const _envelopeVersion = 1;
  static const _cipherKey = 'cipher';
  static const _cipherName = 'openpgp';
  static const _slotsKey = 'slots';

  // ── OpenPGP serialization ───────────────────────────────────────────────────
  // The openpgp package is backed by a Go/FFI bridge that is NOT safe to call
  // concurrently: a second operation started while another is in flight can
  // transiently fail — verify() returns false, decrypt() returns empty — which
  // surfaced as random "🔒 Unable to decrypt" on freshly-arrived messages that
  // fixed themselves on reload. Routing every crypto op through this gate
  // guarantees strictly one-at-a-time execution. A throwing op (caught by the
  // onError below) never breaks the chain for the next operation.
  static Future<void> _opGate = Future<void>.value();
  static Future<T> _serial<T>(Future<T> Function() op) {
    final result = _opGate.then((_) => op());
    _opGate = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Generate a new ECC key pair (Curve25519 + Ed25519).
  static Future<PgpKeyPair> generateKeyPair({
    required String username,
    String? passphrase,
  }) async {
    return _generateKeyPairWithOptions(
      username: username,
      passphrase: passphrase,
      keyOptions: KeyOptions()
        ..algorithm = Algorithm.EDDSA
        ..curve = Curve.CURVE25519
        ..hash = Hash.SHA512
        ..cipher = Cipher.AES256
        ..keyLifetimeSecs = 0,
    );
  }

  static Future<PgpKeyPair> generateKeyPairForType({
    required String username,
    required KeyType keyType,
    String? passphrase,
  }) {
    return switch (keyType) {
      KeyType.curve25519 => generateKeyPair(
        username: username,
        passphrase: passphrase,
      ),
      KeyType.rsa4096 => generateRsaKeyPair(
        username: username,
        passphrase: passphrase,
      ),
      KeyType.mldsa65Ed25519 ||
      KeyType.mldsa87Ed448 ||
      KeyType.mlkem768X25519 ||
      KeyType.mlkem1024X448 => generateQuantumKeyPair(
        username: username,
        keyType: keyType,
        passphrase: passphrase,
      ),
    };
  }

  static Future<PgpKeyPair> _generateKeyPairWithOptions({
    required String username,
    required KeyOptions keyOptions,
    String? passphrase,
  }) async {
    final keyPair = await OpenPGP.generate(
      options: Options()
        ..name = username
        ..email = '$username@openchat'
        ..passphrase = passphrase ?? ''
        ..keyOptions = keyOptions,
    );
    final meta = await OpenPGP.getPublicKeyMetadata(keyPair.publicKey);
    return PgpKeyPair(
      publicKeyArmored: keyPair.publicKey,
      privateKeyArmored: keyPair.privateKey,
      fingerprint: meta.fingerprint.toUpperCase(),
    );
  }

  /// Generate a composite post-quantum key pair. Requires the notquiteog fork.
  static Future<PgpKeyPair> generateQuantumKeyPair({
    required String username,
    required KeyType keyType,
    String? passphrase,
  }) async {
    if (!keyType.isQuantum) {
      throw ArgumentError.value(
        keyType,
        'keyType',
        'must be a post-quantum key type',
      );
    }
    return _generateKeyPairWithOptions(
      username: username,
      passphrase: passphrase,
      keyOptions: KeyOptions()
        ..algorithm = keyType.algorithm
        ..hash = Hash.SHA512
        ..cipher = Cipher.AES256
        ..keyLifetimeSecs = 0,
    );
  }

  /// Generate a composite ML-DSA-65 + Ed25519 key pair.
  static Future<PgpKeyPair> generatePqcKeyPair({
    required String username,
    String? passphrase,
  }) {
    return generateQuantumKeyPair(
      username: username,
      keyType: KeyType.mldsa65Ed25519,
      passphrase: passphrase,
    );
  }

  /// Generate an RSA-4096 key pair for users who prefer RSA over ECC.
  static Future<PgpKeyPair> generateRsaKeyPair({
    required String username,
    String? passphrase,
  }) async {
    return _generateKeyPairWithOptions(
      username: username,
      passphrase: passphrase,
      keyOptions: KeyOptions()
        ..algorithm = Algorithm.RSA
        ..rsaBits = 4096
        ..hash = Hash.SHA512
        ..cipher = Cipher.AES256
        ..keyLifetimeSecs = 0,
    );
  }

  /// Encrypt a plaintext message for multiple recipients.
  ///
  /// [recipients] should include every active non-expired conversation member
  /// (sender included), with the member's current fingerprint.
  ///
  /// Always stores a compact OpenChat envelope containing anonymous
  /// signed+encrypted PGP slots. Using the same envelope path for DMs and groups
  /// avoids platform OpenPGP bridge keyring parsing limits and keeps sender,
  /// message type, and recipient IDs out of the server-visible envelope.
  static Future<String> encrypt({
    required String plaintext,
    required List<PgpRecipient> recipients,
    required String signingPrivateKeyArmored,
    String signingKeyPassphrase = '',
  }) async {
    final normalizedRecipients = _normalizeRecipients(recipients);
    if (normalizedRecipients.isEmpty) {
      throw ArgumentError.value(
        recipients,
        'recipients',
        'must contain at least one public key',
      );
    }
    return _encryptEnvelope(
      plaintext: plaintext,
      recipients: normalizedRecipients,
      signingPrivateKeyArmored: signingPrivateKeyArmored,
      signingKeyPassphrase: signingKeyPassphrase,
    );
  }

  static List<PgpRecipient> _normalizeRecipients(
    List<PgpRecipient> recipients,
  ) {
    final seen = <String>{};
    final out = <PgpRecipient>[];
    for (final raw in recipients) {
      final userId = raw.userId.trim();
      final publicKey = raw.publicKeyArmored
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .trim();
      final fingerprint = raw.keyFingerprint.trim().toUpperCase();
      if (userId.isEmpty ||
          publicKey.isEmpty ||
          fingerprint.isEmpty ||
          !seen.add(userId)) {
        continue;
      }
      out.add(
        PgpRecipient(
          userId: userId,
          publicKeyArmored: publicKey,
          keyFingerprint: fingerprint,
        ),
      );
    }
    out.sort((a, b) => a.userId.compareTo(b.userId));
    return out;
  }

  static Future<String> _encryptEnvelope({
    required String plaintext,
    required List<PgpRecipient> recipients,
    required String signingPrivateKeyArmored,
    required String signingKeyPassphrase,
  }) async {
    final slots = <Map<String, String>>[];
    final paddedPlaintext = _padStructuredPlaintext(plaintext);
    // Hidden recipients: every slot's PKESK carries a wildcard (zeroed) key
    // id, so a slot does not even name which key can open it. Combined with
    // the slot shuffle below, the server sees only "N opaque ciphertexts".
    final slotOptions = KeyOptions()..hiddenRecipients = true;
    for (final recipient in recipients) {
      final signer = Entity()
        ..privateKey = signingPrivateKeyArmored
        ..passphrase = signingKeyPassphrase;
      slots.add({
        'ciphertext': await _serial(
          () => OpenPGP.encrypt(
            paddedPlaintext,
            recipient.publicKeyArmored,
            options: slotOptions,
            signed: signer,
          ),
        ),
      });
    }
    // Shuffle slots with a CSPRNG. Recipients are normalised in sorted order
    // (for dedup determinism), so without this, slot k always belonged to the
    // k-th smallest member UUID and the server — which knows the member list —
    // could attribute every per-recipient ciphertext (and selectively corrupt
    // a specific member's slot).
    slots.shuffle(Random.secure());
    return jsonEncode({
      _envelopeKey: _envelopeVersion,
      _cipherKey: _cipherName,
      _slotsKey: slots,
    });
  }

  static String _padStructuredPlaintext(String plaintext) {
    try {
      final decoded = jsonDecode(plaintext);
      if (decoded is! Map<String, dynamic>) return plaintext;
      if (decoded['openchat_message'] != 1 &&
          decoded['openchat_self_state'] != 1 &&
          decoded['openchat_call_signal'] != 1) {
        return plaintext;
      }
      final currentSize = utf8.encode(plaintext).length;
      const buckets = [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536];
      final target = buckets.firstWhere(
        (bucket) => bucket > currentSize + 48,
        orElse: () => 0,
      );
      if (target == 0) return plaintext;
      final random = Random.secure();
      // Account for the JSON overhead of the padding field itself
      // (`,"_padding":""` ≈ 15 chars) so the padded size lands at or below the
      // bucket boundary instead of bucket+ε.
      const fieldOverhead = 15;
      final available = target - currentSize - fieldOverhead;
      final paddingBytes = max(16, (available * 3 / 4).floor());
      final padding = base64Url.encode(
        List<int>.generate(paddingBytes, (_) => random.nextInt(256)),
      );
      decoded['_padding'] = padding;
      return jsonEncode(decoded);
    } catch (_) {
      return plaintext;
    }
  }

  /// Encrypt binary data (files, images) for multiple recipients.
  ///
  /// Data is base64-encoded before encryption so encrypted file bytes still fit
  /// in the same text-envelope path. Decoded symmetrically in [decryptBytes].
  static Future<String> encryptBytes({
    required List<int> data,
    required String filename,
    required List<PgpRecipient> recipients,
    required String signingPrivateKeyArmored,
    String signingKeyPassphrase = '',
  }) {
    return encrypt(
      plaintext: base64.encode(data),
      recipients: recipients,
      signingPrivateKeyArmored: signingPrivateKeyArmored,
      signingKeyPassphrase: signingKeyPassphrase,
    );
  }

  /// Decrypt a PGP-armored ciphertext using the local private key.
  static Future<String> decrypt({
    required String encryptedArmor,
    required String privateKeyArmored,
    String privateKeyPassphrase = '',
    List<String> senderPublicKeys = const [],
  }) async {
    final envelopeCiphertexts = tryReadEnvelopeCiphertexts(encryptedArmor);
    if (envelopeCiphertexts != null) {
      return _decryptEnvelopeCiphertexts(
        envelopeCiphertexts,
        privateKeyArmored: privateKeyArmored,
        privateKeyPassphrase: privateKeyPassphrase,
        decryptor: (a, b, c) => _serial(() => OpenPGP.decrypt(a, b, c)),
      );
    }

    return _serial(
      () => OpenPGP.decrypt(
        encryptedArmor,
        privateKeyArmored,
        privateKeyPassphrase,
      ),
    );
  }

  static Future<String> _decryptEnvelopeCiphertexts(
    List<String> ciphertexts, {
    required String privateKeyArmored,
    required String privateKeyPassphrase,
    required Future<String> Function(
      String encryptedArmor,
      String privateKeyArmored,
      String privateKeyPassphrase,
    )
    decryptor,
  }) async {
    Object? lastError;
    for (final ciphertext in ciphertexts) {
      try {
        final raw = await decryptor(
          ciphertext,
          privateKeyArmored,
          privateKeyPassphrase,
        );
        if (raw.isNotEmpty) return raw;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError != null) throw lastError;
    return '';
  }

  @visibleForTesting
  static bool usesOpenChatEnvelopeForRecipientCount(int recipientCount) =>
      recipientCount > 0;

  @visibleForTesting
  static Future<String> decryptEnvelopeCiphertextsForTesting(
    List<String> ciphertexts,
    Future<String> Function(String ciphertext) decryptor,
  ) {
    return _decryptEnvelopeCiphertexts(
      ciphertexts,
      privateKeyArmored: '',
      privateKeyPassphrase: '',
      decryptor: (ciphertext, privateKey, passphrase) => decryptor(ciphertext),
    );
  }

  @visibleForTesting
  static bool isOpenChatEnvelope(String encryptedArmor) =>
      tryReadEnvelopeCiphertexts(encryptedArmor) != null;

  @visibleForTesting
  static List<String>? tryReadEnvelopeCiphertexts(String encryptedArmor) {
    final trimmed = encryptedArmor.trimLeft();
    if (!trimmed.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded[_envelopeKey] != _envelopeVersion) return null;
      if (decoded[_cipherKey] != _cipherName) return null;
      final values = decoded[_slotsKey];
      if (values is! List) return const [];
      final ciphertexts = <String>[];
      for (final slot in values) {
        if (slot is! Map) continue;
        final ciphertext = slot['ciphertext'];
        if (ciphertext is String) ciphertexts.add(ciphertext);
      }
      return ciphertexts;
    } catch (_) {
      return null;
    }
  }

  /// Decrypt binary data (files, images).
  static Future<List<int>> decryptBytes({
    required String encryptedArmor,
    required String privateKeyArmored,
    String privateKeyPassphrase = '',
  }) async {
    final b64 = await decrypt(
      encryptedArmor: encryptedArmor,
      privateKeyArmored: privateKeyArmored,
      privateKeyPassphrase: privateKeyPassphrase,
    );
    return base64.decode(b64);
  }

  /// Create an attached PGP signature over data.
  static Future<String> sign({
    required String data,
    required String privateKeyArmored,
    String passphrase = '',
  }) {
    return _serial(() => OpenPGP.sign(data, privateKeyArmored, passphrase));
  }

  /// Verify an attached PGP signature produced by [sign].
  static Future<bool> verify({
    required String data,
    required String signatureArmor,
    required String signerPublicKeyArmored,
  }) async {
    try {
      return await _serial(
        () => OpenPGP.verify(signatureArmor, data, signerPublicKeyArmored),
      );
    } catch (_) {
      return false;
    }
  }

  /// Build the canonical string that is signed (and later verified) as the
  /// sender proof for a sealed message.
  ///
  /// Pass [createdAt] (ISO-8601 UTC) to use the v2 scheme, which binds the
  /// signature to a timestamp and makes identical-content replays detectable.
  /// Omit it only when verifying legacy v1 messages that predate this field.
  static String senderProofData({
    required String conversationId,
    required String messageType,
    required String payload,
    String? createdAt,
  }) {
    final encodedPayload = base64Url.encode(utf8.encode(payload));
    if (createdAt != null && createdAt.isNotEmpty) {
      return 'openchat-pgp-sender-v2:$conversationId:$messageType:$encodedPayload:$createdAt';
    }
    return 'openchat-pgp-sender-v1:$conversationId:$messageType:$encodedPayload';
  }

  static String deviceKeySignatureData({
    required String userId,
    required String deviceKey,
  }) {
    final encodedKey = base64Url.encode(utf8.encode(deviceKey.trim()));
    return 'openchat-device-key-v1:${userId.trim()}:$encodedKey';
  }

  /// Parse the fingerprint from an armored public key.
  static Future<String> fingerprintFromPublicKey(String armoredKey) async {
    final meta = await OpenPGP.getPublicKeyMetadata(armoredKey);
    return meta.fingerprint.toUpperCase();
  }

  /// Derive the armored public key from an armored private key. Lets users
  /// import by pasting only their private key — the public half is computed
  /// locally, never round-tripped through the user or the server.
  static Future<String> publicKeyFromPrivate(String privateKeyArmored) {
    return OpenPGP.convertPrivateKeyToPublicKey(privateKeyArmored);
  }
}

class PgpRecipient {
  final String userId;
  final String publicKeyArmored;
  final String keyFingerprint;

  const PgpRecipient({
    required this.userId,
    required this.publicKeyArmored,
    required this.keyFingerprint,
  });
}

enum KeyType {
  mlkem1024X448(
    title: 'ML-KEM-1024 + X448',
    subtitle: 'Recommended - strongest hybrid quantum encryption',
    dropdownLabel: 'ML-KEM-1024 + X448 (Post-Quantum)',
    algorithm: Algorithm.MLKEM1024X448,
    isQuantum: true,
  ),
  mldsa87Ed448(
    title: 'ML-DSA-87 + Ed448',
    subtitle: 'High-security OpenPGP v6 signing and encryption',
    dropdownLabel: 'ML-DSA-87 + Ed448 (Post-Quantum)',
    algorithm: Algorithm.MLDSA87ED448,
    isQuantum: true,
  ),
  mlkem768X25519(
    title: 'ML-KEM-768 + X25519',
    subtitle: 'Hybrid quantum encryption with Ed25519 signing',
    dropdownLabel: 'ML-KEM-768 + X25519 (Post-Quantum)',
    algorithm: Algorithm.MLKEM768X25519,
    isQuantum: true,
  ),
  mldsa65Ed25519(
    title: 'ML-DSA-65 + Ed25519',
    subtitle: 'Hybrid quantum signing and encryption',
    dropdownLabel: 'ML-DSA-65 + Ed25519 (Post-Quantum)',
    algorithm: Algorithm.MLDSA65ED25519,
    isQuantum: true,
  ),
  curve25519(
    title: 'Curve25519 (ECC)',
    subtitle: 'Fast, modern classical cryptography',
    dropdownLabel: 'Curve25519 (ECC)',
    algorithm: Algorithm.EDDSA,
    isQuantum: false,
  ),
  rsa4096(
    title: 'RSA-4096',
    subtitle: 'Traditional - wider compatibility',
    dropdownLabel: 'RSA-4096',
    algorithm: Algorithm.RSA,
    isQuantum: false,
  );

  const KeyType({
    required this.title,
    required this.subtitle,
    required this.dropdownLabel,
    required this.algorithm,
    required this.isQuantum,
  });

  static const defaultType = KeyType.mlkem1024X448;
  static const accountCreationOptions = [
    KeyType.mlkem1024X448,
    KeyType.mldsa87Ed448,
    KeyType.mlkem768X25519,
    KeyType.mldsa65Ed25519,
    KeyType.curve25519,
    KeyType.rsa4096,
  ];
  static const quantumTypes = [
    KeyType.mldsa65Ed25519,
    KeyType.mldsa87Ed448,
    KeyType.mlkem768X25519,
    KeyType.mlkem1024X448,
  ];

  final String title;
  final String subtitle;
  final String dropdownLabel;
  final Algorithm algorithm;
  final bool isQuantum;
}

class PgpKeyPair {
  final String publicKeyArmored;
  final String privateKeyArmored;
  final String fingerprint;

  const PgpKeyPair({
    required this.publicKeyArmored,
    required this.privateKeyArmored,
    required this.fingerprint,
  });
}
