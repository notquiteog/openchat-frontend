import 'dart:convert';
import 'package:openpgp/openpgp.dart';

/// Handles all PGP cryptographic operations via the openpgp package
/// (backed by Go's ProtonMail/go-crypto OpenPGP implementation).
///
/// Key design:
/// - Private key is NEVER sent to the server or stored unencrypted.
/// - All encryption/decryption happens on-device in this service.
/// - Multi-recipient: recipient public keys are joined into a single keyring
///   string. The Go layer calls ReadArmoredKeyRing and produces one PKESK
///   packet per key in a single PGP message — identical semantics to dart_pg.
class PgpService {
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
  /// included). Keys are joined into a keyring string; the native Go layer
  /// loops over armor.Decode calls to parse each block, producing one PKESK
  /// packet per key.
  ///
  /// Each key is normalised to LF-only line endings before joining (Windows
  /// Credential Manager stores keys with CRLF; CRLF inside the base64 body
  /// breaks armor.Decode on the second block and silently drops all recipients
  /// after the first). Keys are separated by a blank line so armor.Decode can
  /// unambiguously locate each BEGIN header even when the body reader isn't
  /// fully drained before the next iteration.
  static Future<String> encrypt({
    required String plaintext,
    required List<String> recipientPublicKeys,
    required String signingPrivateKeyArmored,
    String signingKeyPassphrase = '',
  }) async {
    final keyring = recipientPublicKeys
        .map((k) => k.replaceAll('\r\n', '\n').trim())
        .join('\n\n');
    final signer = Entity()
      ..privateKey = signingPrivateKeyArmored
      ..passphrase = signingKeyPassphrase;
    return OpenPGP.encrypt(plaintext, keyring, signed: signer);
  }

  /// Encrypt binary data (files, images) for multiple recipients.
  ///
  /// Data is base64-encoded before encryption so the armored PGP output format
  /// is preserved end-to-end. Decoded symmetrically in [decryptBytes].
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
  }) {
    return OpenPGP.decrypt(
        encryptedArmor, privateKeyArmored, privateKeyPassphrase);
  }

  /// Decrypt binary data (files, images).
  static Future<List<int>> decryptBytes({
    required String encryptedArmor,
    required String privateKeyArmored,
    String privateKeyPassphrase = '',
  }) async {
    final b64 = await OpenPGP.decrypt(
        encryptedArmor, privateKeyArmored, privateKeyPassphrase);
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
