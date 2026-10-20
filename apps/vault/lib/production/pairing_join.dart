import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:vault/production/connection_problem.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_net/vault_net.dart';
import 'package:vault_protocol/vault_protocol.dart' show PairingInvite;
import 'package:vault_signaling/vault_signaling.dart';

/// Steps a scanner moves through while pairing is still underway.
enum PairingStep {
  scanned,
  configuring,
  introducing,
  waitingForApproval,
  connecting,
}

/// Where a scanner's pairing attempt stands.
sealed class PairingProgress {
  const new();
}

final class PairingUnderway extends PairingProgress {
  const new(this.step);
  final PairingStep step;
}

final class PairingConnected extends PairingProgress {
  const new();
}

final class PairingFailed extends PairingProgress {
  const new(this.problem, {this.detail});

  /// The person-facing cause, when it is one of the known problems.
  final ConnectionProblem? problem;

  /// Extra context, or the whole explanation when [problem] is null.
  final String? detail;
}

/// What pairing needs from the running app. Implemented by `VaultRuntime`.
abstract interface class PairingJoinPort {
  /// Whether connection setup must move to the invite's broker first.
  bool needsBrokerSwitch(PairingInvite invite);

  Future<void> addContact(ContactCard card);

  /// Accepts offers from [card] even if this device disconnected it before.
  Future<void> allowConnections(ContactCard card);

  /// Uses the invite's broker; signaling must already be stopped.
  Future<void> useBroker(String host, int port);

  /// Starts signaling and completes when the host accepts the introduction.
  Future<void> introduce(PairingInvite invite);

  /// Contact sessions as they start, inbound or outbound.
  Stream<PeerSession> get sessionStarts;

  /// The session with [peerId] that is still negotiating or connected.
  PeerSession? liveSession(String peerId);
}

int _unixNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Drives a scanned invite to a connected session or a stated failure.
/// The person has already confirmed the host and any broker switch.
///
/// The scanner never dials. The host learns the scanner's card only from the
/// introduction and adds it when its person approves, so an earlier offer
/// would be rejected as coming from a noncontact. The host dials instead.
class PairingJoin extends ValueNotifier<PairingProgress> {
  new(this._port, this.invite, {int Function()? now})
    : _now = now ?? _unixNow,
      super(const PairingUnderway(PairingStep.scanned));

  final PairingJoinPort _port;
  final PairingInvite invite;
  final int Function() _now;
  final _cancelled = Completer<void>();
  StreamSubscription<PeerSessionState>? _states;
  bool _disposed = false;

  void _set(PairingProgress next) {
    if (!_disposed && !_cancelled.isCompleted) value = next;
  }

  Future<void> run() async {
    final hostId = invite.card.nodeId;
    final dialed = Completer<PeerSession>();
    final starts = _port.sessionStarts.listen((session) {
      if (session.peerId == hostId && !dialed.isCompleted) {
        dialed.complete(session);
      }
    });
    try {
      _set(const PairingUnderway(PairingStep.configuring));
      await _port.addContact(invite.card);
      await _port.allowConnections(invite.card);
      if (_port.needsBrokerSwitch(invite)) {
        await _port.useBroker(invite.brokerHost, invite.brokerPort);
      }
      _set(const PairingUnderway(PairingStep.introducing));
      await _port.introduce(invite);
      _set(const PairingUnderway(PairingStep.waitingForApproval));
      final session =
          _port.liveSession(hostId) ??
          await Future.any<PeerSession?>([
            dialed.future,
            _cancelled.future.then((_) => null),
          ]).timeout(
            Duration(seconds: max(0, invite.expiresAt - _now())),
            onTimeout: () => null,
          );
      if (_cancelled.isCompleted) return;
      if (session == null) {
        final host = invite.card.name;
        _set(
          PairingFailed(
            ConnectionProblem.negotiationTimedOut,
            detail:
                '$host did not connect before the pairing code expired. Make '
                'a new code on $host and scan it, then choose Add contact on '
                '$host.',
          ),
        );
        return;
      }
      await _follow(session);
    } on ConnectionProblemException catch (error) {
      _set(PairingFailed(error.problem));
    } on SignalingFailure catch (failure) {
      _set(
        failure.kind == SignalingFailureKind.acknowledgmentTimeout
            ? const PairingFailed(
                ConnectionProblem.negotiationTimedOut,
                detail:
                    'Make sure the pairing code is still showing on the '
                    'other device, then scan it again.',
              )
            : PairingFailed(null, detail: failure.reason),
      );
    } on Object catch (error) {
      _set(PairingFailed(null, detail: '$error'));
    } finally {
      unawaited(starts.cancel());
    }
  }

  Future<void> _follow(PeerSession session) {
    final done = Completer<void>();
    void apply(PeerSessionState state) {
      if (done.isCompleted) return;
      switch (state) {
        case PeerSessionState.negotiating || PeerSessionState.authenticating:
          _set(const PairingUnderway(PairingStep.connecting));
        case PeerSessionState.connected:
          _set(const PairingConnected());
          done.complete();
        case PeerSessionState.failed:
          _set(PairingFailed(session.problem, detail: session.failureReason));
          done.complete();
        case PeerSessionState.closed:
          _set(const PairingFailed(null, detail: 'The connection was closed.'));
          done.complete();
      }
    }

    apply(session.state);
    if (!done.isCompleted) _states = session.states.listen(apply);
    return Future.any([done.future, _cancelled.future])
        .whenComplete(() => _states?.cancel());
  }

  /// Stops waiting for or following the host. The progress stays as it was.
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
    unawaited(_states?.cancel());
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}
