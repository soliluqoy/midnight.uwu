import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// A requested read has been abandoned or the server has shut down.
class RangeCancelled implements Exception {
  /// Creates the signal thrown when a response no longer needs its bytes.
  const new();

  @override
  String toString() => 'RangeCancelled';
}

/// Cooperative cancellation shared with the verified-chunk fetcher.
class RangeCancellation {
  final Completer<void> _cancelled = Completer<void>();
  final Set<void Function()> _listeners = <void Function()>{};

  /// Whether completion, shutdown, a deadline or an explicit call cancelled it.
  bool get isCancelled => _cancelled.isCompleted;

  /// Completes on cancellation, never with an error.
  Future<void> get cancelled => _cancelled.future;

  /// Signals cancellation once and wakes pending chunk/response operations.
  void cancel() {
    if (isCancelled) return;
    _cancelled.complete();
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }

  /// Throws [RangeCancelled] if this response must stop fetching or sending.
  void check() {
    if (isCancelled) throw const RangeCancelled();
  }
}

/// Serves verified chunks to a native player without a sparse fake media file.
///
/// Only IPv4 loopback is bound. The URL contains a fresh 256-bit secret
/// capability: do not log or share it. The caller must verify chunk digests and
/// authorization before returning bytes, and cancel network work when signaled.
/// No cache or whole-file buffer is retained. At most four requests and one
/// chunk per request are in progress. Each GET is capped at 1 MiB, including
/// GETs without Range (which receive 206 when the resource is larger).
class VaultRangeServer {
  /// Creates a server whose fetcher supplies exact, already-verified chunks.
  ///
  /// [chunkBytes] must be positive and no larger than [maxResponseBytes].
  new({
    required this.contentId,
    required this.length,
    required String mimeType,
    required this.fetchChunk,
    this.chunkBytes = 262144,
  }) : mimeType = ContentType.parse(mimeType).toString() {
    if (contentId.isEmpty || contentId.length > 512) {
      throw ArgumentError.value(contentId, 'contentId');
    }
    if (length < 0) throw ArgumentError.value(length, 'length');
    if (chunkBytes <= 0 || chunkBytes > maxResponseBytes) {
      throw ArgumentError.value(chunkBytes, 'chunkBytes');
    }
  }

  /// Maximum admitted responses, including those stalled on output.
  static const int maxConcurrentRequests = 4;

  /// Maximum bytes returned by a single GET, regardless of its requested range.
  static const int maxResponseBytes = 1024 * 1024;

  /// Maximum fetch/output lifetime before cancellation and connection closure.
  static const Duration requestTimeout = Duration(seconds: 30);
  static const Duration _closeTimeout = Duration(seconds: 2);

  /// Resource identifier bound to the returned URL capability.
  final String contentId;

  /// Exact total size of the authenticated media resource.
  final int length;

  /// Parsed content type returned with successful responses.
  final String mimeType;

  /// Chunk size used by the fetcher, except for the shorter final chunk.
  final int chunkBytes;

  /// Fetches one authorized chunk whose integrity was verified by delivery.
  final Future<Uint8List> Function(int index, RangeCancellation cancellation)
  fetchChunk;

  HttpServer? _server;
  Uri? _uri;
  Future<Uri>? _starting;
  Future<void>? _closing;
  bool _closed = false;
  final Set<RangeCancellation> _active = <RangeCancellation>{};

  /// Binds an ephemeral port. Repeated calls return the same capability URL.
  Future<Uri> start() {
    if (_closed) return Future<Uri>.error(StateError('Range server is closed'));
    return _starting ??= _bind();
  }

