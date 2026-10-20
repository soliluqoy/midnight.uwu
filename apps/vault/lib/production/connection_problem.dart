import 'package:flutter/material.dart';
import 'package:vault_net/vault_net.dart';

export 'package:vault_net/vault_net.dart' show ConnectionProblem, PeerProblem;

/// The single remedy offered for a [ConnectionProblem].
enum ProblemAction {
  /// Start pairing so the sender becomes a verified contact.
  pair,

  /// Clear your earlier disconnect and connect to this contact.
  connect,

  /// Try the same connection again.
  retry,
}

/// Person-facing copy and remedy for one connection problem.
typedef ProblemCopy = ({String text, ProblemAction action, String label});

/// Short, still-distinctive fingerprint form for notices.
String shortFingerprint(String nodeId) => nodeId.length <= 12
    ? nodeId
    : '${nodeId.substring(0, 6)}…${nodeId.substring(nodeId.length - 6)}';

/// The one table of connection problem copy. [who] is a contact name, or a
/// short fingerprint for a sender who is not a contact.
ProblemCopy problemCopy(
  ConnectionProblem problem, {
  required String who,
}) => switch (problem) {
  ConnectionProblem.notAContact => (
    text:
        'Someone who is not in your contacts tried to connect '
        '(fingerprint $who). Midnight ignored it. If you expected this, '
        'pair with them first.',
    action: ProblemAction.pair,
    label: 'Pair',
  ),
  ConnectionProblem.youDisconnected => (
    text:
        '$who tried to connect, but you disconnected them earlier, so '
        'Midnight ignored it. Choose Connect to allow connections again.',
    action: ProblemAction.connect,
    label: 'Connect',
  ),
  ConnectionProblem.negotiationTimedOut => (
    text:
        'Could not reach $who in time. Midnight may be closed or offline on '
        'their device, or the two devices use different connection '
        'setups. Open Midnight on both devices, then try again.',
    action: ProblemAction.retry,
    label: 'Try again',
  ),
  ConnectionProblem.noDirectRoute => (
    text:
        'Your network and the network $who is on would not allow a '
        'direct connection. Try again with one device on Wi-Fi, or with '
        'both devices on the same network.',
    action: ProblemAction.retry,
    label: 'Try again',
  ),
  ConnectionProblem.signalingUnavailable => (
    text:
        'Midnight could not reach the connection-setup service, so it could '
        'not contact $who. Check your internet connection and try again, '
        'or choose a different setup in Connection settings.',
    action: ProblemAction.retry,
    label: 'Try again',
  ),
};

/// Bounded, deduplicated record of inbound attempts that Vault ignored.
class IgnoredAttempts {
  /// Most noncontact senders kept; older ones are dropped first.
  static const maxUnknownSenders = 5;

  /// Repeats from one sender inside this window do not notify again.
  static const repeatWindow = Duration(minutes: 1);

  final _unknownSenders = <String, DateTime>{};
  final _blockedOffers = <String>{};

  /// Noncontacts whose signed signaling was ignored, oldest first.
  Map<String, DateTime> get unknownSenders => Map.unmodifiable(_unknownSenders);

  /// Contacts whose new connection was ignored because you disconnected them.
  Set<String> get blockedOffers => Set.unmodifiable(_blockedOffers);

  /// Records [attempt]; returns whether it is new enough to show again.
  bool record(PeerProblem attempt, {required DateTime now}) {
    final peerId = attempt.peerId;
    switch (attempt.problem) {
      case ConnectionProblem.notAContact:
        final previous = _unknownSenders.remove(peerId);
        _unknownSenders[peerId] = now;
        while (_unknownSenders.length > maxUnknownSenders) {
          _unknownSenders.remove(_unknownSenders.keys.first);
        }
        return previous == null || now.difference(previous) >= repeatWindow;
      case ConnectionProblem.youDisconnected:
        return _blockedOffers.add(peerId);
      case ConnectionProblem.negotiationTimedOut ||
          ConnectionProblem.noDirectRoute ||
          ConnectionProblem.signalingUnavailable:
        return false;
    }
  }

  /// Forgets only an ignored noncontact attempt.
  bool dismissUnknown(String peerId) => _unknownSenders.remove(peerId) != null;

  /// Forgets only an ignored disconnected-contact attempt.
  bool dismissBlocked(String peerId) => _blockedOffers.remove(peerId);
}

/// A failed operation whose cause is already shown as a [ConnectionProblem].
class ConnectionProblemException implements Exception {
  const new(this.problem);
  final ConnectionProblem problem;

  @override
  String toString() => problemCopy(problem, who: 'the other device').text;
}

/// A problem notice with its one remedy and an optional dismiss control.
class ConnectionProblemNotice extends StatelessWidget {
  const new({
    required this.problem,
    required this.who,
    required this.onAction,
    this.onDismiss,
    this.busy = false,
    super.key,
  });

  final ConnectionProblem problem;
  final String who;
  final void Function(ProblemAction action) onAction;
  final VoidCallback? onDismiss;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final copy = problemCopy(problem, who: who);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              copy.text,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.tonal(
                key: ValueKey('problem-${problem.name}-action'),
                onPressed: busy ? null : () => onAction(copy.action),
                child: Text(copy.label),
              ),
              if (onDismiss != null)
                TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
            ],
          ),
        ],
      ),
    );
  }
}
