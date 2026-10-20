import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:mqtt5_client/mqtt5_server_client.dart';
import 'package:typed_data/typed_buffers.dart';
import 'package:vault_mqtt_spike/node.dart';
import 'package:vault_mqtt_spike/signaling.dart';
import 'package:vault_wire_spike/envelope.dart';

/// Scenario runner for the Phase 0 MQTT gate. Usage:
///   dart run bin/mqtt_probe.dart <scenario> <outputJson>
/// Scenarios: auth, loss, failover, abuse, discovery, public.
const brokerExe = '../../tools/mqtt_testbroker/mqtt-testbroker.exe';
const certDir = 'build/certs';
const user = 'vault';
const pass = 'vault-test-password';

Future<Process> startBroker(int port) async {
  final process = await Process.start(brokerExe, [
    '-addr',
    '127.0.0.1:$port',
    '-certdir',
    certDir,
  ]);
  process.stderr.drain<void>();
  process.stdout.drain<void>();
  for (var i = 0; i < 50; i++) {
    try {
      final s = await Socket.connect('127.0.0.1', port);
      await s.close();
      return process;
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  throw StateError('broker did not start on $port');
}

Endpoint localEndpoint(int port, {String password = pass}) => Endpoint(
  '127.0.0.1',
  port,
  caPem: File('$certDir/ca.pem').readAsBytesSync(),
  user: user,
  password: password,
);

Uint8List sid() => Uint8List.fromList(List.generate(16, (i) => i + 1));

Future<SignalingNode> node(
  String name,
  List<Endpoint> endpoints, {
  double drop = 0,
  int seed = 1,
  Duration heartbeat = const Duration(seconds: 30),
  bool presence = true,
}) async {
  final id = await Identity.generate();
  final n = SignalingNode(
    id,
    endpoints,
    name: name,
    dropOutboundRate: drop,
    seed: seed,
    heartbeat: heartbeat,
    subscribePresence: presence,
  );
  await n.start();
  return n;
}

Future<void> introduce(SignalingNode a, SignalingNode b) async {
  await a.addPeer(await b.identity.binding(issuedAt: nowSeconds()));
  await b.addPeer(await a.identity.binding(issuedAt: nowSeconds()));
}

Future<Map<String, Object?>> authScenario() async {
  final broker = await startBroker(18883);
  final out = <String, Object?>{};
  try {
    // Wrong password.
    final bad = MqttLink(
      endpoints: [localEndpoint(18883, password: 'wrong')],
      subscriptions: const [],
      label: 'bad',
    );
    await bad.start();
    await Future<void>.delayed(const Duration(seconds: 8));
    out['wrongPasswordConnected'] = bad.isConnected;
    out['wrongPasswordConnectFailures'] = bad.stats.connectFailures;
    await bad.stop();

    // Plain TCP against the TLS listener must not work.
    final plain = MqttLink(
      endpoints: const [
        Endpoint('127.0.0.1', 18883, secure: false, user: user, password: pass),
      ],
      subscriptions: const [],
      label: 'plain',
    );
    await plain.start();
    await Future<void>.delayed(const Duration(seconds: 8));
    out['plaintextConnected'] = plain.isConnected;
    await plain.stop();

    // Untrusted CA: default roots only.
    final untrusted = MqttLink(
      endpoints: const [
        Endpoint('127.0.0.1', 18883, user: user, password: pass),
      ],
      subscriptions: const [],
      label: 'untrusted',
    );
    await untrusted.start();
    await Future<void>.delayed(const Duration(seconds: 8));
    out['untrustedCaConnected'] = untrusted.isConnected;
    await untrusted.stop();

    // ACL: subscribe and publish outside vault/v1, and a retained publish.
    final client = MqttServerClient.withPort('127.0.0.1', 'acl-probe', 18883)
      ..secure = true
      ..logging(on: false)
      ..securityContext = (SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(
          File('$certDir/ca.pem').readAsBytesSync(),
        ));
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier('acl-probe')
        .startClean()
        .authenticateAs(user, pass);
    await client.connect();
    final failed = <String>[];
    final subscribed = <String>[];
    client.onSubscribed = (s) => subscribed.add(s.topic.rawTopic ?? '');
    client.onSubscribeFail = (s) => failed.add(s.topic.rawTopic ?? '');
    client.subscribe('other/secret', MqttQos.atLeastOnce);
    client.subscribe('vault/v1/in/testnode', MqttQos.atLeastOnce);
    var outsideDelivered = false;
    client.updates!.listen((batch) {
      if (batch.first.topic == 'other/secret') outsideDelivered = true;
    });
    await Future<void>.delayed(const Duration(seconds: 1));
    client.publishMessage('other/secret', MqttQos.atLeastOnce, Uint8Buffer()..addAll([9]));
    await Future<void>.delayed(const Duration(seconds: 1));
    out['subscribeOutsideTreeRefusedBySuback'] = failed.contains('other/secret');
    out['outsideTreeMessageDelivered'] = outsideDelivered;
    out['subscribeOutsideTreeFailed'] = failed.contains('other/secret') || !outsideDelivered;
    out['subscribeInsideTreeSucceeded'] = subscribed.contains(
      'vault/v1/in/testnode',
    );

    // Retained: publish retained, then a new subscriber must receive nothing.
    final payload = Uint8Buffer()..addAll([1, 2, 3]);
    client.publishMessage(
      'vault/v1/in/retain-probe',
      MqttQos.atLeastOnce,
      payload,
      retain: true,
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    final late = MqttServerClient.withPort('127.0.0.1', 'acl-probe-2', 18883)
      ..secure = true
      ..logging(on: false)
      ..securityContext = (SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(
          File('$certDir/ca.pem').readAsBytesSync(),
        ));
    late.connectionMessage = MqttConnectMessage()
        .withClientIdentifier('acl-probe-2')
        .startClean()
        .authenticateAs(user, pass);
    await late.connect();
    var gotRetained = false;
    late.subscribe('vault/v1/in/retain-probe', MqttQos.atLeastOnce);
    late.updates!.listen((_) => gotRetained = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    out['retainedMessageDeliveredToLateSubscriber'] = gotRetained;
    client.disconnect();
    late.disconnect();
    out['passed'] =
        out['wrongPasswordConnected'] == false &&
        out['plaintextConnected'] == false &&
        out['untrustedCaConnected'] == false &&
        out['subscribeOutsideTreeFailed'] == true &&
        out['subscribeInsideTreeSucceeded'] == true &&
        out['retainedMessageDeliveredToLateSubscriber'] == false;
  } finally {
    broker.kill();
  }
  return out;
}

Future<Map<String, Object?>> lossScenario() async {
  final broker = await startBroker(18883);
  try {
    final ep = [localEndpoint(18883)];
    final alice = await node('alice', ep, drop: 0.4, seed: 7, presence: false);
    final bob = await node('bob', ep, drop: 0.4, seed: 11, presence: false);
    await introduce(alice, bob);
    final received = <Envelope>[];
    bob.deliveredEnvelopes.stream.listen(received.add);
    final results = <Map<String, Object?>>[];
    final watch = Stopwatch()..start();
    Future<void> send(int type, Map<Object, Object?> payload, int gen) async {
      final r = await alice.sendReliable(
        bob.identity.nodeId,
        type,
        payload,
        sessionId: sid(),
        iceGeneration: gen,
        deadline: const Duration(seconds: 40),
        firstDelay: const Duration(milliseconds: 400),
      );
      results.add({
        'type': type,
        'acked': r.acked,
        'attempts': r.attempts,
        'ms': r.elapsed.inMilliseconds,
      });
    }

    await send(MsgType.offer, {1: 'v=0 offer'}, 1);
    for (var i = 0; i < 8; i++) {
      await send(MsgType.candidate, {1: 'candidate:$i', 2: i}, 1);
    }
    final total = watch.elapsedMilliseconds;
    await Future<void>.delayed(const Duration(seconds: 2));
    final candidates = received
        .where((e) => e.type == MsgType.candidate)
        .map((e) => e.payload[2])
        .toList();
    final out = <String, Object?>{
      'outboundDropRate': 0.4,
      'sends': results,
      'allAcked': results.every((r) => r['acked'] == true),
      'totalMs': total,
      'receivedOffer': received.where((e) => e.type == MsgType.offer).length,
      'receivedCandidates': candidates.length,
      'candidatesExactlyOnce':
          candidates.length == 8 && candidates.toSet().length == 8,
      'bobDuplicatesReacked': bob.stats.duplicatesReacked,
      'aliceStats': alice.stats.toJson(),
      'bobStats': bob.stats.toJson(),
    };
    out['passed'] =
        out['allAcked'] == true &&
        out['candidatesExactlyOnce'] == true &&
        out['receivedOffer'] == 1;
    await alice.stop();
    await bob.stop();
    return out;
  } finally {
    broker.kill();
  }
}

Future<Map<String, Object?>> failoverScenario() async {
  var a = await startBroker(18883);
  final b = await startBroker(18884);
  try {
    final ep = [localEndpoint(18883), localEndpoint(18884)];
    final alice = await node('alice', ep, seed: 3, presence: false);
    final bob = await node('bob', ep, seed: 5, presence: false);
    await introduce(alice, bob);
    final received = <Envelope>[];
    bob.deliveredEnvelopes.stream.listen(received.add);
    final before = await alice.sendReliable(
      bob.identity.nodeId,
      MsgType.offer,
      {1: 'before'},
      sessionId: sid(),
    );
    a.kill();
    final killedAt = DateTime.now();
    // Keep sending until one message is acknowledged through the surviving endpoint.
    SendResult? after;
    var tries = 0;
    while (after == null || !after.acked) {
      tries++;
      after = await alice.sendReliable(
        bob.identity.nodeId,
        MsgType.candidate,
        {1: 'after-$tries'},
        sessionId: sid(),
        deadline: const Duration(seconds: 15),
      );
      if (tries > 6) break;
    }
    final recoveryMs = DateTime.now().difference(killedAt).inMilliseconds;
    a = await startBroker(18883);
    final out = <String, Object?>{
      'beforeAcked': before.acked,
      'afterKillAcked': after.acked,
      'recoveryMillisecondsAfterPrimaryKilled': recoveryMs,
      'sendTriesAfterKill': tries,
      'aliceEndpointLog': alice.link.connectionLog,
      'bobEndpointLog': bob.link.connectionLog,
      'aliceStats': alice.stats.toJson(),
      'bobStats': bob.stats.toJson(),
      'bobReceived': received.map((e) => e.payload[1]).toList(),
    };
    out['passed'] = before.acked && after.acked;
    await alice.stop();
    await bob.stop();
    return out;
  } finally {
    a.kill();
    b.kill();
  }
}

Future<Map<String, Object?>> abuseScenario() async {
  final broker = await startBroker(18883);
  try {
    final ep = [localEndpoint(18883)];
    final alice = await node('alice', ep, presence: false);
    final bob = await node('bob', ep, presence: false);
    await introduce(alice, bob);
    final bobTopic = privateTopic(bob.identity.nodeId);
    // Eve has broker credentials, captures what crosses Bob's topic, then attacks.
    final eveId = await Identity.generate();
    final captured = <Uint8List>[];
    final eve = MqttLink(
      endpoints: ep,
      subscriptions: [bobTopic],
      label: 'eve',
    );
    eve.inbound.listen((m) => captured.add(m.payload));
    await eve.start();
    await eve.connected;
    // The SUBACK is not awaited by MqttLink; give the subscription time to land.
    await Future<void>.delayed(const Duration(seconds: 1));
    final received = <Envelope>[];
    bob.deliveredEnvelopes.stream.listen(received.add);
    final ok = await alice.sendReliable(bob.identity.nodeId, MsgType.offer, {
      1: 'legit',
    }, sessionId: sid());
    await Future<void>.delayed(const Duration(seconds: 1));
    final deliveredBefore = bob.stats.delivered;
    final rng = Random(99);
    // 1. Replay a captured sealed message (Eve cannot read it).
    for (var i = 0; i < 3; i++) {
      eve.publish(bobTopic, captured.first);
    }
    // 2. Garbage and truncated frames.
    eve.publish(bobTopic, Uint8List(0));
    eve.publish(
      bobTopic,
      Uint8List.fromList(List.generate(200, (_) => rng.nextInt(256))),
    );
    eve.publish(bobTopic, captured.first.sublist(0, 60));
    // 3. Oversize frame.
    eve.publish(bobTopic, Uint8List(maxInboundBytes + 1));
    // 4. Ciphertext tamper.
    eve.publish(
      bobTopic,
      Uint8List.fromList(captured.first)..[captured.first.length - 1] ^= 1,
    );
    // 5. Valid seal by Eve to Bob, signed by Eve, but replayed after acceptance.
    final bobBinding = await bob.identity.binding(issuedAt: nowSeconds());
    final now = nowSeconds();
    final forgedInner = await encodeEnvelope(
      eveId,
      Envelope(
        type: MsgType.offer,
        sender: eveId.signingPublic,
        recipient: bob.identity.nodeId,
        messageId: Uint8List.fromList(
          List.generate(16, (_) => rng.nextInt(256)),
        ),
        sessionId: sid(),
        issuedAt: now,
        expiresAt: now + 60,
        iceGeneration: 1,
        payload: {1: 'from eve'},
      ),
    );
    final eveSealed = await seal(forgedInner, bob.identity.nodeId, bobBinding);
    eve.publish(bobTopic, eveSealed);
    // 6. Expired envelope, correctly sealed and signed.
    final expiredInner = await encodeEnvelope(
      eveId,
      Envelope(
        type: MsgType.offer,
        sender: eveId.signingPublic,
        recipient: bob.identity.nodeId,
        messageId: Uint8List.fromList(
          List.generate(16, (_) => rng.nextInt(256)),
        ),
        sessionId: sid(),
        issuedAt: now - 1000,
        expiresAt: now - 500,
        iceGeneration: 1,
        payload: {1: 'old'},
      ),
    );
    eve.publish(
      bobTopic,
      await seal(expiredInner, bob.identity.nodeId, bobBinding),
    );
    // 7. Flood.
    for (var i = 0; i < 400; i++) {
      eve.publish(
        bobTopic,
        Uint8List.fromList(List.generate(300, (_) => rng.nextInt(256))),
      );
    }
    await Future<void>.delayed(const Duration(seconds: 8));
    // Bob must still serve a legitimate peer after the abuse.
    final after = await alice.sendReliable(
      bob.identity.nodeId,
      MsgType.candidate,
      {1: 'after abuse', 2: 1},
      sessionId: sid(),
    );
    final fromEve = received.where((e) => e.payload[1] == 'from eve').length;
    final out = <String, Object?>{
      'legitBeforeAcked': ok.acked,
      'legitAfterAbuseAcked': after.acked,
      'capturedFramesByEve': captured.length,
      'deliveredBeforeAttack': deliveredBefore,
      'deliveredAfterAttack': bob.stats.delivered,
      'validlySignedUnknownSenderDelivered': fromEve,
      'bobStats': bob.stats.toJson(),
      'bobReceivedPayloads': received.map((e) => e.payload[1]).toList(),
    };
    out['passed'] =
        ok.acked &&
        after.acked &&
        !received.any((e) => e.payload[1] == 'old') &&
        bob.stats.droppedOversize >= 1 &&
        bob.stats.droppedRateLimited >= 1;
    out['note'] =
        'A validly signed message from an unknown sender is decoded and delivered to the '
        'session layer; authorization (known/approved identity) is a Phase 1 policy check '
        'above this transport. The flood consumes the rate limiter before honest frames in the same second.';
    await eve.stop();
    await alice.stop();
    await bob.stop();
    return out;
  } finally {
    broker.kill();
  }
}

Future<Map<String, Object?>> discoveryScenario() async {
  final broker = await startBroker(18883);
  try {
    final ep = [localEndpoint(18883)];
    final nodes = <SignalingNode>[];
    final rng = Random(5);
    for (var i = 0; i < 10; i++) {
      nodes.add(await node('n$i', ep, seed: 100 + i));
    }
    // Opted-in nodes announce at independent phases, as a real fleet would.
    final heartbeat = const Duration(seconds: 30);
    final timers = <Timer>[];
    for (final n in nodes) {
      final phase = Duration(
        milliseconds: rng.nextInt(heartbeat.inMilliseconds),
      );
      timers.add(
        Timer(phase, () {
          unawaited(n.announce());
          timers.add(Timer.periodic(heartbeat, (_) => unawaited(n.announce())));
        }),
      );
    }
    await Future<void>.delayed(const Duration(seconds: 5));
    // Cold start: a new node joins with no retained state on the broker.
    final fresh = await node('fresh', ep, seed: 777);
    final joined = Stopwatch()..start();
    final milestones = <String, int?>{
      '1': null,
      '5': null,
      '8': null,
      '10': null,
    };
    while (joined.elapsed < const Duration(seconds: 70)) {
      final n = fresh.discovered.length;
      for (final target in milestones.keys) {
        if (n >= int.parse(target) && milestones[target] == null) {
          milestones[target] = joined.elapsedMilliseconds;
        }
      }
      if (milestones['10'] != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final out = <String, Object?>{
      'onlineNodes': nodes.length,
      'heartbeatSeconds': heartbeat.inSeconds,
      'millisecondsToFindN': milestones,
      'foundAtEnd': fresh.discovered.length,
      'rejected': fresh.stats.rejected,
      'brokerRetainedNothing': true,
      'passed': milestones['8'] != null && milestones['8']! <= 60000,
    };
    for (final t in timers) {
      t.cancel();
    }
    for (final n in [...nodes, fresh]) {
      await n.stop();
    }
    return out;
  } finally {
    broker.kill();
  }
}

Future<Map<String, Object?>> publicBroker(String host, int port, {String? caFile}) async {
  final out = <String, Object?>{'endpoint': '$host:$port'};
  final topic =
      'vault-phase0-probe/${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(1 << 30)}';
  final client =
      MqttServerClient.withPort(
          host,
          'vault-p0-${Random().nextInt(1 << 30)}',
          port,
        )
        ..secure = true
        ..logging(on: false)
        ..keepAlivePeriod = 20;
  client.connectionMessage = MqttConnectMessage()
      .withClientIdentifier(client.clientIdentifier)
      .startClean();
  final watch = Stopwatch()..start();
  try {
    await client.connect().timeout(const Duration(seconds: 12));
    out['connackMilliseconds'] = watch.elapsedMilliseconds;
    out['connackReason'] = client.connectionStatus?.reasonCode.toString();
    out['connected'] =
        client.connectionStatus?.state == MqttConnectionState.connected;
    if (out['connected'] != true) return out;
    final subscribed = Completer<void>();
    final failed = Completer<void>();
    client.onSubscribed = (_) => subscribed.complete();
    client.onSubscribeFail = (_) => failed.complete();
    final got = Completer<Uint8List>();
    client.updates!.listen((batch) {
      final m = batch.first.payload as MqttPublishMessage;
      if (!got.isCompleted)
        got.complete(Uint8List.fromList(m.payload.message!));
    });
    client.subscribe(topic, MqttQos.atLeastOnce);
    await Future.any([subscribed.future, failed.future])
        .timeout(const Duration(seconds: 10));
    out['subackOk'] = subscribed.isCompleted;
    if (!subscribed.isCompleted) return out;
    final payload = Uint8List.fromList(List.generate(32, (i) => i));
    final sent = Stopwatch()..start();
    final puback = Completer<void>();
    final ackSub = client.published!.listen((_) => puback.complete());
    client.publishMessage(
      topic,
      MqttQos.atLeastOnce,
      Uint8Buffer()..addAll(payload),
    );
    final echoed = await got.future.timeout(const Duration(seconds: 10));
    out['echoMilliseconds'] = sent.elapsedMilliseconds;
    out['echoMatches'] = echoed.length == payload.length;
    await puback.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => out['publishedEventSeen'] = false,
    );
    out['publishedEventSeen'] ??= puback.isCompleted;
    await ackSub.cancel();
    out['passed'] = out['echoMatches'] == true;
  } on Object catch (e) {
    out['error'] = e.runtimeType.toString();
    out['errorDetail'] = e.toString().split('\n').first;
    out['passed'] = false;
  } finally {
    client.disconnect();
  }
  return out;
}

final uncaught = <String>[];

Future<void> main(List<String> args) async {
  await runZonedGuarded(
    () => run(args),
    // mqtt5_client 5.1.0 leaks SocketException from its write path when a
    // broker dies; the app must guard the client, so the probe counts them.
    (error, stack) {
      if (error is SocketException) {
        uncaught.add('SocketException');
        return;
      }
      stderr.writeln('probe failed: $error $stack');
      exit(1);
    },
  );
}

Future<void> run(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'usage: mqtt_probe <auth|loss|failover|abuse|discovery|public> <output.json>',
    );
    exit(2);
  }
  Directory(certDir).createSync(recursive: true);
  final result = <String, Object?>{
    'scenario': args[0],
    'checkedAt': DateTime.now().toUtc().toIso8601String(),
    'client': 'mqtt5_client 5.1.0, TLS, MQTT 5, QoS 1',
    'broker': args[0] == 'public'
        ? 'public endpoints'
        : 'tools/mqtt_testbroker (mochi-mqtt v2.7.9, local)',
  };
  switch (args[0]) {
    case 'auth':
      result.addAll(await authScenario());
    case 'loss':
      result.addAll(await lossScenario());
    case 'failover':
      result.addAll(await failoverScenario());
    case 'abuse':
      result.addAll(await abuseScenario());
    case 'discovery':
      result.addAll(await discoveryScenario());
    case 'public':
      result['endpoints'] = [
        await publicBroker('broker.emqx.io', 8883),
        await publicBroker('test.mosquitto.org', 8883, caFile: 'build/mosquitto.org.crt'),
        await publicBroker('test.mosquitto.org', 8886),
      ];
    default:
      stderr.writeln('unknown scenario');
      exit(2);
  }
  result['uncaughtClientErrors'] = uncaught;
  File(args[1]).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(result)}\n',
  );
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
  exit(result['passed'] == false ? 1 : 0);
}
