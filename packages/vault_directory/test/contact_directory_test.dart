import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vault_directory/vault_directory.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_protocol/vault_protocol.dart';
import 'package:vault_signaling/vault_signaling.dart';

void main() {
  late Identity aliceIdentity;
  late Identity bobIdentity;
  late ContactCard alice;
  late ContactCard bob;
  final now = DateTime.fromMillisecondsSinceEpoch(1000000, isUtc: true);

  setUpAll(() async {
    aliceIdentity = await Identity.fromSeeds(
      Uint8List.fromList(List<int>.filled(32, 1)),
      Uint8List.fromList(List<int>.filled(32, 2)),
    );
    bobIdentity = await Identity.fromSeeds(
      Uint8List.fromList(List<int>.filled(32, 3)),
      Uint8List.fromList(List<int>.filled(32, 4)),
    );
    alice = await ContactCard.create(aliceIdentity, name: 'Alice');
    bob = await ContactCard.create(bobIdentity, name: 'Bob');
  });

  Envelope announcement({
    ContactCard? contact,
    int issued = 1000,
    int expires = 1090,
    int? envelopeExpires,
    int type = MsgType.announce,
    Map<Object, Object?>? payload,
  }) => Envelope(
    type: type,
    sender: (contact ?? alice).binding.signingKey,
    recipient: bobIdentity.nodeId,
    messageId: Uint8List(16),
    sessionId: Uint8List(16),
    issuedAt: issued,
    expiresAt: envelopeExpires ?? expires,
    iceGeneration: 0,
    payload:
        payload ??
        <Object, Object?>{
          'presence': true,
          'name': 'Private name',
          'expires': expires,
        },
  );

  group('authenticated presence cache', () {
    test('retains exact signed expiry and returns immutable snapshots', () {
      final cache = ContactPresenceCache();
      expect(cache.accept(announcement(), alice, now: now), isTrue);
      final first = cache.entriesAt(now);
      expect(first.single.nodeId, alice.nodeId);
      expect(first.single.name, 'Private name');
      expect(first.single.contact, same(alice));
      expect(first.single.expiresAt.millisecondsSinceEpoch, 1090000);
      expect(first.clear, throwsUnsupportedError);
      expect(
        cache.entriesAt(now.add(const Duration(seconds: 89))),
        hasLength(1),
      );
      expect(cache.entriesAt(now.add(const Duration(seconds: 90))), isEmpty);
      expect(first, hasLength(1));
    });

    test('late receipt and repeated acceptance never extend expiry', () {
      final cache = ContactPresenceCache();
      final message = announcement();
      expect(cache.accept(message, alice, now: now), isTrue);
      final later = now.add(const Duration(seconds: 60));
      expect(cache.accept(message, alice, now: later), isTrue);
      expect(
        cache.entriesAt(later).single.expiresAt.millisecondsSinceEpoch,
        1090000,
      );
      expect(cache.entriesAt(now.add(const Duration(seconds: 90))), isEmpty);
      expect(
        cache.accept(message, alice, now: now.add(const Duration(seconds: 90))),
        isFalse,
      );
    });

    test('rejects expired, excessive, future-issued and mismatched TTLs', () {
      final cache = ContactPresenceCache();
      for (final message in <Envelope>[
        announcement(expires: 1000),
        announcement(expires: 1091),
        announcement(issued: 999),
        announcement(issued: 1001),
        announcement(envelopeExpires: 1089),
        announcement(issued: -1),
      ]) {
        expect(cache.accept(message, alice, now: now), isFalse);
      }
      expect(cache.entriesAt(now), isEmpty);
    });

    test(
      'requires exact presence schema and 80 UTF-8 bytes, not characters',
      () {
        final cache = ContactPresenceCache();
        for (final payload in <Map<Object, Object?>>[
          {'presence': false, 'name': 'Alice', 'expires': 1090},
          {'presence': true, 'name': 'Alice', 'expires': '1090'},
          {'presence': true, 'name': 7, 'expires': 1090},
          {'presence': true, 'expires': 1090},
          {
            'presence': true,
            'name': 'Alice',
            'expires': 1090,
            'endpoint': 'private',
          },
          {
            'presence': true,
            'name': List<String>.filled(41, 'é').join(),
            'expires': 1090,
          },
        ]) {
          expect(
            cache.accept(announcement(payload: payload), alice, now: now),
            isFalse,
          );
        }
        expect(
          cache.accept(
            announcement(
              payload: {
                'presence': true,
                'name': List<String>.filled(40, 'é').join(),
                'expires': 1090,
              },
            ),
            alice,
            now: now,
          ),
          isTrue,
        );
        expect(
          cache.accept(
            announcement(
              payload: {'presence': true, 'name': '', 'expires': 1090},
            ),
            alice,
            now: now,
          ),
          isTrue,
        );
      },
    );

    test('rejects another contact key and non-presence message types', () {
      final cache = ContactPresenceCache();
      expect(cache.accept(announcement(), bob, now: now), isFalse);
      expect(
        cache.accept(announcement(type: MsgType.hello), alice, now: now),
        isFalse,
      );
      expect(cache.entriesAt(now), isEmpty);
    });

    test(
      'bounds contacts while allowing refresh and reclaiming expired slots',
      () {
        final cache = ContactPresenceCache(maxEntries: 1);
        expect(
          cache.accept(announcement(expires: 1010), alice, now: now),
          isTrue,
        );
        expect(
          cache.accept(announcement(contact: bob), bob, now: now),
          isFalse,
        );
        expect(
          cache.accept(
            announcement(issued: 1001, expires: 1011),
            alice,
            now: now.add(const Duration(seconds: 1)),
          ),
          isTrue,
        );
        expect(cache.entriesAt(now).single.nodeId, alice.nodeId);
        final afterExpiry = now.add(const Duration(seconds: 11));
        expect(
          cache.accept(
            announcement(contact: bob, issued: 1011, expires: 1101),
            bob,
            now: afterExpiry,
          ),
          isTrue,
        );
        expect(cache.entriesAt(afterExpiry).single.nodeId, bob.nodeId);
      },
    );

    test('out-of-order announcements do not overwrite a newer presence', () {
      final cache = ContactPresenceCache();
      final later = now.add(const Duration(seconds: 2));
      expect(
        cache.accept(
          announcement(issued: 1002, expires: 1092),
          alice,
          now: later,
        ),
        isTrue,
      );
      expect(cache.accept(announcement(), alice, now: later), isFalse);
      expect(
        cache.entriesAt(later).single.expiresAt.millisecondsSinceEpoch,
        1092000,
      );
      cache.clear();
      expect(cache.entriesAt(later), isEmpty);
    });

    test('invalid bounds are refused', () {
      expect(() => ContactPresenceCache(maxEntries: 0), throwsArgumentError);
      expect(() => ContactPresenceCache(maxEntries: -1), throwsArgumentError);
    });
  });

  group('private publication', () {
    late ManualSignaling strategy;
    late SignalingClient client;
    late ContactDirectory directory;

    setUp(() async {
      strategy = ManualSignaling();
      client = SignalingClient(
        identity: aliceIdentity,
        strategy: strategy,
        resolveBinding: (id) async => id == bob.nodeId ? bob.binding : null,
      );
      directory = ContactDirectory(
        signaling: client,
        resolveContact: (id) async => id == bob.nodeId ? bob : null,
      );
      await client.start();
    });

    tearDown(() async {
      await directory.close();
      await client.close();
    });

    test('defaults disabled and enabling alone exports nothing', () async {
      await expectLater(directory.announce(bob), throwsStateError);
      expect(strategy.pendingExports, isEmpty);
      await directory.setPublishing(true, name: 'Alice');
      expect(strategy.pendingExports, isEmpty);
      await directory.setPublishing(false);
      await expectLater(directory.announce(bob), throwsStateError);
      expect(strategy.pendingExports, isEmpty);
    });

    test(
      'explicit announcement is signed, sealed and accepted by known receiver',
      () async {
        final receiverStrategy = ManualSignaling();
        final receiver = SignalingClient(
          identity: bobIdentity,
          strategy: receiverStrategy,
          resolveBinding: (id) async =>
              id == alice.nodeId ? alice.binding : null,
        );
        final lookup = Completer<void>();
        final resolve = Completer<ContactCard?>();
        final receivedDirectory = ContactDirectory(
          signaling: receiver,
          resolveContact: (id) {
            expect(id, alice.nodeId);
            lookup.complete();
            return resolve.future;
          },
        );
        addTearDown(() async {
          await receivedDirectory.close();
          await receiver.close();
        });
        await receiver.start();
        final message = receiver.messages.first.timeout(
          const Duration(seconds: 5),
        );
        await directory.setPublishing(true, name: 'Alice private presence');
        await directory.announce(bob);
        expect(strategy.pendingExports, hasLength(1));
        await receiverStrategy.importText(strategy.lastExport!);
        final verified = await message;
        expect(verified.type, MsgType.announce);
        expect(verified.sender, alice.binding.signingKey);
        expect(verified.payload['name'], 'Alice private presence');
        expect(verified.payload['expires'], verified.expiresAt);
        await lookup.future.timeout(const Duration(seconds: 5));
        resolve.complete(alice);
        // Flush the continuation of the explicitly controlled contact lookup.
        await Future<void>.delayed(Duration.zero);
        expect(receivedDirectory.entries.single.nodeId, alice.nodeId);
        expect(receivedDirectory.entries.single.name, 'Alice private presence');
      },
    );

    for (final closeDuringLookup in <bool>[false, true]) {
      test(
        closeDuringLookup
            ? 'closed directory ignores an in-flight verified contact lookup'
            : 'directory rejects contacts removed after authentication',
        () async {
          final receiverStrategy = ManualSignaling();
          final receiver = SignalingClient(
            identity: bobIdentity,
            strategy: receiverStrategy,
            resolveBinding: (id) async =>
                id == alice.nodeId ? alice.binding : null,
          );
          final lookup = Completer<void>();
          final resolution = Completer<ContactCard?>();
          final receivedDirectory = ContactDirectory(
            signaling: receiver,
            resolveContact: (_) {
              lookup.complete();
              return resolution.future;
            },
          );
          addTearDown(() async {
            await receivedDirectory.close();
            await receiver.close();
          });
          await receiver.start();
          await directory.setPublishing(true);
          await directory.announce(bob);
          await receiverStrategy.importText(strategy.lastExport!);
          await lookup.future.timeout(const Duration(seconds: 5));
          if (closeDuringLookup) await receivedDirectory.close();
          resolution.complete(closeDuringLookup ? alice : null);
          await Future<void>.delayed(Duration.zero);
          expect(receivedDirectory.entries, isEmpty);
          expect(receiverStrategy.connected, isTrue);
        },
      );
    }

    test('unknown contacts and oversized UTF-8 names fail closed', () async {
      await directory.setPublishing(true);
      await expectLater(directory.announce(alice), throwsStateError);
      await expectLater(
        directory.setPublishing(
          true,
          name: List<String>.filled(41, 'é').join(),
        ),
        throwsArgumentError,
      );
      await expectLater(directory.announce(bob), throwsStateError);
      expect(strategy.pendingExports, isEmpty);
    });

    test(
      'disabling while contact resolution waits prevents a later send',
      () async {
        await directory.close();
        final resolution = Completer<ContactCard?>();
        directory = ContactDirectory(
          signaling: client,
          resolveContact: (_) => resolution.future,
        );
        await directory.setPublishing(true);
        final pending = directory.announce(bob);
        final rejected = expectLater(pending, throwsStateError);
        await directory.setPublishing(false);
        resolution.complete(bob);
        await rejected;
        expect(strategy.pendingExports, isEmpty);
      },
    );

    test(
      'close is idempotent and does not close the shared signaling client',
      () async {
        await directory.close();
        await directory.close();
        expect(strategy.connected, isTrue);
        expect(directory.entries, isEmpty);
        await expectLater(directory.setPublishing(true), throwsStateError);
        await expectLater(directory.announce(bob), throwsStateError);
      },
    );
  });
}
