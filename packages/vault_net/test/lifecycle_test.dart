import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_net/vault_net.dart';
import 'package:vault_signaling/vault_signaling.dart';

/// Holds the current trusted-contact lookup at the pre-allocation await.
/// Initial mesh authentication still verifies the real contact signature.
class _DelayedResolver {
  new(this.binding);
  final KeyBinding binding;
  final entered = Completer<void>();
  final release = Completer<void>();
  final finished = Completer<void>();
  int calls = 0;

  Future<KeyBinding?> resolve(String _) async {
    final call = ++calls;
    if (call == 2) {
      entered.complete();
      await release.future;
    }
    if (call == 2) finished.complete();
    return binding;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('disconnect prevents allocation after trust verification', () async {
    final alice = await Identity.generate();
    final bob = await Identity.generate();
    final contact = await ContactCard.create(bob, name: 'Bob');
    final binding = contact.binding;
    final resolver = _DelayedResolver(binding);
    final signaling = SignalingClient(
      identity: alice,
      strategy: ManualSignaling(),
      resolveBinding: (_) async => binding,
    );
    final savedDisconnects = [contact.nodeId];
    final mesh = PeerMesh(
      identity: alice,
      signaling: signaling,
      resolveBinding: resolver.resolve,
      stunUrls: [],
      initiallyDisconnectedPeerIds: savedDisconnects,
    );
    savedDisconnects.clear();
    expect(mesh.disconnectedPeerIds, {contact.nodeId});
    expect(() => mesh.disconnectedPeerIds.clear(), throwsUnsupportedError);
    var nativeCalls = 0;
    const channel = MethodChannel('FlutterWebRTC.Method');
    // This is a forbidden-call tripwire, not a fake transport: no RTC result or
    // forwarded packet is supplied, and authentication/crypto stay real.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          ..setMockMethodCallHandler(channel, (_) async {
            nativeCalls++;
            throw StateError(
              'Native factory invoked after explicit disconnect',
            );
          });
    try {
      final session = await mesh.connect(contact);
      expect(
        mesh.disconnectedPeerIds,
        isEmpty,
        reason: 'only explicit connect clears the restored disconnect intent',
      );
      await resolver.entered.future.timeout(const Duration(seconds: 5));
      Future<void>? repeatedClose;
      final terminalSeen = Completer<void>();
      final states = session.states.listen((state) {
        if (state == PeerSessionState.closed) {
          repeatedClose = session.close();
          terminalSeen.complete();
        }
      });
      final closing = session.close();
      await terminalSeen.future.timeout(const Duration(seconds: 5));
      expect(identical(closing, repeatedClose), isTrue);
      await closing;
      await states.cancel();
      resolver.release.complete();
      await resolver.finished.future.timeout(const Duration(seconds: 5));
      // Drain continuations after the controlled trusted-contact lookup.
      await Future<void>.delayed(Duration.zero);
      expect(session.state, PeerSessionState.closed);
      expect(mesh.disconnectedPeerIds, {contact.nodeId});
      expect(nativeCalls, 0);
    } finally {
      if (!resolver.release.isCompleted) resolver.release.complete();
      await mesh.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
