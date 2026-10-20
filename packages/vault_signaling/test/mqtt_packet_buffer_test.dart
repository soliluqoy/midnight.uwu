import 'package:test/test.dart';
import 'package:vault_signaling/src/mqtt_packet_buffer.dart';

void main() {
  test(
    'oversized fragmented Remaining Length rejected before body allocation',
    () {
      final buffer = BoundedMqttPacketBuffer()..addAll([0x30, 0xff]);
      expect(buffer.length, 2);
      // Declares 2,097,151 bytes without a body. The dependency would retain
      // this partial packet and keep accumulating attacker bytes.
      expect(() => buffer.addAll([0xff, 0x7f]), throwsFormatException);
      expect(buffer.length, 2);
    },
  );

  test('oversized coalesced declared header rejected before copying input', () {
    final buffer = BoundedMqttPacketBuffer();
    expect(
      () => buffer.addAll([0x30, 0xff, 0xff, 0xff, 0x7f]),
      throwsFormatException,
    );
    expect(buffer.length, 0);
  });

  test('aggregate input cap enforced before library backing buffer growth', () {
    final buffer = BoundedMqttPacketBuffer();
    final manyPings = List<int>.generate(
      2 * maxMqttPacketBytes + 2,
      (index) => index.isEven ? 0xd0 : 0,
    );
    expect(() => buffer.addAll(manyPings), throwsFormatException);
    expect(buffer.length, 0);
  });

  test('normal coalesced and fragmented MQTT packets pass to real parser', () {
    final buffer = BoundedMqttPacketBuffer()..addAll([0xd0]);
    expect(buffer.length, 1);
    buffer.addAll([0, 0xd0, 0]);
    expect(buffer.length, 4);
    expect(buffer.isMessageAvailable(), isTrue);
    buffer
      ..skipBytes = 2
      ..shrink();
    expect(buffer.isMessageAvailable(), isTrue);
    buffer
      ..skipBytes = 2
      ..shrink();
    expect(buffer.length, 0);
    buffer
      ..addAll([0x30, 1])
      ..addAll([0]);
    expect(buffer.length, 3);
  });

  test('QoS2 packets rejected before growing dependency receive queues', () {
    final buffer = BoundedMqttPacketBuffer();
    expect(() => buffer.addAll([0x34]), throwsFormatException);
    expect(buffer.length, 0);
  });
}
