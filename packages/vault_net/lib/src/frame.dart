import 'dart:typed_data';

import 'package:vault_net/src/policy.dart';

/// Bytes reserved for the private frame type and big-endian ICE generation.
const peerFrameHeaderBytes = 5;

/// Largest application payload whose complete serialized frame fits 16 KiB.
const int maxPeerPayloadBytes = maxPacketBytes - peerFrameHeaderBytes;

/// Every channel carries a generation, including unordered ephemeral and bulk.
/// Queued SCTP bytes from a previous authenticated ICE generation cannot cross
/// the reauthentication boundary.
class PeerFrame {
  /// Parses a bounded frame, retaining a view over the caller-owned bytes.
  factory decode(Uint8List frame) {
    if (frame.length < peerFrameHeaderBytes ||
        frame.length > maxPacketBytes ||
        !const {1, 2, 3, 16}.contains(frame[0])) {
      throw const PeerFailure('Invalid or oversized packet frame');
    }
    return PeerFrame._(
      frame[0],
      ByteData.sublistView(frame).getUint32(1),
      Uint8List.sublistView(frame, peerFrameHeaderBytes),
    );
  }
  new _(this.type, this.generation, this.body);

  /// Private auth/control discriminator; application frames use type 16.
  final int type;

  /// ICE generation that authenticated this frame.
  final int generation;

  /// Payload view excluding the private header.
  final Uint8List body;

  /// Encodes an owned frame copy while enforcing the total native packet limit.
  static Uint8List encode(int type, int generation, Uint8List body) {
    if (body.length > maxPeerPayloadBytes ||
        generation < 0 ||
        generation > 0xffffffff ||
        !const {1, 2, 3, 16}.contains(type)) {
      throw const PeerFailure('Invalid frame or total packet exceeds 16 KiB');
    }
    final frame = Uint8List(body.length + peerFrameHeaderBytes);
    frame[0] = type;
    ByteData.sublistView(frame).setUint32(1, generation);
    frame.setRange(peerFrameHeaderBytes, frame.length, body);
    return frame;
  }

  /// Returns false only for obsolete bytes; future generations are attacks or
  /// a signaling/state error, never permission to advance negotiation.
  bool isCurrent(int expected, {int? pausedGeneration}) {
    if (generation < expected || generation == pausedGeneration) return false;
    if (generation != expected) {
      throw const PeerFailure('Packet from unnegotiated ICE generation');
    }
    return true;
  }
}
