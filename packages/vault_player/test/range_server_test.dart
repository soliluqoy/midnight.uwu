import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_player/range_server.dart';

const _chunkBytes = 262144;
const int _length = _chunkBytes * 24 + 97;

int _byteAt(int position) => (position * 31 + (position ~/ 251)) & 255;

Uint8List _chunk(int index, {int length = _length}) {
  final start = index * _chunkBytes;
  return Uint8List.fromList(
    List<int>.generate(
      min(_chunkBytes, length - start),
      (offset) => _byteAt(start + offset),
    ),
  );
}

class _Reply {
  new(this.status, this.headers, this.bytes);
  final int status;
  final HttpHeaders headers;
  final Uint8List bytes;
}

Future<_Reply> _request(
  HttpClient client,
  Uri uri, {
  String method = 'GET',
  String? range,
}) async {
  final request = await client.openUrl(method, uri);
  if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
  final response = await request.close();
  final bytes = BytesBuilder(copy: false);
  await response.forEach(bytes.add);
  return _Reply(response.statusCode, response.headers, bytes.takeBytes());
}

Future<int?> _pendingGet(HttpClient client, Uri uri) async {
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } on Object {
    // Server shutdown can close before or after response headers are sent.
    return null;
  }
}

void main() {
  late HttpClient client;
  late VaultRangeServer server;
  late Uri uri;
  late List<int> fetched;
  late List<RangeCancellation> cancellations;

  setUp(() async {
    client = HttpClient()..maxConnectionsPerHost = 8;
    fetched = <int>[];
    cancellations = <RangeCancellation>[];
    server = VaultRangeServer(
      contentId: 'verified-content',
      length: _length,
      mimeType: 'video/mp4',
      fetchChunk: (index, cancellation) async {
        fetched.add(index);
        cancellations.add(cancellation);
        cancellation.check();
        return _chunk(index);
      },
    );
    uri = await server.start();
  });

  tearDown(() async {
    await server.close();
    client.close(force: true);
  });

  test('binds loopback with a random capability and stable start', () async {
    expect(uri.host, InternetAddress.loopbackIPv4.address);
    expect(uri.pathSegments.first.length, 43);
    expect(await server.start(), uri);
    final second = VaultRangeServer(
      contentId: 'verified-content',
      length: 0,
      mimeType: 'video/mp4',
      fetchChunk: (_, _) async => throw StateError('Unexpected fetch'),
    );
    try {
      final other = await second.start();
      expect(other.pathSegments.first, isNot(uri.pathSegments.first));
    } finally {
      await second.close();
    }
  });

  test('cold seek fetches only intersecting chunks and exact bytes', () async {
    const start = 17 * _chunkBytes + _chunkBytes - 13;
    const end = start + 49;
    final reply = await _request(client, uri, range: 'bytes=$start-$end');
    expect(reply.status, HttpStatus.partialContent);
    expect(
      reply.headers.value(HttpHeaders.contentRangeHeader),
      'bytes $start-$end/$_length',
    );
    expect(reply.bytes, List<int>.generate(50, (i) => _byteAt(start + i)));
    expect(fetched, <int>[17, 18]);
    expect(cancellations.every((c) => c.isCancelled), isTrue);
  });

  test('HEAD gives metadata without fetching any chunk', () async {
    final full = await _request(client, uri, method: 'HEAD');
    expect(full.status, HttpStatus.ok);
    expect(full.headers.contentLength, _length);
    expect(full.headers.contentType?.mimeType, 'video/mp4');
    expect(full.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    expect(full.bytes, isEmpty);
    final tail = await _request(
      client,
      uri,
      method: 'HEAD',
      range: 'bytes=-97',
    );
    expect(tail.status, HttpStatus.partialContent);
    expect(tail.headers.contentLength, 97);
    expect(tail.bytes, isEmpty);
    expect(fetched, isEmpty);
  });

  test('suffix and open-ended ranges serve the actual tail', () async {
    final suffix = await _request(client, uri, range: 'bytes=-97');
    expect(suffix.status, HttpStatus.partialContent);
    expect(
      suffix.bytes,
      List<int>.generate(97, (i) => _byteAt(_length - 97 + i)),
    );
    expect(fetched, <int>[24]);
    fetched.clear();
    final open = await _request(client, uri, range: 'bytes=${_length - 23}-');
    expect(
      open.bytes,
      List<int>.generate(23, (i) => _byteAt(_length - 23 + i)),
    );
    expect(fetched, <int>[24]);
  });

  test('caps explicit ranges and un-ranged GETs at one MiB', () async {
    for (final range in <String?>['bytes=0-', null]) {
      fetched.clear();
      final reply = await _request(client, uri, range: range);
      expect(reply.status, HttpStatus.partialContent);
      expect(reply.bytes.length, VaultRangeServer.maxResponseBytes);
      expect(
        reply.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-${VaultRangeServer.maxResponseBytes - 1}/$_length',
      );
      expect(fetched, <int>[0, 1, 2, 3]);
      expect(reply.bytes.first, _byteAt(0));
      expect(reply.bytes.last, _byteAt(VaultRangeServer.maxResponseBytes - 1));
    }
  });

  test('rejects wrong token, resource and query without fetching', () async {
    final wrongToken = uri.replace(
      pathSegments: <String>['not-the-secret', uri.pathSegments.last],
    );
    final wrongResource = uri.replace(
      pathSegments: <String>[uri.pathSegments.first, 'other-content'],
    );
    for (final target in <Uri>[
      wrongToken,
      wrongResource,
      uri.replace(query: 'download=1'),
    ]) {
      final reply = await _request(client, target);
      expect(reply.status, HttpStatus.notFound);
      expect(reply.bytes, isEmpty);
    }
    expect(fetched, isEmpty);
  });

  test('invalid and multipart ranges return bounded 416 responses', () async {
    for (final range in <String>[
      'bytes=$_length-',
      'bytes=4-3',
      'bytes=-0',
      'bytes=-',
      'bytes=0-1,3-4',
      'items=0-1',
      'bytes=abc-def',
      'bytes=${'9' * 150}-',
    ]) {
      final reply = await _request(client, uri, range: range);
      expect(
        reply.status,
        HttpStatus.requestedRangeNotSatisfiable,
        reason: range,
      );
      expect(
        reply.headers.value(HttpHeaders.contentRangeHeader),
        'bytes */$_length',
      );
      expect(reply.bytes, isEmpty);
    }
    expect(fetched, isEmpty);
  });

  test('rejects unsupported methods without starting a read', () async {
    final reply = await _request(client, uri, method: 'POST');
    expect(reply.status, HttpStatus.methodNotAllowed);
    expect(reply.headers.value(HttpHeaders.allowHeader), 'GET, HEAD');
    expect(reply.bytes, isEmpty);
    expect(fetched, isEmpty);
  });

  test('empty content has no invented bytes and no valid range', () async {
    await server.close();
    server = VaultRangeServer(
      contentId: 'empty',
      length: 0,
      mimeType: 'application/octet-stream',
      fetchChunk: (_, _) async => throw StateError('Unexpected fetch'),
    );
    uri = await server.start();
    final reply = await _request(client, uri);
    expect(reply.status, HttpStatus.ok);
    expect(reply.headers.contentLength, 0);
    expect(reply.bytes, isEmpty);
    final range = await _request(client, uri, range: 'bytes=0-');
    expect(range.status, HttpStatus.requestedRangeNotSatisfiable);
    expect(range.headers.value(HttpHeaders.contentRangeHeader), 'bytes */0');
  });

  test('invalid verified chunk length is a bounded error, not media', () async {
    await server.close();
    server = VaultRangeServer(
      contentId: 'broken-fetch',
      length: _length,
      mimeType: 'video/mp4',
      fetchChunk: (_, _) async => Uint8List(1),
    );
    uri = await server.start();
    final reply = await _request(client, uri, range: 'bytes=0-9');
    expect(reply.status, HttpStatus.badGateway);
    expect(reply.bytes, isEmpty);
    expect(reply.headers.value(HttpHeaders.contentRangeHeader), isNull);
  });

  test(
    'limits active reads to four and shutdown cancels blocked fetches',
    () async {
      await server.close();
      final allStarted = Completer<void>();
      final blocked = Completer<Uint8List>();
      final active = <RangeCancellation>[];
      server = VaultRangeServer(
        contentId: 'blocked',
        length: _length,
        mimeType: 'video/mp4',
        fetchChunk: (index, cancellation) {
          active.add(cancellation);
          if (active.length == 4) allStarted.complete();
          return blocked.future;
        },
      );
      uri = await server.start();
      final pending = List<Future<int?>>.generate(
        4,
        (_) => _pendingGet(client, uri),
      );
      await allStarted.future.timeout(const Duration(seconds: 5));
      final fifth = await _request(client, uri, range: 'bytes=0-0');
      expect(fifth.status, HttpStatus.serviceUnavailable);
      expect(active.length, 4);
      await server.close().timeout(const Duration(seconds: 5));
      await Future.wait(active.map((c) => c.cancelled));
      expect(active.every((c) => c.isCancelled), isTrue);
      await Future.wait(pending).timeout(const Duration(seconds: 5));
      // A late fetch completion must not revive a stream after shutdown.
      blocked.complete(_chunk(0));
      await expectLater(server.start(), throwsStateError);
      await server.close();
    },
  );

  test('client abort bounds old seek work to one response', () async {
    await server.close();
    final fetched = <int>[];
    final tokens = <RangeCancellation>[];
    server = VaultRangeServer(
      contentId: 'abort',
      length: _length,
      mimeType: 'video/mp4',
      fetchChunk: (index, cancellation) async {
        fetched.add(index);
        tokens.add(cancellation);
        return _chunk(index);
      },
    );
    uri = await server.start();
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
    final response = await request.close();
    await response.first;
    client.close(force: true);
    await tokens.first.cancelled.timeout(const Duration(seconds: 5));
    expect(tokens.every((c) => c.isCancelled), isTrue);
    expect(
      fetched.length,
      lessThanOrEqualTo(VaultRangeServer.maxResponseBytes ~/ _chunkBytes),
    );
  });

  test('cancellation is idempotent and check rejects cancelled work', () async {
    final cancellation = RangeCancellation();
    expect(cancellation.isCancelled, isFalse);
    cancellation
      ..check()
      ..cancel()
      ..cancel();
    await cancellation.cancelled;
    expect(cancellation.isCancelled, isTrue);
    expect(cancellation.check, throwsA(isA<RangeCancelled>()));
  });
}
