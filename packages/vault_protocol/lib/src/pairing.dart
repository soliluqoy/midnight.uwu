import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_protocol/src/codec/cbor_strict.dart';
import 'package:vault_protocol/src/envelope.dart';

/// Text form prefix of a pairing invite shown as a QR code or pasted.
const pairingInvitePrefix = 'vault-pair:1:';

/// Longest accepted invite text, before any decoding.
const maxPairingInviteChars = 1024;

/// How long a host's pairing code stays valid.
const pairingLifetimeSeconds = 600;

/// Longest accepted contact text inside an introduction.
const maxIntroductionCardBytes = 2048;

final _hostPattern = RegExp(
  r'^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
  r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$',
);

/// The invite was well formed but its validity window has ended.
class PairingCodeExpired implements Exception {
  /// Reports an expired invite.
  const new();
  @override
  String toString() => 'This pairing code has expired. Ask for a new one.';
}

/// A host's verified contact, its signaling broker and a one-time secret.
class PairingInvite {
  /// Snapshots [token]; use [parse] for untrusted text.
  new({
    required this.card,
    required this.brokerHost,
    required this.brokerPort,
    required Uint8List token,
    required this.expiresAt,
  }) : token = Uint8List.fromList(token).asUnmodifiableView();

  /// The host's public contact; its key binding is verified.
  final ContactCard card;

  /// TLS MQTT broker hostname both devices use for connection setup.
  final String brokerHost;

  /// TLS MQTT broker port.
  final int brokerPort;

  /// 32 random bytes known only to the host and whoever sees this code.
  final Uint8List token;

  /// End of validity in Unix seconds.
  final int expiresAt;

  /// Canonical `vault-pair:1:<base64url CBOR>` text for a QR code.
  String encode() {
    final binding = card.binding;
    return pairingInvitePrefix +
        base64Url.encode(
          cborEncode({
            1: {
              1: card.name,
              2: binding.signingKey,
              3: binding.encryptionKey,
              4: binding.issuedAt,
              5: binding.signature,
            },
            2: brokerHost,
            3: brokerPort,
            4: token,
            5: expiresAt,
          }),
        );
  }

  /// Strictly parses untrusted invite text and verifies its contact.
  ///
  /// Throws [PairingCodeExpired] for a stale code and [FormatException] for
  /// anything else that is not exactly a valid invite.
  static Future<PairingInvite> parse(String text, {required int now}) async {
    const invalid = FormatException('Not a valid Midnight pairing code.');
    final trimmed = text.trim();
    if (trimmed.length > maxPairingInviteChars ||
        !trimmed.startsWith(pairingInvitePrefix)) {
      throw invalid;
    }
    final encoded = trimmed.substring(pairingInvitePrefix.length);
    final Object? decoded;
    try {
      final bytes = base64Url.decode(encoded);
      if (base64Url.encode(bytes) != encoded) throw invalid;
      decoded = cborDecode(bytes);
    } on Object {
      throw invalid;
    }
    if (decoded is! Map<Object, Object?> || !_exactKeys(decoded, 5)) {
      throw invalid;
    }
    final cardMap = decoded[1];
    final host = decoded[2];
    final port = decoded[3];
    final token = decoded[4];
    final expiresAt = decoded[5];
    if (cardMap is! Map<Object, Object?> ||
        !_exactKeys(cardMap, 5) ||
        cardMap[1] is! String ||
        !_bytes(cardMap[2], 32) ||
        !_bytes(cardMap[3], 32) ||
        cardMap[4] is! int ||
        (cardMap[4]! as int) < 0 ||
        !_bytes(cardMap[5], 64) ||
        host is! String ||
        !_hostPattern.hasMatch(host) ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        !_bytes(token, 32) ||
        expiresAt is! int) {
      throw invalid;
    }
    if (expiresAt > now + pairingLifetimeSeconds + clockSkewSeconds) {
      throw invalid;
    }
    if (expiresAt <= now) throw const PairingCodeExpired();
    final ContactCard card;
    try {
      card = await ContactCard.fromBinding(
        KeyBinding(
          cardMap[2]! as Uint8List,
          cardMap[3]! as Uint8List,
          cardMap[4]! as int,
          cardMap[5]! as Uint8List,
        ),
        name: cardMap[1]! as String,
      );
    } on FormatException {
      throw invalid;
    }
    return PairingInvite(
      card: card,
      brokerHost: host,
      brokerPort: port,
      token: token! as Uint8List,
      expiresAt: expiresAt,
    );
  }
}

