import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:vault_identity/src/hpke.dart';

final _ed = Ed25519();

Uint8List _bytes(List<int> value, int length) {
  if (value.length != length || value.any((b) => b < 0 || b > 255)) {
    throw ArgumentError('Expected $length bytes');
  }
  return Uint8List.fromList(value).asUnmodifiableView();
}

/// Derives the domain-separated node identifier from a 32-byte signing key.
Future<Uint8List> nodeIdOf(List<int> edPublicKey) async {
  final key = _bytes(edPublicKey, 32);
  final hash = await Sha256().hash([
    ...ascii.encode('vault/v1/node-id'),
    ...key,
  ]);
  return Uint8List.fromList(hash.bytes).asUnmodifiableView();
}

const _base32 = 'abcdefghijklmnopqrstuvwxyz234567';

/// Encodes a 32-byte node identifier as canonical lowercase unpadded base32.
String nodeIdText(List<int> nodeId) {
  final bytes = _bytes(nodeId, 32);
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final byte in bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out.write(_base32[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) {
    out.write(_base32[(buffer << (5 - bits)) & 31]);
  }
  return out.toString();
}

/// Parses a canonical 52-character node identifier, rejecting alternate forms.
Uint8List nodeIdFromText(String text) {
  if (text.length != 52) {
    throw const FormatException('Invalid nodeId');
  }
  final out = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final code in text.codeUnits) {
    final index = _base32.indexOf(String.fromCharCode(code));
    if (index < 0) {
      throw const FormatException('Invalid nodeId');
    }
    buffer = (buffer << 5) | index;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 255);
    }
    buffer &= (1 << bits) - 1;
  }
  final result = _bytes(out, 32);
  if (nodeIdText(result) != text) {
    throw const FormatException('Noncanonical nodeId');
  }
  return result;
}

/// Signing and encryption keys with their derived, immutable node identifier.
class Identity {
  new _(this._signingPair, this.signingPublic, this.encryption, this.nodeId);
  final SimpleKeyPair _signingPair;

  /// The immutable Ed25519 public key used for signatures and node identity.
  final Uint8List signingPublic;

  /// The X25519 encryption keys; private key material must remain confidential.
  final HpkeKeyPair encryption;

  /// The immutable domain-separated hash of [signingPublic].
  final Uint8List nodeId;

  /// Derives an identity from copied, validated 32-byte secret inputs.
  static Future<Identity> fromSeeds(
    Uint8List signingSeed,
    Uint8List encryptionIkm,
  ) async {
    final seed = _bytes(signingSeed, 32);
    final ikm = _bytes(encryptionIkm, 32);
    final pair = await _ed.newKeyPairFromSeed(seed);
    final public = _bytes((await pair.extractPublicKey()).bytes, 32);
    return Identity._(
      pair,
      public,
      await hpkeDeriveKeyPair(ikm),
      await nodeIdOf(public),
    );
  }

  /// Creates a fresh identity using cryptographically secure random keys.
  static Future<Identity> generate() async {
    final pair = await _ed.newKeyPair();
    final seed = Uint8List.fromList(await pair.extractPrivateKeyBytes());
    final enc = await hpkeNewKeyPair();
    return await fromSeeds(seed, enc.privateKey);
  }

  /// Signs a copied byte message of at most 128 KiB with this identity.
  Future<Uint8List> sign(List<int> message) async {
    if (message.length > 128 * 1024 || message.any((b) => b < 0 || b > 255)) {
      throw ArgumentError('Invalid signing input');
    }
    final signature = await _ed.sign(
      List<int>.of(message),
      keyPair: _signingPair,
    );
    return _bytes(signature.bytes, 64);
  }

  /// Signs a binding of the public signing and encryption keys at [issuedAt].
  Future<KeyBinding> binding({required int issuedAt}) async {
    final body = _bindingBody(signingPublic, encryption.publicKey, issuedAt);
    return KeyBinding(
      signingPublic,
      encryption.publicKey,
      issuedAt,
      await sign([...ascii.encode('vault/v1/key-binding\x00'), ...body]),
    );
  }
}

/// Verifies an Ed25519 signature, returning false for invalid bounded inputs.
Future<bool> verifyEd25519(
  List<int> publicKey,
  List<int> message,
  List<int> signature,
) async {
  if (publicKey.length != 32 ||
      signature.length != 64 ||
      message.length > 128 * 1024) {
    return false;
  }
  try {
    final key = _bytes(publicKey, 32);
    final sig = _bytes(signature, 64);
    if (message.any((b) => b < 0 || b > 255)) {
      return false;
    }
    return await _ed.verify(
      List<int>.of(message),
      signature: Signature(
        sig,
        publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
      ),
    );
  } on Object {
    return false;
  }
}

/// A signed, domain-separated association of signing and encryption keys.
class KeyBinding {
  /// Copies fixed-size key and signature bytes and rejects negative timestamps.
  new(
    Uint8List signingKey,
    Uint8List encryptionKey,
    this.issuedAt,
    Uint8List signature,
  ) : signingKey = _bytes(signingKey, 32),
      encryptionKey = _bytes(encryptionKey, 32),
      signature = _bytes(signature, 64) {
    if (issuedAt < 0) {
      throw ArgumentError.value(issuedAt, 'issuedAt');
    }
  }

  /// The immutable Ed25519 public key authenticating this binding.
  final Uint8List signingKey;

  /// The immutable X25519 public key associated with [signingKey].
  final Uint8List encryptionKey;

  /// The nonnegative issuance timestamp included in the signed body.
  final int issuedAt;

  /// The immutable Ed25519 signature over the canonical binding body.
  final Uint8List signature;

  /// Checks the binding signature without making a trust or freshness decision.
  Future<bool> verify() => verifyEd25519(signingKey, [
    ...ascii.encode('vault/v1/key-binding\x00'),
    ..._bindingBody(signingKey, encryptionKey, issuedAt),
  ], signature);
}

// Fixed canonical CBOR map {1: bstr32, 2: bstr32, 3: uint}.
// Private fixed profile; vault_protocol owns the general strict CBOR codec.
Uint8List _bindingBody(Uint8List signing, Uint8List encryption, int issuedAt) {
  if (issuedAt < 0) {
    throw ArgumentError.value(issuedAt, 'issuedAt');
  }
  final out = BytesBuilder(copy: false)
    ..add([0xa3, 1, 0x58, 32])
    ..add(signing)
    ..add([2, 0x58, 32])
    ..add(encryption)
    ..addByte(3);
  if (issuedAt < 24) {
    out.addByte(issuedAt);
  } else if (issuedAt <= 255) {
    out.add([24, issuedAt]);
  } else if (issuedAt <= 65535) {
    out.add([25, issuedAt >> 8, issuedAt & 255]);
  } else if (issuedAt <= 0xffffffff) {
    final data = ByteData(4)..setUint32(0, issuedAt);
    out
      ..addByte(26)
      ..add(data.buffer.asUint8List());
  } else {
    final data = ByteData(8)..setUint64(0, issuedAt);
    out
      ..addByte(27)
      ..add(data.buffer.asUint8List());
  }
  return out.toBytes();
}
