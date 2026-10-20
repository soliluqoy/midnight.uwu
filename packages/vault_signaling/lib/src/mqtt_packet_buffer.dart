import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:typed_data/typed_buffers.dart';

/// Full MQTT packet bound, allowing 24 KiB ciphertext plus bounded framing.
const int maxMqttPacketBytes = 26 * 1024;

/// Rejects oversized Remaining Length before library packet accumulation.
///
/// Header state is independent of parser reads/shrinks. A coalesced network chunk
/// is also bounded before copying, preventing many partial valid packets from
/// expanding the dependency's backing buffer without limit.
class BoundedMqttPacketBuffer extends MqttByteBuffer {
  /// Starts with no buffered input and no partially parsed header.
  new() : super(Uint8Buffer());
  int _bodyRemaining = 0;
  int _headerBytes = 0;
  int _declared = 0;
  int _multiplier = 1;
  bool _needsFixedHeader = true;

  @override
  void addAll(List<int> data) {
    if (length + data.length > 2 * maxMqttPacketBytes) {
      throw const FormatException('MQTT buffered input limit');
    }
    for (final byte in data) {
      if (_bodyRemaining > 0) {
        _bodyRemaining--;
        if (_bodyRemaining == 0) _needsFixedHeader = true;
        continue;
      }
      if (_needsFixedHeader) {
        if ((byte >> 4) == 0 || (byte >> 4) == 15) {
          throw const FormatException('Invalid MQTT packet header');
        }
        if ((byte >> 4) == 3 && ((byte >> 1) & 3) > 1) {
          throw const FormatException('MQTT publish exceeds subscribed QoS1');
        }
        _needsFixedHeader = false;
        _headerBytes = 0;
        _declared = 0;
        _multiplier = 1;
        continue;
      }
      _headerBytes++;
      _declared += (byte & 127) * _multiplier;
      if (_declared + _headerBytes + 1 > maxMqttPacketBytes ||
          _headerBytes > 4 ||
          (_headerBytes == 4 && (byte & 128) != 0)) {
        throw const FormatException('MQTT declared packet size limit');
      }
      if ((byte & 128) == 0) {
        if (_headerBytes > 1 && byte == 0) {
          throw const FormatException('Noncanonical MQTT remaining length');
        }
        _bodyRemaining = _declared;
        if (_bodyRemaining == 0) _needsFixedHeader = true;
      } else {
        _multiplier *= 128;
      }
    }
    super.addAll(data);
  }
}
