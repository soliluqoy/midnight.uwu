import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_phase0_probe/range_fixture.dart';
import 'package:vault_phase0_probe/webrtc_adapter.dart';

void main() {
  late RangeFixtureServer server;
  late HttpClient client;
  final bytes = Uint8List.fromList(List<int>.generate(100, (i) => i));

  setUp(() async {
    server = RangeFixtureServer({'test.mp4': bytes}, 'test-session');
    await server.start();
    client = HttpClient()..findProxy = (_) => 'DIRECT';
  });
  tearDown(() async {
    client.close(force: true);
    await server.close();
  });

  Future<(HttpClientResponse, List<int>)> get({
    String? range,
    String method = 'GET',
    String? url,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse(url ?? server.url('test.mp4')),
    );
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final body = await response.expand((chunk) => chunk).toList();
    return (response, body);
  }

  test('HEAD advertises exact length without delivering content', () async {
    final (response, body) = await get(method: 'HEAD');
    expect(response.statusCode, 200);
    expect(response.contentLength, 100);
    expect(response.headers.value('accept-ranges'), 'bytes');
    expect(body, isEmpty);
  });

  test(
    'bounded range returns exact bytes and an inclusive Content-Range',
    () async {
      final (response, body) = await get(range: 'bytes=10-19');
      expect(response.statusCode, 206);
      expect(response.headers.value('content-range'), 'bytes 10-19/100');
      expect(body, bytes.sublist(10, 20));
    },
  );

  test('suffix and open-ended ranges support tail metadata and EOF', () async {
    final (suffix, last) = await get(range: 'bytes=-8');
    expect(suffix.statusCode, 206);
    expect(last, bytes.sublist(92));
    final (open, tail) = await get(range: 'bytes=97-');
    expect(open.statusCode, 206);
    expect(tail, bytes.sublist(97));
  });

  test('invalid ranges return 416 with resource length and no bytes', () async {
    for (final value in [
      'bytes=100-',
      'bytes=9-3',
      'bytes=-0',
      'bytes=0-1,4-5',
    ]) {
      final (response, body) = await get(range: value);
      expect(response.statusCode, 416, reason: value);
      expect(response.headers.value('content-range'), 'bytes */100');
      expect(body, isEmpty);
    }
  });

  test('unguessable per-session path is required', () async {
    final (response, body) = await get(
      url: server.url('test.mp4').replaceFirst('test-session', 'wrong'),
    );
    expect(response.statusCode, 404);
    expect(body, isEmpty);
  });

  test('zero retransmits is serialized despite upstream >0 omission', () {
    final init = EphemeralInit().toMap();
    expect(init['maxRetransmits'], 0);
    expect(init['ordered'], false);
  });
}
