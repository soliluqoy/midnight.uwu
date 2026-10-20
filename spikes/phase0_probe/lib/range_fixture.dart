import 'dart:io';
import 'dart:typed_data';

/// Throwaway local playback adapter. Deliberately accepts synthetic fixtures only.
/// Source bytes are resident in memory; this is NOT the future P2P/cache adapter.
class RangeFixtureServer {
  RangeFixtureServer(this.fixtures, this.session);

  final Map<String, Uint8List> fixtures;
  final String session;
  final List<Map<String, Object?>> requests = [];
  HttpServer? _server;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) async {
      try {
        final parts = request.uri.pathSegments;
        if (parts.length != 2 ||
            parts.first != session ||
            !fixtures.containsKey(parts.last)) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        await serve(request, fixtures[parts.last]!);
      } catch (_) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
    });
  }

  String url(String fixture) =>
      'http://127.0.0.1:${_server!.port}/$session/$fixture';

  Future<void> serve(HttpRequest request, Uint8List bytes) async {
    final response = request.response;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    var start = 0;
    var end = bytes.length - 1;
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
          start = (bytes.length - suffix).clamp(0, bytes.length);
        }
      } else {
        start = int.tryParse(match[1]!) ?? bytes.length;
        end = match[2]!.isEmpty ? end : int.tryParse(match[2]!) ?? -1;
        end = end.clamp(-1, bytes.length - 1);
        if (start >= bytes.length || start > end) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        }
      }
      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${bytes.length}',
        );
        response.contentLength = 0;
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${bytes.length}',
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
    if (request.method == 'GET') {
      response.add(Uint8List.sublistView(bytes, start, end + 1));
    }
    await response.close();
  }

  Future<void> close() async => _server?.close(force: true);
}
