import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/production/connection_problem.dart';
import 'package:vault/production/pairing_code.dart';
import 'package:vault/production/pairing_dialogs.dart';
import 'package:vault/production/pairing_join.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_net/vault_net.dart';
import 'package:vault_protocol/vault_protocol.dart'
    show ActivePairing, PairingInvite;
import 'package:vault_signaling/vault_signaling.dart';

/// Renders [modules] as a camera-like luminance frame with padding per row.
({Uint8List bytes, int width, int height, int stride}) _frame(
  QrModules modules, {
  int scale = 3,
  int padding = 0,
}) {
  final side = (modules.size + 8) * scale;
  final stride = side + padding;
  final bytes = Uint8List(stride * side)..fillRange(0, stride * side, 230);
  for (var y = 0; y < modules.size; y++) {
    for (var x = 0; x < modules.size; x++) {
      if (modules.dark[y * modules.size + x] == 0) continue;
      for (var dy = 0; dy < scale; dy++) {
        final row = ((y + 4) * scale + dy) * stride + (x + 4) * scale;
        bytes.fillRange(row, row + scale, 20);
      }
    }
  }
  return (bytes: bytes, width: side, height: side, stride: stride);
}

class _Session extends Fake implements PeerSession {
  new(this.peerId);

  final _states = StreamController<PeerSessionState>.broadcast(sync: true);
  @override
  final String peerId;
  @override
  PeerSessionState state = PeerSessionState.negotiating;
  @override
  ConnectionProblem? problem;
  @override
  String? failureReason;
  @override
  Stream<PeerSessionState> get states => _states.stream;

  void move(PeerSessionState next) {
    state = next;
    _states.add(next);
  }
}

class _Port implements PairingJoinPort {
  new(this.host, {this.switchBroker = false}) {
    // Tests may fail the introduction before the join awaits it.
    introduced.future.ignore();
  }

  final ContactCard host;
  final bool switchBroker;
  final calls = <String>[];
  final introduced = Completer<void>();
  final _starts = StreamController<PeerSession>.broadcast(sync: true);
  PeerSession? live;

  /// The host approved and dialed: an inbound session from it starts.
  _Session hostDials() {
    final session = _Session(host.nodeId);
    live = session;
    _starts.add(session);
    return session;
  }

  @override
  bool needsBrokerSwitch(PairingInvite invite) => switchBroker;

  @override
  Future<void> addContact(ContactCard card) async => calls.add('add');

  @override
  Future<void> allowConnections(ContactCard card) async =>
      calls.add('allow ${card.name}');

  @override
  Future<void> useBroker(String host, int port) async =>
      calls.add('broker $host:$port');

  @override
  Future<void> introduce(PairingInvite invite) {
    calls.add('introduce');
    return introduced.future;
  }

  @override
  Stream<PeerSession> get sessionStarts => _starts.stream;

  @override
  PeerSession? liveSession(String peerId) =>
      live?.peerId == peerId ? live : null;
}

