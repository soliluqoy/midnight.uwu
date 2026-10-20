import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_protocol/vault_protocol.dart';

const now = 1800000000;

Map<Object, Object?> fields(PairingInvite invite) =>
    cborDecode(
          base64Url.decode(
            invite.encode().substring(pairingInvitePrefix.length),
          ),
        )!
        as Map<Object, Object?>;

String text(Map<Object, Object?> map) =>
    pairingInvitePrefix + base64Url.encode(cborEncode(map));

void main() {
  late Identity hostIdentity;
  late ContactCard host;
  late ContactCard scanner;
  late ActivePairing pairing;
  late PairingInvite invite;

  setUp(() async {
    hostIdentity = await Identity.generate();
    host = await ContactCard.create(hostIdentity, name: 'Laptop');
    scanner = await ContactCard.create(
      await Identity.generate(),
      name: 'Phone',
    );
    pairing = ActivePairing.start(now: now);
    invite = pairing.invite(
      host,
      brokerHost: 'broker.emqx.io',
      brokerPort: 8883,
    );
  });

  group('invite text', () {
    test('round-trips a verified host card, broker and secret', () async {
      final encoded = invite.encode();
      expect(encoded, startsWith('vault-pair:1:'));
      final parsed = await PairingInvite.parse(encoded, now: now);
      expect(parsed.card.nodeId, host.nodeId);
      expect(parsed.card.name, 'Laptop');
      expect(parsed.brokerHost, 'broker.emqx.io');
      expect(parsed.brokerPort, 8883);
      expect(parsed.token, pairing.token);
      expect(parsed.expiresAt, now + pairingLifetimeSeconds);
    });

    test('fits the size cap with the longest display name', () async {
      final longest = await ContactCard.create(hostIdentity, name: 'é' * 64);
      final encoded = pairing
          .invite(longest, brokerHost: 'a' * 63, brokerPort: 65535)
          .encode();
      expect(encoded.length, lessThanOrEqualTo(maxPairingInviteChars));
      await PairingInvite.parse(encoded, now: now);
    });

    test('an expired code is reported as expired', () async {
      await expectLater(
        PairingInvite.parse(invite.encode(), now: invite.expiresAt),
        throwsA(isA<PairingCodeExpired>()),
      );
    });

    test('rejects anything that is not exactly a valid invite', () async {
      final valid = fields(invite);
      final card = valid[1]! as Map<Object, Object?>;
      final badSignature = Uint8List.fromList(card[5]! as Uint8List);
      badSignature[0] ^= 1;
      final cases = <String, String>{
        'wrong prefix': invite.encode().replaceFirst('vault-pair:1:', 'v:'),
        'future version': invite.encode().replaceFirst(':1:', ':2:'),
        'noncanonical base64': '${invite.encode()}AA',
        'oversize': 'vault-pair:1:${'A' * maxPairingInviteChars}',
        'extra key': text({...valid, 6: 1}),
        'missing key': text({...valid}..remove(5)),
        'extra card key': text({
          ...valid,
          1: {...card, 6: 1},
        }),
        'forged card': text({
          ...valid,
          1: {...card, 5: badSignature},
        }),
        'empty card name': text({
          ...valid,
          1: {...card, 1: ''},
        }),
        'url as host': text({...valid, 2: 'mqtt://broker.emqx.io'}),
        'host with space': text({...valid, 2: 'broker emqx.io'}),
        'empty host': text({...valid, 2: ''}),
        'port zero': text({...valid, 3: 0}),
        'port too large': text({...valid, 3: 65536}),
        'short token': text({...valid, 4: Uint8List(31)}),
        'text token': text({...valid, 4: 'secret'}),
        'too far in the future': text({
          ...valid,
          5: now + pairingLifetimeSeconds + clockSkewSeconds + 1,
        }),
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        await expectLater(
          PairingInvite.parse(value, now: now),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'Not a valid Midnight pairing code.',
            ),
          ),
          reason: key,
        );
      }
    });
  });

  group('introduction', () {
    Future<Introduction> received(Introduction sent, {List<int>? sender}) =>
        Introduction.fromPayload(
          sent.toPayload(),
          sender: sender ?? sent.card.binding.signingKey,
        );

    test('redeems a valid introduction exactly once', () async {
      final introduction = await received(
        await Introduction.create(card: scanner, invite: invite),
      );
      expect(introduction.card.nodeId, scanner.nodeId);
      expect(
        await pairing.redeem(
          introduction,
          recipientNodeId: hostIdentity.nodeId,
          now: now,
        ),
        isTrue,
      );
      expect(pairing.used, isTrue);
      expect(
        await pairing.redeem(
          introduction,
          recipientNodeId: hostIdentity.nodeId,
          now: now,
        ),
        isFalse,
        reason: 'the secret is single-use',
      );
    });

    test('a wrong MAC is refused without consuming the secret', () async {
      final otherSecret = ActivePairing.start(now: now)
          .invite(host, brokerHost: 'broker.emqx.io', brokerPort: 8883);
      final wrong = await received(
        await Introduction.create(card: scanner, invite: otherSecret),
      );
      expect(
        await pairing.redeem(
          wrong,
          recipientNodeId: hostIdentity.nodeId,
          now: now,
        ),
        isFalse,
      );
      expect(pairing.used, isFalse);
    });

    test('the MAC binds the intended host', () async {
      final introduction = await received(
        await Introduction.create(card: scanner, invite: invite),
      );
      final elsewhere = (await Identity.generate()).nodeId;
      expect(
        await pairing.redeem(
          introduction,
          recipientNodeId: elsewhere,
          now: now,
        ),
        isFalse,
      );
    });

    test('an expired pairing refuses a valid MAC', () async {
      final introduction = await received(
        await Introduction.create(card: scanner, invite: invite),
      );
      expect(
        await pairing.redeem(
          introduction,
          recipientNodeId: hostIdentity.nodeId,
          now: pairing.expiresAt,
        ),
        isFalse,
      );
    });

    test('the contact must be the envelope signer', () async {
      final sent = await Introduction.create(card: scanner, invite: invite);
      await expectLater(
        received(sent, sender: host.binding.signingKey),
        throwsA(
          isA<WireReject>().having(
            (error) => error.reason,
            'reason',
            'introduction contact is not the signer',
          ),
        ),
      );
    });

    test('a substituted card no longer matches its MAC', () async {
      final sent = await Introduction.create(card: scanner, invite: invite);
      final other = await ContactCard.create(
        await Identity.generate(),
        name: 'Other',
      );
      final swapped = await Introduction.fromPayload({
        'card': await other.encode(),
        'mac': sent.mac,
      }, sender: other.binding.signingKey);
      expect(
        await pairing.redeem(
          swapped,
          recipientNodeId: hostIdentity.nodeId,
          now: now,
        ),
        isFalse,
      );
    });
  });
}
