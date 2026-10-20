import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// RFC 9180 HPKE, base mode (0), DHKEM(X25519, HKDF-SHA256) kem 0x0020,
/// HKDF-SHA256 kdf 0x0001, ChaCha20-Poly1305 aead 0x0003. Single-shot only.
/// Checked against the RFC 9180 appendix A.2 vectors.
final _hmac = Hmac.sha256();
final _x25519 = X25519();
final _aead = Chacha20.poly1305Aead();

Uint8List _cat(List<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  parts.forEach(b.add);
  return b.toBytes();
}

Uint8List _i2osp(int v, int len) {
  final out = Uint8List(len);
  var x = v;
  for (var i = len - 1; i >= 0; i--) {
    out[i] = x & 0xff;
    x >>= 8;
  }
  return out;
}

final Uint8List _suiteKem = _cat([ascii.encode('KEM'), _i2osp(0x20, 2)]);
final Uint8List _suiteHpke = _cat([
  ascii.encode('HPKE'),
  _i2osp(0x20, 2),
  _i2osp(1, 2),
  _i2osp(3, 2),
]);
final List<int> _v1 = ascii.encode('HPKE-v1');

Future<Uint8List> _mac(List<int> key, List<int> data) async {
  final mac = await _hmac.calculateMac(data, secretKey: SecretKey(key));
  return Uint8List.fromList(mac.bytes);
}

Future<Uint8List> _extract(List<int> salt, List<int> ikm) =>
    _mac(salt.isEmpty ? Uint8List(32) : salt, ikm);

Future<Uint8List> _expand(List<int> prk, List<int> info, int length) async {
  final out = BytesBuilder();
  var t = Uint8List(0);
  for (var i = 1; out.length < length; i++) {
    t = await _mac(
      prk,
      _cat([
        t,
        info,
        [i],
      ]),
    );
    out.add(t);
  }
  return Uint8List.sublistView(out.toBytes(), 0, length);
}

Future<Uint8List> _labeledExtract(
  List<int> suite,
  List<int> salt,
  String label,
  List<int> ikm,
) => _extract(salt, _cat([_v1, suite, ascii.encode(label), ikm]));

Future<Uint8List> _labeledExpand(
  List<int> suite,
  List<int> prk,
  String label,
  List<int> info,
  int length,
) => _expand(
  prk,
  _cat([_i2osp(length, 2), _v1, suite, ascii.encode(label), info]),
  length,
);

/// An X25519 key pair with validated, immutable copies of its key bytes.
class HpkeKeyPair {
  /// Copies both keys, rejecting values that are not exactly 32 bytes.
  new(Uint8List privateKey, Uint8List publicKey)
    : privateKey = _fixed(privateKey, 32),
      publicKey = _fixed(publicKey, 32);

  /// The immutable private key material; keep this confidential.
  final Uint8List privateKey;

  /// The immutable public key suitable for sharing with senders.
  final Uint8List publicKey;
}

Future<HpkeKeyPair> _pairFromSeed(Uint8List sk) async {
  final pair = await _x25519.newKeyPairFromSeed(sk);
  final pk = await pair.extractPublicKey();
  return HpkeKeyPair(sk, Uint8List.fromList(pk.bytes));
}

/// RFC 9180 DeriveKeyPair for X25519.
Future<HpkeKeyPair> hpkeDeriveKeyPair(List<int> ikm) async {
  final input = _fixed(ikm, 32);
  final prk = await _labeledExtract(_suiteKem, const [], 'dkp_prk', input);
  final sk = await _labeledExpand(_suiteKem, prk, 'sk', const [], 32);
  return await _pairFromSeed(sk);
}

/// Generates a fresh X25519 key pair using cryptographically secure randomness.
Future<HpkeKeyPair> hpkeNewKeyPair() async {
  final pair = await _x25519.newKeyPair();
  final sk = Uint8List.fromList(await pair.extractPrivateKeyBytes());
  return await _pairFromSeed(sk);
}

Future<Uint8List> _dh(Uint8List sk, Uint8List pk) async {
  final pair = await _x25519.newKeyPairFromSeed(sk);
  final secret = await _x25519.sharedSecretKey(
    keyPair: pair,
    remotePublicKey: SimplePublicKey(pk, type: KeyPairType.x25519),
  );
  final bytes = Uint8List.fromList(await secret.extractBytes());
  if (bytes.every((b) => b == 0)) {
    throw StateError('Low-order X25519 point');
  }
  return bytes;
}

