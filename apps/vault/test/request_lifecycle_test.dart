import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault/production/vault_runtime.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_net/vault_net.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.vault/availability');
  late Directory root;
  late VaultRuntime runtime;
  late _Peer peer;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => {
            'supported': true,
            'platform': Platform.operatingSystem,
            'publishing': call.method == 'start',
            'autostart': false,
            'canAutostart': false,
            'canMinimizeToTray': false,
            'backgroundMode': 'test',
            'wakeLockHeld': false,
            'detail': null,
          },
        );
    root = await Directory.systemTemp.createTemp('vault-request-lifecycle-');
    runtime = await VaultRuntime.load(
      store: _Store(),
      preferences: _Preferences(),
      root: root,
    );
    final viewer = await Identity.generate();
    peer = _Peer(nodeIdText(viewer.nodeId));
    await runtime.delivery.setPublishing(true);
  });

  Future<void> closeRuntime() async {
    try {
      if (Platform.isWindows || Platform.isAndroid) {
        await runtime.close();
      } else {
        await expectLater(runtime.close(), throwsUnsupportedError);
      }
    } finally {
      await peer.dispose();
    }
  }

  tearDown(() async {
    try {
      await closeRuntime();
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    }
  });

  test('runtime pending queue follows real expiry without approval '
      'or peer disconnection', () async {
    final clock = FakeAsync();
    var observed = <String>[];
    runtime.addListener(() {
      observed = runtime.requests.map((request) => request.requestId).toList();
    });
    clock.run((_) {
      runtime.delivery.attach(peer);
      peer.request();
    });
    try {
      clock.flushMicrotasks();
      await Future<void>.delayed(Duration.zero);
      expect(runtime.requests, hasLength(1));
      final request = runtime.requests.single;
      expect(observed, [request.requestId]);
      clock.elapse(const Duration(minutes: 1, seconds: 59));
      expect(runtime.requests.single.requestId, request.requestId);
      expect(observed, [request.requestId]);
      clock.elapse(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      expect(runtime.requests, isEmpty);
      expect(observed, isEmpty);
      expect(peer.state, PeerSessionState.connected);
      expect(peer.sent, isEmpty);
      expect(runtime.approvedThisRun, isEmpty);
    } finally {
      // Detach clock-bound listeners before native/storage teardown.
      clock
        ..run((_) => unawaited(peer.close()))
        ..flushMicrotasks();
      await Future<void>.delayed(Duration.zero);
      clock.flushMicrotasks();
    }
  });

  test('runtime pending queue follows actual denial', () async {
    runtime.delivery.attach(peer);
    peer.request();
    await Future<void>.delayed(Duration.zero);
    final request = runtime.requests.single;
    await runtime.deny(request);
    await Future<void>.delayed(Duration.zero);
    expect(runtime.requests, isEmpty);
    expect(peer.state, PeerSessionState.connected);
    expect(peer.sent.single['op'], 'error');
  });
}

class _Preferences extends Fake implements SharedPreferencesAsync {
  @override
  Future<String?> getString(String key) async => null;
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

/// Only the authenticated transport is replaced: runtime, delivery and its
/// two-minute request timer are real.
class _Peer implements PeerSession {
  new(this.peerId);

  @override
  final String peerId;
  @override
  final String sessionId = 'pending-consent-session';
  @override
  PeerSessionState state = PeerSessionState.connected;
  final _packets = StreamController<PeerPacket>(sync: true);
  final _states = StreamController<PeerSessionState>.broadcast(sync: true);
  final sent = <Map<String, Object?>>[];

  @override
  Stream<PeerPacket> get packets => _packets.stream;
  @override
  Stream<PeerSessionState> get states => _states.stream;

  void request() {
    _packets.add(
      PeerPacket.control({
        'vault': 'delivery',
        'op': 'access',
        'id': '0123456789abcdef0123456789abcdef',
      }),
    );
  }

  @override
  Future<void> sendControl(Map<String, Object?> message) async {
    sent.add(message);
  }

  @override
  Future<void> close() async {
    if (state == PeerSessionState.closed) return;
    state = PeerSessionState.closed;
    _states.add(state);
  }

  Future<void> dispose() async {
    await _packets.close();
    await _states.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
