import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vault_identity/vault_identity.dart';

Uint8List h(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);
String hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // RFC 9180 appendix A.2: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256,
  // ChaCha20Poly1305, base mode.
  final info = h('4f6465206f6e2061204772656369616e2055726e');
  final ikmE = h(
    '909a9b35d3dc4713a5e72a4da274b55d3d3821a37e5d099e74a647db583a904b',
  );
  final ikmR = h(
    '1ac01f181fdf9f352797655161c58b75c656a6cc2716dcb66372da835542e1df',
  );
  final pt = h('4265617574792069732074727574682c20747275746820626561757479');
  final aad0 = h('436f756e742d30');
  const enc0 =
      '1afa08d3dec047a643885163f1180476fa7ddb54c6a8029ea33f95796bf2ac4a';
  const ct0 =
      '1c5250d8034ec2b784ba2cfd69dbdb8af406cfe3ff938e131f0def8c8b60b4db'
      '21993c62ce81883d2dd1b51a28';

  test('DeriveKeyPair matches RFC 9180 A.2 keys', () async {
    final r = await hpkeDeriveKeyPair(ikmR);
    expect(
      hex(r.privateKey),
      '8057991eef8f1f1af18f4a9491d16a1ce333f695d4db8e38da75975c4478e0fb',
    );
    expect(
      hex(r.publicKey),
      '4310ee97d88cc1f088a5576c77ab0cf5c3ac797f3d95139c6c84b5429c59662a',
    );
    expect(hex((await hpkeDeriveKeyPair(ikmE)).publicKey), enc0);
  });

  test('seal reproduces the RFC 9180 A.2 encryption at sequence 0', () async {
    final r = await hpkeDeriveKeyPair(ikmR);
    final sealed = await hpkeSeal(
      recipientPublicKey: r.publicKey,
      info: info,
      aad: aad0,
      plaintext: pt,
      ephemeralIkm: ikmE,
    );
    expect(hex(sealed.enc), enc0);
    expect(hex(sealed.ciphertext), ct0);
  });

  test('open decrypts the RFC vector and rejects tampering', () async {
    final r = await hpkeDeriveKeyPair(ikmR);
    final enc = h(enc0);
    final ct = h(ct0);
    expect(
      await hpkeOpen(
        recipient: r,
        enc: enc,
        info: info,
        aad: aad0,
        ciphertext: ct,
      ),
      pt,
    );
    final flipped = Uint8List.fromList(ct)..[3] ^= 1;
    await expectLater(
      hpkeOpen(
        recipient: r,
        enc: enc,
        info: info,
        aad: aad0,
        ciphertext: flipped,
      ),
      throwsA(anything),
    );
    await expectLater(
      hpkeOpen(
        recipient: r,
        enc: enc,
        info: info,
        aad: h('436f756e742d31'),
        ciphertext: ct,
      ),
      throwsA(anything),
    );
    await expectLater(
      hpkeOpen(
        recipient: r,
        enc: enc,
        info: h('00'),
        aad: aad0,
        ciphertext: ct,
      ),
      throwsA(anything),
    );
  });

  test('random key round trip', () async {
    final r = await hpkeNewKeyPair();
    final s = await hpkeSeal(
      recipientPublicKey: r.publicKey,
      info: info,
      aad: aad0,
      plaintext: pt,
    );
    expect(
      await hpkeOpen(
        recipient: r,
        enc: s.enc,
        info: info,
        aad: aad0,
        ciphertext: s.ciphertext,
      ),
      pt,
    );
  });
}
