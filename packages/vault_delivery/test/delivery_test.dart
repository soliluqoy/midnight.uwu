import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_delivery/vault_delivery.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_media_index/vault_media_index.dart';
import 'package:vault_net/vault_net.dart';
import 'package:vault_protocol/vault_protocol.dart';

void main() {
  late Directory temp;
  late VaultLibrary library;
  late VaultLibrary empty;
  late Identity ownerId;
  late Identity viewerId;
  late _Store ownerStore;
  late AuthorizationRepository ownerAuth;
  late AuthorizationRepository viewerAuth;
  late VaultDelivery owner;
  late VaultDelivery viewer;
  late _Peer ownerPeer;
  late _Peer viewerPeer;
  late Uint8List fixture;
  void connect() {
    ownerPeer = _Peer(
      nodeIdText(viewerId.nodeId),
      'session-${DateTime.now().microsecondsSinceEpoch}',
    );
    viewerPeer = _Peer(nodeIdText(ownerId.nodeId), ownerPeer.sessionId);
    ownerPeer.other = viewerPeer;
    viewerPeer.other = ownerPeer;
    owner.attach(ownerPeer);
    viewer.attach(viewerPeer);
  }

  void connectionState(PeerSessionState state) {
    ownerPeer.changeState(state);
    viewerPeer.changeState(state);
  }

  Future<RemoteMedia> approve() async {
    final request = owner.accessRequests.first;
    final access = viewer.requestAccess(viewerPeer);
    await owner.approve(await request);
    await access;
    return (await viewer.browse(viewerPeer)).single;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault-delivery-');
    ownerId = await Identity.generate();
    viewerId = await Identity.generate();
    ownerStore = _Store();
    ownerAuth = AuthorizationRepository(ownerStore, ownerId);
    await ownerAuth.load();
    viewerAuth = AuthorizationRepository(_Store(), viewerId);
    await viewerAuth.load();
    library = VaultLibrary(Directory('${temp.path}/library'));
    await library.load();
    empty = VaultLibrary(Directory('${temp.path}/empty'));
    await empty.load();
    fixture = Uint8List.fromList(
      List.generate(1024 * 1024 + 123, (i) => (i * 7) % 251),
    );
    final file = await File('${temp.path}/clip.mp4').writeAsBytes(fixture);
    await library.addFile(file);
    owner = VaultDelivery(
      library: library,
      authorization: ownerAuth,
      cacheDirectory: Directory('${temp.path}/owner'),
    );
    viewer = VaultDelivery(
      library: empty,
      authorization: viewerAuth,
      cacheDirectory: Directory('${temp.path}/viewer'),
    );
    connect();
  });
  tearDown(() async {
    await viewer.close();
    await owner.close();
    await temp.delete(recursive: true);
  });
  test('pending consent expires after two minutes without approving '
      'or disconnecting its peer', () async {
    await owner.load();
    await viewer.load();
    await owner.setPublishing(true);
    final clock = FakeAsync();
    final snapshots = <List<AccessRequest>>[];
    final arrivals = <AccessRequest>[];
    late StreamSubscription<List<AccessRequest>> lifecycle;
    late StreamSubscription<AccessRequest> incoming;
    clock.run((_) {
      connect();
      lifecycle = owner.accessRequestChanges.listen(snapshots.add);
      incoming = owner.accessRequests.listen(arrivals.add);
      unawaited(
        viewerPeer.sendControl({
          'vault': 'delivery',
          'op': 'access',
          'id': '0123456789abcdef0123456789abcdef',
        }),
      );
    });
    try {
      clock.flushMicrotasks();
      expect(arrivals, hasLength(1));
      expect(snapshots, hasLength(1));
      expect(snapshots.single.single.requestId, arrivals.single.requestId);
      expect(() => snapshots.single.clear(), throwsUnsupportedError);
      clock.elapse(const Duration(minutes: 1, seconds: 59));
      expect(snapshots, hasLength(1));
      clock.elapse(const Duration(seconds: 1));
      expect(snapshots, hasLength(2));
      expect(snapshots.last, isEmpty);
      expect(snapshots.first.single.requestId, arrivals.single.requestId);
      expect(arrivals, hasLength(1));
      expect(ownerPeer.state, PeerSessionState.connected);
      expect(viewerPeer.state, PeerSessionState.connected);
      expect(ownerPeer.sent, isEmpty);
    } finally {
      clock
        ..run((_) {
          unawaited(ownerPeer.close());
          unawaited(lifecycle.cancel());
          unawaited(incoming.cancel());
        })
        ..flushMicrotasks();
      await Future<void>.delayed(Duration.zero);
      clock.flushMicrotasks();
    }
  });
  for (final transition in [
    'approve',
    'deny',
    'cancel',
    'interrupt',
    'disconnect',
    'publication stop',
    'shutdown',
  ]) {
    test('pending consent lifecycle clears on $transition', () async {
      await owner.setPublishing(true);
      final snapshots = <List<AccessRequest>>[];
      var streamClosed = false;
      final lifecycle = owner.accessRequestChanges.listen(
        snapshots.add,
        onDone: () => streamClosed = true,
      );
      try {
        final incoming = owner.accessRequests.first;
        const id = '0123456789abcdef0123456789abcdef';
        await viewerPeer.sendControl({
          'vault': 'delivery',
          'op': 'access',
          'id': id,
        });
        final request = await incoming;
        await Future<void>.delayed(Duration.zero);
        expect(snapshots.single.single, same(request));
        switch (transition) {
          case 'approve':
            await owner.approve(request);
          case 'deny':
            await owner.deny(request);
          case 'cancel':
            await viewerPeer.sendControl({
              'vault': 'delivery',
              'op': 'cancel',
              'id': id,
            });
          case 'interrupt':
            connectionState(PeerSessionState.negotiating);
          case 'disconnect':
            await viewerPeer.close();
          case 'publication stop':
            await owner.setPublishing(false);
          case 'shutdown':
            await owner.close();
        }
        await Future<void>.delayed(Duration.zero);
        expect(snapshots, hasLength(2));
        expect(snapshots.last, isEmpty);
        expect(snapshots.first.single, same(request));
        expect(streamClosed, transition == 'shutdown');
      } finally {
        await lifecycle.cancel();
      }
    });
  }
  test('publication and approval precede private index; cold tail range '
      'and full download are verified', () async {
    expect(owner.publishing, isFalse);
    await expectLater(viewer.browse(viewerPeer), throwsStateError);
    await expectLater(viewer.requestAccess(viewerPeer), throwsStateError);
    expect(ownerPeer.bulkFrames, 0);
    await owner.setPublishing(true);
    final item = await approve();
    expect(item.id, sha256.convert(fixture).toString());
    final uri = await viewer.play(viewerPeer, item);
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.headers.set('Range', 'bytes=-100');
      final response = await request.close();
      expect(response.statusCode, 206);
      final actual = await response.fold<List<int>>(
        [],
        (bytes, next) => bytes..addAll(next),
      );
      expect(actual, fixture.sublist(fixture.length - 100));
      expect(
        viewerPeer.sent.where((m) => m['op'] == 'chunk').map((m) => m['index']),
        [4],
      );
    } finally {
      client.close(force: true);
    }
    final downloaded = await viewer.download(viewerPeer, item);
    expect(
      (await sha256.bind(downloaded.openRead()).first).toString(),
      item.id,
    );
    expect(ownerPeer.maxFrame, lessThanOrEqualTo(16 * 1024 - 5));
    await owner.revoke(nodeIdText(viewerId.nodeId));
    expect(viewerPeer.state, PeerSessionState.closed);
    final reloadedAuth = AuthorizationRepository(ownerStore, ownerId);
    await reloadedAuth.load();
    await owner.close();
    owner = VaultDelivery(
      library: library,
      authorization: reloadedAuth,
      cacheDirectory: Directory('${temp.path}/owner'),
    );
    await owner.setPublishing(true);
    await viewer.close();
    viewer = VaultDelivery(
      library: empty,
      authorization: viewerAuth,
      cacheDirectory: Directory('${temp.path}/viewer'),
    );
    connect();
    await expectLater(viewer.browse(viewerPeer), throwsStateError);
  });
  test('cancel leaves verified disk prefix; restart resumes without '
      'requesting completed chunks', () async {
    await owner.setPublishing(true);
    final item = await approve();
    final cancellation = DeliveryCancellation();
    await expectLater(
      viewer.download(
        viewerPeer,
        item,
        cancellation: cancellation,
        onProgress: (received, _) {
          if (received >= mediaChunkBytes) cancellation.cancel();
        },
      ),
      throwsA(isA<DeliveryCancelled>()),
    );
    final partial = File('${temp.path}/viewer/downloads/${item.id}.part');
    expect(await partial.length(), mediaChunkBytes);
    await viewer.close();
    viewer = VaultDelivery(
      library: empty,
      authorization: viewerAuth,
      cacheDirectory: Directory('${temp.path}/viewer'),
    );
    connect();
    final resumed = await viewer.download(viewerPeer, item);
    expect((await sha256.bind(resumed.openRead()).first).toString(), item.id);
    expect(
      viewerPeer.sent.where((m) => m['op'] == 'chunk').map((m) => m['index']),
      [1, 2, 3, 4],
    );
  });
  test(
    'corrupt fragments are rejected, never committed as sparse cache bytes',
    () async {
      await owner.setPublishing(true);
      final item = await approve();
      ownerPeer.corruptBulk = true;
      await expectLater(
        viewer.download(viewerPeer, item),
        throwsA(isA<FormatException>()),
      );
      expect(await Directory('${temp.path}/viewer/chunks').list().length, 0);
    },
  );
  test(
    'stolen viewer-bound token cannot authorize another authenticated peer',
    () async {
      await owner.setPublishing(true);
      await approve();
      final grants = jsonDecode(
        await File('${temp.path}/viewer/viewer-grants.json').readAsString(),
      ) as Map<String, dynamic>;
      final stolen = grants.values.single;
      final intruder = await Identity.generate();
      final foreignDir = await Directory('${temp.path}/foreign').create();
      await File('${foreignDir.path}/viewer-grants.json')
          .writeAsString(jsonEncode({nodeIdText(ownerId.nodeId): stolen}));
      final foreign = VaultDelivery(
        library: empty,
        authorization: viewerAuth,
        cacheDirectory: foreignDir,
      );
      final ownerSide = _Peer(nodeIdText(intruder.nodeId), 'intruder');
      final foreignSide = _Peer(nodeIdText(ownerId.nodeId), 'intruder');
      ownerSide.other = foreignSide;
      foreignSide.other = ownerSide;
      owner.attach(ownerSide);
      foreign.attach(foreignSide);
      try {
        await expectLater(foreign.browse(foreignSide), throwsStateError);
        expect(ownerSide.bulkFrames, 0);
      } finally {
        await foreign.close();
      }
    },
  );
  test('unpublish closes active serving connection but does not revoke '
      'remembered approval', () async {
    await owner.setPublishing(true);
    await approve();
    await owner.setPublishing(false);
    expect(viewerPeer.state, PeerSessionState.closed);
    await owner.setPublishing(true);
    connect();
    expect(await viewer.browse(viewerPeer), hasLength(1));
  });
  test('overlapping playback replacements and shutdown leave no orphan '
      'loopback server', () async {
    await owner.setPublishing(true);
    final item = await approve();
    final original = await viewer.play(viewerPeer, item);
    final superseded = viewer.play(viewerPeer, item);
    final supersededResult = expectLater(
      superseded,
      throwsA(isA<DeliveryCancelled>()),
    );
    final replacement = viewer.play(viewerPeer, item);
    await supersededResult;
    final current = await replacement;
    final duringClose = viewer.play(viewerPeer, item);
    final cancelled = expectLater(
      duringClose,
      throwsA(isA<DeliveryCancelled>()),
    );
    await viewer.close();
    await cancelled;
    final client = HttpClient();
    try {
      for (final uri in [original, current]) {
        await expectLater(client.getUrl(uri), throwsA(isA<SocketException>()));
      }
    } finally {
      client.close(force: true);
    }
  });
  test(
    'closing a viewer releases its URL without cancelling newer playback',
    () async {
      await owner.setPublishing(true);
      final item = await approve();
      final original = await viewer.play(viewerPeer, item);
      final replacement = viewer.play(viewerPeer, item);
      await viewer.stopPlayback(viewerPeer, original);
      final current = await replacement;
      // A delayed teardown of the previous viewer cannot close this one.
      await viewer.stopPlayback(viewerPeer, original);
      final client = HttpClient();
      try {
        await expectLater(
          client.getUrl(original),
          throwsA(isA<SocketException>()),
        );
        final request = await client.getUrl(current);
        request.headers.set('Range', 'bytes=0-31');
        request.persistentConnection = false;
        final response = await request.close();
        expect(response.statusCode, 206);
        expect(
          await response.fold<List<int>>(
            [],
            (bytes, next) => bytes..addAll(next),
          ),
          fixture.sublist(0, 32),
        );
        await viewer.stopPlayback(viewerPeer, current);
        await viewer.stopPlayback(viewerPeer, current);
        await expectLater(
          client.getUrl(current),
          throwsA(isA<SocketException>()),
        );
        expect(viewerPeer.state, PeerSessionState.connected);
        expect((await viewer.browse(viewerPeer)).single.id, item.id);
      } finally {
        client.close(force: true);
      }
    },
  );
  test('recovery releases all request slots before old sends finish', () async {
    await owner.setPublishing(true);
    final item = await approve();
    final started = Completer<void>();
    final release = Completer<void>();
    var stalled = 0;
    viewerPeer.beforeControl = (message) async {
      if (message['op'] != 'browse') return;
      if (++stalled == 4) started.complete();
      await release.future;
    };
    final interrupted = [
      for (var i = 0; i < 4; i++)
        expectLater(
          viewer.browse(viewerPeer),
          throwsA(isA<DeliveryCancelled>()),
        ),
    ];
    try {
      await started.future;
      await expectLater(viewer.browse(viewerPeer), throwsStateError);
      connectionState(PeerSessionState.negotiating);
      await Future.wait(interrupted).timeout(const Duration(seconds: 2));
      connectionState(PeerSessionState.authenticating);
      await expectLater(viewer.browse(viewerPeer), throwsStateError);
      viewerPeer.beforeControl = null;
      connectionState(PeerSessionState.connected);
      final results = await Future.wait([
        for (var i = 0; i < 4; i++) viewer.browse(viewerPeer),
      ]);
      expect(results.map((items) => items.single.id), everyElement(item.id));
      expect(
        viewerPeer.sent.where((message) => message['op'] == 'access'),
        hasLength(1),
      );
    } finally {
      // Late native send failures must not affect recovered requests or escape.
      release.completeError(StateError('Old route send failed'));
      await Future.wait(interrupted);
    }
  });
  test('recovery cancels saturated owner reads and replaces the loopback '
      'without waiting for old native sends', () async {
    await owner.setPublishing(true);
    final item = await approve();
    final original = await viewer.play(viewerPeer, item);
    final started = Completer<void>();
    final release = Completer<void>();
    var stalled = 0;
    ownerPeer.beforeBulk = () async {
      if (++stalled == 4) started.complete();
      await release.future;
    };
    final client = HttpClient()..maxConnectionsPerHost = 4;
    Future<List<int>> read(Uri uri, int offset) async {
      final request = await client.getUrl(uri);
      request.headers.set('Range', 'bytes=$offset-${offset + 31}');
      request.persistentConnection = false;
      final response = await request.close();
      return await response.fold<List<int>>(
        [],
        (bytes, next) => bytes..addAll(next),
      );
    }

    Future<List<int>> interruptedRead(int index) async {
      try {
        return await read(original, index * mediaChunkBytes);
      } on HttpException {
        return [];
      } on SocketException {
        return [];
      }
    }

    final oldReads = [for (var i = 0; i < 4; i++) interruptedRead(i)];
    try {
      await started.future;
      connectionState(PeerSessionState.negotiating);
      ownerPeer.beforeBulk = null;
      connectionState(PeerSessionState.authenticating);
      await expectLater(viewer.play(viewerPeer, item), throwsStateError);
      connectionState(PeerSessionState.connected);
      final restored = await viewer
          .play(viewerPeer, item)
          .timeout(const Duration(seconds: 2));
      // Cleanup from the old viewer cannot invalidate the restored listener.
      await viewer.stopPlayback(viewerPeer, original);
      expect(await read(restored, 0), fixture.sublist(0, 32));
      expect(
        await Future.wait(oldReads).timeout(const Duration(seconds: 2)),
        everyElement(isEmpty),
      );
      await expectLater(
        client.getUrl(original),
        throwsA(isA<SocketException>()),
      );
      expect(
        viewerPeer.sent.where((message) => message['op'] == 'access'),
        hasLength(1),
      );
    } finally {
      release.complete();
      client.close(force: true);
      await Future.wait(oldReads);
    }
  });
  test('recovered cached playback rechecks owner permission and never '
      'mints another grant', () async {
    await owner.setPublishing(true);
    final item = await approve();
    final client = HttpClient();
    Future<List<int>> read(Uri uri) async {
      final request = await client.getUrl(uri);
      request.headers.set('Range', 'bytes=0-31');
      request.persistentConnection = false;
      final response = await request.close();
      expect(response.statusCode, 206);
      return await response.fold<List<int>>(
        [],
        (bytes, next) => bytes..addAll(next),
      );
    }

    try {
      final original = await viewer.play(viewerPeer, item);
      expect(await read(original), fixture.sublist(0, 32));
      final bulkFrames = ownerPeer.bulkFrames;
      final permits = viewerPeer.sent
          .where((message) => message['op'] == 'permit')
          .length;
      connectionState(PeerSessionState.negotiating);
      connectionState(PeerSessionState.authenticating);
      connectionState(PeerSessionState.connected);
      final restored = await viewer.play(viewerPeer, item);
      expect(restored, isNot(original));
      expect(await read(restored), fixture.sublist(0, 32));
      expect(ownerPeer.bulkFrames, bulkFrames);
      expect(
        viewerPeer.sent.where((message) => message['op'] == 'permit').length,
        greaterThan(permits),
      );
      // Persist a revocation without a transport notice: the fresh manifest
      // check, not a new consent or possession of cached bytes, gates recovery.
      await ownerAuth.revokeViewer(viewerId.nodeId);
      connectionState(PeerSessionState.negotiating);
      connectionState(PeerSessionState.connected);
      await expectLater(viewer.play(viewerPeer, item), throwsStateError);
      expect(ownerPeer.bulkFrames, bulkFrames);
      expect(
        viewerPeer.sent.where((message) => message['op'] == 'access'),
        hasLength(1),
      );
      await expectLater(
        client.getUrl(restored),
        throwsA(isA<SocketException>()),
      );
    } finally {
      client.close(force: true);
    }
  });
  for (final terminal in [PeerSessionState.closed, PeerSessionState.failed]) {
    test(
      '$terminal closes playback and permanently detaches the session',
      () async {
        await owner.setPublishing(true);
        final item = await approve();
        final uri = await viewer.play(viewerPeer, item);
        final sent = viewerPeer.sent.length;
        connectionState(terminal);
        await expectLater(viewer.browse(viewerPeer), throwsStateError);
        await expectLater(viewer.play(viewerPeer, item), throwsStateError);
        // Even a stale connected notification cannot reattach a terminal peer.
        connectionState(PeerSessionState.connected);
        await expectLater(viewer.browse(viewerPeer), throwsStateError);
        await expectLater(viewer.play(viewerPeer, item), throwsStateError);
        expect(viewerPeer.sent, hasLength(sent));
        final client = HttpClient();
        try {
          await expectLater(
            client.getUrl(uri),
            throwsA(isA<SocketException>()),
          );
        } finally {
          client.close(force: true);
        }
      },
    );
  }
  test('revoking Alice does not cancel an unrelated Bob transfer', () async {
    await owner.setPublishing(true);
    final item = await approve();
    final bobId = await Identity.generate();
    final bob = VaultDelivery(
      library: empty,
      authorization: viewerAuth,
      cacheDirectory: Directory('${temp.path}/bob'),
    );
    final ownerBob = _Peer(nodeIdText(bobId.nodeId), 'bob');
    final bobOwner = _Peer(nodeIdText(ownerId.nodeId), 'bob');
    ownerBob.other = bobOwner;
    bobOwner.other = ownerBob;
    owner.attach(ownerBob);
    bob.attach(bobOwner);
    final request = owner.accessRequests.first;
    final access = bob.requestAccess(bobOwner);
    await owner.approve(await request);
    await access;
    final started = Completer<void>();
    final release = Completer<void>();
    ownerBob.beforeBulk = () async {
      if (!started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    try {
      final download = bob.download(bobOwner, item);
      await started.future;
      await owner.revoke(nodeIdText(viewerId.nodeId));
      expect(bobOwner.state, PeerSessionState.connected);
      release.complete();
      expect(
        (await sha256.bind((await download).openRead()).first).toString(),
        item.id,
      );
    } finally {
      if (!release.isCompleted) release.complete();
      await bob.close();
    }
  });
  test('decoder metadata and real poster bytes require approval and cached '
      'posters recheck revocation', () async {
    await owner.close();
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
    );
    library = VaultLibrary(
      Directory('${temp.path}/postered'),
      metadataExtractor: (_) async =>
          MediaMetadata(width: 1, height: 1, poster: png),
    );
    await library.load();
    await library.addFile(await File('${temp.path}/one.png').writeAsBytes(png));
    owner = VaultDelivery(
      library: library,
      authorization: ownerAuth,
      cacheDirectory: Directory('${temp.path}/owner'),
    );
    connect();
    await owner.setPublishing(true);
    await expectLater(viewer.browse(viewerPeer), throwsStateError);
    final item = await approve();
    expect(item.width, 1);
    expect(item.height, 1);
    expect(item.posterDigest, sha256.convert(png).toString());
    expect(await viewer.poster(viewerPeer, item), png);
    await owner.revoke(nodeIdText(viewerId.nodeId));
    connect();
    await expectLater(viewer.poster(viewerPeer, item), throwsStateError);
  });
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

/// In-memory transport fixture. Authorization, indexing, hashing, disk cache
/// and HTTP serving remain real; native transport smoke is separate.
class _Peer implements PeerSession {
  new(this.peerId, this.sessionId);
  @override
  final String peerId;
  @override
  final String sessionId;
  late _Peer other;
  final _packets = StreamController<PeerPacket>(sync: true);
  final _states = StreamController<PeerSessionState>.broadcast(sync: true);
  final sent = <Map<String, Object?>>[];
  bool corruptBulk = false;
  Future<void> Function(Map<String, Object?> message)? beforeControl;
  Future<void> Function()? beforeBulk;
  int bulkFrames = 0;
  int maxFrame = 0;
  int _routeEpoch = 0;
  @override
  PeerSessionState state = PeerSessionState.connected;
  @override
  Stream<PeerPacket> get packets => _packets.stream;
  @override
  Stream<PeerSessionState> get states => _states.stream;

  void changeState(PeerSessionState next) {
    if (next != PeerSessionState.connected) _routeEpoch++;
    state = next;
    _states.add(next);
  }

  @override
  Future<void> sendControl(Map<String, Object?> message) async {
    if (state != PeerSessionState.connected) throw StateError('Closed');
    final epoch = _routeEpoch;
    await beforeControl?.call(message);
    if (state != PeerSessionState.connected || epoch != _routeEpoch) {
      throw StateError('Route changed');
    }
    if (utf8.encode(jsonEncode(message)).length > maxPeerPayloadBytes) {
      throw StateError('Oversized test control frame');
    }
    sent.add(message);
    other._packets.add(PeerPacket.control(message));
  }

  @override
  Future<void> sendBulk(Uint8List bytes) async {
    if (state != PeerSessionState.connected) throw StateError('Closed');
    final epoch = _routeEpoch;
    await beforeBulk?.call();
    if (state != PeerSessionState.connected || epoch != _routeEpoch) {
      throw StateError('Route changed');
    }
    bulkFrames++;
    if (bytes.length > maxFrame) maxFrame = bytes.length;
    final value = Uint8List.fromList(bytes);
    if (corruptBulk) value[value.length - 1] ^= 1;
    other._packets.add(PeerPacket.bulk(value));
  }

  @override
  Future<void> sendEphemeral(Map<String, Object?> message) async =>
      throw UnsupportedError('Not used');
  @override
  Future<void> close() async {
    if (state == PeerSessionState.closed) return;
    changeState(PeerSessionState.closed);
    if (other.state != PeerSessionState.closed) {
      other.changeState(PeerSessionState.closed);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
