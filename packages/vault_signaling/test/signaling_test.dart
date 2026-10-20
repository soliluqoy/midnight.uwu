import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_protocol/vault_protocol.dart'
    show
        Envelope,
        MsgType,
        WireReject,
        decodeEnvelope,
        encodeEnvelope,
        open,
        seal;
import 'package:vault_signaling/vault_signaling.dart';

/// Reproducible real cryptographic identities for behavioral tests.
Future<Identity> identity(int seed) => Identity.fromSeeds(
  Uint8List.fromList(List.filled(32, seed)),
  Uint8List.fromList(List.filled(32, seed + 20)),
);

/// Waits for observable asynchronous state with a bounded failure deadline.
Future<void> until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('Condition did not settle');
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Identity alice;
  late Identity bob;
  late KeyBinding aliceBinding;
  late KeyBinding bobBinding;
  late ManualSignaling left;
  late ManualSignaling right;
  late SignalingClient a;
  late SignalingClient b;
  final session = Uint8List.fromList(List.generate(16, (i) => i));

  setUp(() async {
    alice = await identity(1);
    bob = await identity(2);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    aliceBinding = await alice.binding(issuedAt: now);
    bobBinding = await bob.binding(issuedAt: now);
    left = ManualSignaling();
    right = ManualSignaling();
    final contacts = {
      nodeIdText(alice.nodeId): aliceBinding,
      nodeIdText(bob.nodeId): bobBinding,
    };
    a = SignalingClient(
      identity: alice,
      strategy: left,
      resolveBinding: (id) async => contacts[id],
      retryDelay: const Duration(hours: 1),
    );
    b = SignalingClient(
      identity: bob,
      strategy: right,
      resolveBinding: (id) async => contacts[id],
      retryDelay: const Duration(hours: 1),
    );
    await a.start();
    await b.start();
  });

  tearDown(() async {
    await a.close();
    await b.close();
  });

  test(
    'complete manual offer, answer and signed encrypted ACK exchange',
    () async {
      final received = b.messages.first;
      await a.send(
        peer: bobBinding,
        type: MsgType.offer,
        sessionId: session,
        payload: {'sdp': 'v=0\r\na=fingerprint:sha-256 offer\r\n'},
      );
      expect(a.pendingCount, 1);
      expect(left.pendingExports, hasLength(1));
      final ack = right.exports.first;
      await right.importText(left.pendingExports.single);
      final offer = await received;
      expect(offer.type, MsgType.offer);
      expect(offer.sender, alice.signingPublic);
      expect(offer.payload['sdp'], contains('offer'));
      await left.importText(await ack);
      await until(() => a.pendingCount == 0);
      expect(left.pendingExports, isEmpty);

      final answerReceived = a.messages.first;
      await b.send(
        peer: aliceBinding,
        type: MsgType.answer,
        sessionId: session,
        payload: {'sdp': 'v=0\r\na=fingerprint:sha-256 answer\r\n'},
      );
      final answerText = right.pendingExports.last;
      final answerAck = left.exports.first;
      await left.importText(answerText);
      expect((await answerReceived).type, MsgType.answer);
      await right.importText(await answerAck);
      await until(() => b.pendingCount == 0);
      expect(right.pendingExports, isNot(contains(answerText)));
      // ACK exports remain explicitly removable, not fictional short codes.
      right.pendingExports.forEach(right.removeExport);
      expect(right.pendingExports, isEmpty);
    },
  );

  test(
    'lost ACK and duplicate import reACK without repeated delivery',
    () async {
      var deliveries = 0;
      final sub = b.messages.listen((_) => deliveries++);
      await a.send(
        peer: bobBinding,
        type: MsgType.offer,
        sessionId: session,
        payload: {'sdp': 'v=0\r\n'},
      );
      final text = left.pendingExports.single;
      final firstAck = right.exports.first;
      await right.importText(text);
      await firstAck; // Drop this ACK deliberately.
      expect(a.pendingCount, 1);
      final secondAck = right.exports.first;
      await right.importText(text);
      await left.importText(await secondAck);
      await until(() => a.pendingCount == 0);
      expect(deliveries, 1);
      await sub.cancel();
    },
  );

  test(
    'ACK publish transition failure is recoverable and duplicate reACKs',
    () async {
      final transport = _TestTransport()..rejectNextPublish = true;
      final receiver = SignalingClient(
        identity: bob,
        strategy: transport,
        resolveBinding: (_) async => aliceBinding,
      );
      addTearDown(receiver.close);
      await receiver.start();
      var deliveries = 0;
      final subscription = receiver.messages.listen((_) => deliveries++);
      addTearDown(subscription.cancel);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final inner = await encodeEnvelope(
        alice,
        Envelope(
          type: MsgType.offer,
          sender: alice.signingPublic,
          recipient: bob.nodeId,
          messageId: Uint8List(16),
          sessionId: session,
          issuedAt: now,
          expiresAt: now + 60,
          iceGeneration: 0,
          payload: {'sdp': 'v=0'},
        ),
      );
      final frame = SignalFrame(
        nodeIdText(bob.nodeId),
        await seal(inner, bob.nodeId, bobBinding),
      );
      final failedAck = receiver.failures.first;
      transport.input.add(frame);
      final failure = await failedAck;
      expect(failure.reason, 'signal acknowledgment publish failed');
      expect(failure.terminal, isFalse);
      expect(failure.peerId, nodeIdText(alice.nodeId));
      expect(failure.sessionId, session);
      expect(deliveries, 1);
      transport.input.add(frame);
      await until(() => transport.publications == 1);
      expect(deliveries, 1);
    },
  );

  test(
    'ACK from another known contact cannot acknowledge a peer message',
    () async {
      final mallory = await identity(3);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final malloryBinding = await mallory.binding(issuedAt: now);
      final transport = _TestTransport();
      final client = SignalingClient(
        identity: alice,
        strategy: transport,
        resolveBinding: (id) async => id == nodeIdText(bob.nodeId)
            ? bobBinding
            : id == nodeIdText(mallory.nodeId)
            ? malloryBinding
            : null,
        retryDelay: const Duration(hours: 1),
      );
      await client.start();
      await client.send(
        peer: bobBinding,
        type: MsgType.offer,
        sessionId: session,
        payload: {'sdp': 'v=0'},
      );
      final original = await decodeEnvelope(
        await open(transport.lastBytes!, bob),
        now: now,
      );
      Future<Uint8List> forged(
        int type,
        Map<Object, Object?> payload,
        int id,
      ) async {
        final inner = await encodeEnvelope(
          mallory,
          Envelope(
            type: type,
            sender: mallory.signingPublic,
            recipient: alice.nodeId,
            messageId: Uint8List.fromList(List.filled(16, id)),
            sessionId: session,
            issuedAt: now,
            expiresAt: now + 60,
            iceGeneration: 0,
            payload: payload,
          ),
        );
        return await seal(inner, alice.nodeId, aliceBinding);
      }

      transport.input.add(
        SignalFrame(
          nodeIdText(alice.nodeId),
          await forged(MsgType.ack, {1: original.messageId}, 40),
        ),
      );
      // This valid message is a serialization barrier after the forged ACK.
      final barrier = client.messages.first;
      transport.input.add(
        SignalFrame(
          nodeIdText(alice.nodeId),
          await forged(MsgType.bye, {'reason': 'barrier'}, 41),
        ),
      );
      await barrier;
      expect(client.pendingCount, 1);
      await client.close();
    },
  );

  test(
    'no caller media, grant, extra SDP fields or caller ACK bypass',
    () async {
      for (final payload in <Map<Object, Object?>>[
        {'sdp': 'v=0', 'index': 'private'},
        {'media': Uint8List(1)},
        {'grant': 'private'},
        {'sdp': 'x' * (20 * 1024 + 1)},
      ]) {
        await expectLater(
          a.send(
            peer: bobBinding,
            type: MsgType.offer,
            sessionId: session,
            payload: payload,
          ),
          throwsA(isA<WireReject>()),
        );
      }
      await expectLater(
        a.send(
          peer: bobBinding,
          type: MsgType.ack,
          sessionId: session,
          payload: {1: Uint8List(16)},
        ),
        throwsA(isA<WireReject>()),
      );
      expect(left.pendingExports, isEmpty);
    },
  );

  test(
    'unknown contacts and tampered ciphertext have no side effects',
    () async {
      await b.close();
      right = ManualSignaling();
      b = SignalingClient(
        identity: bob,
        strategy: right,
        resolveBinding: (_) async => null,
      );
      await b.start();
      var deliveries = 0;
      final sub = b.messages.listen((_) => deliveries++);
      final rejection = b.failures.first;
      await a.send(
        peer: bobBinding,
        type: MsgType.offer,
        sessionId: session,
        payload: {'sdp': 'v=0'},
      );
      await right.importText(left.pendingExports.single);
      expect((await rejection).reason, 'unknown or changed contact binding');
      expect(deliveries, 0);
      expect(right.pendingExports, isEmpty);
      await sub.cancel();

      final forged = ManualSignaling();
      await forged.start(nodeIdText(alice.nodeId));
      await forged.publish(
        nodeIdText(bob.nodeId),
        Uint8List.fromList(List.filled(200, 1)),
      );
      final tamperFailure = b.failures.first;
      await right.importText(forged.lastExport!);
      expect((await tamperFailure).reason, isNotEmpty);
      expect(right.pendingExports, isEmpty);
      await forged.close();
    },
  );

  test('strict bounded manual decompression and recipient checks', () async {
    final compressed = gzip.encode(Uint8List(64 * 1024));
    final bomb =
        'vault-signal:1:z:${nodeIdText(bob.nodeId)}:'
        '${base64Url.encode(compressed)}';
    await expectLater(right.importText(bomb), throwsFormatException);
    await expectLater(
      right.importText('x' * (40 * 1024 + 1)),
      throwsFormatException,
    );
    await a.send(
      peer: bobBinding,
      type: MsgType.offer,
      sessionId: session,
      payload: {'sdp': 'v=0'},
    );
    await expectLater(left.importText(left.lastExport!), throwsFormatException);
  });

  test('known-contact private presence is bounded and authenticated', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final incoming = b.messages.first;
    final ack = right.exports.first;
    await a.send(
      peer: bobBinding,
      type: MsgType.announce,
      sessionId: session,
      payload: {'presence': true, 'name': 'Alice', 'expires': now + 60},
    );
    await right.importText(left.lastExport!);
    final envelope = await incoming;
    expect(envelope.expiresAt, now + 60);
    expect(envelope.payload['name'], 'Alice');
    await left.importText(await ack);
    await until(() => a.pendingCount == 0);
    await expectLater(
      a.send(
        peer: bobBinding,
        type: MsgType.announce,
        sessionId: session,
        payload: {'presence': true, 'name': 'Alice', 'expires': now + 3600},
      ),
      throwsA(isA<WireReject>()),
    );
  });

  test(
    'stream failures surface and close cancels pending retry publication',
    () async {
      final transport = _TestTransport();
      final client = SignalingClient(
        identity: alice,
        strategy: transport,
        resolveBinding: (_) async => bobBinding,
        retryDelay: const Duration(milliseconds: 10),
      );
      await client.start();
      final failure = client.failures.first;
      transport.input.addError(StateError('unavailable'));
      expect((await failure).reason, 'transport stream failed');
      await client.send(
        peer: bobBinding,
        type: MsgType.offer,
        sessionId: session,
        payload: {'sdp': 'v=0'},
      );
      expect(client.pendingCount, 1);
      await client.close();
      final count = transport.publications;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(transport.publications, count);
      expect(client.pendingCount, 0);
      await expectLater(
        client.send(
          peer: bobBinding,
          type: MsgType.offer,
          sessionId: session,
          payload: {'sdp': 'v=0'},
        ),
        throwsStateError,
      );
    },
  );

  test('asynchronous acknowledgment timeout is observable', () async {
    final transport = _TestTransport();
    final client = SignalingClient(
      identity: alice,
      strategy: transport,
      resolveBinding: (_) async => bobBinding,
      retryDelay: const Duration(milliseconds: 5),
      retryDeadline: const Duration(milliseconds: 40),
    );
    await client.start();
    final failure = client.failures.first;
    await client.send(
      peer: bobBinding,
      type: MsgType.offer,
      sessionId: session,
      payload: {'sdp': 'v=0'},
    );
    final exhausted = await failure;
    expect(exhausted.reason, 'signal acknowledgment deadline exceeded');
    expect(exhausted.terminal, isTrue);
    expect(client.pendingCount, 0);
    await client.close();
  });

  test(
    'MQTT rejects plaintext endpoint and cannot restart after close',
    () async {
      expect(() => MqttEndpoint('host', port: 1883), throwsArgumentError);
      final mqtt = MqttSignaling([MqttEndpoint('broker.emqx.io')]);
      expect(mqtt.publicPresenceEnabled, isFalse);
      await mqtt.setPublicPresenceEnabled(true);
      expect(mqtt.publicPresenceEnabled, isTrue);
      await mqtt.setPublicPresenceEnabled(false);
      expect(mqtt.publicPresenceEnabled, isFalse);
      await mqtt.close();
      await expectLater(mqtt.start(nodeIdText(alice.nodeId)), throwsStateError);
      expect(mqtt.connected, isFalse);
    },
  );
}

class _TestTransport implements SignalingStrategy {
  final input = StreamController<SignalFrame>.broadcast();
  final states = StreamController<bool>.broadcast();
  bool ready = false;
  int publications = 0;
  Uint8List? lastBytes;
  bool rejectNextPublish = false;
  @override
  bool get connected => ready;
  @override
  Stream<SignalFrame> get inbound => input.stream;
  @override
  Stream<bool> get connectionChanges => states.stream;
  @override
  Future<void> start(String nodeId) async {
    ready = true;
  }

  @override
  Future<void> publish(String recipient, Uint8List bytes) async {
    if (!ready) throw StateError('closed');
    if (rejectNextPublish) {
      rejectNextPublish = false;
      throw StateError('Transport subscription transition');
    }
    publications++;
    lastBytes = Uint8List.fromList(bytes);
  }

  @override
  Future<void> close() async {
    ready = false;
    unawaited(input.close());
    unawaited(states.close());
  }
}
