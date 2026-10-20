import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_net/vault_net.dart';
import 'package:vault_signaling/vault_signaling.dart';

import 'policy_test.dart' show reports, sdp;

Future<T> _complete<T>(Future<T> operation, String step) => operation.timeout(
  const Duration(seconds: 5),
  onTimeout: () => throw StateError('Fixture step timed out: $step'),
);

Future<void> _until(bool Function() ready, String step) async {
  final watch = Stopwatch()..start();
  while (!ready()) {
    if (watch.elapsed > const Duration(seconds: 5)) {
      fail('Fixture state timed out: $step');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Only the native RTC boundary is simulated. Both endpoints run PeerSession,
/// real signatures and encrypted, signed ManualSignaling exports/imports.
/// Explicit native events hold Alice's local challenge behind Bob's challenge.
class _NativeLink {
  static const method = MethodChannel('FlutterWebRTC.Method');
  static const codec = StandardMethodCodec();
  static const labels = ['critical', 'bulk', 'ephemeral'];
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final eventChannels = <String>[];
  final listening = <String>{};
  final descriptions = <String, Object?>{};
  final sent = <String, List<Uint8List>>{'alice': [], 'bob': []};
  final bobChallengeDelivered = Completer<void>();
  int peers = 0;
  int restarts = 0;
  String remoteCandidateType = 'srflx';

  String peerEvents(String peer) => 'FlutterWebRTC/peerConnectionEvent$peer';
  String channelEvents(String peer, String label) =>
      'FlutterWebRTC/dataChannelEvent$peer$label';

  void install() {
    _registerEvents('FlutterWebRTC.Event');
    messenger.setMockMethodCallHandler(method, _handle);
  }

  void _registerEvents(String name) {
    eventChannels.add(name);
    messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
      switch (call.method) {
        case 'listen':
          listening.add(name);
        case 'cancel':
          listening.remove(name);
        default:
          throw StateError('Unexpected event subscription: ${call.method}');
      }
      return null;
    });
  }

  Future<void> _emit(String name, Map<String, Object?> event) async {
    if (!listening.contains(name)) {
      throw StateError('Native event has no subscriber: $name');
    }
    final delivered = Completer<void>();
    await messenger.handlePlatformMessage(
      name,
      codec.encodeSuccessEnvelope(event),
      (_) => delivered.complete(),
    );
    await delivered.future;
  }

  Future<void> openAlice(String label) => _emit(channelEvents('alice', label), {
    'event': 'dataChannelStateChanged',
    'id': labels.indexOf(label),
    'state': 'open',
  });

  Future<void> iceState(String peer, String state) =>
      _emit(peerEvents(peer), {'event': 'iceConnectionState', 'state': state});
  Future<void> connectionState(String peer, String state) =>
      _emit(peerEvents(peer), {'event': 'peerConnectionState', 'state': state});
  Future<void> attachBob() async {
    for (final label in labels) {
      _registerEvents(channelEvents('bob', label));
      await _emit(peerEvents('bob'), {
        'event': 'didOpenDataChannel',
        'id': labels.indexOf(label),
        'flutterId': label,
        'label': label,
      });
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = call.arguments as Map<dynamic, dynamic>?;
    final peer = args?['peerConnectionId'] as String?;
    switch (call.method) {
      case 'initialize':
        return null;
      case 'createPeerConnection':
        if (peers >= 2) throw StateError('Unexpected extra native peer');
        final id = peers++ == 0 ? 'alice' : 'bob';
        _registerEvents(peerEvents(id));
        return {'peerConnectionId': id};
      case 'createDataChannel':
        final label = args!['label'] as String;
        _registerEvents(channelEvents(peer!, label));
        return {'id': labels.indexOf(label), 'flutterId': label};
      case 'createOffer':
        return {'sdp': sdp(), 'type': 'offer'};
      case 'restartIce':
        restarts++;
        return null;
      case 'createAnswer':
        return {'sdp': sdp(fingerprint: 'CD'), 'type': 'answer'};
      case 'setLocalDescription':
        descriptions[peer!] = args!['description'];
        return null;
      case 'getLocalDescription':
        return descriptions[peer];
      case 'setRemoteDescription':
        if (restarts > 0 && peer == 'alice') {
          await iceState('alice', 'connected');
          await iceState('bob', 'connected');
        }
        return null;
      case 'getIceGatheringState':
        return {'state': 'complete'};
      case 'getStats':
        return {
          'stats': [
            for (final report in reports(remote: remoteCandidateType))
              {
                'id': report.id,
                'type': report.type,
                'timestamp': 0.0,
                'values': report.values,
              },
          ],
        };
      case 'dataChannelGetBufferedAmount':
        return {'bufferedAmount': 0};
      case 'dataChannelSend':
        final label = args!['dataChannelId'] as String;
        final bytes = Uint8List.fromList(args['data'] as Uint8List);
        sent[peer]!.add(bytes);
        final remote = peer == 'alice' ? 'bob' : 'alice';
        await _emit(channelEvents(remote, label), {
          'event': 'dataChannelReceiveMessage',
          'id': labels.indexOf(label),
          'type': 'binary',
          'data': bytes,
        });
        if (peer == 'bob' &&
            bytes[0] == 1 &&
            !bobChallengeDelivered.isCompleted) {
          bobChallengeDelivered.complete();
        }
        return null;
      case 'dataChannelClose':
      case 'peerConnectionClose':
      case 'peerConnectionDispose':
        return null;
      default:
        throw StateError('Unexpected native method: ${call.method}');
    }
  }

  void uninstall() {
    messenger.setMockMethodCallHandler(method, null);
    for (final name in eventChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  }
}

class _SessionPair {
  new({
    required Identity alice,
    required Identity bob,
    required this.aliceCard,
    required this.bobCard,
    required this.holdTrust,
  }) {
    aliceMesh = PeerMesh(
      identity: alice,
      signaling: SignalingClient(
        identity: alice,
        strategy: aliceManual,
        resolveBinding: (_) async => bobCard.binding,
      ),
      resolveBinding: (_) async {
        if (holdTrust &&
            aliceSession?.state == PeerSessionState.authenticating &&
            !trustEntered.isCompleted) {
          trustEntered.complete();
          await trustRelease.future;
        }
        return bobCard.binding;
      },
      stunUrls: [],
    );
    bobMesh = PeerMesh(
      identity: bob,
      signaling: SignalingClient(
        identity: bob,
        strategy: bobManual,
        resolveBinding: (_) async => aliceCard.binding,
      ),
      resolveBinding: (_) async => aliceCard.binding,
      stunUrls: [],
    );
  }

  final ContactCard aliceCard;
  final ContactCard bobCard;
  final bool holdTrust;
  final native = _NativeLink();
  final aliceManual = ManualSignaling();
  final bobManual = ManualSignaling();
  final trustEntered = Completer<void>();
  final trustRelease = Completer<void>();
  final subscriptions = <StreamSubscription<dynamic>>[];
  late final PeerMesh aliceMesh;
  late final PeerMesh bobMesh;
  PeerSession? aliceSession;
  PeerSession? bobSession;

  Future<void> start() async {
    native.install();
    subscriptions.addAll([
      aliceManual.exports.listen((text) {
        unawaited(bobManual.importText(text));
      }),
      bobManual.exports.listen((text) {
        unawaited(aliceManual.importText(text));
      }),
      bobMesh.sessions.listen((session) => bobSession = session),
    ]);
    await bobMesh.start();
    aliceSession = await aliceMesh.connect(bobCard);
  }

  Future<void> arrangeEarlyChallenge() async {
    await _until(
      () =>
          aliceSession?.state == PeerSessionState.authenticating &&
          bobSession?.state == PeerSessionState.authenticating,
      'both authentication contexts',
    );
    await _complete(native.openAlice('critical'), 'open critical');
    if (holdTrust) {
      await _complete(native.openAlice('bulk'), 'open bulk');
      await _complete(native.openAlice('ephemeral'), 'open ephemeral');
      await _complete(trustEntered.future, 'local trust lookup entered');
    }
    await _complete(native.attachBob(), 'attach remote channels');
    await _complete(native.bobChallengeDelivered.future, 'remote challenge');
    // Let the inbound callback run while the explicit local readiness gate
    // stays closed. Successful assertions below also check final wire order.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(native.sent['bob']!.map((frame) => frame[0]), [1]);
    expect(
      native.sent['alice'],
      isEmpty,
      reason: 'A received challenge must not bypass local challenge readiness',
    );
    expect(aliceSession!.state, PeerSessionState.authenticating);
    expect(bobSession!.state, PeerSessionState.authenticating);
  }

  Future<void> release() async {
    if (holdTrust) {
      trustRelease.complete();
    } else {
      await _complete(native.openAlice('bulk'), 'release bulk');
      await _complete(native.openAlice('ephemeral'), 'release ephemeral');
    }
    await _until(
      () =>
          aliceSession?.state == PeerSessionState.connected &&
          bobSession?.state == PeerSessionState.connected,
      'both authenticated peers',
    );
  }

  Future<void> close() async {
    if (!trustRelease.isCompleted) trustRelease.complete();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    try {
      await aliceMesh.close();
      await bobMesh.close();
    } finally {
      native.uninstall();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Identity alice;
  late Identity bob;
  late ContactCard aliceCard;
  late ContactCard bobCard;
  setUpAll(() async {
    alice = await Identity.fromSeeds(
      Uint8List.fromList(List.filled(32, 1)),
      Uint8List.fromList(List.filled(32, 2)),
    );
    bob = await Identity.fromSeeds(
      Uint8List.fromList(List.filled(32, 3)),
      Uint8List.fromList(List.filled(32, 4)),
    );
    aliceCard = await ContactCard.create(alice, name: 'Alice');
    bobCard = await ContactCard.create(bob, name: 'Bob');
  });

  test(
    'a responder whose offerer fails reports the failure and its cause',
    () async {
      final pair = _SessionPair(
        alice: alice,
        bob: bob,
        aliceCard: aliceCard,
        bobCard: bobCard,
        holdTrust: false,
      );
      try {
        await pair.start();
        await _until(
          () => pair.bobSession?.state == PeerSessionState.authenticating,
          'responder answered',
        );
        await pair.native.connectionState('alice', 'failed');
        await _until(
          () => pair.aliceSession!.state == PeerSessionState.failed,
          'offerer failed',
        );
        expect(pair.aliceSession!.problem, ConnectionProblem.noDirectRoute);
        await _until(
          () => pair.bobSession!.state != PeerSessionState.authenticating,
          'responder ended',
        );
        expect(pair.bobSession!.state, PeerSessionState.failed);
        expect(pair.bobSession!.problem, ConnectionProblem.noDirectRoute);
        expect(pair.bobSession!.failureReason, isNotNull);
      } finally {
        await pair.close();
      }
    },
  );

  test(
    'brief ICE loss pauses traffic and recovers without signaling',
    () async {
      final pair = _SessionPair(
        alice: alice,
        bob: bob,
        aliceCard: aliceCard,
        bobCard: bobCard,
        holdTrust: false,
      );
      try {
        await pair.start();
        await pair.arrangeEarlyChallenge();
        await pair.release();
        await pair.native.iceState('alice', 'connected');
        await pair.native.iceState('bob', 'connected');
        final originalSession = pair.aliceSession!.sessionId;
        final received = <PeerPacket>[];
        pair.subscriptions.add(pair.bobSession!.packets.listen(received.add));
        for (var interruption = 0; interruption < 4; interruption++) {
          await pair.native.iceState('alice', 'disconnected');
          await _until(
            () => pair.aliceSession!.state != PeerSessionState.connected,
            'traffic paused',
          );
          final sentBefore = pair.native.sent['alice']!.length;
          await expectLater(
            pair.aliceSession!.sendControl({'must': 'not-send'}),
            throwsA(isA<PeerFailure>()),
          );
          expect(pair.native.sent['alice']!.length, sentBefore);
          await pair.native.iceState('alice', 'connected');
          await _until(
            () => pair.aliceSession!.state == PeerSessionState.connected,
            'original route restored',
          );
          await pair.aliceSession!.sendControl({'interruption': interruption});
          await _until(
            () => received.length == interruption + 1,
            'protected payload after route restoration',
          );
          expect(received.last.control, {'interruption': interruption});
          expect(pair.aliceSession!.sessionId, originalSession);
          expect(pair.aliceSession!.failureReason, isNull);
        }
        expect(pair.native.peers, 2);
        expect(pair.native.restarts, 0);
      } finally {
        await pair.close();
      }
    },
  );

  test(
    'sustained ICE loss restarts and reauthenticates the same session',
    () async {
      final pair = _SessionPair(
        alice: alice,
        bob: bob,
        aliceCard: aliceCard,
        bobCard: bobCard,
        holdTrust: false,
      );
      try {
        await pair.start();
        await pair.arrangeEarlyChallenge();
        await pair.release();
        await pair.native.iceState('alice', 'connected');
        await pair.native.iceState('bob', 'connected');
        final originalSession = pair.aliceSession!.sessionId;
        await pair.native.iceState('alice', 'disconnected');
        await Future<void>.delayed(const Duration(milliseconds: 10100));
        await _until(
          () =>
              pair.aliceSession!.state == PeerSessionState.connected &&
              pair.bobSession!.state == PeerSessionState.connected,
          'fresh mutual authentication',
        );
        expect(pair.native.restarts, 1);
        expect(pair.aliceSession!.sessionId, originalSession);
        final received = pair.bobSession!.packets.first;
        await pair.aliceSession!.sendControl({'after': 'ice-restart'});
        expect((await received).control, {'after': 'ice-restart'});
        expect(
          pair.native.sent['alice']!
              .where((frame) => frame[0] == 1)
              .map((frame) => ByteData.sublistView(frame).getUint32(1)),
          [0, 1],
        );
      } finally {
        await pair.close();
      }
    },
  );

  test('explicit disconnect during route recovery cannot reconnect', () async {
    final pair = _SessionPair(
      alice: alice,
      bob: bob,
      aliceCard: aliceCard,
      bobCard: bobCard,
      holdTrust: false,
    );
    try {
      await pair.start();
      await pair.arrangeEarlyChallenge();
      await pair.release();
      await pair.native.iceState('alice', 'connected');
      await pair.native.iceState('alice', 'disconnected');
      await pair.aliceSession!.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(pair.aliceSession!.state, PeerSessionState.closed);
      expect(pair.aliceMesh.disconnectedPeerIds, contains(bobCard.nodeId));
      expect(pair.native.restarts, 0);
      await expectLater(
        pair.aliceSession!.sendControl({'must': 'stay-closed'}),
        throwsA(isA<PeerFailure>()),
      );
    } finally {
      await pair.close();
    }
  });

  test('restored ICE cannot authorize a relayed route', () async {
    final pair = _SessionPair(
      alice: alice,
      bob: bob,
      aliceCard: aliceCard,
      bobCard: bobCard,
      holdTrust: false,
    );
    try {
      await pair.start();
      await pair.arrangeEarlyChallenge();
      await pair.release();
      await pair.native.iceState('alice', 'connected');
      await pair.native.iceState('alice', 'disconnected');
      pair.native.remoteCandidateType = 'relay';
      await pair.native.iceState('alice', 'connected');
      await _until(
        () => pair.aliceSession!.state == PeerSessionState.failed,
        'relay rejection after interruption',
      );
      expect(pair.aliceSession!.selectedCandidateTypes, isEmpty);
      await expectLater(
        pair.aliceSession!.sendControl({'must': 'not-relay'}),
        throwsA(isA<PeerFailure>()),
      );
      expect(pair.native.restarts, 0);
    } finally {
      await pair.close();
    }
  });

  for (final holdTrust in [false, true]) {
    final wait = holdTrust
        ? 'asynchronous trust lookup'
        : 'other channel opens';
    test('peer challenge waits for $wait before proof', () async {
      final pair = _SessionPair(
        alice: alice,
        bob: bob,
        aliceCard: aliceCard,
        bobCard: bobCard,
        holdTrust: holdTrust,
      );
      try {
        await _complete(pair.start(), 'start both meshes');
        await pair.arrangeEarlyChallenge();
        await pair.release();
        expect(pair.native.sent['alice']!.map((frame) => frame[0]), [1, 2, 3]);
        expect(pair.native.sent['bob']!.map((frame) => frame[0]), [1, 2, 3]);
        expect(pair.aliceSession!.state, PeerSessionState.connected);
        expect(pair.bobSession!.state, PeerSessionState.connected);
        expect(pair.aliceSession!.failureReason, isNull);
        expect(pair.bobSession!.failureReason, isNull);

        // Authentication must unlock the actual protected application path.
        final received = pair.bobSession!.packets.first;
        await _complete(
          pair.aliceSession!.sendControl({'after': 'mutual-auth'}),
          'send protected control',
        );
        expect(
          (await _complete(received, 'receive protected control')).control,
          {'after': 'mutual-auth'},
        );
      } finally {
        await _complete(pair.close(), 'close both meshes');
      }
    });

    test('close cancels proof waiting for $wait', () async {
      final pair = _SessionPair(
        alice: alice,
        bob: bob,
        aliceCard: aliceCard,
        bobCard: bobCard,
        holdTrust: holdTrust,
      );
      try {
        await _complete(pair.start(), 'start both meshes');
        await pair.arrangeEarlyChallenge();
        await _complete(pair.aliceSession!.close(), 'explicit close');
        // Closed channel events must not be fabricated after native teardown.
        // The trust await, when present, is released explicitly after closure.
        if (holdTrust) pair.trustRelease.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(pair.aliceSession!.state, PeerSessionState.closed);
        expect(pair.aliceSession!.failureReason, isNull);
        expect(pair.native.sent['alice'], isEmpty);
        expect(pair.aliceMesh.disconnectedPeerIds, contains(bobCard.nodeId));
      } finally {
        await _complete(pair.close(), 'close both meshes');
      }
    });
  }
}
