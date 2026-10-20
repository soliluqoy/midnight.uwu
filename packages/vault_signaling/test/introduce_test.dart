import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_protocol/vault_protocol.dart'
    show ActivePairing, Introduction, MsgType, PairingInvite;
import 'package:vault_signaling/vault_signaling.dart';

int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  late Identity host;
  late Identity phone;
  late ContactCard hostCard;
  late ContactCard phoneCard;
  late ManualSignaling hostTransport;
  late ManualSignaling phoneTransport;
  late SignalingClient hostClient;
  late SignalingClient phoneClient;
  late ActivePairing pairing;
  late PairingInvite invite;
  late List<SignalingFailure> hostFailures;
  late List<Introduction> accepted;
  int? clockOffset;
  Future<bool> Function(Introduction)? onIntroduce;

  Future<bool> redeem(Introduction introduction) async {
    final ok = await pairing.redeem(
      introduction,
      recipientNodeId: host.nodeId,
      now: _now + (clockOffset ?? 0),
    );
    if (ok) accepted.add(introduction);
    return ok;
  }

  setUp(() async {
    host = await Identity.generate();
    phone = await Identity.generate();
    hostCard = await ContactCard.create(host, name: 'Laptop');
    phoneCard = await ContactCard.create(phone, name: 'Phone');
    pairing = ActivePairing.start(now: _now);
    invite = pairing.invite(hostCard, brokerHost: 'b.example', brokerPort: 1);
    accepted = [];
    hostFailures = [];
    clockOffset = null;
    onIntroduce = redeem;
    hostTransport = ManualSignaling();
    phoneTransport = ManualSignaling();
    hostClient = SignalingClient(
      identity: host,
      strategy: hostTransport,
      resolveBinding: (_) async => null,
      onIntroduce: (introduction) => onIntroduce!(introduction),
      retryDelay: const Duration(hours: 1),
    );
    phoneClient = SignalingClient(
      identity: phone,
      strategy: phoneTransport,
      resolveBinding: (id) async =>
          id == hostCard.nodeId ? hostCard.binding : null,
      retryDelay: const Duration(hours: 1),
    );
    hostClient.failures.listen(hostFailures.add);
    await hostClient.start();
    await phoneClient.start();
  });

  tearDown(() async {
    await hostClient.close();
    await phoneClient.close();
  });

  /// Delivers the phone's newest frame; returns the host's new ACK, if any.
  Future<String?> deliver([String? frame]) async {
    final before = hostTransport.pendingExports.length;
    await hostTransport.importText(frame ?? phoneTransport.pendingExports.last);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final after = hostTransport.pendingExports;
    return after.length > before ? after.last : null;
  }

  /// Sends an introduction; the record's future completes on its ACK.
  Future<({Future<void> done})> introduce(Introduction introduction) async {
    final done = phoneClient.introduce(
      host: hostCard.binding,
      introduction: introduction,
    )..ignore();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return (done: done);
  }

  test('a valid introduction is accepted once and acknowledged', () async {
    final (:done) = await introduce(
      await Introduction.create(card: phoneCard, invite: invite),
    );
    final frame = phoneTransport.pendingExports.last;
    final ack = await deliver(frame);
    expect(ack, isNotNull);
    expect(accepted.single.card.nodeId, phoneCard.nodeId);
    await phoneTransport.importText(ack!);
    await done.timeout(const Duration(seconds: 3));
    expect(phoneTransport.pendingExports, isEmpty);

    final duplicateAck = await deliver(frame);
    expect(duplicateAck, isNotNull, reason: 'a lost ACK is sent again');
    expect(accepted, hasLength(1), reason: 'without a second acceptance');
  });

  test('a reused secret is refused for a new introduction', () async {
    final first = await introduce(
      await Introduction.create(card: phoneCard, invite: invite),
    );
    await phoneTransport.importText((await deliver())!);
    await first.done;
    await introduce(await Introduction.create(card: phoneCard, invite: invite));
    expect(await deliver(), isNull);
    expect(hostFailures.last.reason, 'introduction rejected');
  });

  test('a wrong MAC is refused and not acknowledged', () async {
    final otherInvite = ActivePairing.start(now: _now)
        .invite(hostCard, brokerHost: 'b.example', brokerPort: 1);
    await introduce(
      await Introduction.create(card: phoneCard, invite: otherInvite),
    );
    expect(await deliver(), isNull);
    expect(accepted, isEmpty);
    expect(pairing.used, isFalse);
    expect(hostFailures.last.reason, 'introduction rejected');
  });

  test('an expired pairing is refused', () async {
    clockOffset = pairing.expiresAt - _now;
    await introduce(await Introduction.create(card: phoneCard, invite: invite));
    expect(await deliver(), isNull);
    expect(accepted, isEmpty);
  });

  test(
    'a card that is not the signer is refused before the secret check',
    () async {
      final other = await ContactCard.create(
        await Identity.generate(),
        name: 'Other',
      );
      final forged = await Introduction.create(card: other, invite: invite);
      await phoneClient.send(
        peer: hostCard.binding,
        type: MsgType.introduce,
        sessionId: Uint8List(16),
        payload: forged.toPayload(),
      );
      expect(await deliver(), isNull);
      expect(accepted, isEmpty);
      expect(
        hostFailures.last.reason,
        'introduction contact is not the signer',
      );
    },
  );

  test('other message types from a noncontact are still rejected', () async {
    await phoneClient.send(
      peer: hostCard.binding,
      type: MsgType.offer,
      sessionId: Uint8List(16),
      payload: {'sdp': 'v=0\r\n'},
    );
    expect(await deliver(), isNull);
    expect(hostFailures.last.kind, SignalingFailureKind.unknownSender);
    expect(hostFailures.last.peerId, phoneCard.nodeId);
  });

  test(
    'without a pairing callback an introduction is an unknown sender',
    () async {
      await hostClient.close();
      hostTransport = ManualSignaling();
      hostClient = SignalingClient(
        identity: host,
        strategy: hostTransport,
        resolveBinding: (_) async => null,
        retryDelay: const Duration(hours: 1),
      );
      hostClient.failures.listen(hostFailures.add);
      await hostClient.start();
      await introduce(
        await Introduction.create(card: phoneCard, invite: invite),
      );
      expect(await deliver(), isNull);
      expect(hostFailures.last.kind, SignalingFailureKind.unknownSender);
    },
  );

  test('an unanswered introduction fails at its deadline', () async {
    await phoneClient.close();
    phoneTransport = ManualSignaling();
    phoneClient = SignalingClient(
      identity: phone,
      strategy: phoneTransport,
      resolveBinding: (id) async =>
          id == hostCard.nodeId ? hostCard.binding : null,
      retryDelay: const Duration(milliseconds: 20),
      retryDeadline: const Duration(milliseconds: 200),
    );
    await phoneClient.start();
    await expectLater(
      phoneClient.introduce(
        host: hostCard.binding,
        introduction: await Introduction.create(
          card: phoneCard,
          invite: invite,
        ),
      ),
      throwsA(
        isA<SignalingFailure>().having(
          (failure) => failure.kind,
          'kind',
          SignalingFailureKind.acknowledgmentTimeout,
        ),
      ),
    );
  });
}
