import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_protocol/vault_protocol.dart'
    show Envelope, MsgType, WireReject, encodeEnvelope, seal;
import 'package:vault_signaling/vault_signaling.dart';

Future<Identity> _identity(int seed) => Identity.fromSeeds(
  Uint8List.fromList(List.filled(32, seed)),
  Uint8List.fromList(List.filled(32, seed + 30)),
);

void main() {
  test(
    'unknown public signer discovered, but never trusted for private signaling',
    () async {
      final alice = await _identity(1);
      final bob = await _identity(2);
      final left = _PublicTransport();
      final right = _PublicTransport();
      left.peer = right;
      right.peer = left;
      var resolutions = 0;
      final a = SignalingClient(
        identity: alice,
        strategy: left,
        resolveBinding: (_) async {
          resolutions++;
          return null;
        },
      );
      final b = SignalingClient(
        identity: bob,
        strategy: right,
        resolveBinding: (_) async {
          resolutions++;
          return null;
        },
      );
      addTearDown(a.close);
      addTearDown(b.close);
      await a.start();
      await b.start();
      expect(b.publicDiscoveryEnabled, isFalse);
      await a.setPublicDiscoveryEnabled(true);
      await b.setPublicDiscoveryEnabled(true);
      final received = b.publicPresence.first;
      await a.announcePublicPresence(
        name: 'Alice',
        tags: ['films'],
        sharedCount: 4,
      );
      final record = await received;
      expect(record.nodeId, nodeIdText(alice.nodeId));
      expect(record.tags, ['films']);
      expect(record.sharedCount, 4);
      expect(await record.binding.verify(), isTrue);
      expect(resolutions, 0);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final cached = await verifyPublicPresenceRecord(
        record.signedEnvelope,
        now: now,
        expectedNodeId: record.nodeId,
      );
      expect(cached.nodeId, record.nodeId);
      expect(cached.sequence, record.sequence);
      expect(b.publicPresenceRecords, hasLength(1));

      final rejectedReplay = b.failures.first;
      right.publicInput.add(SignalFrame(record.nodeId, record.signedEnvelope));
      expect((await rejectedReplay).reason, 'public presence replay');
      expect(b.publicPresenceRecords, hasLength(1));

      final bobBinding = await bob.binding(issuedAt: now);
      await expectLater(
        a.send(
          peer: bobBinding,
          type: MsgType.offer,
          sessionId: Uint8List(16),
          payload: {'sdp': 'v=0'},
        ),
        throwsA(isA<WireReject>()),
      );
      // A direct unknown sender attempting a valid encrypted private signal is
      // still rejected after public discovery of the same signing identity.
      final inner = await encodeEnvelope(
        alice,
        Envelope(
          type: MsgType.offer,
          sender: alice.signingPublic,
          recipient: bob.nodeId,
          messageId: Uint8List(16),
          sessionId: Uint8List(16),
          issuedAt: now,
          expiresAt: now + 60,
          iceGeneration: 0,
          payload: {'sdp': 'v=0'},
        ),
      );
      final privateFailure = b.failures.first;
      right.privateInput.add(
        SignalFrame(
          nodeIdText(bob.nodeId),
          await seal(inner, bob.nodeId, bobBinding),
        ),
      );
      expect(
        (await privateFailure).reason,
        'unknown or changed contact binding',
      );

      await b.setPublicDiscoveryEnabled(false);
      expect(b.publicPresenceRecords, isEmpty);
      expect(right.publicPresenceEnabled, isFalse);
      right.publicInput.add(SignalFrame(record.nodeId, record.signedEnvelope));
      await Future<void>.delayed(Duration.zero);
      expect(b.publicPresenceRecords, isEmpty);
    },
  );

  test(
    'origin signature, topic binding, expiry and metadata allowlist enforced',
    () async {
      final alice = await _identity(3);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final binding = await alice.binding(issuedAt: now);
      final body = <Object, Object?>{
        'presence': true,
        'name': 'Alice',
        'tags': <String>['music'],
        'sharedCount': 0,
        'epoch': now * 1000000,
        'sequence': 1,
        'expires': now + 60,
        'encryptionKey': binding.encryptionKey,
        'bindingIssuedAt': binding.issuedAt,
        'bindingSignature': binding.signature,
      };
      Future<Uint8List> encode(
        Map<Object, Object?> payload, {
        int type = MsgType.announce,
        int? expires,
      }) => encodeEnvelope(
        alice,
        Envelope(
          type: type,
          sender: alice.signingPublic,
          recipient: null,
          messageId: Uint8List(16),
          sessionId: Uint8List(16),
          issuedAt: now,
          expiresAt: expires ?? now + 60,
          iceGeneration: 0,
          payload: payload,
        ),
      );
      final bytes = await encode(body);
      final record = await verifyPublicPresenceRecord(bytes, now: now);
      expect(record.name, 'Alice');
      final tampered = Uint8List.fromList(bytes);
      tampered[40] ^= 1;
      await expectLater(
        verifyPublicPresenceRecord(tampered, now: now),
        throwsA(isA<WireReject>()),
      );
      await expectLater(
        verifyPublicPresenceRecord(
          bytes,
          now: now,
          expectedNodeId: nodeIdText((await _identity(4)).nodeId),
        ),
        throwsA(isA<WireReject>()),
      );
      await expectLater(
        verifyPublicPresenceRecord(bytes, now: now + 61),
        throwsA(isA<WireReject>()),
      );
      for (final extra in ['filename', 'grant', 'acl', 'ip', 'index']) {
        await expectLater(
          verifyPublicPresenceRecord(
            await encode({...body, extra: 'private'}),
            now: now,
          ),
          throwsA(isA<WireReject>()),
        );
      }
      await expectLater(
        verifyPublicPresenceRecord(
          await encode(body, type: MsgType.offer),
          now: now,
        ),
        throwsA(isA<WireReject>()),
      );
      await expectLater(
        verifyPublicPresenceRecord(
          await encode({...body, 'expires': now + 300}, expires: now + 300),
          now: now,
        ),
        throwsA(isA<WireReject>()),
      );
      await expectLater(
        verifyPublicPresenceRecord(
          Uint8List(maxPublicPresenceBytes + 1),
          now: now,
        ),
        throwsA(isA<WireReject>()),
      );
      await expectLater(
        verifyPublicPresenceRecord(
          await encode({
            ...body,
            'tags': List<String>.generate(9, (i) => 'tag$i'),
          }),
          now: now,
        ),
        throwsA(isA<WireReject>()),
      );
    },
  );

  test('manual public discovery is explicitly unsupported', () async {
    final client = SignalingClient(
      identity: await _identity(5),
      strategy: ManualSignaling(),
      resolveBinding: (_) async => null,
    );
    addTearDown(client.close);
    expect(client.supportsPublicDiscovery, isFalse);
    await expectLater(
      client.setPublicDiscoveryEnabled(true),
      throwsA(isA<UnsupportedError>()),
    );
    await expectLater(
      client.announcePublicPresence(name: 'Nobody'),
      throwsA(isA<UnsupportedError>()),
    );
    expect(client.publicPresenceRecords, isEmpty);
  });
}

