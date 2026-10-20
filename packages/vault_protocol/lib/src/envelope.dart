import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_protocol/src/codec/cbor_strict.dart';

/// Throwaway Phase 0 wire/crypto profile. Not the production package.
const wireVersion = 1;

/// Allowed clock difference when checking signed envelope validity.
const clockSkewSeconds = 120;

/// Maximum signed envelope length, including its header and signature.
const int maxEnvelopeBytes = 32 * 1024;

/// Wire discriminants for signed messages and HPKE-sealed wrappers.
abstract final class MsgType {
  /// Initial peer greeting.
  static const hello = 1;

  /// Session negotiation offer.
  static const offer = 2;

  /// Session negotiation answer.
  static const answer = 3;

  /// ICE candidate update.
  static const candidate = 4;

  /// Peer announcement.
  static const announce = 5;

  /// Session termination.
  static const bye = 6;

  /// Message acknowledgement.
  static const ack = 7;

  /// Pairing introduction from a sender who is not yet a contact.
  static const introduce = 8;

  /// Encrypted wrapper containing a complete signed envelope.
  static const sealed = 0x0100;

  /// Types accepted in a signed inner envelope, excluding sealed wrappers.
  static const Set<int> known = {
    hello,
    offer,
    answer,
    candidate,
    announce,
    bye,
    ack,
    introduce,
  };
}

/// A fail-closed wire validation or authorization rejection.
class WireReject implements Exception {
  /// Records a rejection reason without exposing secret key material.
  const new(this.reason);

  /// The validation constraint that failed.
  final String reason;
  @override
  String toString() => 'WireReject: $reason';
}

Uint8List _cat(List<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  parts.forEach(b.add);
  return b.toBytes();
}

/// A signed message's fields with immutable byte and payload snapshots.
class Envelope {
  /// Copies byte fields and recursively snapshots the bounded CBOR payload.
  new({
    required this.type,
    required Uint8List sender,
    required Uint8List? recipient,
    required Uint8List messageId,
    required Uint8List sessionId,
    required this.issuedAt,
    required this.expiresAt,
    required this.iceGeneration,
    required Map<Object, Object?> payload,
  }) : sender = _fixed(sender, 32),
       recipient = recipient == null ? null : _fixed(recipient, 32),
       messageId = _fixed(messageId, 16),
       sessionId = _fixed(sessionId, 16),
       payload =
           _freeze(payload, 0, _SnapshotBudget())! as Map<Object, Object?>;

  /// The signed message discriminant from [MsgType].
  final int type;

  /// The sender's Ed25519 public key.
  final Uint8List sender;

  /// The intended recipient node ID, or null for an unaddressed message.
  final Uint8List? recipient;

  /// The unique 16-byte identifier used for replay detection.
  final Uint8List messageId;

  /// The 16-byte session identifier.
  final Uint8List sessionId;

  /// Start of the validity window in Unix seconds.
  final int issuedAt;

  /// End of the validity window in Unix seconds.
  final int expiresAt;

  /// The nonnegative ICE restart generation.
  final int iceGeneration;

  /// Recursively immutable fields in the supported CBOR subset.
  final Map<Object, Object?> payload;
}

Uint8List _signedPart(
  int version,
  int type,
  List<int> sender,
  List<int> body,
) => _cat([
  ascii.encode('vault/v1/envelope\x00'),
  [version, type >> 8, type & 0xff],
  sender,
  body,
]);

/// Signs version, type, sender key and the canonical CBOR body.
Future<Uint8List> encodeEnvelope(Identity from, Envelope e) async {
  if (!MsgType.known.contains(e.type) ||
      !_equal(e.sender, from.signingPublic)) {
    throw const WireReject('sender or type mismatch');
  }
  _validTimes(e.issuedAt, e.expiresAt);
  if (e.iceGeneration < 0) throw const WireReject('field types');
  final body = cborEncode({
    1: e.recipient,
    2: e.messageId,
    3: e.sessionId,
    4: e.issuedAt,
    5: e.expiresAt,
    6: e.iceGeneration,
    7: e.payload,
  });
  if (body.length + 99 > maxEnvelopeBytes) throw const WireReject('size');
  final sig = await from.sign(
    _signedPart(wireVersion, e.type, from.signingPublic, body),
  );
  return _cat([
    [wireVersion, e.type >> 8, e.type & 0xff],
    from.signingPublic,
    sig,
    body,
  ]);
}

