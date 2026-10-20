import 'dart:convert';

import 'package:vault_identity/vault_identity.dart' show nodeIdFromText;

/// Only public, user-entered preferences belong here. Never add key material.
class PublicConfig {
  const new({
    this.name = 'My Midnight',
    this.transport = 'manual',
    this.brokerHost = '',
    this.brokerPort = 8883,
    this.dark = false,
    this.disconnectedPeerIds = const {},
  });
  factory decode(String text) {
    if (text.length > 256 * 1024) {
      throw const FormatException('Configuration too large.');
    }
    final json = jsonDecode(text);
    if (json is! Map<String, dynamic> ||
        json['version'] != 1 ||
        json.keys.any(
          (key) => !const {
            'version',
            'name',
            'transport',
            'brokerHost',
            'brokerPort',
            'dark',
            'disconnectedPeerIds',
          }.contains(key),
        )) {
      throw const FormatException('Not a public Midnight configuration.');
    }
    final name = json['name'];
    final transport = json['transport'];
    final host = json['brokerHost'];
    final port = json['brokerPort'];
    final dark = json['dark'];
    if (name is! String ||
        name.length > 128 ||
        utf8.encode(name).length > 128 ||
        name.codeUnits.any((code) => code < 32 || code == 127) ||
        name.trim().isEmpty ||
        (transport != 'manual' && transport != 'mqtt') ||
        host is! String ||
        host.length > 253 ||
        host.contains(RegExp(r'[\s/:]')) ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        dark is! bool ||
        (transport == 'mqtt' && host.isEmpty)) {
      throw const FormatException('Invalid name or TLS broker configuration.');
    }
    final rawDisconnected = json['disconnectedPeerIds'] ?? const <Object?>[];
    if (rawDisconnected is! List<Object?> || rawDisconnected.length > 4096) {
      throw const FormatException('Invalid explicit-disconnect policy.');
    }
    final disconnected = <String>{};
    for (final value in rawDisconnected) {
      if (value is! String) {
        throw const FormatException('Invalid disconnected fingerprint.');
      }
      nodeIdFromText(value);
      if (!disconnected.add(value)) {
        throw const FormatException('Duplicate disconnected fingerprint.');
      }
    }
    return PublicConfig(
      name: name.trim(),
      transport: transport as String,
      brokerHost: host,
      brokerPort: port,
      dark: dark,
      disconnectedPeerIds: Set.unmodifiable(disconnected),
    );
  }

  /// Third-party public broker used only after the person chooses the
  /// internet preset. It passed the Phase 0 public TLS MQTT 5 probe.
  static const internetBrokerHost = 'broker.emqx.io';
  static const internetBrokerPort = 8883;

  final String name;
  final String transport;
  final String brokerHost;
  final int brokerPort;
  final bool dark;
  final Set<String> disconnectedPeerIds;

  PublicConfig copyWith({
    String? name,
    String? transport,
    String? brokerHost,
    int? brokerPort,
    bool? dark,
    Set<String>? disconnectedPeerIds,
  }) => PublicConfig(
    name: name ?? this.name,
    transport: transport ?? this.transport,
    brokerHost: brokerHost ?? this.brokerHost,
    brokerPort: brokerPort ?? this.brokerPort,
    dark: dark ?? this.dark,
    disconnectedPeerIds: disconnectedPeerIds ?? this.disconnectedPeerIds,
  );

  /// This configuration with the internet preset's transport and endpoint.
  PublicConfig withInternetPreset() => copyWith(
    transport: 'mqtt',
    brokerHost: internetBrokerHost,
    brokerPort: internetBrokerPort,
  );

  bool get usesInternetPreset =>
      transport == 'mqtt' &&
      brokerHost == internetBrokerHost &&
      brokerPort == internetBrokerPort;

  String encode() => jsonEncode({
    'version': 1,
    'name': name,
    'transport': transport,
    'brokerHost': brokerHost,
    'brokerPort': brokerPort,
    'dark': dark,
    'disconnectedPeerIds': disconnectedPeerIds.toList()..sort(),
  });
}
