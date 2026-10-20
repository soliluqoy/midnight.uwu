import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_phase0_probe/remote_range.dart';

void main() {
  const length = rangeChunkBytes * 5 + 123;
  final source = Uint8List.fromList(List<int>.generate(length, (i) => i % 251));
  late List<int> fetched;
  late RemoteRangeCache cache;
  late RemoteRangeServer server;
  late HttpClient client;

  Future<Uint8List> fetch(String name, int chunk, RangeCancellation c) async {
    fetched.add(chunk);
    final start = chunk * rangeChunkBytes;
    final end = (start + rangeChunkBytes).clamp(0, length);
    return Uint8List.sublistView(source, start, end);
  }

  setUp(() async {
    fetched = [];
    cache = RemoteRangeCache({'a.mp4': length}, fetch, maxChunks: 2);
    server = RemoteRangeServer(cache, 's');
    await server.start();
    client = HttpClient()..findProxy = (_) => 'DIRECT';
  });
  tearDown(() async {
    client.close(force: true);
    await server.close();
  });

  Future<(int, List<int>)> get(String range) async {
    final request = await client.getUrl(Uri.parse(server.url('a.mp4')));
    request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final body = await response.fold<List<int>>([], (a, b) => a..addAll(b));
    return (response.statusCode, body);
  }

  test('range spanning chunk boundary returns exact bytes', () async {
    final start = rangeChunkBytes - 10;
    final (status, body) = await get('bytes=$start-${start + 19}');
    expect(status, HttpStatus.partialContent);
    expect(body, source.sublist(start, start + 20));
    expect(fetched, [0, 1]);
  });

  test('suffix range reads only the tail chunk', () async {
    final (status, body) = await get('bytes=-100');
    expect(status, HttpStatus.partialContent);
    expect(body, source.sublist(length - 100));
    expect(fetched, [5]);
  });

  test('cache stays bounded and evicts least recently used', () async {
    final none = RangeCancellation();
    for (final i in [0, 1, 0, 2]) {
      await cache.chunk('a.mp4', i, none);
    }
    expect(cache.hits, 1);
    expect(cache.evictions, 1);
    expect(cache.peakBytes, lessThanOrEqualTo(2 * rangeChunkBytes));
    await cache.chunk('a.mp4', 1, none);
    expect(fetched, [0, 1, 2, 1]);
  });

  test('rejects invalid chunk length and unknown chunk', () async {
    final bad = RemoteRangeCache({
      'a.mp4': length,
    }, (n, c, x) async => Uint8List(3));
    expect(bad.chunk('a.mp4', 0, RangeCancellation()), throwsStateError);
    expect(cache.chunk('a.mp4', 99, RangeCancellation()), throwsRangeError);
    expect(cache.chunk('b.mp4', 0, RangeCancellation()), throwsRangeError);
  });

  test('cancelled fetch is not cached', () async {
    final gate = Completer<Uint8List>();
    final slow = RemoteRangeCache({'a.mp4': length}, (n, c, x) => gate.future);
    final cancel = RangeCancellation();
    final pending = slow.chunk('a.mp4', 0, cancel);
    cancel.cancel();
    gate.complete(Uint8List(rangeChunkBytes));
    await expectLater(pending, throwsA(isA<RangeCancelled>()));
    expect(slow.residentBytes, 0);
  });

  test('open-ended range is capped so an aborted read wastes little', () async {
    final (status, body) = await get('bytes=0-');
    expect(status, HttpStatus.partialContent);
    expect(body.length, maxRangeResponseBytes);
    expect(body, source.sublist(0, maxRangeResponseBytes));
    expect(fetched.length, maxRangeResponseBytes ~/ rangeChunkBytes);
  });

  test('unsatisfiable range returns 416', () async {
    final (status, _) = await get('bytes=$length-');
    expect(status, HttpStatus.requestedRangeNotSatisfiable);
  });
}
