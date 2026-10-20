import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:vault_delivery/src/cache.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_media_index/vault_media_index.dart';
import 'package:vault_net/vault_net.dart';
import 'package:vault_player/range_server.dart';
import 'package:vault_protocol/vault_protocol.dart';

export 'src/cache.dart';

const _scope = 'library/all';
const int _fragmentBytes = 12 * 1024;
const _browsePageSize = 8;
String _randomId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
bool _hash(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

/// Cancellation of a local delivery operation, not a remote grant denial.
class DeliveryCancelled implements Exception {
  /// Creates the explicit cancellation outcome.
  const new();
  @override
  String toString() => 'Delivery cancelled';
}

/// Idempotent cancellation shared by a transfer and its bounded requests.
class DeliveryCancellation {
  final _done = Completer<void>();
  final _events = StreamController<void>.broadcast(sync: true);

  /// Notifications used by requests to release their cancellation listeners.
  Stream<void> get onCancel => _events.stream;

  /// Whether cancellation has already been requested.
  bool get isCancelled => _done.isCompleted;

  /// Completes once when the operation is cancelled.
  Future<void> get cancelled => _done.future;

  /// Cancels pending requests and prevents subsequent transfer work.
  void cancel() {
    if (_done.isCompleted) return;
    _done.complete();
    _events.add(null);
    unawaited(_events.close());
  }

  /// Throws [DeliveryCancelled] when work must stop.
  void check() {
    if (isCancelled) throw const DeliveryCancelled();
  }
}

/// Authenticated remote index metadata, never an owner filesystem path.
class RemoteMedia {
  /// Validates a bounded remote content generation and optional preview.
  new({
    required this.id,
    required this.name,
    required this.size,
    required this.mimeType,
    required this.generation,
    required this.chunkCount,
    this.width,
    this.height,
    this.durationMillis,
    this.posterDigest,
    this.posterSize,
    this.metadataUnavailable = false,
  }) {
    if (!_hash(id) ||
        !_hash(generation) ||
        size <= 0 ||
        chunkCount <= 0 ||
        chunkCount > maxMediaChunks ||
        chunkCount != (size + mediaChunkBytes - 1) ~/ mediaChunkBytes ||
        utf8.encode(name).length > 512 ||
        mimeType.length > 80 ||
        RegExp(r'[\x00-\x1f]').hasMatch(mimeType) ||
        (posterDigest == null) != (posterSize == null) ||
        (posterDigest != null &&
            (!_hash(posterDigest!) ||
                posterSize! <= 0 ||
                posterSize! > mediaChunkBytes)) ||
        (width == null) != (height == null) ||
        (width != null &&
            (width! < 1 || width! > 32768 || height! < 1 || height! > 32768)) ||
        (durationMillis != null &&
            (durationMillis! < 0 || durationMillis! > 30 * 86400000))) {
      throw const FormatException('Invalid remote media');
    }
  }

  /// Validates metadata received through an authenticated index response.
  factory fromJson(Map<String, Object?> json) => RemoteMedia(
    id: json['content']! as String,
    name: json['name']! as String,
    size: json['size']! as int,
    mimeType: json['mime']! as String,
    generation: json['generation']! as String,
    chunkCount: json['count']! as int,
    width: json['width'] as int?,
    height: json['height'] as int?,
    durationMillis: json['duration'] as int?,
    posterDigest: json['posterDigest'] as String?,
    posterSize: json['posterSize'] as int?,
    metadataUnavailable: json['metadataUnavailable'] as bool? ?? true,
  );

  /// Full-content SHA-256 identifier.
  final String id;

  /// Original bounded display name disclosed after approval.
  final String name;

  /// Complete content length in bytes.
  final int size;

  /// MIME type supplied by the authenticated owner.
  final String mimeType;

  /// Canonical SHA-256 digest of the authenticated integrity manifest.
  final String generation;

  /// Number of complete or final partial integrity blocks.
  final int chunkCount;

  /// Actual extracted width, or null when unsupported.
  final int? width;

  /// Actual extracted height, or null when unsupported.
  final int? height;

  /// Actual extracted duration, or null when unsupported.
  final int? durationMillis;

  /// SHA-256 of the protected encoded poster, when available.
  final String? posterDigest;

  /// Exact encoded poster byte length.
  final int? posterSize;

  /// Whether the owner reported unsupported or unavailable extraction.
  final bool metadataUnavailable;
}

/// Pending request requiring an explicit owner approval or denial.
class AccessRequest {
  new _(this.session, this.requestId);

  /// Authenticated session that submitted this request.
  final PeerSession session;

  /// Authenticated viewer node identifier, not its display name.
  String get peerId => session.peerId;

  /// Random request identifier scoped to the session.
  final String requestId;
  Timer? _expiry;
}

class _Pending {
  new(this.session, {this.expectedLength, this.expectedDigest});
  final PeerSession session;
  final Stopwatch watch = Stopwatch()..start();
  final int? expectedLength;
  final String? expectedDigest;
  final result = Completer<Object?>();
  Uint8List? bytes;
  int received = 0;
  Timer? timer;
  // Cancelled by both _fail and _complete when this request leaves _pending.
  // ignore: cancel_subscriptions
  StreamSubscription<void>? cancellationSubscription;
}

/// Explicit opt-in owner service and authenticated remote client. Every owner
/// read rechecks the session-bound viewer token, including each bulk fragment.
class VaultDelivery {
  /// Opens the bounded client cache and an explicitly disabled owner service.
  new({
    required this.library,
    required this.authorization,
    required this.cacheDirectory,
    int maxCacheBytes = 256 * 1024 * 1024,
    this.maxDownloadBytes = 8 * 1024 * 1024 * 1024,
  }) : cache = SparseMediaCache(
         Directory('${cacheDirectory.path}/chunks'),
         maxBytes: maxCacheBytes,
       ) {
    if (maxDownloadBytes <= 0) {
      throw ArgumentError.value(maxDownloadBytes, 'maxDownloadBytes');
    }
    _ready = _load();
    _ready.ignore();
  }

  /// Real local index used for owner-approved reads.
  final VaultLibrary library;

  /// Protected persistent owner grant authority.
  final AuthorizationRepository authorization;

  /// App-owned sparse-cache, token and explicit-download directory.
  final Directory cacheDirectory;

  /// Verified and bounded disk-only chunk cache.
  final SparseMediaCache cache;

  /// Aggregate budget for explicit saved and staging downloads.
  final int maxDownloadBytes;

  late final Future<void> _ready;
  final _sessions = <String, PeerSession>{};
  final _subscriptions = <String, List<StreamSubscription<Object?>>>{};
  final _messengerSessions = <String>{};
  final _grants = <String, GrantedAccess>{};
  final _pending = <String, _Pending>{};
  final _access = <String, AccessRequest>{};
  final _ownerReads = <String, DeliveryCancellation>{};
  final _players = <String, List<VaultRangeServer>>{};
  final _playTails = <String, Future<void>>{};
  final _playGenerations = <String, int>{};
  final _playbackUrls = <String, ({Uri uri, int generation})>{};
  final _downloads = <DeliveryCancellation>{};
  final _requests = StreamController<AccessRequest>.broadcast();
  final _requestChanges = StreamController<List<AccessRequest>>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  Future<void> _grantWrites = Future.value();
  bool _publishing = false;
  bool _closed = false;
  Future<void>? _closeFuture;
  bool _downloadActive = false;
  Completer<void>? _downloadFinished;

  /// Incoming authenticated requests awaiting explicit owner consent.
  Stream<AccessRequest> get accessRequests => _requests.stream;

  /// Immutable pending-request snapshots after every arrival or end transition.
  /// No initial snapshot is replayed. Cancel the subscription when its consumer
  /// is disposed; [close] removes remaining requests and closes this stream.
  Stream<List<AccessRequest>> get accessRequestChanges =>
      _requestChanges.stream;

  /// Asynchronous protocol/source failures for visible application reporting.
  Stream<Object> get errors => _errors.stream;

  /// Whether the owner explicitly enabled new protected reads.
  bool get publishing => _publishing;

  /// Surfaces cache/token startup errors before the UI begins serving requests.
  Future<void> load() => _ready;

  Future<void> _load() async {
    await cacheDirectory.create(recursive: true);
    await cache.load();
    final file = File('${cacheDirectory.path}/viewer-grants.json');
    if (!await file.exists()) return;
    if (await file.length() > 1024 * 1024) {
      throw const FormatException('Grant cache too large');
    }
    final data = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    if (data.length > 256) {
      throw const FormatException('Too many cached grants');
    }
    for (final row in data.entries) {
      nodeIdFromText(row.key);
      _grants[row.key] = GrantedAccess.fromJson(
        row.value! as Map<String, Object?>,
      );
    }
  }

  Future<void> _saveGrants() {
    final result = _grantWrites.then((_) async {
      final file = File('${cacheDirectory.path}/viewer-grants.json');
      final next = File('${file.path}.next');
      await next.writeAsString(
        jsonEncode(_grants.map((key, value) => MapEntry(key, value.toJson()))),
        flush: true,
      );
      if (await file.exists()) await file.delete();
      await next.rename(file.path);
    });
    _grantWrites = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Consumes the sole packet stream; optional chat routing is independent of
  /// publication and does not grant any media access.
  void attach(
    PeerSession session, {
    Future<void> Function(PeerSession, Map<String, Object?>)?
    onMessengerControl,
  }) {
    if (_closed) throw StateError('Delivery closed');
    if (_sessions.containsKey(session.sessionId)) return;
    if (_sessions.length >= 16) throw StateError('Session limit');
    _sessions[session.sessionId] = session;
    if (onMessengerControl != null) _messengerSessions.add(session.sessionId);
    var activeControls = 0;
    void dispatch(Future<void> Function() operation) {
      // Never accumulate unbounded futures while a remote peer floods controls.
      if (activeControls >= 16) {
        unawaited(session.close().catchError(_report));
        return;
      }
      activeControls++;
      unawaited(
        Future<void>.sync(operation).catchError(_report).whenComplete(() {
          activeControls--;
        }),
      );
    }

    _subscriptions[session.sessionId] = [
      session.packets.listen((packet) {
        if (session.state != PeerSessionState.connected) return;
        if (packet.kind == PeerPacketKind.control &&
            packet.control?['vault'] == 'delivery') {
          dispatch(() => _control(session, packet.control!));
        } else if (packet.kind == PeerPacketKind.control &&
            packet.control?['vault'] == 'messenger' &&
            onMessengerControl != null) {
          dispatch(() => onMessengerControl(session, packet.control!));
        } else if (packet.kind == PeerPacketKind.bulk && packet.bytes != null) {
          try {
            _bulk(session, packet.bytes!);
          } on Object catch (error) {
            _report(error);
          }
        }
      }, onError: _report),
      session.states.listen((state) {
        if (state == PeerSessionState.closed ||
            state == PeerSessionState.failed) {
          unawaited(_detach(session));
        } else if (state != PeerSessionState.connected) {
          unawaited(
            _interrupt(session, const DeliveryCancelled()).catchError(_report),
          );
        }
      }),
    ];
  }

  void _report(Object error) {
    if (!_closed) _errors.add(error);
  }

  AccessRequest? _dropAccess(String id) {
    final request = _access.remove(id);
    request?._expiry?.cancel();
    if (request != null) _publishAccess();
    return request;
  }

  void _publishAccess() {
    _requestChanges.add(List<AccessRequest>.unmodifiable(_access.values));
  }

  void _clearAccess() {
    if (_access.isEmpty) return;
    for (final request in _access.values) {
      request._expiry?.cancel();
    }
    _access.clear();
    _publishAccess();
  }

  Future<void> _interrupt(PeerSession session, Object reason) {
    final key = session.sessionId;
    _playGenerations[key] = (_playGenerations[key] ?? 0) + 1;
    _playbackUrls.remove(key);
    for (final row in _pending.entries.toList()) {
      if (identical(row.value.session, session)) {
        _fail(row.key, reason);
      }
    }
    for (final request
        in _access.values
            .where((r) => identical(r.session, session))
            .toList()) {
      _dropAccess(request.requestId);
    }
    for (final row in _ownerReads.entries) {
      if (row.key.startsWith('${session.sessionId}:')) row.value.cancel();
    }
    // Begin closing immediately, and make replacement playback join teardown.
    final servers = _players.remove(key) ?? <VaultRangeServer>[];
    final previous = _playTails[key];
    final tail = Future.wait<void>([
      ?previous,
      for (final server in servers) server.close(),
    ]).then<void>((_) {}, onError: _report);
    _trackPlaybackTail(key, tail);
    return tail;
  }

  Future<void> _detach(PeerSession session) async {
    _sessions.remove(session.sessionId);
    _messengerSessions.remove(session.sessionId);
    final interrupted = _interrupt(session, StateError('Peer disconnected'));
    for (final sub
        in _subscriptions.remove(session.sessionId) ??
            <StreamSubscription<Object?>>[]) {
      await sub.cancel();
    }
    await interrupted;
    if (!_sessions.containsKey(session.sessionId)) {
      _playGenerations.remove(session.sessionId);
    }
  }

  /// Enables serving, or cancels media work without revoking remembered grants.
  ///
  /// The positional boolean preserves the shared application lifecycle API.
  // ignore: avoid_positional_boolean_parameters
  Future<void> setPublishing(bool enabled) async {
    await _ready;
    if (_closed) throw StateError('Delivery closed');
    _publishing = enabled;
    if (enabled) return;
    for (final cancellation in _ownerReads.values) {
      cancellation.cancel();
    }
    _clearAccess();
    // Chat-enabled sessions outlive publication. Interrupt all media work;
    // subsequent owner reads still require publication.
    for (final session in _sessions.values.toList()) {
      if (_messengerSessions.contains(session.sessionId)) {
        await _interrupt(session, const DeliveryCancelled());
      } else {
        await session.close();
        await _detach(session);
      }
    }
  }

  /// Requests explicit owner consent and persists the returned viewer token.
  Future<void> requestAccess(PeerSession session) async {
    final response = await _request(
      session,
      'access',
      {},
      timeout: const Duration(minutes: 2),
    );
    final json = response! as Map<String, Object?>;
    final grant = GrantedAccess.fromJson(
      json['grant']! as Map<String, Object?>,
    );
    if (_grants.length >= 256 && !_grants.containsKey(session.peerId)) {
      throw StateError('Grant limit');
    }
    _grants[session.peerId] = grant;
    await _saveGrants();
  }

  /// Persists consent before sending a viewer-bound capability token.
  Future<void> approve(AccessRequest request) async {
    await _ready;
    if (!_publishing ||
        !identical(_access[request.requestId], request) ||
        request.session.state != PeerSessionState.connected) {
      throw StateError(
        'Access request no longer active or publication stopped',
      );
    }
    final grant = await authorization.approve(
      viewerId: nodeIdFromText(request.peerId),
      resource: _scope,
      actions: ['browse', 'play', 'download'],
    );
    _dropAccess(request.requestId);
    if (!_publishing) throw StateError('Publication stopped');
    await _reply(request.session, request.requestId, {'grant': grant.toJson()});
  }

  /// Denies the pending request without disclosing private metadata.
  Future<void> deny(AccessRequest request) async {
    if (identical(_dropAccess(request.requestId), request)) {
      await _error(request.session, request.requestId, 'Access denied');
    }
  }

  /// Persists revocations before cancelling only this viewer's serving work.
  Future<void> revoke(String peerId) async {
    await authorization.revokeViewer(nodeIdFromText(peerId));
    final sessions = _sessions.values.where((s) => s.peerId == peerId).toList();
    for (final session in sessions) {
      for (final row in _ownerReads.entries) {
        if (row.key.startsWith('${session.sessionId}:')) row.value.cancel();
      }
      await session.close();
      await _detach(session);
    }
  }

  Future<Map<String, Object?>> _credentials(PeerSession session) async {
    await _ready;
    final grant = _grants[session.peerId];
    if (grant == null) throw StateError('Request owner approval first');
    return {'grant': grant.toJson()};
  }

  /// Collects bounded authenticated index pages after owner approval.
  Future<List<RemoteMedia>> browse(PeerSession session) async {
    final result = <RemoteMedia>[];
    for (
      var page = 0;
      page < (maxLibraryItems + _browsePageSize - 1) ~/ _browsePageSize;
      page++
    ) {
      final response =
          (await _request(session, 'browse', {
                ...await _credentials(session),
                'page': page,
              }))!
              as Map<String, Object?>;
      final rows = (response['items']! as List<Object?>)
          .cast<Map<String, Object?>>();
      if (rows.length > _browsePageSize) {
        throw const FormatException('Oversized library page');
      }
      result.addAll(rows.map(RemoteMedia.fromJson));
      if (result.length > maxLibraryItems) {
        throw const FormatException('Library limit');
      }
      if (response['more'] == false) return result;
    }
    throw const FormatException('Library pagination limit');
  }

  /// Returns a verified bounded real preview after a fresh permission check.
  Future<Uint8List?> poster(PeerSession session, RemoteMedia item) async {
    final digest = item.posterDigest;
    final length = item.posterSize;
    if (digest == null || length == null) return null;
    await _request(session, 'permit', {
      ...await _credentials(session),
      'content': item.id,
      'generation': item.generation,
      'action': 'browse',
    });
    final cached = await cache.read(digest, 0, digest, length);
    if (cached != null) {
      validateMediaPoster(cached);
      return cached;
    }
    final bytes =
        (await _request(
              session,
              'poster',
              {
                ...await _credentials(session),
                'content': item.id,
                'generation': item.generation,
                'posterDigest': digest,
              },
              expectedLength: length,
              expectedDigest: digest,
            ))!
            as Uint8List;
    validateMediaPoster(bytes);
    await cache.put(digest, 0, digest, bytes);
    return bytes;
  }

  Future<List<String>> _manifest(
    PeerSession session,
    RemoteMedia item,
    String action, {
    DeliveryCancellation? cancellation,
  }) async {
    final chunks = <String>[];
    for (var offset = 0; offset < item.chunkCount; offset += 64) {
      final response = await _request(session, 'manifest', {
        ...await _credentials(session),
        'content': item.id,
        'generation': item.generation,
        'action': action,
        'offset': offset,
      }, cancellation: cancellation);
      final page =
          ((response! as Map<String, Object?>)['chunks']! as List<Object?>)
              .cast<String>();
      if (page.length != min(64, item.chunkCount - offset) ||
          page.any((hash) => !_hash(hash))) {
        throw const FormatException('Invalid manifest page');
      }
      chunks.addAll(page);
    }
    if (manifestDigest(item.id, item.size, chunks) != item.generation) {
      throw const FormatException('Manifest authentication failed');
    }
    return chunks;
  }

  Future<Uint8List> _chunk(
    PeerSession session,
    RemoteMedia item,
    List<String> hashes,
    int index,
    String action,
    DeliveryCancellation cancellation,
  ) async {
    cancellation.check();
    final length = min(mediaChunkBytes, item.size - index * mediaChunkBytes);
    // Reauthorize cached playback too. Revocation cannot recall saved copies.
    await _request(session, 'permit', {
      ...await _credentials(session),
      'content': item.id,
      'generation': item.generation,
      'action': action,
    }, cancellation: cancellation);
    cancellation.check();
    final cached = await cache.read(item.id, index, hashes[index], length);
    cancellation.check();
    if (cached != null) return cached;
    final bytes =
        (await _request(
              session,
              'chunk',
              {
                ...await _credentials(session),
                'content': item.id,
                'generation': item.generation,
                'action': action,
                'index': index,
              },
              expectedLength: length,
              expectedDigest: hashes[index],
              cancellation: cancellation,
            ))!
            as Uint8List;
    cancellation.check();
    await cache.put(item.id, index, hashes[index], bytes);
    return bytes;
  }

  /// Replaces playback with a secret loopback URL backed by verified ranges.
  Future<Uri> play(PeerSession session, RemoteMedia item) {
    final key = session.sessionId;
    if (_closed ||
        session.state != PeerSessionState.connected ||
        !identical(_sessions[key], session)) {
      return Future.error(StateError('Peer detached'));
    }
    final generation = (_playGenerations[key] ?? 0) + 1;
    _playGenerations[key] = generation;
    void check() {
      if (_closed ||
          session.state != PeerSessionState.connected ||
          !_sessions.containsKey(key) ||
          _playGenerations[key] != generation) {
        throw const DeliveryCancelled();
      }
    }

    final previousTail = _playTails[key] ?? Future<void>.value();
    final result = previousTail.then((_) async {
      check();
      final hashes = await _manifest(session, item, 'play');
      check();
      _playbackUrls.remove(key);
      for (final server in _players.remove(key) ?? <VaultRangeServer>[]) {
        await server.close();
      }
      check();
      final server = VaultRangeServer(
        contentId: item.id,
        length: item.size,
        mimeType: item.mimeType,
        fetchChunk: (index, rangeCancellation) async {
          check();
          final cancellation = DeliveryCancellation();
          if (rangeCancellation.isCancelled) cancellation.cancel();
          unawaited(
            rangeCancellation.cancelled.then((_) => cancellation.cancel()),
          );
          try {
            final bytes = await _chunk(
              session,
              item,
              hashes,
              index,
              'play',
              cancellation,
            );
            rangeCancellation.check();
            check();
            return bytes;
          } finally {
            cancellation.cancel();
          }
        },
      );
      try {
        final uri = await server.start();
        check();
        _players[key] = [server];
        _playbackUrls[key] = (uri: uri, generation: generation);
        return uri;
      } on Object catch (_) {
        await server.close();
        rethrow;
      }
    });
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _trackPlaybackTail(key, tail);
    return result;
  }

  void _trackPlaybackTail(String key, Future<void> tail) {
    _playTails[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_playTails[key], tail)) {
          unawaited(_playTails.remove(key));
        }
      }, onError: (Object _, StackTrace _) {}),
    );
  }

  /// Releases only the listener opened for [uri], without disconnecting a peer.
  ///
  /// A late viewer teardown cannot close or invalidate a newer playback.
  Future<void> stopPlayback(PeerSession session, Uri uri) async {
    final key = session.sessionId;
    final current = _playbackUrls[key];
    if (current == null || current.uri != uri) return;
    _playbackUrls.remove(key);
    if (_playGenerations[key] == current.generation) {
      _playGenerations[key] = current.generation + 1;
    }
    final servers = _players.remove(key);
    if (servers != null) {
      for (final server in servers) {
        await server.close();
      }
    }
  }

  /// Downloads or resumes a verified disk prefix within the save quota.
  ///
  /// Cancellation retains complete chunks; progress counts durable bytes.
  Future<File> download(
    PeerSession session,
    RemoteMedia item, {
    DeliveryCancellation? cancellation,
    void Function(int received, int total)? onProgress,
  }) async {
    await _ready;
    if (_closed) throw StateError('Delivery closed');
    if (_downloadActive) {
      throw StateError('Only one active download is allowed');
    }
    _downloadActive = true;
    _downloadFinished = Completer<void>();
    final cancel = cancellation ?? DeliveryCancellation();
    _downloads.add(cancel);
    RandomAccessFile? output;
    try {
      final hashes = await _manifest(
        session,
        item,
        'download',
        cancellation: cancel,
      );
      final directory = await Directory('${cacheDirectory.path}/downloads')
          .create(recursive: true);
      final file = File('${directory.path}/${item.id}.part');
      final destination = File('${directory.path}/${item.id}.media');
      if (await destination.exists() &&
          await destination.length() == item.size &&
          await _hashDownload(destination, cancel) == item.id) {
        cancel.check();
        await _request(session, 'permit', {
          ...await _credentials(session),
          'content': item.id,
          'generation': item.generation,
          'action': 'download',
        }, cancellation: cancel);
        onProgress?.call(item.size, item.size);
        return destination;
      }
      var reserved = item.size;
      var entries = 0;
      await for (final entry in directory.list()) {
        if (++entries > maxLibraryItems) {
          throw StateError('Download entry limit');
        }
        if (entry is File && entry.path != file.path) {
          reserved += await entry.length();
        }
      }
      if (reserved > maxDownloadBytes) {
        throw StateError(
          'Download storage budget exceeded; remove cached downloads '
          'or raise maxDownloadBytes',
        );
      }
      output = await file.open(mode: FileMode.append);
      // Restart resume trusts no bitmap: rehash each existing complete chunk in
      // order. A partial tail is truncated before new data is appended.
      var position = 0;
      final available = await output.length();
      for (var index = 0; index < hashes.length; index++) {
        cancel.check();
        final length = min(mediaChunkBytes, item.size - position);
        if (position + length > available) break;
        await output.setPosition(position);
        final bytes = await output.read(length);
        if (sha256.convert(bytes).toString() != hashes[index]) break;
        position += length;
      }
      await output.truncate(position);
      await output.setPosition(position);
      onProgress?.call(position, item.size);
      while (position < item.size) {
        cancel.check();
        final bytes = await _chunk(
          session,
          item,
          hashes,
          position ~/ mediaChunkBytes,
          'download',
          cancel,
        );
        await output.writeFrom(bytes);
        await output.flush();
        position += bytes.length;
        onProgress?.call(position, item.size);
      }
      await output.close();
      output = null;
      cancel.check();
      if (await _hashDownload(file, cancel) != item.id) {
        throw const FormatException('Full content digest mismatch');
      }
      // Revalidate completion even if the entire partial file already existed.
      await _request(session, 'permit', {
        ...await _credentials(session),
        'content': item.id,
        'generation': item.generation,
        'action': 'download',
      }, cancellation: cancel);
      if (await destination.exists()) await destination.delete();
      return await file.rename(destination.path);
    } finally {
      try {
        await output?.close();
      } finally {
        _downloads.remove(cancel);
        _downloadActive = false;
        _downloadFinished?.complete();
        _downloadFinished = null;
      }
    }
  }

  Future<Object?> _request(
    PeerSession session,
    String op,
    Map<String, Object?> fields, {
    int? expectedLength,
    String? expectedDigest,
    DeliveryCancellation? cancellation,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await _ready;
    cancellation?.check();
    if (_closed ||
        session.state != PeerSessionState.connected ||
        !_sessions.containsKey(session.sessionId)) {
      throw StateError('Peer not connected/attached');
    }
    if (_pending.length >= 4) throw StateError('In-flight request limit');
    final id = _randomId();
    final pending = _Pending(
      session,
      expectedLength: expectedLength,
      expectedDigest: expectedDigest,
    );
    _pending[id] = pending;
    // Attach an error consumer immediately: disconnect may precede completion
    // of the bounded native send, before this async method returns its future.
    unawaited(
      pending.result.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    pending.timer = Timer(timeout, () {
      _fail(
        id,
        TimeoutException(
          'Delivery $op timeout: ${pending.received}/'
          '${expectedLength ?? 0} bytes after '
          '${pending.watch.elapsedMilliseconds} ms',
        ),
      );
      unawaited(_sendCancel(session, id));
    });
    if (cancellation != null) {
      pending.cancellationSubscription = cancellation.onCancel.listen((_) {
        if (identical(_pending[id], pending)) {
          _fail(id, const DeliveryCancelled());
          unawaited(_sendCancel(session, id));
        }
      });
    }
    // A route pause can cancel the response before a bounded native send
    // finishes. Do not hold the caller or its transfer slot behind that send.
    try {
      unawaited(
        session
            .sendControl({'vault': 'delivery', 'op': op, 'id': id, ...fields})
            .catchError((Object error) => _fail(id, error)),
      );
    } on Object catch (error) {
      _fail(id, error);
    }
    return await pending.result.future;
  }

  Future<void> _sendCancel(PeerSession session, String id) async {
    if (session.state != PeerSessionState.connected) return;
    try {
      await session.sendControl({
        'vault': 'delivery',
        'op': 'cancel',
        'id': id,
      });
    } on Object catch (_) {
      /* peer may already be closed */
    }
  }

  void _fail(String id, Object error) {
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.timer?.cancel();
    unawaited(pending.cancellationSubscription?.cancel());
    if (!pending.result.isCompleted) pending.result.completeError(error);
  }

  void _complete(String id, Object? value) {
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.timer?.cancel();
    unawaited(pending.cancellationSubscription?.cancel());
    pending.result.complete(value);
  }

  Future<void> _reply(
    PeerSession session,
    String id,
    Map<String, Object?> data,
  ) => session.sendControl({
    'vault': 'delivery',
    'op': 'response',
    'id': id,
    ...data,
  });
  Future<void> _error(PeerSession session, String id, String error) =>
      session.sendControl({
        'vault': 'delivery',
        'op': 'error',
        'id': id,
        'error': error,
      });
  Future<void> _check(
    PeerSession session,
    Map<String, Object?> message,
    String action,
  ) async {
    if (!_publishing ||
        _closed ||
        session.state != PeerSessionState.connected) {
      throw StateError('Owner not publishing');
    }
    final access = GrantedAccess.fromJson(
      message['grant']! as Map<String, Object?>,
    );
    await authorization.check(
      access: access,
      viewerId: nodeIdFromText(session.peerId),
      resource: _scope,
      action: action,
    );
    if (!_publishing) throw StateError('Owner stopped publication');
  }

  LibraryItem _item(Map<String, Object?> message) {
    final id = message['content'];
    final item = id is String ? library.byId(id) : null;
    if (item == null || item.generation != message['generation']) {
      throw StateError('Unknown content generation');
    }
    return item;
  }

  Future<T> _untilCancelled<T>(
    Future<T> operation,
    DeliveryCancellation cancellation,
  ) => Future.any<T>([
    operation,
    cancellation.cancelled.then<T>((_) => throw const DeliveryCancelled()),
  ]);

  Future<void> _control(
    PeerSession session,
    Map<String, Object?> message,
  ) async {
    final id = message['id'];
    final op = message['op'];
    if (id is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        op is! String) {
      throw const FormatException('Invalid delivery message');
    }
    if (op == 'response' || op == 'error') {
      final pending = _pending[id];
      if (pending == null || !identical(pending.session, session)) return;
      if (op == 'error') {
        _fail(id, StateError('Owner denied request'));
        return;
      }
      if (pending.expectedLength != null) {
        _fail(id, const FormatException('Expected bulk data'));
        return;
      }
      _complete(id, message);
      return;
    }
    final key = '${session.sessionId}:$id';
    if (op == 'cancel') {
      _ownerReads[key]?.cancel();
      final access = _access[id];
      if (access != null && identical(access.session, session)) _dropAccess(id);
      return;
    }
    if (op == 'access') {
      if (!_publishing ||
          _access.length >= 32 ||
          _access.values.any((r) => identical(r.session, session))) {
        await _error(session, id, 'Unavailable');
        return;
      }
      final request = AccessRequest._(session, id);
      _access[id] = request;
      _requests.add(request);
      _publishAccess();
      request._expiry = Timer(const Duration(minutes: 2), () {
        if (identical(_access[id], request)) _dropAccess(id);
      });
      return;
    }
    if (_ownerReads.length >= 4 || _ownerReads.containsKey(key)) {
      await _error(session, id, 'Busy');
      return;
    }
    final cancellation = DeliveryCancellation();
    _ownerReads[key] = cancellation;
    try {
      if (op == 'browse') {
        await _check(session, message, 'browse');
        cancellation.check();
        final page = message['page'];
        if (page is! int ||
            page < 0 ||
            page >=
                (maxLibraryItems + _browsePageSize - 1) ~/ _browsePageSize) {
          throw const FormatException('Invalid page');
        }
        final start = min(page * _browsePageSize, library.length);
        final items = library.page(start, limit: _browsePageSize);
        final end = start + items.length;
        await _untilCancelled(
          _reply(session, id, {
            'items': items
                .map(
                  (item) => {
                    'content': item.id,
                    'name': item.name,
                    'size': item.size,
                    'mime': item.mimeType,
                    'generation': item.generation,
                    'count': item.chunks.length,
                    'width': item.metadata.width,
                    'height': item.metadata.height,
                    'duration': item.metadata.durationMillis,
                    'posterDigest': item.posterDigest,
                    'posterSize': item.posterSize,
                    'metadataUnavailable':
                        item.metadata.unavailableReason != null,
                  },
                )
                .toList(),
            'more': end < library.length,
          }),
          cancellation,
        );
      } else if (op == 'manifest' ||
          op == 'permit' ||
          op == 'chunk' ||
          op == 'poster') {
        final action = op == 'poster' ? 'browse' : message['action']! as String;
        if (action != 'play' &&
            action != 'download' &&
            !(action == 'browse' && (op == 'poster' || op == 'permit'))) {
          throw const FormatException('Invalid delivery action');
        }
        await _check(session, message, action);
        cancellation.check();
        final item = _item(message);
        if (op == 'permit') {
          await _untilCancelled(_reply(session, id, {}), cancellation);
          return;
        }
        if (op == 'manifest') {
          final offset = message['offset'];
          if (offset is! int ||
              offset < 0 ||
              offset >= item.chunks.length ||
              offset % 64 != 0) {
            throw const FormatException('Invalid manifest offset');
          }
          await _untilCancelled(
            _reply(session, id, {
              'chunks': item.chunks.sublist(
                offset,
                min(offset + 64, item.chunks.length),
              ),
            }),
            cancellation,
          );
          return;
        }
        final Uint8List bytes;
        if (op == 'poster') {
          if (item.posterDigest != message['posterDigest']) {
            throw StateError('Poster generation changed');
          }
          bytes = await _untilCancelled(library.readPoster(item), cancellation);
        } else {
          final index = message['index'];
          if (index is! int || index < 0 || index >= item.chunks.length) {
            throw const FormatException('Invalid chunk index');
          }
          bytes = await _untilCancelled(
            library.readChunk(item, index),
            cancellation,
          );
        }
        for (var offset = 0; offset < bytes.length; offset += _fragmentBytes) {
          cancellation.check();
          await _check(session, message, action);
          cancellation.check();
          if (_item(message).generation != item.generation) {
            throw StateError('Content removed');
          }
          final count = min(_fragmentBytes, bytes.length - offset);
          final frame = Uint8List(40 + count);
          ByteData.sublistView(frame)
            ..setUint32(32, offset)
            ..setUint32(36, bytes.length);
          frame
            ..setRange(0, 32, ascii.encode(id))
            ..setRange(40, frame.length, bytes, offset);
          await _untilCancelled(session.sendBulk(frame), cancellation);
        }
      } else {
        throw const FormatException('Unknown delivery operation');
      }
    } on Object catch (error) {
      if (error is! DeliveryCancelled &&
          session.state == PeerSessionState.connected) {
        try {
          await _error(session, id, 'Denied or unavailable');
        } on Object catch (_) {}
      }
      if (error is! DeliveryCancelled) _report(error);
    } finally {
      cancellation.cancel();
      _ownerReads.remove(key);
    }
  }

  void _bulk(PeerSession session, Uint8List frame) {
    if (frame.length <= 40 || frame.length > 40 + _fragmentBytes) {
      throw const FormatException('Invalid fragment envelope');
    }
    final id = ascii.decode(Uint8List.sublistView(frame, 0, 32));
    final pending = _pending[id];
    if (pending == null || !identical(pending.session, session)) return;
    final header = ByteData.sublistView(frame);
    final offset = header.getUint32(32);
    final total = header.getUint32(36);
    final count = frame.length - 40;
    if (pending.expectedLength != total ||
        total > mediaChunkBytes ||
        offset != pending.received ||
        offset + count > total) {
      _fail(id, const FormatException('Invalid or out-of-order fragment'));
      return;
    }
    pending.bytes ??= Uint8List(total);
    pending.bytes!.setRange(offset, offset + count, frame, 40);
    pending.received += count;
    if (pending.received == total) {
      if (sha256.convert(pending.bytes!).toString() != pending.expectedDigest) {
        _fail(id, const FormatException('Chunk integrity failure'));
        return;
      }
      _complete(id, pending.bytes);
    }
  }

  /// Cancels and joins transfers, peer sessions and all loopback replacements.
  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _publishing = false;
    _clearAccess();
    for (final cancellation in _downloads) {
      cancellation.cancel();
    }
    for (final cancellation in _ownerReads.values) {
      cancellation.cancel();
    }
    for (final key in _pending.keys.toList()) {
      _fail(key, const DeliveryCancelled());
    }
    for (final session in _sessions.values.toList()) {
      await session.close();
      await _detach(session);
    }
    await Future.wait(_playTails.values.toList());
    await _downloadFinished?.future;
    _playGenerations.clear();
    await _grantWrites;
    try {
      await _ready;
    } on Object catch (_) {
      /* load() reports startup failure; cleanup still completes. */
    }
    await _requests.close();
    await _requestChanges.close();
    await _errors.close();
  }
}

class _DownloadDigestSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest value) => digest = value;
  @override
  void close() {}
}

Future<String> _hashDownload(
  File file,
  DeliveryCancellation cancellation,
) async {
  final result = _DownloadDigestSink();
  final sink = sha256.startChunkedConversion(result);
  await for (final bytes in file.openRead()) {
    cancellation.check();
    sink.add(bytes);
  }
  cancellation.check();
  sink.close();
  return result.digest!.toString();
}
