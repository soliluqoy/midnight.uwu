import 'dart:typed_data';

import 'envelope.dart';
import 'hpke.dart';

String hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

Uint8List filled(int n, int value) => Uint8List.fromList(List.filled(n, value));

const vectorNow = 1800000000;

/// Fixed identities so every byte is reproducible. Test keys only.
Future<(Identity, Identity)> vectorIdentities() async => (
  await Identity.fromSeeds(filled(32, 0x11), filled(32, 0x21)),
  await Identity.fromSeeds(filled(32, 0x12), filled(32, 0x22)),
);

Envelope vectorOffer(Identity from, Identity to) => Envelope(
  type: MsgType.offer,
  sender: from.signingPublic,
  recipient: to.nodeId,
  messageId: filled(16, 0xa1),
  sessionId: filled(16, 0xb1),
  issuedAt: vectorNow,
  expiresAt: vectorNow + 120,
  iceGeneration: 1,
  payload: {1: 'v=0 test-sdp', 2: filled(32, 0xc1)},
);

/// Deterministic vector set. Sealing uses fixed ephemeral key material.
Future<Map<String, Object?>> buildVectors() async {
  final (alice, bob) = await vectorIdentities();
  final offer = await encodeEnvelope(alice, vectorOffer(alice, bob));
  final binding = await bob.binding(issuedAt: vectorNow);
  final inner = offer;
  final sealedParts = await hpkeSeal(
    recipientPublicKey: bob.encryption.publicKey,
    info: [...'vault/v1/sealed\x00'.codeUnits, ...bob.nodeId],
    aad: [1, 0x01, 0x00, ...bob.nodeId],
    plaintext: inner,
    ephemeralIkm: filled(32, 0x31),
  );
  final sealed = Uint8List.fromList([
    1,
    0x01,
    0x00,
    ...bob.nodeId,
    ...sealedParts.enc,
    ...sealedParts.ciphertext,
  ]);
  final grant = Grant(
    version: 1,
    ownerId: bob.nodeId,
    viewerId: alice.nodeId,
    grantId: filled(16, 0xd1),
    resource: 'library/all',
    actions: const ['index', 'range'],
    issuedAt: vectorNow,
    expiresAt: vectorNow + 3600,
    epoch: 7,
  );
  final mintingKey = filled(32, 0x41);
  return {
    'aliceEdPublic': hex(alice.signingPublic),
    'aliceX25519Public': hex(alice.encryption.publicKey),
    'aliceNodeId': hex(alice.nodeId),
    'aliceNodeIdText': nodeIdText(alice.nodeId),
    'bobNodeId': hex(bob.nodeId),
    'bobKeyBinding': hex(binding.signature),
    'signedOffer': hex(offer),
    'sealedOffer': hex(sealed),
    'grantCanonical': hex(grant.canonical()),
    'grantMac': hex(await grant.mac(mintingKey)),
  };
}
