import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault/production/vault_runtime.dart';
import 'package:vault_identity/vault_identity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const availability = MethodChannel('dev.vault/availability');
  late Directory root;
  late VaultRuntime runtime;
  late ContactCard phone;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          availability,
          (call) async => {
            'supported': true,
            'platform': Platform.operatingSystem,
            'publishing': false,
            'autostart': false,
            'canAutostart': false,
            'canMinimizeToTray': false,
            'backgroundMode': 'test',
            'wakeLockHeld': false,
            'detail': null,
          },
        );
    root = await Directory.systemTemp.createTemp('vault-pairing-runtime-');
    runtime = await VaultRuntime.load(
      store: _Store(),
      preferences: _Preferences(),
      root: root,
    );
    phone = await ContactCard.create(await Identity.generate(), name: 'Phone');
  });

  tearDown(() async {
    try {
      await runtime.close();
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(availability, null);
      await root.delete(recursive: true);
    }
  });

  test('approving a pairing adds the phone and dials it', () async {
    await runtime.saveConfig(
      runtime.config.copyWith(disconnectedPeerIds: {phone.nodeId}),
    );
    runtime.pairingRequest = phone;
    await runtime.approvePairing();
    expect(runtime.contacts.map((card) => card.nodeId), [phone.nodeId]);
    expect(runtime.pairingRequest, isNull);
    expect(
      runtime.sessions[phone.nodeId],
      isNotNull,
      reason: 'The scanner waits for the host to dial',
    );
    expect(runtime.config.disconnectedPeerIds, isEmpty);
  });

  test(
    'allowing a disconnected host clears the block without dialing',
    () async {
      await runtime.addContact(phone);
      await runtime.saveConfig(
        runtime.config.copyWith(disconnectedPeerIds: {phone.nodeId}),
      );
      await runtime.start();
      expect(runtime.mesh!.disconnectedPeerIds, {phone.nodeId});
      await runtime.allowConnections(phone);
      expect(runtime.config.disconnectedPeerIds, isEmpty);
      expect(runtime.mesh!.disconnectedPeerIds, isEmpty);
      expect(runtime.sessions, isEmpty);
    },
  );
}

class _Preferences extends Fake implements SharedPreferencesAsync {
  final values = <String, String>{};

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }
}

class _Store implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
