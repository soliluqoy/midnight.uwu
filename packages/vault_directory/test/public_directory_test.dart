import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:vault_directory/vault_directory.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_protocol/vault_protocol.dart';
import 'package:vault_signaling/vault_signaling.dart';

Future<Uint8List> _signedPresence(
  Identity identity, {
  required int now,
  String name = 'Public photographer',
  List<String> tags = const <String>['photography'],
  int sequence = 1,
  int? epoch,
  int lifetime = 90,
  int? payloadExpiry,
  Map<Object, Object?> extra = const <Object, Object?>{},
}) async {
  final binding = await identity.binding(issuedAt: now);
  return await encodeEnvelope(
    identity,
    Envelope(
      type: MsgType.announce,
      sender: identity.signingPublic,
      recipient: null,
      messageId: Uint8List(16),
      sessionId: Uint8List(16),
      issuedAt: now,
      expiresAt: now + lifetime,
      iceGeneration: 0,
      payload: <Object, Object?>{
        'presence': true,
        'name': name,
        'tags': tags,
        'sharedCount': 20,
        'epoch': epoch ?? now * 1000000,
        'sequence': sequence,
        'expires': payloadExpiry ?? now + lifetime,
        'encryptionKey': binding.encryptionKey,
        'bindingIssuedAt': binding.issuedAt,
        'bindingSignature': binding.signature,
        ...extra,
      },
    ),
  );
}

/// Test-only bytes; authentication remains the production client's work.
class _PublicTransport implements SignalingStrategy, PublicPresenceTransport {
  final _inbound = StreamController<SignalFrame>.broadcast();
  final _connections = StreamController<bool>.broadcast();
  final _public = StreamController<SignalFrame>.broadcast();
  final published = <SignalFrame>[];
  bool _connected = false;
  bool _enabled = false;
  int privatePublishes = 0;

  @override
  Stream<SignalFrame> get inbound => _inbound.stream;
  @override
  Stream<bool> get connectionChanges => _connections.stream;
  @override
  Stream<SignalFrame> get publicFrames => _public.stream;
  @override
  bool get connected => _connected;
  @override
  bool get publicPresenceEnabled => _enabled;

  @override
  Future<void> start(String nodeId) async {
    _connected = true;
    _connections.add(true);
  }

  @override
  Future<void> setPublicPresenceEnabled(bool enabled) async {
    _enabled = enabled;
  }

  @override
  Future<void> publishPublicPresence(
    String signerNodeId,
    Uint8List bytes,
  ) async {
    if (!_connected || !_enabled) throw StateError('Public transport disabled');
    published.add(SignalFrame(signerNodeId, bytes));
  }

  @override
  Future<void> publish(String recipient, Uint8List bytes) async {
    privatePublishes++;
    throw StateError(
      'No private peer is trusted in these public directory tests',
    );
  }

  void receive(String nodeId, Uint8List bytes) {
    if (!_enabled) throw StateError('Public transport disabled');
    _public.add(SignalFrame(nodeId, bytes));
  }

  @override
  Future<void> close() async {
    _connected = false;
    _enabled = false;
    await _inbound.close();
    await _connections.close();
    await _public.close();
  }
}

