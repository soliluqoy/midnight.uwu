import 'dart:typed_data';

/// Observable transport lifecycle; only [PeerSessionState.connected] may send.
enum PeerSessionState {
  /// Signed complete-SDP negotiation or an allowed ICE restart is in progress.
  negotiating,

  /// DTLS channels exist but mutual signed challenges are not yet complete.
  authenticating,

  /// Both identity proofs and a selected direct route have been verified.
  connected,

  /// The session ended intentionally and cannot resume.
  closed,

  /// A policy, authentication, transport or deadline failure ended the session.
  failed,
}

/// Application delivery channel for an authenticated packet.
enum PeerPacketKind {
  /// Reliable ordered JSON request or response.
  control,

  /// Reliable ordered binary fragment.
  bulk,

  /// Unordered zero-retransmission JSON event.
  ephemeral,
}

/// A bounded application packet emitted only after mutual authentication.
class PeerPacket {
  /// Captures a reliable control object with an immutable top-level map.
  new control(Map<String, Object?> value)
    : kind = PeerPacketKind.control,
      control = Map<String, Object?>.unmodifiable(value),
      bytes = null;

  /// Copies a reliable binary fragment into an immutable owned byte view.
  new bulk(Uint8List value)
    : kind = PeerPacketKind.bulk,
      control = null,
      bytes = Uint8List.fromList(value).asUnmodifiableView();

  /// Captures an unreliable JSON event with an immutable top-level map.
  new ephemeral(Map<String, Object?> value)
    : kind = PeerPacketKind.ephemeral,
      control = Map<String, Object?>.unmodifiable(value),
      bytes = null;

  /// Channel on which this application packet arrived.
  final PeerPacketKind kind;

  /// JSON object for control/ephemeral packets, otherwise null.
  final Map<String, Object?>? control;

  /// Immutable binary fragment for bulk packets, otherwise null.
  final Uint8List? bytes;
}
