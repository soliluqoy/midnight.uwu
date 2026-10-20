import 'dart:typed_data';

/// Maximum serialized private frame size, including HPKE overhead.
const int maxSignalFrameBytes = 24 * 1024;

/// Canonical textual encoding of a 32-byte Vault node identifier.
final signalNodeIdPattern = RegExp(r'^[a-z2-7]{52}$');

/// An immutable addressed transport frame; contents remain sealed.
class SignalFrame {
  /// Copies [bytes] so transport consumers cannot mutate received data.
  new(this.recipient, Uint8List bytes)
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  /// Canonical destination node identifier.
  final String recipient;

  /// Complete signed HPKE-sealed frame.
  final Uint8List bytes;
}

/// Addressed transport with explicit readiness, failures and shutdown.
abstract class SignalingStrategy {
  /// Sealed frames; asynchronous transport failures are stream errors.
  Stream<SignalFrame> get inbound;

  /// Readiness transitions, not just socket connection transitions.
  Stream<bool> get connectionChanges;

  /// Whether the transport can currently publish and receive.
  bool get connected;

  /// Starts receiving for [nodeId], completing only after readiness.
  Future<void> start(String nodeId);

  /// Publishes a complete frame without retaining it at an intermediary.
  Future<void> publish(String recipient, Uint8List bytes);

  /// Permanently stops transport work and closes streams.
  Future<void> close();
}

/// Explicit optional public metadata channel, never a private-signal fallback.
abstract interface class PublicPresenceTransport {
  /// Signed public envelopes; recipient identifies the topic's claimed signer.
  Stream<SignalFrame> get publicFrames;

  /// Whether subscribing/publishing public metadata is explicitly enabled.
  bool get publicPresenceEnabled;

  /// Changes public policy, awaiting subscribe readiness if started.
  // Setter-style API intentionally matches discovery policy consumers.
  // ignore: avoid_positional_boolean_parameters
  Future<void> setPublicPresenceEnabled(bool enabled);

  /// Publishes a signed nonretained public envelope on the signer's own topic.
  Future<void> publishPublicPresence(String signerNodeId, Uint8List bytes);
}

/// What a failure means for the person, independent of its diagnostic text.
enum SignalingFailureKind {
  /// Diagnostic only; no specific remedy.
  other,

  /// A validly signed private frame came from an identity that is not a
  /// contact. [SignalingFailure.peerId] is the authenticated signer.
  unknownSender,

  /// The transport could not start, publish or keep receiving.
  transportUnavailable,

  /// A published message was never acknowledged before its deadline.
  acknowledgmentTimeout,
}

/// Sanitized operational or rejection information, never private payload data.
class SignalingFailure implements Exception {
  /// Associates a failure with its optional peer and negotiation.
  new(
    this.reason, {
    this.peerId,
    Uint8List? sessionId,
    this.cause,
    this.terminal = false,
    this.kind = SignalingFailureKind.other,
  }) : sessionId = sessionId == null
           ? null
           : Uint8List.fromList(sessionId).asUnmodifiableView();

  /// Stable human-readable description of the failed operation.
  final String reason;

  /// UI-friendly alias for [reason].
  String get message => reason;

  /// Canonical remote node identifier, when known.
  final String? peerId;

  /// Negotiation identifier, when the operation belongs to a session.
  final Uint8List? sessionId;

  /// Sanitized underlying error type, never the error's private message.
  final Object? cause;

  /// Whether send/start permanently failed rather than continuing to retry.
  final bool terminal;

  /// Person-facing classification of this failure.
  final SignalingFailureKind kind;
  @override
  String toString() => 'SignalingFailure: $reason';
}