void main() {
  late List<Identity> identities;
  late Directory root;
  late String databasePath;

  setUpAll(() async {
    identities = await Future.wait(<Future<Identity>>[
      for (var seed = 1; seed <= 4; seed++)
        Identity.fromSeeds(
          Uint8List.fromList(List<int>.filled(32, seed)),
          Uint8List.fromList(List<int>.filled(32, seed + 10)),
        ),
    ]);
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('vault_public_directory_');
    databasePath = '${root.path}${Platform.pathSeparator}presence.sqlite3';
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  SignalingClient clientFor(Identity identity, SignalingStrategy transport) =>
      SignalingClient(
        identity: identity,
        strategy: transport,
        resolveBinding: (_) async => null,
      );

  Future<PublicPresenceRecord> verified(
    Identity identity, {
    int now = 1000,
    int sequence = 1,
    int? epoch,
  }) async => await verifyPublicPresenceRecord(
    await _signedPresence(identity, now: now, sequence: sequence, epoch: epoch),
    now: now,
  );

  test(
    'signed cache expiry is exact, bounded and never refreshed by receipt',
    () async {
      final first = await verified(identities[0]);
      final second = await verified(identities[1]);
      final third = await verified(identities[2]);
      final cache = PublicPresenceCache(maxEntries: 2);
      final now = DateTime.fromMillisecondsSinceEpoch(1000000, isUtc: true);
      expect(cache.accept(first, now: now), isTrue);
      expect(cache.accept(second, now: now), isTrue);
      expect(cache.accept(third, now: now), isFalse);
      expect(
        cache.accept(first, now: now.add(const Duration(seconds: 60))),
        isFalse,
      );
      expect(
        cache.entriesAt(now.add(const Duration(seconds: 89))),
        hasLength(2),
      );
      expect(cache.entriesAt(now).first.expiresAt, 1090);
      expect(() => cache.entriesAt(now).clear(), throwsUnsupportedError);
      expect(cache.entriesAt(now.add(const Duration(seconds: 90))), isEmpty);
      final fresh = await verified(identities[2], now: 1090);
      expect(
        cache.accept(fresh, now: now.add(const Duration(seconds: 90))),
        isTrue,
      );
      expect(
        cache
            .search('PHOTO', now: now.add(const Duration(seconds: 90)))
            .single
            .nodeId,
        fresh.nodeId,
      );
      expect(() => cache.search('x', now: now, limit: 0), throwsArgumentError);
    },
  );

  test(
    'live epoch and sequence watermarks reject stale signed updates',
    () async {
      final cache = PublicPresenceCache();
      final now = DateTime.fromMillisecondsSinceEpoch(1000000, isUtc: true);
      final newer = await verified(identities[0], sequence: 2);
      expect(cache.accept(newer, now: now), isTrue);
      expect(cache.accept(await verified(identities[0]), now: now), isFalse);
      expect(
        cache.accept(
          await verified(identities[0], sequence: 9, epoch: 999000000),
          now: now,
        ),
        isFalse,
      );
      expect(
        cache.accept(await verified(identities[0], sequence: 3), now: now),
        isTrue,
      );
      expect(cache.entriesAt(now).single.sequence, 3);
      expect(cache.entriesAt(now).single.expiresAt, newer.expiresAt);
    },
  );

  test(
    'real verifier rejects signature/expiry tampering and private metadata',
    () async {
      final bytes = await _signedPresence(identities[0], now: 1000);
      final tampered = Uint8List.fromList(bytes)..[35] ^= 1;
      await expectLater(
        verifyPublicPresenceRecord(tampered, now: 1000),
        throwsA(isA<WireReject>()),
      );
      await expectLater(
        verifyPublicPresenceRecord(bytes, now: 1090),
        throwsA(isA<WireReject>()),
      );
      await expectLater(
        verifyPublicPresenceRecord(
          bytes,
          now: 1000,
          expectedNodeId: nodeIdText(identities[1].nodeId),
        ),
        throwsA(isA<WireReject>()),
      );
      for (final key in <String>[
        'filename',
        'path',
        'endpoint',
        'poster',
        'acl',
        'grant',
      ]) {
        final forbidden = await _signedPresence(
          identities[0],
          now: 1000,
          extra: <Object, Object?>{key: 'must never become public'},
        );
        await expectLater(
          verifyPublicPresenceRecord(forbidden, now: 1000),
          throwsA(isA<WireReject>()),
        );
      }
      for (final invalid in <Uint8List>[
        await _signedPresence(identities[0], now: 1000, lifetime: 91),
        await _signedPresence(identities[0], now: 1000, payloadExpiry: 1089),
        await _signedPresence(
          identities[0],
          now: 1000,
          name: List<String>.filled(41, 'é').join(),
        ),
        await _signedPresence(
          identities[0],
          now: 1000,
          tags: List<String>.generate(9, (index) => 'tag$index'),
        ),
      ]) {
        await expectLater(
          verifyPublicPresenceRecord(invalid, now: 1000),
          throwsA(isA<WireReject>()),
        );
      }
    },
  );

  test(
    'browse and public publication opt-ins are independent and off by default',
    () async {
      final transport = _PublicTransport();
      final client = clientFor(identities[0], transport);
      final directory = PublicContactDirectory(
        signaling: client,
        databasePath: databasePath,
      );
      addTearDown(() async {
        await directory.close();
        await client.close();
      });
      await client.start();
      await directory.load();
      expect(directory.discovering, isFalse);
      expect(directory.publishing, isFalse);
      expect(transport.publicPresenceEnabled, isFalse);
      expect(transport.published, isEmpty);
      await directory.setDiscovering(true);
      expect(transport.published, isEmpty);
      await directory.setPublishing(
        true,
        name: 'Chosen public name',
        tags: <String>['art'],
      );
      expect(transport.published, hasLength(1));
      final record = await verifyPublicPresenceRecord(
        transport.published.single.bytes,
        now: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      expect(record.name, 'Chosen public name');
      expect(record.tags, <String>['art']);
      await directory.setPublishing(false);
      expect(directory.discovering, isTrue);
      expect(transport.publicPresenceEnabled, isTrue);
      await directory.setDiscovering(false);
      expect(transport.publicPresenceEnabled, isFalse);
      expect(directory.entries, isEmpty);
      expect(transport.privatePublishes, 0);
    },
  );

  test('SQLite restart preserves expiry, bounds and search', () async {
    final transport = _PublicTransport();
    final client = clientFor(identities[3], transport);
    var directory = PublicContactDirectory(
      signaling: client,
      databasePath: databasePath,
      maxEntries: 2,
    );
    addTearDown(() async {
      await directory.close();
      await client.close();
    });
    await client.start();
    await directory.setDiscovering(true);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (var index = 0; index < 2; index++) {
      final received = directory.changes
          .firstWhere((entries) => entries.length == index + 1)
          .timeout(const Duration(seconds: 5));
      final bytes = await _signedPresence(
        identities[index],
        now: now,
        name: index == 0 ? 'Alice Artist' : 'Bob Traveller',
        tags: index == 0 ? <String>['painting'] : <String>['travel'],
      );
      transport.receive(nodeIdText(identities[index].nodeId), bytes);
      await received;
    }
    final thirdId = nodeIdText(identities[2].nodeId);
    final rejectedAtCapacity = client.publicPresence
        .firstWhere((record) => record.nodeId == thirdId)
        .timeout(const Duration(seconds: 5));
    transport.receive(thirdId, await _signedPresence(identities[2], now: now));
    await rejectedAtCapacity;
    expect(directory.entries, hasLength(2));
    final signedExpiries = <String, int>{
      for (final record in directory.entries) record.nodeId: record.expiresAt,
    };
    await directory.close();
    final database = sqlite3.open(databasePath);
    try {
      expect(
        database
            .select('SELECT COUNT(*) AS count FROM public_presence')
            .single['count'],
        2,
      );
      expect(
        () => database.execute(
          'INSERT INTO public_presence(node_id, expires_at, signed_envelope) '
          'VALUES (?, ?, ?)',
          <Object?>[thirdId, now + 90, Uint8List(maxPublicPresenceBytes + 1)],
        ),
        throwsA(isA<SqliteException>()),
      );
    } finally {
      database.close();
    }
    directory = PublicContactDirectory(
      signaling: client,
      databasePath: databasePath,
      maxEntries: 2,
    );
    await directory.load();
    expect(
      directory.entries,
      isEmpty,
      reason: 'Loading disk does not opt into browsing',
    );
    await directory.setDiscovering(true);
    expect(directory.entries, hasLength(2));
    expect(<String, int>{
      for (final record in directory.entries) record.nodeId: record.expiresAt,
    }, signedExpiries);
    expect(directory.search('PAINTING').single.name, 'Alice Artist');
    expect(directory.search('traveller').single.name, 'Bob Traveller');
    expect(directory.search('', limit: 1), hasLength(1));
    expect(directory.search('no such public metadata'), isEmpty);
    final discovered = directory.entries.first;
    final contact = await directory.contactFor(
      discovered,
      name: 'Independently compared contact',
    );
    expect(contact.nodeId, discovered.nodeId);
    expect(contact.name, 'Independently compared contact');
    expect(transport.privatePublishes, 0);
    expect(directory.publishing, isFalse);
    await directory.setDiscovering(false);
    final cleared = sqlite3.open(databasePath);
    try {
      expect(
        cleared
            .select('SELECT COUNT(*) AS count FROM public_presence')
            .single['count'],
        0,
      );
    } finally {
      cleared.close();
    }
  });

  test(
    'tampered SQLite hints cannot revive expired or unsigned presence',
    () async {
      final transport = _PublicTransport();
      final client = clientFor(identities[3], transport);
      final initial = PublicContactDirectory(
        signaling: client,
        databasePath: databasePath,
      );
      await initial.close();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final expired = await _signedPresence(identities[0], now: now - 91);
      final tampered = Uint8List.fromList(
        await _signedPresence(identities[1], now: now),
      )..[35] ^= 1;
      final database = sqlite3.open(databasePath);
      try {
        for (final row in <(Identity, Uint8List)>[
          (identities[0], expired),
          (identities[1], tampered),
        ]) {
          database.execute(
            'INSERT INTO public_presence(node_id, expires_at, signed_envelope) '
            'VALUES (?, ?, ?)',
            <Object?>[nodeIdText(row.$1.nodeId), now + 3600, row.$2],
          );
        }
      } finally {
        database.close();
      }
      final directory = PublicContactDirectory(
        signaling: client,
        databasePath: databasePath,
      );
      final errors = <Object>[];
      final subscription = directory.errors.listen(errors.add);
      addTearDown(() async {
        await subscription.cancel();
        await directory.close();
        await client.close();
      });
      await client.start();
      await directory.load();
      await directory.setDiscovering(true);
      expect(directory.entries, isEmpty);
      expect(errors, hasLength(2));
      final persisted = sqlite3.open(databasePath);
      try {
        expect(
          persisted
              .select('SELECT COUNT(*) AS count FROM public_presence')
              .single['count'],
          0,
        );
      } finally {
        persisted.close();
      }
    },
  );

  test('manual discovery fails honestly without fabricated exports', () async {
    final transport = ManualSignaling();
    final client = clientFor(identities[0], transport);
    final directory = PublicContactDirectory(
      signaling: client,
      databasePath: databasePath,
    );
    addTearDown(() async {
      await directory.close();
      await client.close();
    });
    await client.start();
    await expectLater(directory.setDiscovering(true), throwsUnsupportedError);
    await expectLater(
      directory.setPublishing(true, name: 'Not published'),
      throwsUnsupportedError,
    );
    expect(directory.discovering, isFalse);
    expect(directory.publishing, isFalse);
    expect(directory.entries, isEmpty);
    expect(transport.pendingExports, isEmpty);
  });
}