/// A single-shot HPKE encapsulated public key and authenticated ciphertext.
class HpkeSealed {
  /// Copies and validates a 32-byte encapsulation and bounded ciphertext.
  new(Uint8List enc, Uint8List ciphertext)
    : enc = _fixed(enc, 32),
      ciphertext = _bounded(ciphertext, 65552).asUnmodifiableView() {
    if (ciphertext.length < 16) {
      throw ArgumentError('Malformed HPKE ciphertext');
    }
  }

  /// The immutable ephemeral public key needed to open the message.
  final Uint8List enc;

  /// The immutable ciphertext followed by its 16-byte authentication tag.
  final Uint8List ciphertext;
}

Future<({Uint8List key, Uint8List baseNonce})> _schedule(
  Uint8List sharedSecret,
  List<int> info,
) async {
  final pskIdHash = await _labeledExtract(
    _suiteHpke,
    const [],
    'psk_id_hash',
    const [],
  );
  final infoHash = await _labeledExtract(
    _suiteHpke,
    const [],
    'info_hash',
    info,
  );
  final context = _cat([
    [0],
    pskIdHash,
    infoHash,
  ]);
  final secret = await _labeledExtract(
    _suiteHpke,
    sharedSecret,
    'secret',
    const [],
  );
  return (
    key: await _labeledExpand(_suiteHpke, secret, 'key', context, 32),
    baseNonce: await _labeledExpand(
      _suiteHpke,
      secret,
      'base_nonce',
      context,
      12,
    ),
  );
}

Future<Uint8List> _sharedSecret(Uint8List dh, Uint8List kemContext) async {
  final prk = await _labeledExtract(_suiteKem, const [], 'eae_prk', dh);
  return await _labeledExpand(_suiteKem, prk, 'shared_secret', kemContext, 32);
}

/// Seals [plaintext] to [recipientPublicKey], snapshotting inputs first.
///
/// [ephemeralIkm] is for deterministic test vectors only, not production use.
Future<HpkeSealed> hpkeSeal({
  required Uint8List recipientPublicKey,
  required List<int> info,
  required List<int> aad,
  required List<int> plaintext,
  List<int>? ephemeralIkm,
}) async {
  final recipientKey = _fixed(recipientPublicKey, 32);
  final infoBytes = _bounded(info, 1024);
  final aadBytes = _bounded(aad, 65536);
  final plaintextBytes = _bounded(plaintext, 65536);
  final ephemeralSeed = ephemeralIkm == null ? null : _fixed(ephemeralIkm, 32);
  final eph = ephemeralSeed != null
      ? await hpkeDeriveKeyPair(ephemeralSeed)
      : await hpkeNewKeyPair();
  final dh = await _dh(eph.privateKey, recipientKey);
  final shared = await _sharedSecret(dh, _cat([eph.publicKey, recipientKey]));
  final s = await _schedule(shared, infoBytes);
  final box = await _aead.encrypt(
    plaintextBytes,
    secretKey: SecretKey(s.key),
    nonce: s.baseNonce,
    aad: aadBytes,
  );
  return HpkeSealed(eph.publicKey, _cat([box.cipherText, box.mac.bytes]));
}

/// Opens and authenticates a single HPKE message for [recipient].
///
/// Copies bounded inputs before awaiting and rejects malformed encapsulations,
/// low-order points, and unauthenticated ciphertext.
Future<Uint8List> hpkeOpen({
  required HpkeKeyPair recipient,
  required Uint8List enc,
  required List<int> info,
  required List<int> aad,
  required List<int> ciphertext,
}) async {
  final encapsulation = _fixed(enc, 32);
  final infoBytes = _bounded(info, 1024);
  final aadBytes = _bounded(aad, 65536);
  final ciphertextBytes = _bounded(ciphertext, 65552);
  if (ciphertextBytes.length < 16) {
    throw StateError('Malformed HPKE message');
  }
  final dh = await _dh(recipient.privateKey, encapsulation);
  final shared = await _sharedSecret(
    dh,
    _cat([encapsulation, recipient.publicKey]),
  );
  final s = await _schedule(shared, infoBytes);
  final split = ciphertextBytes.length - 16;
  final box = SecretBox(
    ciphertextBytes.sublist(0, split),
    nonce: s.baseNonce,
    mac: Mac(ciphertextBytes.sublist(split)),
  );
  return Uint8List.fromList(
    await _aead.decrypt(box, secretKey: SecretKey(s.key), aad: aadBytes),
  );
}

Uint8List _fixed(List<int> value, int size) {
  if (value.length != size) {
    throw ArgumentError('Expected $size bytes');
  }
  return _bounded(value, size).asUnmodifiableView();
}

Uint8List _bounded(List<int> value, int max) {
  if (value.length > max || value.any((b) => b < 0 || b > 255)) {
    throw ArgumentError('Invalid or excessive bytes');
  }
  return Uint8List.fromList(value);
}