void main() {
  late PairingInvite invite;

  setUp(() async {
    invite =
        ActivePairing.start(
          now: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ).invite(
          await ContactCard.create(await Identity.generate(), name: 'Laptop'),
          brokerHost: 'broker.emqx.io',
          brokerPort: 8883,
        );
  });

  group('QR code', () {
    test('an invite survives encoding, a camera-like frame and decoding', () {
      final text = invite.encode();
      final modules = encodeQr(text);
      for (final padding in [0, 37]) {
        final frame = _frame(modules, padding: padding);
        expect(
          decodeQrLuminance(
            frame.bytes,
            frame.width,
            frame.height,
            frame.stride,
          ),
          text,
          reason: 'row padding $padding',
        );
      }
    });

    test('a frame without a code yields nothing', () {
      final blank = Uint8List(200 * 200)..fillRange(0, 200 * 200, 128);
      expect(decodeQrLuminance(blank, 200, 200, 200), isNull);
      expect(decodeQrLuminance(blank, 200, 200, 199), isNull);
    });
  });

  group('scanner pairing state machine', () {
    List<String> steps(PairingJoin join) {
      final seen = <String>[];
      void record() => seen.add(switch (join.value) {
        PairingUnderway(:final step) => step.name,
        PairingConnected() => 'connected',
        PairingFailed(:final problem) => 'failed ${problem?.name}',
      });
      record();
      join.addListener(record);
      return seen;
    }

    test('waits for the host to dial, then follows that session', () async {
      final port = _Port(invite.card, switchBroker: true);
      final join = PairingJoin(port, invite);
      final seen = steps(join);
      final running = join.run();
      await pumpEventQueue();
      expect(seen.last, 'introducing');
      port.introduced.complete();
      await pumpEventQueue();
      expect(seen.last, 'waitingForApproval');
      expect(
        port.calls,
        isNot(contains('connect')),
        reason: 'The host is not a contact of ours until it approves',
      );
      final session = port.hostDials();
      await pumpEventQueue();
      session
        ..move(PeerSessionState.authenticating)
        ..move(PeerSessionState.connected);
      await running;
      expect(seen, [
        'scanned',
        'configuring',
        'introducing',
        'waitingForApproval',
        'connecting',
        'connected',
      ]);
      expect(port.calls, [
        'add',
        'allow Laptop',
        'broker broker.emqx.io:8883',
        'introduce',
      ]);
    });

    test('keeps a matching broker', () async {
      final port = _Port(invite.card)..introduced.complete();
      final join = PairingJoin(port, invite);
      final running = join.run();
      await pumpEventQueue();
      port.hostDials().move(PeerSessionState.connected);
      await running;
      expect(join.value, isA<PairingConnected>());
      expect(port.calls, ['add', 'allow Laptop', 'introduce']);
    });

    test('ignores sessions with other peers while waiting', () async {
      final port = _Port(invite.card)..introduced.complete();
      final join = PairingJoin(port, invite);
      final running = join.run();
      await pumpEventQueue();
      port._starts.add(
        _Session('someone-else')..state = PeerSessionState.failed,
      );
      await pumpEventQueue();
      expect(
        (join.value as PairingUnderway).step,
        PairingStep.waitingForApproval,
      );
      port.hostDials().move(PeerSessionState.connected);
      await running;
      expect(join.value, isA<PairingConnected>());
    });

    test('follows a session with the host that is already underway', () async {
      final port = _Port(invite.card)..introduced.complete();
      final existing = _Session(invite.card.nodeId)
        ..state = PeerSessionState.connected;
      port.live = existing;
      await PairingJoin(port, invite).run().timeout(const Duration(seconds: 5));
    });

    test('fails as timed out when the code expires before the host dials', () {
      fakeAsync((async) {
        final port = _Port(invite.card)..introduced.complete();
        final join = PairingJoin(
          port,
          invite,
          now: () => invite.expiresAt - 60,
        );
        var finished = false;
        unawaited(join.run().whenComplete(() => finished = true));
        async.elapse(const Duration(seconds: 59));
        expect(
          (join.value as PairingUnderway).step,
          PairingStep.waitingForApproval,
        );
        async.elapse(const Duration(seconds: 2));
        expect(join.value, isA<PairingFailed>());
        expect(finished, isTrue);
        final failed = join.value as PairingFailed;
        expect(failed.problem, ConnectionProblem.negotiationTimedOut);
        expect(failed.detail, contains('expired'));
        port.hostDials().move(PeerSessionState.connected);
        async.flushMicrotasks();
        expect(join.value, same(failed));
      });
    });

    test('cancel ends the wait and ignores a later session', () async {
      final port = _Port(invite.card)..introduced.complete();
      final join = PairingJoin(port, invite);
      final running = join.run();
      await pumpEventQueue();
      final waiting = join.value;
      join.cancel();
      await running.timeout(const Duration(seconds: 5));
      port.hostDials().move(PeerSessionState.connected);
      await pumpEventQueue();
      expect(join.value, same(waiting));
    });

    test('an unanswered introduction fails as a timeout', () async {
      final port = _Port(invite.card);
      final join = PairingJoin(port, invite);
      port.introduced.completeError(
        SignalingFailure(
          'signal acknowledgment deadline exceeded',
          kind: SignalingFailureKind.acknowledgmentTimeout,
        ),
      );
      await join.run();
      expect(
        join.value,
        isA<PairingFailed>().having(
          (failed) => failed.problem,
          'problem',
          ConnectionProblem.negotiationTimedOut,
        ),
      );
    });

    test('an unreachable broker fails as signalingUnavailable', () async {
      final port = _Port(invite.card);
      final join = PairingJoin(port, invite);
      port.introduced.completeError(
        const ConnectionProblemException(
          ConnectionProblem.signalingUnavailable,
        ),
      );
      await join.run();
      expect(
        (join.value as PairingFailed).problem,
        ConnectionProblem.signalingUnavailable,
      );
    });

    test('a refused direct route fails with that problem', () async {
      final port = _Port(invite.card)..introduced.complete();
      final join = PairingJoin(port, invite);
      final running = join.run();
      await pumpEventQueue();
      port.hostDials()
        ..problem = ConnectionProblem.noDirectRoute
        ..failureReason = 'Native peer connection failed'
        ..move(PeerSessionState.failed);
      await running;
      expect(
        (join.value as PairingFailed).problem,
        ConnectionProblem.noDirectRoute,
      );
    });
  });

  testWidgets('the progress dialog explains each stage and the failure', (
    tester,
  ) async {
    final port = _Port(invite.card);
    final join = PairingJoin(port, invite);
    addTearDown(join.dispose);
    final ownNodeId = nodeIdText((await Identity.generate()).nodeId);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PairingJoinDialog(join: join, ownNodeId: ownNodeId),
        ),
      ),
    );
    unawaited(join.run());
    await tester.pump();
    expect(find.text('Pairing with Laptop'), findsOneWidget);
    port.introduced.complete();
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining(ownNodeId.substring(ownNodeId.length - 6)),
      findsOneWidget,
    );
    port.hostDials()
      ..problem = ConnectionProblem.noDirectRoute
      ..move(PeerSessionState.failed);
    await tester.pump();
    expect(find.text('Pairing did not finish'), findsOneWidget);
    expect(find.textContaining('would not allow a direct'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });
}
