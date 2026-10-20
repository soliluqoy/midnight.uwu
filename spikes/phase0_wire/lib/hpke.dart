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

final _suiteKem = _cat([ascii.encode('KEM'), _i2osp(0x20, 2)]);
final _suiteHpke = _cat([
  ascii.encode('HPKE'),
  _i2osp(0x20, 2),
  _i2osp(1, 2),
  _i2osp(3, 2),
]);
final _v1 = ascii.encode('HPKE-v1');

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

class HpkeKeyPair {
  HpkeKeyPair(this.privateKey, this.publicKey);
  final Uint8List privateKey;
  final Uint8List publicKey;
}

Future<HpkeKeyPair> _pairFromSeed(Uint8List sk) async {
  final pair = await _x25519.newKeyPairFromSeed(sk);
  final pk = await pair.extractPublicKey();
  return HpkeKeyPair(sk, Uint8List.fromList(pk.bytes));
}

/// RFC 9180 DeriveKeyPair for X25519.
Future<HpkeKeyPair> hpkeDeriveKeyPair(List<int> ikm) async {
  final prk = await _labeledExtract(_suiteKem, const [], 'dkp_prk', ikm);
  final sk = await _labeledExpand(_suiteKem, prk, 'sk', const [], 32);
  return _pairFromSeed(sk);
}

Future<HpkeKeyPair> hpkeNewKeyPair() async {
  final pair = await _x25519.newKeyPair();
  final sk = Uint8List.fromList(await pair.extractPrivateKeyBytes());
  return _pairFromSeed(sk);
}

Future<Uint8List> _dh(Uint8List sk, Uint8List pk) async {
  final pair = await _x25519.newKeyPairFromSeed(sk);
  final secret = await _x25519.sharedSecretKey(
    keyPair: pair,
    remotePublicKey: SimplePublicKey(pk, type: KeyPairType.x25519),
  );
  final bytes = Uint8List.fromList(await secret.extractBytes());
  if (bytes.every((b) => b == 0)) throw StateError('Low-order X25519 point');
  return bytes;
}

class HpkeSealed {
  HpkeSealed(this.enc, this.ciphertext);
  final Uint8List enc;
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
  return _labeledExpand(_suiteKem, prk, 'shared_secret', kemContext, 32);
}

/// Seals [plaintext] to [recipientPublicKey]. [ephemeralIkm] is for vectors only.
Future<HpkeSealed> hpkeSeal({
  required Uint8List recipientPublicKey,
  required List<int> info,
  required List<int> aad,
  required List<int> plaintext,
  List<int>? ephemeralIkm,
}) async {
  final eph = ephemeralIkm != null
      ? await hpkeDeriveKeyPair(ephemeralIkm)
      : await hpkeNewKeyPair();
  final dh = await _dh(eph.privateKey, recipientPublicKey);
  final shared = await _sharedSecret(
    dh,
    _cat([eph.publicKey, recipientPublicKey]),
  );
  final s = await _schedule(shared, info);
  final box = await _aead.encrypt(
    plaintext,
    secretKey: SecretKey(s.key),
    nonce: s.baseNonce,
    aad: aad,
  );
  return HpkeSealed(eph.publicKey, _cat([box.cipherText, box.mac.bytes]));
}

Future<Uint8List> hpkeOpen({
  required HpkeKeyPair recipient,
  required Uint8List enc,
  required List<int> info,
  required List<int> aad,
  required List<int> ciphertext,
}) async {
  if (enc.length != 32 || ciphertext.length < 16) {
    throw StateError('Malformed HPKE message');
  }
  final dh = await _dh(recipient.privateKey, enc);
  final shared = await _sharedSecret(dh, _cat([enc, recipient.publicKey]));
  final s = await _schedule(shared, info);
  final split = ciphertext.length - 16;
  final box = SecretBox(
    ciphertext.sublist(0, split),
    nonce: s.baseNonce,
    mac: Mac(ciphertext.sublist(split)),
  );
  return Uint8List.fromList(
    await _aead.decrypt(box, secretKey: SecretKey(s.key), aad: aad),
  );
}
