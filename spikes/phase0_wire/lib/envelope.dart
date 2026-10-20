import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'cbor_strict.dart';
import 'hpke.dart';

/// Throwaway Phase 0 wire/crypto profile. Not the production package.
const wireVersion = 1;
const clockSkewSeconds = 120;
const maxEnvelopeBytes = 32 * 1024;

abstract final class MsgType {
  static const hello = 1;
  static const offer = 2;
  static const answer = 3;
  static const candidate = 4;
  static const announce = 5;
  static const bye = 6;
  static const ack = 7;
  static const sealed = 0x0100;
  static const known = {hello, offer, answer, candidate, announce, bye, ack};
}

class WireReject implements Exception {
  const WireReject(this.reason);
  final String reason;
  @override
  String toString() => 'WireReject: $reason';
}

Uint8List _cat(List<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  parts.forEach(b.add);
  return b.toBytes();
}

final _ed = Ed25519();

/// nodeId = SHA-256("vault/v1/node-id" || ed25519PublicKey).
Future<Uint8List> nodeIdOf(List<int> edPublicKey) async {
  final h = await Sha256().hash(
    _cat([ascii.encode('vault/v1/node-id'), edPublicKey]),
  );
  return Uint8List.fromList(h.bytes);
}

String nodeIdText(List<int> nodeId) => _base32(nodeId);

