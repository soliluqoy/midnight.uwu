import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const rangeChunkBytes = 64 * 1024;

/// dart:io's HttpServer does not report a client abort until the response
/// closes, so each ranged response is capped. A player re-requests the rest.
const maxRangeResponseBytes = 4 * rangeChunkBytes;

class RangeCancelled implements Exception {
  const RangeCancelled();
}

class RangeCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get cancelled => _cancelled.future;
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const RangeCancelled();
  }
}

typedef RangeChunkFetcher = Future<Uint8List> Function(
  String fixture,
  int chunk,
  RangeCancellation cancellation,
);

class RemoteRangeCache {
  RemoteRangeCache(Map<String, int> lengths, this.fetch, {this.maxChunks = 4})
    : lengths = Map.unmodifiable(lengths) {
    if (maxChunks < 1) throw ArgumentError.value(maxChunks, 'maxChunks');
  }

  final Map<String, int> lengths;
  final RangeChunkFetcher fetch;
  final int maxChunks;
  final _entries = <(String, int), Uint8List>{};
  int hits = 0;
  int misses = 0;
  int evictions = 0;
  int peakBytes = 0;
  int get residentBytes => _entries.values.fold(0, (sum, b) => sum + b.length);

  void clear() => _entries.clear();

  Future<Uint8List> chunk(
    String fixture,
    int index,
    RangeCancellation cancellation,
  ) async {
    cancellation.check();
    final length = lengths[fixture];
    if (length == null || index < 0 || index * rangeChunkBytes >= length) {
      throw RangeError('Unknown fixture or chunk');
    }
    final key = (fixture, index);
    final cached = _entries.remove(key);
    if (cached != null) {
      hits++;
      _entries[key] = cached;
      return cached;
    }
    misses++;
    final bytes = await fetch(fixture, index, cancellation);
    cancellation.check();
    final expected = min(rangeChunkBytes, length - index * rangeChunkBytes);
    if (bytes.length != expected) {
      throw StateError('Invalid remote chunk length');
    }
    _entries.remove(key);
    while (_entries.length >= maxChunks) {
      _entries.remove(_entries.keys.first);
      evictions++;
    }
    // Copy so a view cannot retain an entire source file behind one cache entry.
    final owned = Uint8List.fromList(bytes);
    _entries[key] = owned;
    peakBytes = max(peakBytes, residentBytes);
    return owned;
  }
}

class RemoteRangeServer {
  RemoteRangeServer(this.cache, this.session);
  final RemoteRangeCache cache;
  final String session;
  final List<Map<String, Object?>> requests = [];
  HttpServer? _server;
  final _active = <RangeCancellation>{};
  bool _closed = false;
  int cancelledReads = 0;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) => unawaited(_serve(request)));
  }

  String url(String fixture) =>
      'http://127.0.0.1:${_server!.port}/$session/$fixture';

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    var started = false;
    final cancellation = RangeCancellation();
    if (_closed || _active.length >= 4) {
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }
    _active.add(cancellation);
    unawaited(
      response.done.then(
        (_) => cancellation.cancel(),
        onError: (Object _) => cancellation.cancel(),
      ),
    );
    try {
      final parts = request.uri.pathSegments;
      final fixture = parts.length == 2 && parts.first == session
          ? parts.last
          : null;
      final length = cache.lengths[fixture];
      if (fixture == null || length == null) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      var start = 0;
      var end = length - 1;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
        if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        } else if (match[1]!.isEmpty) {
          final suffix = int.tryParse(match[2]!);
          if (suffix == null || suffix <= 0) {
            response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          } else {
            start = max(0, length - suffix);
          }
        } else {
          start = int.tryParse(match[1]!) ?? length;
          end = match[2]!.isEmpty ? end : int.tryParse(match[2]!) ?? -1;
          end = min(end, length - 1);
          if (start >= length || start > end) {
            response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          }
        }
        if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$length',
          );
          response.contentLength = 0;
          return;
        }
        end = min(end, start + maxRangeResponseBytes - 1);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$length',
        );
      }
      response.contentLength = end - start + 1;
      requests.add({
        'method': request.method,
        'range': range,
        'start': start,
        'end': end,
        'status': response.statusCode,
      });
      if (requests.length > 200) requests.removeAt(0);
      if (request.method == 'HEAD') return;
      var position = start;
      while (position <= end) {
        cancellation.check();
        final bytes = await cache.chunk(
          fixture,
          position ~/ rangeChunkBytes,
          cancellation,
        );
        final offset = position % rangeChunkBytes;
        final count = min(bytes.length - offset, end - position + 1);
        started = true;
        response.add(Uint8List.sublistView(bytes, offset, offset + count));
        position += count;
        await response.flush();
      }
    } on RangeCancelled {
      cancelledReads++;
    } catch (_) {
      if (!started) {
        response.statusCode = HttpStatus.internalServerError;
        response.headers.removeAll(HttpHeaders.contentRangeHeader);
        response.contentLength = 0;
      }
    } finally {
      cancellation.cancel();
      _active.remove(cancellation);
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final cancellation in _active.toList()) {
      cancellation.cancel();
    }
    await _server?.close(force: true);
  }
}