/// Order: size, version, type, strict CBOR, field shape, signature, time.
/// Recipient, session and replay checks require caller state: [EnvelopeChecks].
Future<Envelope> decodeEnvelope(Uint8List wire, {required int now}) async {
  if (wire.length < 99 + 1 || wire.length > maxEnvelopeBytes) {
    throw const WireReject('size');
  }
  final snapshot = Uint8List.fromList(wire);
  if (snapshot[0] != wireVersion) throw const WireReject('unknown version');
  final type = (snapshot[1] << 8) | snapshot[2];
  if (!MsgType.known.contains(type)) throw const WireReject('unknown type');
  final sender = Uint8List.sublistView(snapshot, 3, 35);
  final sig = Uint8List.sublistView(snapshot, 35, 99);
  final body = Uint8List.sublistView(snapshot, 99);
  final Object? parsed;
  try {
    parsed = cborDecode(body);
  } on CborError catch (e) {
    throw WireReject('cbor: ${e.message}');
  }
  if (parsed is! Map<Object, Object?> ||
      parsed.keys.toSet().difference({1, 2, 3, 4, 5, 6, 7}).isNotEmpty ||
      parsed.length != 7) {
    throw const WireReject('body shape');
  }
  final recipient = parsed[1];
  final messageId = parsed[2];
  final sessionId = parsed[3];
  final issuedAt = parsed[4];
  final expiresAt = parsed[5];
  final iceGen = parsed[6];
  final payload = parsed[7];
  if ((recipient != null &&
          !(recipient is Uint8List && recipient.length == 32)) ||
      messageId is! Uint8List ||
      messageId.length != 16 ||
      sessionId is! Uint8List ||
      sessionId.length != 16 ||
      issuedAt is! int ||
      expiresAt is! int ||
      iceGen is! int ||
      iceGen < 0 ||
      payload is! Map<Object, Object?>) {
    throw const WireReject('field types');
  }
  if (!await verifyEd25519(
    sender,
    _signedPart(snapshot[0], type, sender, body),
    sig,
  )) {
    throw const WireReject('bad signature');
  }
  _validTimes(issuedAt, expiresAt);
  if (now + clockSkewSeconds < issuedAt) {
    throw const WireReject('issued in future');
  }
  if (now > expiresAt + clockSkewSeconds) throw const WireReject('expired');
  return Envelope(
    type: type,
    sender: sender,
    recipient: recipient as Uint8List?,
    messageId: messageId,
    sessionId: sessionId,
    issuedAt: issuedAt,
    expiresAt: expiresAt,
    iceGeneration: iceGen,
    payload: payload,
  );
}

/// Caller state checks, applied after [decodeEnvelope] and before side effects.
class EnvelopeChecks {
  /// Creates a bounded replay cache owned by the receiving identity.
  new(this.self, {this.maxEntries = 4096}) {
    if (maxEntries < 1 || maxEntries > 65536) {
      throw ArgumentError.value(maxEntries, 'maxEntries');
    }
  }

  /// Identity whose node ID must match addressed messages.
  final Identity self;

  /// Maximum retained sender/message identifiers.
  final int maxEntries;
  final _seen = <String, int>{};