const _b32 = 'abcdefghijklmnopqrstuvwxyz234567';
String _base32(List<int> data) {
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final byte in data) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out.write(_b32[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_b32[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

class Identity {
  Identity._(
    this.signingPair,
    this.signingPublic,
    this.encryption,
    this.nodeId,
  );

  final SimpleKeyPair signingPair;
  final Uint8List signingPublic;
  final HpkeKeyPair encryption;
  final Uint8List nodeId;

  static Future<Identity> fromSeeds(
    Uint8List signingSeed,
    Uint8List encryptionIkm,
  ) async {
    final pair = await _ed.newKeyPairFromSeed(signingSeed);
    final pub = Uint8List.fromList((await pair.extractPublicKey()).bytes);
    return Identity._(
      pair,
      pub,
      await hpkeDeriveKeyPair(encryptionIkm),
      await nodeIdOf(pub),
    );
  }

  static Future<Identity> generate() async {
    final pair = await _ed.newKeyPair();
    final seed = Uint8List.fromList(await pair.extractPrivateKeyBytes());
    final enc = await hpkeNewKeyPair();
    return fromSeeds(seed, enc.privateKey);
  }

  Future<Uint8List> sign(List<int> message) async {
    final s = await _ed.sign(message, keyPair: signingPair);
    return Uint8List.fromList(s.bytes);
  }

  /// Vault-signed binding of the encryption key to this identity.
  Future<KeyBinding> binding({required int issuedAt}) async {
    final body = cborEncode({
      1: signingPublic,
      2: encryption.publicKey,
      3: issuedAt,
    });
    final sig = await sign(
      _cat([ascii.encode('vault/v1/key-binding\x00'), body]),
    );
    return KeyBinding(signingPublic, encryption.publicKey, issuedAt, sig);
  }
}

Future<bool> verifyEd25519(
  List<int> publicKey,
  List<int> message,
  List<int> signature,
) {
  if (publicKey.length != 32 || signature.length != 64) {
    return Future.value(false);
  }
  return _ed.verify(
    message,
    signature: Signature(
      signature,
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
    ),
  );
}

class KeyBinding {
  KeyBinding(
    this.signingKey,
    this.encryptionKey,
    this.issuedAt,
    this.signature,
  );
  final Uint8List signingKey;
  final Uint8List encryptionKey;
  final int issuedAt;
  final Uint8List signature;

  Future<bool> verify() {
    final body = cborEncode({1: signingKey, 2: encryptionKey, 3: issuedAt});
    return verifyEd25519(
      signingKey,
      _cat([ascii.encode('vault/v1/key-binding\x00'), body]),
      signature,
    );
  }
}

class Envelope {
  Envelope({
    required this.type,
    required this.sender,
    required this.recipient,
    required this.messageId,
    required this.sessionId,
    required this.issuedAt,
    required this.expiresAt,
    required this.iceGeneration,
    required this.payload,
  });

  final int type;
  final Uint8List sender;
  final Uint8List? recipient;
  final Uint8List messageId;
  final Uint8List sessionId;
  final int issuedAt;
  final int expiresAt;
  final int iceGeneration;
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

/// Layout: version(1) | type(2) | sender Ed25519 key(32) | signature(64) | CBOR body.
Future<Uint8List> encodeEnvelope(Identity from, Envelope e) async {
  final body = cborEncode({
    1: e.recipient,
    2: e.messageId,
    3: e.sessionId,
    4: e.issuedAt,
    5: e.expiresAt,
    6: e.iceGeneration,
    7: e.payload,
  });
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
/// Recipient, session and replay checks need caller state: see [EnvelopeChecks].
Future<Envelope> decodeEnvelope(Uint8List wire, {required int now}) async {
  if (wire.length < 99 + 1 || wire.length > maxEnvelopeBytes) {
    throw const WireReject('size');
  }
  if (wire[0] != wireVersion) throw const WireReject('unknown version');
  final type = (wire[1] << 8) | wire[2];
  if (!MsgType.known.contains(type)) throw const WireReject('unknown type');
  final sender = Uint8List.fromList(wire.sublist(3, 35));
  final sig = wire.sublist(35, 99);
  final body = Uint8List.fromList(wire.sublist(99));
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
    _signedPart(wire[0], type, sender, body),
    sig,
  )) {
    throw const WireReject('bad signature');
  }
  if (expiresAt <= issuedAt || expiresAt - issuedAt > 3600) {
    throw const WireReject('invalid validity window');
  }
  if (now + clockSkewSeconds < issuedAt)
    throw const WireReject('issued in future');
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
  EnvelopeChecks(this.self, {this.maxEntries = 4096});
  final Identity self;
  final int maxEntries;
  final _seen = <String, int>{};

  void accept(Envelope e, {Uint8List? expectedSession, required int now}) {
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

/// Sealed layout: version(1) | type 0x0100 (2) | recipient nodeId(32) | enc(32) | HPKE ciphertext.
/// The sealed plaintext is the complete signed inner envelope.
Future<Uint8List> seal(
  Uint8List innerWire,
  Uint8List recipientNodeId,
  KeyBinding recipient,
) async {
  if (!await recipient.verify() ||
      !_equal(await nodeIdOf(recipient.signingKey), recipientNodeId)) {
    throw const WireReject('recipient key binding invalid');
  }
  final header = [wireVersion, MsgType.sealed >> 8, MsgType.sealed & 0xff];
  final sealed = await hpkeSeal(
    recipientPublicKey: recipient.encryptionKey,
    info: _cat([ascii.encode('vault/v1/sealed\x00'), recipientNodeId]),
    aad: _cat([header, recipientNodeId]),
    plaintext: innerWire,
  );
  return _cat([header, recipientNodeId, sealed.enc, sealed.ciphertext]);
}

Future<Uint8List> open(Uint8List outer, Identity self) async {
  if (outer.length < 67 + 16 || outer.length > maxEnvelopeBytes + 128) {
    throw const WireReject('size');
  }
  if (outer[0] != wireVersion) throw const WireReject('unknown version');
  if (((outer[1] << 8) | outer[2]) != MsgType.sealed) {
    throw const WireReject('not sealed');
  }
  final to = outer.sublist(3, 35);
  if (!_equal(to, self.nodeId)) throw const WireReject('wrong recipient');
  try {
    return await hpkeOpen(
      recipient: self.encryption,
      enc: Uint8List.fromList(outer.sublist(35, 67)),
      info: _cat([ascii.encode('vault/v1/sealed\x00'), self.nodeId]),
      aad: _cat([outer.sublist(0, 3), to]),
      ciphertext: outer.sublist(67),
    );
  } on Object {
    throw const WireReject('decryption failed');
  }
}

/// Owner-minted grant: HMAC-SHA256 over the domain-separated canonical encoding.
class Grant {
  Grant({
    required this.version,
    required this.ownerId,
    required this.viewerId,
    required this.grantId,
    required this.resource,
    required this.actions,
    required this.issuedAt,
    required this.expiresAt,
    required this.epoch,
  });

  final int version;
  final Uint8List ownerId;
  final Uint8List viewerId;
  final Uint8List grantId;
  final String resource;
  final List<String> actions;
  final int issuedAt;
  final int expiresAt;
  final int epoch;

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

  Future<Uint8List> mac(Uint8List mintingKey) async {
    final m = await Hmac.sha256().calculateMac(
      _cat([ascii.encode('vault/v1/grant\x00'), canonical()]),
      secretKey: SecretKey(mintingKey),
    );
    return Uint8List.fromList(m.bytes);
  }
}

class OwnerState {
  OwnerState(this.mintingKey, this.nodeId, this.epoch);
  final Uint8List mintingKey;
  final Uint8List nodeId;
  int epoch;
  final revoked = <String>{};
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
  if (blockedOrRevoked(owner, grant, authenticatedViewer)) {
    throw const WireReject('revoked or blocked');
  }
  if (grant.version != 1 ||
      !_equal(grant.ownerId, owner.nodeId) ||
      !_equal(grant.viewerId, authenticatedViewer)) {
    throw const WireReject('identity mismatch');
  }
  final expected = await grant.mac(owner.mintingKey);
  if (!_equal(expected, mac)) throw const WireReject('bad mac');
  if (grant.epoch != owner.epoch) throw const WireReject('stale epoch');
  if (now >= grant.expiresAt || now < grant.issuedAt) {
    throw const WireReject('outside validity');
  }
  if (grant.resource != resource || !grant.actions.contains(action)) {
    throw const WireReject('out of scope');
  }
}

bool blockedOrRevoked(OwnerState owner, Grant g, Uint8List viewer) =>
    owner.blocked.contains(base64.encode(viewer)) ||
    owner.revoked.contains(base64.encode(g.grantId));