bool _exactKeys(Map<Object, Object?> map, int count) =>
    map.length == count &&
    List.generate(count, (i) => i + 1).every(map.containsKey);

bool _bytes(Object? value, int length) =>
    value is Uint8List && value.length == length;

/// HMAC-SHA256(token, "vault-introduce-v1" ‖ recipient nodeId ‖ card bytes).
Future<Uint8List> introductionMac({
  required List<int> token,
  required List<int> recipientNodeId,
  required List<int> cardBytes,
}) async {
  if (token.length != 32 || recipientNodeId.length != 32) {
    throw const WireReject('introduction key or recipient');
  }
  final mac = await Hmac.sha256().calculateMac([
    ...ascii.encode('vault-introduce-v1'),
    ...recipientNodeId,
    ...cardBytes,
  ], secretKey: SecretKey(List<int>.of(token)));
  return Uint8List.fromList(mac.bytes);
}

/// A scanner's contact and proof that it saw the host's pairing code.
class Introduction {
  new _(this.card, this.cardText, Uint8List mac)
    : mac = Uint8List.fromList(mac).asUnmodifiableView();

  /// The scanner's verified public contact.
  final ContactCard card;

  /// Exact contact text whose UTF-8 bytes the MAC covers.
  final String cardText;

  /// [introductionMac] under the invite token.
  final Uint8List mac;

  /// Proves possession of [invite]'s token for [card].
  static Future<Introduction> create({
    required ContactCard card,
    required PairingInvite invite,
  }) async {
    final text = await card.encode();
    return Introduction._(
      card,
      text,
      await introductionMac(
        token: invite.token,
        recipientNodeId: nodeIdFromText(invite.card.nodeId),
        cardBytes: utf8.encode(text),
      ),
    );
  }

  /// Parses a schema-checked `introduce` payload signed by [sender].
  ///
  /// The contact must verify and its signing key must be the envelope signer.
  static Future<Introduction> fromPayload(
    Map<Object, Object?> payload, {
    required List<int> sender,
  }) async {
    final text = payload['card'];
    final mac = payload['mac'];
    if (text is! String ||
        utf8.encode(text).length > maxIntroductionCardBytes ||
        !_bytes(mac, 32)) {
      throw const WireReject('introduction payload');
    }
    final ContactCard card;
    try {
      card = await ContactCard.decode(text);
    } on FormatException {
      throw const WireReject('introduction contact');
    }
    if (!_constantTimeEquals(card.binding.signingKey, sender)) {
      throw const WireReject('introduction contact is not the signer');
    }
    return Introduction._(card, text, mac! as Uint8List);
  }

  /// The `introduce` signaling payload.
  Map<Object, Object?> toPayload() => {'card': cardText, 'mac': mac};
}

/// The host's one in-memory pairing secret. Never persist it.
class ActivePairing {
  new _(this.token, this.expiresAt);

  /// Creates a fresh single-use secret valid for [pairingLifetimeSeconds].
  factory start({required int now}) =>
      ActivePairing._(secureRandomBytes(32), now + pairingLifetimeSeconds);

  /// Secret placed in the invite.
  final Uint8List token;

  /// End of validity in Unix seconds.
  final int expiresAt;
  bool _used = false;

  /// Whether an introduction already consumed this secret.
  bool get used => _used;

  /// The invite a scanner needs, carrying this pairing's secret.
  PairingInvite invite(
    ContactCard host, {
    required String brokerHost,
    required int brokerPort,
  }) => PairingInvite(
    card: host,
    brokerHost: brokerHost,
    brokerPort: brokerPort,
    token: token,
    expiresAt: expiresAt,
  );

  /// Consumes this secret if [introduction] proves it and it is still valid.
  ///
  /// A wrong MAC does not consume it, so noise cannot cancel a pairing.
  Future<bool> redeem(
    Introduction introduction, {
    required List<int> recipientNodeId,
    required int now,
  }) async {
    if (_used || now >= expiresAt) return false;
    final expected = await introductionMac(
      token: token,
      recipientNodeId: recipientNodeId,
      cardBytes: utf8.encode(introduction.cardText),
    );
    if (_used || !_constantTimeEquals(expected, introduction.mac)) {
      return false;
    }
    _used = true;
    return true;
  }
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}