class _PublicTransport implements SignalingStrategy, PublicPresenceTransport {
  final privateInput = StreamController<SignalFrame>.broadcast();
  final publicInput = StreamController<SignalFrame>.broadcast();
  final states = StreamController<bool>.broadcast();
  _PublicTransport? peer;
  bool _connected = false;
  bool _enabled = false;
  @override
  bool get connected => _connected;
  @override
  bool get publicPresenceEnabled => _enabled;
  @override
  Stream<SignalFrame> get inbound => privateInput.stream;
  @override
  Stream<SignalFrame> get publicFrames => publicInput.stream;
  @override
  Stream<bool> get connectionChanges => states.stream;
  @override
  Future<void> start(String nodeId) async {
    _connected = true;
  }

  @override
  Future<void> publish(String recipient, Uint8List bytes) async {
    if (!_connected) throw StateError('Closed');
    peer?.privateInput.add(SignalFrame(recipient, bytes));
  }

  @override
  Future<void> setPublicPresenceEnabled(bool enabled) async {
    _enabled = enabled;
  }

  @override
  Future<void> publishPublicPresence(
    String signerNodeId,
    Uint8List bytes,
  ) async {
    if (!_connected || !_enabled) throw StateError('Not enabled');
    peer?.publicInput.add(SignalFrame(signerNodeId, bytes));
  }

  @override
  Future<void> close() async {
    _connected = false;
    _enabled = false;
    unawaited(privateInput.close());
    unawaited(publicInput.close());
    unawaited(states.close());
  }
}
