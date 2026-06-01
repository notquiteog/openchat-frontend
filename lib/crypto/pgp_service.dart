import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:openpgp/openpgp.dart';

/// Handles all PGP cryptographic operations via the openpgp package
/// (backed by Go's ProtonMail/go-crypto OpenPGP implementation).
///
/// Key design:
/// - Private key is NEVER sent to the server or stored unencrypted.
/// - All encryption/decryption happens on-device in this service.
/// - Outbound messages are stored as an OpenChat envelope with one
///   signed+encrypted PGP ciphertext per recipient. This keeps decryptability
///   independent of platform-specific multi-key keyring parsing and lets the
///   sender decrypt their own messages after an app restart.
class PgpService {
  static const _envelopeKey = 'openchat_encrypted_envelope';
  static const _envelopeVersion = 1;
  static const _ciphertextsKey = 'ciphertexts';

  /// Generate a new ECC key pair (Curve25519 + Ed25519).
  static Future<PgpKeyPair> generateKeyPair({
    required String username,
    String? passphrase,
  }) async {
    final keyPair = await OpenPGP.generate(
      options: Options()
        ..name = username
        ..email = '$username@openchat'
        ..passphrase = passphrase ?? ''
        ..keyOptions = (KeyOptions()
          ..algorithm = Algorithm.EDDSA
          ..curve = Curve.CURVE25519
          ..hash = Hash.SHA512
          ..cipher = Cipher.AES256
          ..keyLifetimeSecs = 0), // 0 = never expires; OpenChat policy
    );
    final meta = await OpenPGP.getPublicKeyMetadata(keyPair.publicKey);
    return PgpKeyPair(
      publicKeyArmored: keyPair.publicKey,
      privateKeyArmored: keyPair.privateKey,
      fingerprint: meta.fingerprint.toUpperCase(),
    );
  }

  /// Generate a composite post-quantum key pair (ML-DSA-65 + Ed25519 signing,
  /// ML-KEM-768 + X25519 encryption subkey). Requires the notquiteog fork.
  static Future<PgpKeyPair> generatePqcKeyPair({
    required String username,
    String? passphrase,
  }) async {
    final keyPair = await OpenPGP.generate(
      options: Options()
        ..name = username
        ..email = '$username@openchat'
        ..passphrase = passphrase ?? ''
        ..keyOptions = (KeyOptions()
          ..algorithm = Algorithm.MLDSA65ED25519
          ..hash = Hash.SHA512
          ..cipher = Cipher.AES256
          ..keyLifetimeSecs = 0),
    );
    final meta = await OpenPGP.getPublicKeyMetadata(keyPair.publicKey);
    return PgpKeyPair(
      publicKeyArmored: keyPair.publicKey,
      privateKeyArmored: keyPair.privateKey,
      fingerprint: meta.fingerprint.toUpperCase(),
    );
  }

  /// Generate an RSA-4096 key pair for users who prefer RSA over ECC.
  static Future<PgpKeyPair> generateRsaKeyPair({
    required String username,
    String? passphrase,
  }) async {
    final keyPair = await OpenPGP.generate(
      options: Options()
        ..name = username
        ..email = '$username@openchat'
        ..passphrase = passphrase ?? ''
        ..keyOptions = (KeyOptions()
          ..algorithm = Algorithm.RSA
          ..rsaBits = 4096
          ..hash = Hash.SHA512
          ..cipher = Cipher.AES256
          ..keyLifetimeSecs = 0),
    );
    final meta = await OpenPGP.getPublicKeyMetadata(keyPair.publicKey);
    return PgpKeyPair(
      publicKeyArmored: keyPair.publicKey,
      privateKeyArmored: keyPair.privateKey,
      fingerprint: meta.fingerprint.toUpperCase(),
    );
  }

  /// Encrypt a plaintext message for multiple recipients.
  ///
  /// [recipientPublicKeys] should include ALL conversation members (sender
  /// included).
  ///
  /// Always stores a compact OpenChat envelope containing one signed+encrypted
  /// PGP message per recipient. Using the same envelope path for DMs and groups
  /// avoids platform OpenPGP bridge keyring parsing limits that can omit later
  /// recipients or the sender's own key, which makes messages undecryptable
  /// after a restart.
  static Future<String> encrypt({
    required String plaintext,
    required List<String> recipientPublicKeys,
    required String signingPrivateKeyArmored,
    String signingKeyPassphrase = '',
  }) async {
    final keys = _normalizeArmoredKeys(recipientPublicKeys);
    if (keys.isEmpty) {
      throw ArgumentError.value(
        recipientPublicKeys,
        'recipientPublicKeys',
        'must contain at least one public key',
      );
    }
    return _encryptEnvelope(
      plaintext: plaintext,
      recipientPublicKeys: keys,
      signingPrivateKeyArmored: signingPrivateKeyArmored,
      signingKeyPassphrase: signingKeyPassphrase,
    );
  }

  static List<String> _normalizeArmoredKeys(List<String> keys) {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in keys) {
      final key = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
      if (key.isEmpty || !seen.add(key)) continue;
      out.add(key);
    }
    return out;
  }

  static Future<String> _encryptEnvelope({
    required String plaintext,
    required List<String> recipientPublicKeys,
    required String signingPrivateKeyArmored,
    required String signingKeyPassphrase,
  }) async {
    final ciphertexts = <String>[];
    for (final key in recipientPublicKeys) {
      final signer = Entity()
        ..privateKey = signingPrivateKeyArmored
        ..passphrase = signingKeyPassphrase;
      ciphertexts.add(await OpenPGP.encrypt(plaintext, key, signed: signer));
    }
    return jsonEncode({
      _envelopeKey: _envelopeVersion,
      _ciphertextsKey: ciphertexts,
    });
  }

  /// Encrypt binary data (files, images) for multiple recipients.
  ///
  /// Data is base64-encoded before encryption so encrypted file bytes still fit
  /// in the same text-envelope path. Decoded symmetrically in [decryptBytes].
  static Future<String> encryptBytes({
    required List<int> data,
    required String filename,
    required List<String> recipientPublicKeys,
    required String signingPrivateKeyArmored,
    String signingKeyPassphrase = '',
  }) {
    return encrypt(
      plaintext: base64.encode(data),
      recipientPublicKeys: recipientPublicKeys,
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
        decryptor: OpenPGP.decrypt,
      );
    }

    return OpenPGP.decrypt(
      encryptedArmor,
      privateKeyArmored,
      privateKeyPassphrase,
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
    ) decryptor,
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
      final values = decoded[_ciphertextsKey];
      if (values is! List) return const [];
      return values.whereType<String>().toList(growable: false);
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
    return OpenPGP.sign(data, privateKeyArmored, passphrase);
  }

  /// Verify an attached PGP signature produced by [sign].
  static Future<bool> verify({
    required String data,
    required String signatureArmor,
    required String signerPublicKeyArmored,
  }) async {
    try {
      return await OpenPGP.verify(signatureArmor, data, signerPublicKeyArmored);
    } catch (_) {
      return false;
    }
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

enum KeyType { curve25519, rsa4096, pqc }

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