  /// Checks recipient, optional session and replay state before side effects.
  void accept(Envelope e, {required int now, Uint8List? expectedSession}) {
    _validTimes(e.issuedAt, e.expiresAt);
    if (now + clockSkewSeconds < e.issuedAt ||
        now > e.expiresAt + clockSkewSeconds) {
      throw const WireReject('outside validity');
    }
    final to = e.recipient;
    if (to != null && !_equal(to, self.nodeId)) {
      throw const WireReject('wrong recipient');
    }
    if (expectedSession != null && !_equal(expectedSession, e.sessionId)) {
      throw const WireReject('wrong session');
    }
    _seen.removeWhere((_, until) => until < now);
    final key = '${base64.encode(e.sender)}|${base64.encode(e.messageId)}';
    if (_seen.containsKey(key)) throw const WireReject('replay');
    if (_seen.length >= maxEntries) throw const WireReject('replay cache full');
    _seen[key] = e.expiresAt + clockSkewSeconds;
  }
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

/// Wraps a signed inner envelope with the recipient's verified HPKE key.
/// The sealed plaintext is the complete signed inner envelope.
Future<Uint8List> seal(
  Uint8List innerWire,
  Uint8List recipientNodeId,
  KeyBinding recipient,
) async {
  if (innerWire.length < 100 || innerWire.length > maxEnvelopeBytes) {
    throw const WireReject('size');
  }
  final innerSnapshot = Uint8List.fromList(innerWire);
  final recipientSnapshot = _fixed(recipientNodeId, 32);
  if (!await recipient.verify() ||
      !_equal(await nodeIdOf(recipient.signingKey), recipientSnapshot)) {
    throw const WireReject('recipient key binding invalid');
  }
  final header = [wireVersion, MsgType.sealed >> 8, MsgType.sealed & 0xff];
  final sealed = await hpkeSeal(
    recipientPublicKey: recipient.encryptionKey,
    info: _cat([ascii.encode('vault/v1/sealed\x00'), recipientSnapshot]),
    aad: _cat([header, recipientSnapshot]),
    plaintext: innerSnapshot,
  );
  return _cat([header, recipientSnapshot, sealed.enc, sealed.ciphertext]);
}

/// Decrypts a bounded sealed wrapper addressed to [self].
Future<Uint8List> open(Uint8List outer, Identity self) async {
  if (outer.length < 67 + 16 || outer.length > maxEnvelopeBytes + 128) {
    throw const WireReject('size');
  }
  final snapshot = Uint8List.fromList(outer);
  if (snapshot[0] != wireVersion) throw const WireReject('unknown version');
  if (((snapshot[1] << 8) | snapshot[2]) != MsgType.sealed) {
    throw const WireReject('not sealed');
  }
  final to = Uint8List.sublistView(snapshot, 3, 35);
  if (!_equal(to, self.nodeId)) throw const WireReject('wrong recipient');
  try {
    return await hpkeOpen(
      recipient: self.encryption,
      enc: Uint8List.sublistView(snapshot, 35, 67),
      info: _cat([ascii.encode('vault/v1/sealed\x00'), self.nodeId]),
      aad: _cat([Uint8List.sublistView(snapshot, 0, 3), to]),
      ciphertext: Uint8List.sublistView(snapshot, 67),
    );
  } on Object {
    throw const WireReject('decryption failed');
  }
}

/// Owner-minted scope authenticated by a domain-separated HMAC-SHA256.
class Grant {
  /// Snapshots identifiers and actions, then validates scope and lifetime.
  new({
    required this.version,
    required Uint8List ownerId,
    required Uint8List viewerId,
    required Uint8List grantId,
    required this.resource,
    required List<String> actions,
    required this.issuedAt,
    required this.expiresAt,
    required this.epoch,
  }) : ownerId = _fixed(ownerId, 32),
       viewerId = _fixed(viewerId, 32),
       grantId = _fixed(grantId, 16),
       actions = List<String>.unmodifiable(actions) {
    _validateGrant(this);
  }

  /// Grant format version; currently only version one is accepted.
  final int version;

  /// Node ID of the owner minting this capability.
  final Uint8List ownerId;

  /// Node ID of the only viewer permitted to exercise this capability.
  final Uint8List viewerId;

  /// Unique 16-byte grant identifier used for revocation.
  final Uint8List grantId;

  /// Exact resource covered by this capability.
  final String resource;

  /// Distinct permitted action names.
  final List<String> actions;

  /// Start of the grant validity window in Unix seconds.
  final int issuedAt;

  /// Exclusive end of the grant validity window in Unix seconds.
  final int expiresAt;

  /// Owner authority epoch used to invalidate all older grants.
  final int epoch;

  /// Canonically encodes every authenticated grant field.
  Uint8List canonical() => cborEncode({
    1: version,
    2: ownerId,
    3: viewerId,
    4: grantId,
    5: resource,
    6: actions,
    7: issuedAt,
    8: expiresAt,
    9: epoch,
  });

  /// Computes the domain-separated authenticator using an owner-only key.
  Future<Uint8List> mac(Uint8List mintingKey) async {
    final keySnapshot = _fixed(mintingKey, 32);
    final m = await Hmac.sha256().calculateMac(
      _cat([ascii.encode('vault/v1/grant\x00'), canonical()]),
      secretKey: SecretKey(keySnapshot),
    );
    return Uint8List.fromList(m.bytes);
  }
}

/// Mutable owner-only revocation state; never distribute the minting key.
class OwnerState {
  /// Snapshots owner secrets and identifiers at the supplied authority epoch.
  new(Uint8List mintingKey, Uint8List nodeId, this.epoch)
    : mintingKey = _fixed(mintingKey, 32),
      nodeId = _fixed(nodeId, 32);

  /// Secret key used exclusively for minting and checking grant MACs.
  final Uint8List mintingKey;

  /// Node ID identifying this capability authority.
  final Uint8List nodeId;

  /// Current authority epoch; advancing it invalidates previous grants.
  int epoch;

  /// Revoked grant identifiers encoded with standard base64.
  final revoked = <String>{};

