import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_net/src/authentication.dart';
import 'package:vault_net/src/policy.dart';
import 'package:vault_protocol/vault_protocol.dart' show cborEncode;

import 'policy_test.dart' show sdp;

void main() {
  late Identity alice;
  late Identity bob;
  late KeyBinding aliceBinding;
  late KeyBinding bobBinding;
  final session = Uint8List.fromList(List<int>.generate(16, (i) => i));
  setUpAll(() async {
    alice = await Identity.fromSeeds(
      Uint8List.fromList(List.filled(32, 1)),
      Uint8List.fromList(List.filled(32, 2)),
    );
    bob = await Identity.fromSeeds(
      Uint8List.fromList(List.filled(32, 3)),
      Uint8List.fromList(List.filled(32, 4)),
    );
    aliceBinding = await alice.binding(issuedAt: 100);
    bobBinding = await bob.binding(issuedAt: 100);
  });

  (SessionAuthenticator, SessionAuthenticator) pair() {
    final offererId = nodeIdText(alice.nodeId);
    return (
      SessionAuthenticator(
        identity: alice,
        peer: bobBinding,
        session: session,
        generation: 0,
        offererId: offererId,
        offer: sdp(),
        answer: sdp(fingerprint: 'CD'),
      ),
      SessionAuthenticator(
        identity: bob,
        peer: aliceBinding,
        session: session,
        generation: 0,
        offererId: offererId,
        offer: sdp(),
        answer: sdp(fingerprint: 'CD'),
      ),
    );
  }

  test(
    'both real signatures and mutual fresh challenges precede readiness',
    () async {
      final (a, b) = pair();
      expect(a.connected, isFalse);
      expect(a.acceptReady, throwsA(isA<PeerFailure>()));
      a.acceptChallenge(b.challenge);
      b.acceptChallenge(a.challenge);
      final proofA = await a.createProof();
      final proofB = await b.createProof();
      await b.acceptProof(proofA);
      expect(b.authenticated, isFalse, reason: 'own proof has not been sent');
      a.markProofSent();
      b.markProofSent();
      await a.acceptProof(proofB);
      expect(a.authenticated, isTrue);
      expect(b.authenticated, isTrue);
      expect(a.connected, isFalse, reason: 'peer readiness is still required');
      a.acceptReady();
      b.acceptReady();
      expect(a.connected, isTrue);
      expect(b.connected, isTrue);
      expect(a.acceptReady, throwsA(isA<PeerFailure>()));
      await expectLater(b.acceptProof(proofA), throwsA(isA<PeerFailure>()));
    },
  );

  test(
    'proof binds every SDP, DTLS, identity, session and nonce field',
    () async {
      final (a, b) = pair();
      a.acceptChallenge(b.challenge);
      b.acceptChallenge(a.challenge);
      final offer = SdpBinding.parse(sdp());
      final answer = SdpBinding.parse(sdp(fingerprint: 'CD'));
      final transcript = <Object, Object?>{
        1: 'vault/v1/session-auth',
        2: session,
        3: 0,
        4: nodeIdText(alice.nodeId),
        5: offer.digest,
        6: offer.fingerprint,
        7: answer.digest,
        8: answer.fingerprint,
        9: alice.signingPublic,
        10: bob.signingPublic,
        11: a.challenge,
        12: b.challenge,
      };
      final mutations = <int, Object?>{
        1: 'another-protocol',
        2: Uint8List(16),
        3: 1,
        4: nodeIdText(bob.nodeId),
        5: answer.digest,
        6: answer.fingerprint,
        7: offer.digest,
        8: offer.fingerprint,
        9: bob.signingPublic,
        10: alice.signingPublic,
        11: b.challenge,
        12: a.challenge,
      };
      for (final mutation in mutations.entries) {
        final altered = Map<Object, Object?>.of(transcript)
          ..[mutation.key] = mutation.value;
        final proof = await alice.sign(cborEncode(altered));
        await expectLater(
          b.acceptProof(proof),
          throwsA(isA<PeerFailure>()),
          reason: 'transcript field ${mutation.key} must be bound',
        );
        expect(b.authenticated, isFalse);
      }
      final valid = await a.createProof();
      await b.acceptProof(valid);
      expect(b.authenticated, isFalse, reason: 'local proof still unsent');
    },
  );

  test('replaying a prior valid proof fails against new challenges', () async {
    final (a, b) = pair();
    a.acceptChallenge(b.challenge);
    b.acceptChallenge(a.challenge);
    final proof = await a.createProof();
    final (nextA, nextB) = pair();
    nextA.acceptChallenge(nextB.challenge);
    nextB.acceptChallenge(nextA.challenge);
    expect(sameBytes(a.challenge, nextA.challenge), isFalse);
    await expectLater(nextB.acceptProof(proof), throwsA(isA<PeerFailure>()));
  });

  test('reflection and duplicate challenge are rejected', () {
    final (a, b) = pair();
    expect(() => a.acceptChallenge(a.challenge), throwsA(isA<PeerFailure>()));
    expect(() => a.acceptChallenge(Uint8List(31)), throwsA(isA<PeerFailure>()));
    a.acceptChallenge(b.challenge);
    expect(() => a.acceptChallenge(b.challenge), throwsA(isA<PeerFailure>()));
  });

  test(
    'changed encryption binding is not an alias for the same signing key',
    () async {
      final replacement = KeyBinding(
        aliceBinding.signingKey,
        bobBinding.encryptionKey,
        aliceBinding.issuedAt,
        aliceBinding.signature,
      );
      expect(sameBinding(aliceBinding, replacement), isFalse);
      expect(await replacement.verify(), isFalse);
      final (a, _) = pair();
      expect(a.markProofSent, throwsA(isA<PeerFailure>()));
      await expectLater(a.createProof(), throwsA(isA<PeerFailure>()));
    },
  );
}
