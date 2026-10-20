import 'package:flutter_test/flutter_test.dart';
import 'package:vault_net/src/webrtc_adapter.dart';

void main() {
  test('native ephemeral init preserves unordered zero retransmissions', () {
    final configuration = EphemeralInit().toMap();
    expect(configuration['ordered'], isFalse);
    expect(configuration['maxRetransmits'], 0);
    expect(
      experimentalHotspot,
      isFalse,
      reason: 'standard tests must not enable the experimental hotspot factory',
    );
  });
}
