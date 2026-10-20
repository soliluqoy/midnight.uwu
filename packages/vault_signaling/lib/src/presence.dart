import 'dart:convert';
import 'dart:typed_data';

import 'package:vault_identity/vault_identity.dart';
import 'package:vault_protocol/vault_protocol.dart'
    show MsgType, WireReject, decodeEnvelope;

/// Maximum signed unencrypted presence envelope size.
const maxPublicPresenceBytes = 2048;

/// Verified public metadata, never an approved contact or media authorization.
class PublicPresenceRecord {
  /// Creates a bounded immutable metadata view after client verification.
  new({
    required this.nodeId,
    required this.binding,
    required this.name,
    required List<String> tags,
    required this.sharedCount,
    required this.epoch,
    required this.sequence,
    required this.expiresAt,
    required Uint8List signedEnvelope,
  }) : tags = List.unmodifiable(tags),
       signedEnvelope = Uint8List.fromList(signedEnvelope).asUnmodifiableView();

  /// Stable derived signing identity, compared instead of display names.
  final String nodeId;

  /// Self-signed public encryption-key binding; contact approval is separate.
  final KeyBinding binding;

  /// Public display name, at most 80 UTF-8 bytes.
  final String name;

  /// Up to eight explicit public search tags, each at most 24 UTF-8 bytes.
  final List<String> tags;

  /// Public coarse shared item count, never filenames or an index.
  final int sharedCount;

  /// Process-start Unix microseconds, not persistent rotation authority.
  final int epoch;

  /// Strictly increasing announcement sequence within [epoch].
  final int sequence;

  /// Signed expiry in Unix seconds, at most 90 seconds after issue.
  final int expiresAt;

  /// Complete origin-signed bytes for revalidation of an untrusted disk cache.
  final Uint8List signedEnvelope;
}

/// Rejects every field outside the explicit public discovery metadata schema.
void validatePublicPresencePayload(
  Map<Object, Object?> payload, {
  required int now,
}) {
  const fields = {
    'presence',
    'name',
    'tags',
    'sharedCount',
    'epoch',
    'sequence',
    'expires',
    'encryptionKey',
    'bindingIssuedAt',
    'bindingSignature',
  };
  bool text(Object? value, int max) =>
      value is String &&
      value.length <= max &&
      utf8.encode(value).length <= max;
  final tags = payload['tags'];
  final count = payload['sharedCount'];
  final epoch = payload['epoch'];
  final sequence = payload['sequence'];
  final expires = payload['expires'];
  final encryption = payload['encryptionKey'];
  final signature = payload['bindingSignature'];
  if (payload.length != fields.length ||
      !payload.keys.every(fields.contains) ||
      payload['presence'] != true ||
      !text(payload['name'], 80) ||
      tags is! List<Object?> ||
      tags.length > 8 ||
      !tags.every((tag) => text(tag, 24) && (tag! as String).isNotEmpty) ||
      tags.toSet().length != tags.length ||
      count is! int ||
      count < 0 ||
      count > 1000000 ||
      epoch is! int ||
      epoch < 1 ||
      epoch > (now + 120) * 1000000 ||
      sequence is! int ||
      sequence < 1 ||
      sequence > 0x7fffffff ||
      expires is! int ||
      expires <= now ||
      expires > now + 90 ||
      encryption is! Uint8List ||
      encryption.length != 32 ||
      signature is! Uint8List ||
      signature.length != 64 ||
      payload['bindingIssuedAt'] is! int) {
    throw const WireReject('public presence schema');
  }
}

/// Revalidates an origin-signed public record, including persisted cache bytes.
/// Does not grant contact trust or replace the client's bounded replay state.
Future<PublicPresenceRecord> verifyPublicPresenceRecord(
  Uint8List bytes, {
  required int now,
  String? expectedNodeId,
}) async {
  if (bytes.isEmpty || bytes.length > maxPublicPresenceBytes) {
    throw const WireReject('public presence frame size');
  }
  final envelope = await decodeEnvelope(bytes, now: now);
  if (envelope.type != MsgType.announce ||
      envelope.recipient != null ||
      envelope.issuedAt > now + 5 ||
      envelope.expiresAt <= now ||
      envelope.expiresAt - envelope.issuedAt > 90 ||
      envelope.iceGeneration != 0 ||
      envelope.sessionId.any((byte) => byte != 0)) {
    throw const WireReject('public presence envelope');
  }
  final payload = envelope.payload;
  validatePublicPresencePayload(payload, now: now);
  if (envelope.expiresAt != payload['expires']) {
    throw const WireReject('public presence expiry mismatch');
  }
  final nodeId = nodeIdText(await nodeIdOf(envelope.sender));
  if (expectedNodeId != null && nodeId != expectedNodeId) {
    throw const WireReject('public presence topic signer mismatch');
  }
  final binding = KeyBinding(
    envelope.sender,
    payload['encryptionKey']! as Uint8List,
    payload['bindingIssuedAt']! as int,
    payload['bindingSignature']! as Uint8List,
  );
  if (!await binding.verify()) {
    throw const WireReject('public presence key binding');
  }
  return PublicPresenceRecord(
    nodeId: nodeId,
    binding: binding,
    name: payload['name']! as String,
    tags: (payload['tags']! as List<Object?>).cast<String>(),
    sharedCount: payload['sharedCount']! as int,
    epoch: payload['epoch']! as int,
    sequence: payload['sequence']! as int,
    expiresAt: envelope.expiresAt,
    signedEnvelope: bytes,
  );
}
