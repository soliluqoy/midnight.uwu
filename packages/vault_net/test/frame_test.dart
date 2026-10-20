import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_net/src/frame.dart';
import 'package:vault_net/src/policy.dart';

void main() {
  test('maximum payload includes framing in the 16KiB wire limit', () {
    final bytes = PeerFrame.encode(16, 7, Uint8List(maxPeerPayloadBytes));
    expect(bytes.length, maxPacketBytes);
    final frame = PeerFrame.decode(bytes);
    expect(frame.generation, 7);
    expect(frame.body.length, maxPeerPayloadBytes);
    expect(frame.isCurrent(7), isTrue);
    expect(
      () => PeerFrame.encode(16, 7, Uint8List(maxPeerPayloadBytes + 1)),
      throwsA(isA<PeerFailure>()),
    );
    expect(
      () => PeerFrame.decode(Uint8List(maxPacketBytes + 1)),
      throwsA(isA<PeerFailure>()),
    );
  });

  test('old SCTP bytes cannot cross restart or paused-generation boundary', () {
    for (final type in [1, 2, 3, 16]) {
      final old = PeerFrame.decode(PeerFrame.encode(type, 1, Uint8List(0)));
      expect(old.isCurrent(2), isFalse);
      expect(old.isCurrent(1, pausedGeneration: 1), isFalse);
      expect(old.isCurrent(1), isTrue);
      expect(() => old.isCurrent(0), throwsA(isA<PeerFailure>()));
    }
  });

  test('invalid type, missing header and generation overflow are rejected', () {
    expect(() => PeerFrame.decode(Uint8List(4)), throwsA(isA<PeerFailure>()));
    expect(() => PeerFrame.decode(Uint8List(5)), throwsA(isA<PeerFailure>()));
    expect(
      () => PeerFrame.encode(255, 0, Uint8List(0)),
      throwsA(isA<PeerFailure>()),
    );
    expect(
      () => PeerFrame.encode(16, -1, Uint8List(0)),
      throwsA(isA<PeerFailure>()),
    );
    expect(
      () => PeerFrame.encode(16, 0x100000000, Uint8List(0)),
      throwsA(isA<PeerFailure>()),
    );
  });

  test(
    'enqueue frame takes ownership without trusting later caller mutation',
    () {
      final payload = Uint8List.fromList([1, 2, 3]);
      final frame = PeerFrame.encode(16, 0, payload);
      payload[0] = 99;
      expect(PeerFrame.decode(frame).body, [1, 2, 3]);
    },
  );
}