  /// Blocked viewer node IDs encoded with standard base64.
  final blocked = <String>{};
}

/// Checks identity, MAC, scope, expiry, epoch, revoked and block state.
Future<void> authorize({
  required OwnerState owner,
  required Grant grant,
  required Uint8List mac,
  required Uint8List authenticatedViewer,
  required String resource,
  required String action,
  required int now,
}) async {
  final viewerSnapshot = _fixed(authenticatedViewer, 32);
  final macSnapshot = _fixed(mac, 32);
  _validateGrant(grant);
  final expectedEpoch = owner.epoch;
  if (blockedOrRevoked(owner, grant, viewerSnapshot)) {
    throw const WireReject('revoked or blocked');
  }
  if (grant.version != 1 ||
      !_equal(grant.ownerId, owner.nodeId) ||
      !_equal(grant.viewerId, viewerSnapshot)) {
    throw const WireReject('identity mismatch');
  }
  final expected = await grant.mac(owner.mintingKey);
  if (!_equal(expected, macSnapshot)) throw const WireReject('bad mac');
  if (grant.epoch != expectedEpoch || owner.epoch != expectedEpoch) {
    throw const WireReject('stale epoch');
  }
  if (now >= grant.expiresAt || now < grant.issuedAt) {
    throw const WireReject('outside validity');
  }
  if (blockedOrRevoked(owner, grant, viewerSnapshot)) {
    throw const WireReject('revoked or blocked');
  }
  if (grant.resource != resource || !grant.actions.contains(action)) {
    throw const WireReject('out of scope');
  }
}

/// Tests the owner's current explicit viewer block and grant revocation sets.
bool blockedOrRevoked(OwnerState owner, Grant g, Uint8List viewer) =>
    owner.blocked.contains(base64.encode(viewer)) ||
    owner.revoked.contains(base64.encode(g.grantId));

Uint8List _fixed(List<int> value, int size) {
  if (value.length != size || value.any((b) => b < 0 || b > 255)) {
    throw const WireReject('field types');
  }
  return Uint8List.fromList(value).asUnmodifiableView();
}

void _validTimes(int issuedAt, int expiresAt) {
  if (issuedAt < 0 ||
      expiresAt <= issuedAt ||
      expiresAt - issuedAt > 3600 ||
      expiresAt > 0x7fffffffffffffff - clockSkewSeconds) {
    throw const WireReject('invalid validity window');
  }
}

void _validateGrant(Grant grant) {
  if (grant.version != 1 ||
      grant.issuedAt < 0 ||
      grant.expiresAt <= grant.issuedAt ||
      grant.expiresAt - grant.issuedAt > 30 * 86400 ||
      grant.epoch < 0 ||
      grant.resource.isEmpty ||
      grant.resource.length > 512 ||
      utf8.encode(grant.resource).length > 512 ||
      grant.actions.isEmpty ||
      grant.actions.length > 16 ||
      grant.actions.toSet().length != grant.actions.length ||
      grant.actions.any(
        (a) => a.isEmpty || a.length > 64 || utf8.encode(a).length > 64,
      )) {
    throw const WireReject('invalid grant fields');
  }
}

class _SnapshotBudget {
  int items = 0;
  int bytes = 0;
}

Object? _freeze(Object? value, int depth, _SnapshotBudget budget) {
  if (depth > cborMaxDepth || ++budget.items > cborMaxItems) {
    throw const WireReject('payload complexity');
  }
  if (value is Uint8List) {
    budget.bytes += value.length;
    if (budget.bytes > maxEnvelopeBytes) throw const WireReject('payload size');
    return Uint8List.fromList(value).asUnmodifiableView();
  }
  if (value is String) {
    if (value.length > maxEnvelopeBytes) throw const WireReject('payload size');
    budget.bytes += utf8.encode(value).length;
    if (budget.bytes > maxEnvelopeBytes) throw const WireReject('payload size');
    return value;
  }
  if (value is List<Object?>) {
    if (value.length > cborMaxItems) {
      throw const WireReject('payload complexity');
    }
    return List<Object?>.unmodifiable(
      value.map((e) => _freeze(e, depth + 1, budget)),
    );
  }
  if (value is Map<Object?, Object?>) {
    if (value.length > cborMaxItems) {
      throw const WireReject('payload complexity');
    }
    final out = <Object, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! int && entry.key is! String) {
        throw const WireReject('payload key');
      }
      final key = _freeze(entry.key, depth + 1, budget)!;
      out[key] = _freeze(entry.value, depth + 1, budget);
    }
    return Map<Object, Object?>.unmodifiable(out);
  }
  if (value == null || value is int || value is bool) return value;
  throw const WireReject('payload type');
}
