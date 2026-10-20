import 'dart:convert';
import 'dart:typed_data';

import 'package:vault_protocol/vault_protocol.dart';

/// The complete application signaling allowlist. No arbitrary control/media map.
void validateSignalPayload(
  int type,
  Map<Object, Object?> payload, {
  required int now,
  bool internalAck = false,
}) {
  bool keys(Set<String> allowed, Set<String> required) =>
      payload.keys.every(allowed.contains) &&
      required.every(payload.containsKey);
  bool text(Object? value, int max, {bool empty = false}) =>
      value is String &&
      (empty || value.isNotEmpty) &&
      value.length <= max &&
      utf8.encode(value).length <= max;
  var valid = false;
  switch (type) {
    case MsgType.offer:
    case MsgType.answer:
      valid = keys({'sdp'}, {'sdp'}) && text(payload['sdp'], 20 * 1024);
    case MsgType.candidate:
      valid =
          keys({'candidate', 'sdpMid', 'sdpMLineIndex'}, {'candidate'}) &&
          text(payload['candidate'], 2048, empty: true) &&
          (payload['sdpMid'] == null ||
              text(payload['sdpMid'], 64, empty: true)) &&
          (payload['sdpMLineIndex'] == null ||
              (payload['sdpMLineIndex'] is int &&
                  (payload['sdpMLineIndex']! as int) >= 0 &&
                  (payload['sdpMLineIndex']! as int) <= 255));
    case MsgType.hello:
      valid =
          keys({'nonce'}, {'nonce'}) &&
          payload['nonce'] is Uint8List &&
          (payload['nonce']! as Uint8List).length == 32;
    case MsgType.bye:
      valid =
          keys({'reason'}, {}) &&
          (payload['reason'] == null ||
              text(payload['reason'], 160, empty: true));
    case MsgType.announce:
      final expires = payload['expires'];
      valid =
          keys(
            {'presence', 'name', 'expires'},
            {'presence', 'name', 'expires'},
          ) &&
          payload['presence'] == true &&
          text(payload['name'], 80, empty: true) &&
          expires is int &&
          expires > now &&
          expires <= now + 90;
    case MsgType.introduce:
      valid =
          keys({'card', 'mac'}, {'card', 'mac'}) &&
          text(payload['card'], maxIntroductionCardBytes) &&
          payload['mac'] is Uint8List &&
          (payload['mac']! as Uint8List).length == 32;
    case MsgType.ack:
      valid =
          internalAck &&
          payload.length == 1 &&
          payload[1] is Uint8List &&
          (payload[1]! as Uint8List).length == 16;
  }
  if (!valid) throw const WireReject('signaling payload schema');
}