  Future<Uri> _bind() async {
    final random = Random.secure();
    final token = base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw StateError('Range server is closed');
    }
    _server = server;
    server.idleTimeout = const Duration(seconds: 10);
    final uri = Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      pathSegments: <String>[token, contentId],
    );
    _uri = uri;
    server.listen(
      (request) => unawaited(_serve(request)),
      onError: (Object error) => unawaited(close()),
    );
    return uri;
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final cancellation = RangeCancellation();
    var started = false;
    Timer? deadline;
    try {
      // This transport deadline also destroys a stalled client's connection.
      // Cancelling a fetch alone cannot unblock a socket with a full buffer.
      response.deadline = requestTimeout;
      // Do not expose metadata or start remote reads for the wrong capability.
      if (request.uri.path != _uri?.path || request.uri.hasQuery) {
        response
          ..statusCode = HttpStatus.notFound
          ..contentLength = 0;
        return;
      }
      if (_closed || _active.length >= maxConcurrentRequests) {
        response
          ..statusCode = HttpStatus.serviceUnavailable
          ..contentLength = 0;
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        response.contentLength = 0;
        return;
      }
      _active.add(cancellation);
      deadline = Timer(requestTimeout, cancellation.cancel);
      void finished() {
        cancellation.cancel();
        _active.remove(cancellation);
      }

      unawaited(
        response.done.then<void>(
          (_) => finished(),
          onError: (Object error) => finished(),
        ),
      );
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentTypeHeader, mimeType);
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      final headers = request.headers[HttpHeaders.rangeHeader];
      final range = headers == null
          ? (0, length - 1)
          : headers.length == 1
          ? _parseRange(headers.single)
          : null;
      if (range == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        response.contentLength = 0;
        return;
      }
      final (start, requestedEnd) = range;
      // HEAD without Range describes the whole entity but never fetches it.
      final end = request.method == 'HEAD' && headers == null
          ? requestedEnd
          : min(requestedEnd, start + maxResponseBytes - 1);
      if (headers != null || end < length - 1) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$length',
        );
      }
      response.contentLength = end - start + 1;
      if (request.method == 'HEAD') return;
      var position = start;
      while (position <= end) {
        cancellation.check();
        final index = position ~/ chunkBytes;
        final bytes = await _whileActive(
          Future<Uint8List>.sync(() => fetchChunk(index, cancellation)),
          cancellation,
        );
        cancellation.check();
        final expected = min(chunkBytes, length - index * chunkBytes);
        if (bytes.length != expected) {
          throw StateError('Verified chunk has an invalid length');
        }
        final offset = position % chunkBytes;
        final count = min(bytes.length - offset, end - position + 1);
        started = true;
        response.add(Uint8List.sublistView(bytes, offset, offset + count));
        await _whileActive(response.flush(), cancellation);
        position += count;
      }
    } on Object catch (error) {
      // Do not send exception details or source identifiers to the client.
      // Once body output starts, a short response signals failure. Never fill
      // missing content with zeros or send an error document as media bytes.
      if (!started) {
        try {
          response.statusCode = error is RangeCancelled
              ? HttpStatus.serviceUnavailable
              : HttpStatus.badGateway;
          response.headers.removeAll(HttpHeaders.contentRangeHeader);
          response.contentLength = 0;
        } on Object {
          // The connection may already have been destroyed by close/abort.
        }
      }
    } finally {
      deadline?.cancel();
      cancellation.cancel();
      try {
        await response.close().timeout(_closeTimeout);
      } on Object {
        // Client aborts and deliberately truncated failed responses end here.
      }
    }
  }

  (int, int)? _parseRange(String value) {
    if (value.length > 128 || length == 0) return null;
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value);
    if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
      return null;
    }
    if (match[1]!.isEmpty) {
      final suffix = int.tryParse(match[2]!);
      if (suffix == null || suffix <= 0) return null;
      return (max(0, length - suffix), length - 1);
    }
    final start = int.tryParse(match[1]!);
    final requestedEnd = match[2]!.isEmpty
        ? length - 1
        : int.tryParse(match[2]!);
    if (start == null || requestedEnd == null || start >= length) return null;
    final end = min(requestedEnd, length - 1);
    if (start > end) return null;
    return (start, end);
  }

  Future<T> _whileActive<T>(
    Future<T> operation,
    RangeCancellation cancellation,
  ) {
    final result = Completer<T>();
    void aborted() {
      if (!result.isCompleted) result.completeError(const RangeCancelled());
    }

    cancellation._listeners.add(aborted);
    if (cancellation.isCancelled) aborted();
    unawaited(
      operation.then<void>(
        (value) {
          cancellation._listeners.remove(aborted);
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          cancellation._listeners.remove(aborted);
          if (!result.isCompleted) result.completeError(error, stack);
        },
      ),
    );
    return result.future;
  }

  /// Cancels outstanding reads and forcibly closes all loopback connections.
  ///
  /// This does not await an uncooperative remote fetcher. That fetcher must use
  /// the cancellation signal to release its own network/cache resources.
  Future<void> close() {
    _closed = true;
    return _closing ??= _shutdown();
  }

  Future<void> _shutdown() async {
    for (final cancellation in _active.toList()) {
      cancellation.cancel();
    }
    await _server?.close(force: true);
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } on Object {
        // A bind finishing after close disposes its own socket before failing.
      }
    }
  }
}
