import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_net/vault_net.dart';
import 'package:vault_protocol/vault_protocol.dart' show MsgType;
import 'package:vault_signaling/vault_signaling.dart';

Future<Identity> _identity(int seed) => Identity.fromSeeds(
  Uint8List.fromList(List.filled(32, seed)),
  Uint8List.fromList(List.filled(32, seed + 40)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Identity alice;
  late KeyBinding aliceBinding;
  late ManualSignaling aliceTransport;
  late PeerMesh mesh;
  late int nativeCalls;
  const channel = MethodChannel('FlutterWebRTC.Method');

  Future<SignalingClient> remote(Identity identity) async {
    final client = SignalingClient(
      identity: identity,
      strategy: ManualSignaling(),
      resolveBinding: (id) async =>
          id == nodeIdText(alice.nodeId) ? aliceBinding : null,
      retryDelay: const Duration(hours: 1),
    );
    await client.start();
    return client;
  }

  Future<void> deliverOffer(SignalingClient from) async {
    await from.send(
      peer: aliceBinding,
      type: MsgType.offer,
      sessionId: Uint8List.fromList(List.generate(16, (i) => i + 1)),
      payload: {'sdp': 'v=0\r\n'},
    );
    final manual = from.strategy as ManualSignaling;
    await aliceTransport.importText(manual.pendingExports.single);
  }

  Future<void> setUpMesh(
    Identity contact, {
    Iterable<String> disconnected = const [],
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final contactBinding = await contact.binding(issuedAt: now);
    Future<KeyBinding?> resolve(String id) async =>
        id == nodeIdText(contact.nodeId) ? contactBinding : null;
    aliceTransport = ManualSignaling();
    mesh = PeerMesh(
      identity: alice,
      signaling: SignalingClient(
        identity: alice,
        strategy: aliceTransport,
        resolveBinding: resolve,
        retryDelay: const Duration(hours: 1),
      ),
      resolveBinding: resolve,
      stunUrls: [],
      initiallyDisconnectedPeerIds: disconnected,
    );
    await mesh.start();
  }

  setUp(() async {
    alice = await _identity(1);
    aliceBinding = await alice.binding(
      issuedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    nativeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          nativeCalls++;
          throw StateError('Native peer must not be created');
        });
  });

  tearDown(() async {
    await mesh.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'an offer from a disconnected contact reports youDisconnected',
    () async {
      final bob = await _identity(2);
      final bobId = nodeIdText(bob.nodeId);
      await setUpMesh(bob, disconnected: [bobId]);
      final sessions = <PeerSession>[];
      final created = mesh.sessions.listen(sessions.add);
      final problem = mesh.problems.first.timeout(const Duration(seconds: 5));
      final client = await remote(bob);
      try {
        await deliverOffer(client);
        final reported = await problem;
        expect(reported.peerId, bobId);
        expect(reported.problem, ConnectionProblem.youDisconnected);
        expect(sessions, isEmpty);
        expect(nativeCalls, 0);
        expect(mesh.disconnectedPeerIds, {bobId});
      } finally {
        await created.cancel();
        await client.close();
      }
    },
  );

  test('allowing a disconnected contact accepts its next offer', () async {
    final bob = await _identity(2);
    final bobId = nodeIdText(bob.nodeId);
    await setUpMesh(bob, disconnected: [bobId]);
    final problems = <PeerProblem>[];
    final reported = mesh.problems.listen(problems.add);
    final session = mesh.sessions.first.timeout(const Duration(seconds: 5));
    mesh.allow(bobId);
    final client = await remote(bob);
    try {
      await deliverOffer(client);
      expect((await session).peerId, bobId);
      expect(problems, isEmpty);
      expect(mesh.disconnectedPeerIds, isEmpty);
    } finally {
      await reported.cancel();
      await client.close();
    }
  });

  test('a signed offer from a noncontact reports notAContact', () async {
    final bob = await _identity(2);
    final carol = await _identity(3);
    await setUpMesh(bob);
    final problem = mesh.problems.first.timeout(const Duration(seconds: 5));
    final client = await remote(carol);
    try {
      await deliverOffer(client);
      final reported = await problem;
      expect(reported.peerId, nodeIdText(carol.nodeId));
      expect(reported.problem, ConnectionProblem.notAContact);
      expect(nativeCalls, 0);
    } finally {
      await client.close();
    }
  });
}
