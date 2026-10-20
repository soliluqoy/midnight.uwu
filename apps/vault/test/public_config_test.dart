import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/production/public_config.dart';

void main() {
  test('public configuration round-trips without secret fields', () {
    const config = PublicConfig(
      name: 'Owner',
      transport: 'mqtt',
      brokerHost: 'broker.example',
      dark: true,
    );
    final restored = PublicConfig.decode(config.encode());
    expect(restored.name, 'Owner');
    expect(restored.transport, 'mqtt');
    expect(restored.brokerHost, 'broker.example');
    expect(restored.brokerPort, 8883);
    expect(restored.dark, isTrue);
    expect((jsonDecode(config.encode()) as Map<String, Object?>).keys.toSet(), {
      'version',
      'name',
      'transport',
      'brokerHost',
      'brokerPort',
      'dark',
      'disconnectedPeerIds',
    });
  });

  test('the internet preset is explicit, public-only and keeps '
      'other preferences', () {
    final peerId = 'a' * 52;
    final existing = PublicConfig(
      name: 'Owner',
      dark: true,
      disconnectedPeerIds: {peerId},
    );
    expect(const PublicConfig().transport, 'manual');
    expect(const PublicConfig().usesInternetPreset, isFalse);
    expect(PublicConfig.decode(existing.encode()).transport, 'manual');

    final preset = PublicConfig.decode(existing.withInternetPreset().encode());
    expect(preset.usesInternetPreset, isTrue);
    expect(preset.transport, 'mqtt');
    expect(preset.brokerHost, 'broker.emqx.io');
    expect(preset.brokerPort, 8883);
    expect(preset.name, 'Owner');
    expect(preset.dark, isTrue);
    expect(preset.disconnectedPeerIds, {peerId});
    expect(
      (jsonDecode(preset.encode()) as Map<String, Object?>).keys.toSet(),
      (jsonDecode(existing.encode()) as Map<String, Object?>).keys.toSet(),
    );
    expect(
      preset.copyWith(brokerHost: 'broker.example').usesInternetPreset,
      isFalse,
    );
    expect(preset.copyWith(transport: 'manual').usesInternetPreset, isFalse);
  });

  test('explicit disconnect policy survives exports and rejects '
      'malformed fingerprints', () {
    final peerId = 'a' * 52;
    final config = PublicConfig(disconnectedPeerIds: {peerId});
    expect(PublicConfig.decode(config.encode()).disconnectedPeerIds, {peerId});
    final fields = jsonDecode(config.encode()) as Map<String, Object?>;
    expect(
      () => PublicConfig.decode(
        jsonEncode({
          ...fields,
          'disconnectedPeerIds': ['not-a-fingerprint'],
        }),
      ),
      throwsFormatException,
    );
    expect(
      () => PublicConfig.decode(
        jsonEncode({
          ...fields,
          'disconnectedPeerIds': [peerId, peerId],
        }),
      ),
      throwsFormatException,
    );
  });

  test('private or unknown import fields are rejected, not persisted', () {
    final fields =
        jsonDecode(const PublicConfig().encode()) as Map<String, dynamic>;
    for (final key in [
      'signingSeed',
      'privateKey',
      'authorization',
      'password',
    ]) {
      expect(
        () => PublicConfig.decode(jsonEncode({...fields, key: 'secret'})),
        throwsFormatException,
      );
    }
  });

  test('invalid transport, endpoint and oversized input fail closed', () {
    final fields =
        jsonDecode(const PublicConfig().encode()) as Map<String, dynamic>;
    for (final patch in <Map<String, Object?>>[
      {'transport': 'simulation'},
      {'brokerPort': 0},
      {'brokerPort': 65536},
      {'transport': 'mqtt', 'brokerHost': ''},
      {'brokerHost': 'mqtt://broker'},
      {'dark': 'true'},
      {'name': ''},
      {'version': 2},
    ]) {
      expect(
        () => PublicConfig.decode(jsonEncode({...fields, ...patch})),
        throwsFormatException,
      );
    }
    expect(
      () => PublicConfig.decode('x' * (256 * 1024 + 1)),
      throwsFormatException,
    );
  });
}
