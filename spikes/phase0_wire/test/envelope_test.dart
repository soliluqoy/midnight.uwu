import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vault_wire_spike/cbor_strict.dart';
import 'package:vault_wire_spike/envelope.dart';
import 'package:vault_wire_spike/vectors.dart';

Uint8List h(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

Matcher rejects(String reason) => throwsA(
  isA<WireReject>().having((e) => e.reason, 'reason', contains(reason)),
);

void main() {
  late Identity alice;
  late Identity bob;
  late Uint8List offer;

  setUpAll(() async {
    (alice, bob) = await vectorIdentities();
    offer = await encodeEnvelope(alice, vectorOffer(alice, bob));
  });

  test('Ed25519 matches RFC 8032 test 1 (empty message)', () async {
    final id = await Identity.fromSeeds(
      h('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'),
      filled(32, 1),
    );
    expect(
      hex(id.signingPublic),
      'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
    );
    expect(
      hex(await id.sign(const [])),
      'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
    );
  });

  test('golden vectors are byte-for-byte stable', () async {
    final golden = jsonDecode(File('test/vectors.json').readAsStringSync());
    expect(await buildVectors(), golden);
  });

  test('valid offer decodes with all fields', () async {
    final e = await decodeEnvelope(offer, now: vectorNow + 5);
    expect(e.type, MsgType.offer);
    expect(e.sender, alice.signingPublic);
    expect(e.recipient, bob.nodeId);
    expect(e.iceGeneration, 1);
    expect(e.payload[1], 'v=0 test-sdp');
  });

  group('rejection vectors', () {
    Future<void> expectReject(Uint8List wire, String reason, {int? now}) =>
        expectLater(
          decodeEnvelope(wire, now: now ?? vectorNow),
          rejects(reason),
        );

    Uint8List mutate(void Function(Uint8List) f) {
      final copy = Uint8List.fromList(offer);
      f(copy);
      return copy;
    }

    test(
      'unknown version',
      () => expectReject(mutate((b) => b[0] = 2), 'version'),
    );
    test(
      'unknown type',
      () => expectReject(mutate((b) => b[2] = 0x77), 'type'),
    );
    test('truncated', () => expectReject(offer.sublist(0, 60), 'size'));
    test('oversize', () => expectReject(Uint8List(40 * 1024), 'size'));
    test(
      'signature bit flip',
      () => expectReject(mutate((b) => b[40] ^= 1), 'signature'),
    );
    test(
      'body bit flip',
      () => expectReject(mutate((b) => b[b.length - 1] ^= 1), 'signature'),
    );
    test('sender key swapped', () async {
      final other = await Identity.generate();
      expect(
        decodeEnvelope(
          mutate((b) => b.setRange(3, 35, other.signingPublic)),
          now: vectorNow,
        ),
        rejects('signature'),
      );
    });
    test(
      'type changed after signing',
      () => expectReject(mutate((b) => b[2] = 3), 'signature'),
    );
    test(
      'expired',
      () => expectReject(
        offer,
        'expired',
        now: vectorNow + 120 + clockSkewSeconds + 1,
      ),
    );
    test(
      'issued in the future',
      () =>
          expectReject(offer, 'future', now: vectorNow - clockSkewSeconds - 1),
    );
    test(
      'malformed CBOR body',
      () => expectReject(
        Uint8List.fromList([...offer.sublist(0, 99), 0x9f, 0xff]),
        'cbor',
      ),
    );
    test('missing field', () async {
      final wire = await _resign(alice, MsgType.offer, {
        1: null,
        2: filled(16, 1),
        3: filled(16, 2),
        4: vectorNow,
        5: vectorNow + 60,
        6: 0,
      });
      await expectReject(wire, 'body shape');
    });
    test('unknown extra field', () async {
      final wire = await _resign(alice, MsgType.offer, {
        1: null,
        2: filled(16, 1),
        3: filled(16, 2),
        4: vectorNow,
        5: vectorNow + 60,
        6: 0,
        7: <Object, Object?>{},
        8: 1,
      });
      await expectReject(wire, 'body shape');
    });
    test('wrong field type', () async {
      final wire = await _resign(alice, MsgType.offer, {
        1: null,
        2: 'not-bytes',
        3: filled(16, 2),
        4: vectorNow,
        5: vectorNow + 60,
        6: 0,
        7: <Object, Object?>{},
      });
      await expectReject(wire, 'field types');
    });
    test('validity window longer than one hour', () async {
      final wire = await _resign(alice, MsgType.offer, {
        1: null,
        2: filled(16, 1),
        3: filled(16, 2),
        4: vectorNow,
        5: vectorNow + 7200,
        6: 0,
        7: <Object, Object?>{},
      });
      await expectReject(wire, 'validity');
    });
  });

  group('state checks', () {
    test('wrong recipient', () async {
      final e = await decodeEnvelope(offer, now: vectorNow);
      final eve = await Identity.generate();
      expect(
        () => EnvelopeChecks(eve).accept(e, now: vectorNow),
        rejects('recipient'),
      );
    });
    test('wrong session', () async {
      final e = await decodeEnvelope(offer, now: vectorNow);
      expect(
        () =>
            EnvelopeChecks(bob)
                .accept(e, expectedSession: filled(16, 9), now: vectorNow),
        rejects('session'),
      );
    });
    test(
      'replay is rejected, then accepted again only after the cache window',
      () async {
        final e = await decodeEnvelope(offer, now: vectorNow);
        final checks = EnvelopeChecks(bob)..accept(e, now: vectorNow);
        expect(() => checks.accept(e, now: vectorNow + 10), rejects('replay'));
      },
    );
    test('replay cache is bounded', () async {
      final e = await decodeEnvelope(offer, now: vectorNow);
      final checks = EnvelopeChecks(bob, maxEntries: 1)
        ..accept(e, now: vectorNow);
      final second = Envelope(
        type: e.type,
        sender: e.sender,
        recipient: e.recipient,
        messageId: filled(16, 7),
        sessionId: e.sessionId,
        issuedAt: e.issuedAt,
        expiresAt: e.expiresAt,
        iceGeneration: 1,
        payload: e.payload,
      );
      expect(() => checks.accept(second, now: vectorNow), rejects('full'));
    });
  });

  group('sealed signaling', () {
    late KeyBinding bobBinding;
    setUpAll(() async => bobBinding = await bob.binding(issuedAt: vectorNow));

    test(
      'round trip hides the inner envelope and verifies the signature',
      () async {
        final outer = await seal(offer, bob.nodeId, bobBinding);
        expect(
          utf8.decode(outer, allowMalformed: true).contains('test-sdp'),
          isFalse,
        );
        final inner = await open(outer, bob);
        final e = await decodeEnvelope(inner, now: vectorNow);
        expect(e.sender, alice.signingPublic);
      },
    );
    test('golden sealed vector opens', () async {
      final golden = jsonDecode(
        File('test/vectors.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final inner = await open(h(golden['sealedOffer'] as String), bob);
      expect(inner, offer);
    });
    test('another identity cannot open it', () async {
      final eve = await Identity.generate();
      final outer = await seal(offer, bob.nodeId, bobBinding);
      await expectLater(open(outer, eve), rejects('recipient'));
      final redirected = Uint8List.fromList(outer)..setRange(3, 35, eve.nodeId);
      await expectLater(open(redirected, eve), rejects('decryption'));
    });
    test('header, ciphertext and recipient tampering fail', () async {
      final outer = await seal(offer, bob.nodeId, bobBinding);
      await expectLater(
        open(Uint8List.fromList(outer)..[0] = 2, bob),
        rejects('version'),
      );
      await expectLater(
        open(Uint8List.fromList(outer)..[outer.length - 1] ^= 1, bob),
        rejects('decryption'),
      );
      await expectLater(
        open(Uint8List.fromList(outer)..[10] ^= 1, bob),
        rejects('recipient'),
      );
      await expectLater(
        open(Uint8List.fromList(outer)..[40] ^= 1, bob),
        rejects('decryption'),
      );
    });
    test('forged key binding is refused', () async {
      final forged = KeyBinding(
        bobBinding.signingKey,
        (await Identity.generate()).encryption.publicKey,
        vectorNow,
        bobBinding.signature,
      );
      await expectLater(seal(offer, bob.nodeId, forged), rejects('binding'));
    });
    test('binding for a different node id is refused', () async {
      await expectLater(
        seal(offer, alice.nodeId, bobBinding),
        rejects('binding'),
      );
    });
  });

  group('grants', () {
    final key = filled(32, 0x41);
    late OwnerState owner;
    late Grant grant;
    late Uint8List mac;

    setUp(() async {
      owner = OwnerState(key, bob.nodeId, 7);
      grant = Grant(
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
      mac = await grant.mac(key);
    });

    Future<void> check({
      String resource = 'library/all',
      String action = 'range',
      int? now,
      Uint8List? viewer,
      Uint8List? tag,
    }) => authorize(
      owner: owner,
      grant: grant,
      mac: tag ?? mac,
      authenticatedViewer: viewer ?? alice.nodeId,
      resource: resource,
      action: action,
      now: now ?? vectorNow + 10,
    );

    test('valid grant passes', () => check());
    test('golden MAC', () async {
      final golden = jsonDecode(
        File('test/vectors.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(hex(mac), golden['grantMac']);
    });
    test(
      'wrong viewer (copied token)',
      () async => expectLater(
        check(viewer: (await Identity.generate()).nodeId),
        rejects('mismatch'),
      ),
    );
    test(
      'bit-flipped MAC',
      () => expectLater(
        check(tag: Uint8List.fromList(mac)..[0] ^= 1),
        rejects('mac'),
      ),
    );
    test('wrong minting key', () async {
      final forged = await grant.mac(filled(32, 0x42));
      await expectLater(check(tag: forged), rejects('mac'));
    });
    test('scope: resource and action', () async {
      await expectLater(check(resource: 'library/private'), rejects('scope'));
      await expectLater(check(action: 'download'), rejects('scope'));
    });
    test('expiry and not-yet-valid', () async {
      await expectLater(check(now: vectorNow + 3600), rejects('validity'));
      await expectLater(check(now: vectorNow - 1), rejects('validity'));
    });
    test('epoch bump invalidates the grant', () async {
      owner.epoch = 8;
      await expectLater(check(), rejects('epoch'));
    });
    test('revoked grant and blocked viewer', () async {
      owner.revoked.add(base64.encode(grant.grantId));
      await expectLater(check(), rejects('revoked'));
      owner.revoked.clear();
      owner.blocked.add(base64.encode(alice.nodeId));
      await expectLater(check(), rejects('revoked'));
    });
    test('field change after minting breaks the MAC', () async {
      grant = Grant(
        version: 1,
        ownerId: bob.nodeId,
        viewerId: alice.nodeId,
        grantId: filled(16, 0xd1),
        resource: 'library/all',
        actions: const ['index', 'range', 'download'],
        issuedAt: vectorNow,
        expiresAt: vectorNow + 3600,
        epoch: 7,
      );
      await expectLater(check(action: 'download'), rejects('mac'));
    });
  });
}

Future<Uint8List> _resign(
  Identity from,
  int type,
  Map<Object, Object?> body,
) async {
  final bytes = cborEncode(body);
  final signed = <int>[
    ...ascii.encode('vault/v1/envelope\x00'),
    wireVersion,
    type >> 8,
    type & 0xff,
    ...from.signingPublic,
    ...bytes,
  ];
  final sig = await from.sign(signed);
  return Uint8List.fromList([
    wireVersion,
    type >> 8,
    type & 0xff,
    ...from.signingPublic,
    ...sig,
    ...bytes,
  ]);
}
