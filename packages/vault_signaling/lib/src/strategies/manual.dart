import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vault_signaling/src/strategy.dart';

/// Complete frames, not rendezvous codes. Exports remain until ACK or removal.
class ManualSignaling implements SignalingStrategy {
  final _inbound = StreamController<SignalFrame>.broadcast();
  final _connections = StreamController<bool>.broadcast();
  final _exports = StreamController<String>.broadcast();
  final _pending = <String, String>{};
  String? _nodeId;
  bool _closed = false;

  /// Maximum simultaneously displayed complete exports.
  static const maxPendingExports = 128;

  /// Maximum text size accepted before parsing or decompression.
  static const int maxImportCharacters = 40 * 1024;
  @override
  Stream<SignalFrame> get inbound => _inbound.stream;
  @override
  Stream<bool> get connectionChanges => _connections.stream;
  @override
  bool get connected => _nodeId != null && !_closed;

  /// Newly queued exports; subscribe before starting a negotiation.
  Stream<String> get exports => _exports.stream;

  /// Immutable snapshot including exports queued before a listener attached.
  List<String> get pendingExports => List.unmodifiable(_pending.values);

  /// Most recent export, insufficient by itself for a multi-frame exchange.
  String? get lastExport => _pending.isEmpty ? null : _pending.values.last;

  @override
  Future<void> start(String nodeId) async {
    if (_closed) throw StateError('Manual signaling is closed');
    if (!signalNodeIdPattern.hasMatch(nodeId)) {
      throw const FormatException('Invalid node id');
    }
    if (_nodeId != null && _nodeId != nodeId) {
      throw StateError('Manual identity cannot change');
    }
    _nodeId = nodeId;
    _connections.add(true);
  }

  @override
  Future<void> publish(String recipient, Uint8List bytes) async {
    if (!connected) throw StateError('Manual signaling is not started');
    if (!signalNodeIdPattern.hasMatch(recipient) ||
        bytes.isEmpty ||
        bytes.length > maxSignalFrameBytes) {
      throw const FormatException('Invalid manual frame');
    }
    final key = '$recipient:${base64Url.encode(bytes)}';
    if (_pending.containsKey(key)) return;
    if (_pending.length >= maxPendingExports) {
      throw StateError(
        'Manual export queue is full; exchange or remove frames',
      );
    }
    final compressed = gzip.encode(bytes);
    final useCompression = compressed.length < bytes.length;
    final text =
        'vault-signal:1:${useCompression ? 'z' : 'r'}:$recipient:'
        '${base64Url.encode(useCompression ? compressed : bytes)}';
    _pending[key] = text;
    _exports.add(text);
  }

  /// Explicitly discards exchanged ACK text or an unwanted/expired export.
  void removeExport(String text) =>
      _pending.removeWhere((_, value) => value == text);

  /// The client calls this only after an authenticated matching ACK.
  void acknowledge(String recipient, Uint8List bytes) =>
      _pending.remove('$recipient:${base64Url.encode(bytes)}');

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pending.clear();
    _connections.add(false);
    unawaited(_connections.close());
    unawaited(_exports.close());
    unawaited(_inbound.close());
  }

  /// Imports one complete addressed frame with strictly bounded decompression.
  Future<void> importText(String text) async {
    if (!connected) throw StateError('Manual signaling is not started');
    if (text.length > maxImportCharacters) {
      throw const FormatException('Manual text exceeds limit');
    }
    final parts = text.trim().split(':');
    if (parts.length != 5 ||
        parts[0] != 'vault-signal' ||
        parts[1] != '1' ||
        (parts[2] != 'z' && parts[2] != 'r') ||
        parts[3] != _nodeId ||
        !RegExp(r'^[A-Za-z0-9_=-]+$').hasMatch(parts[4])) {
      throw const FormatException('Invalid manual text or recipient');
    }
    final encoded = base64Url.decode(parts[4]);
    if (encoded.isEmpty || encoded.length > maxSignalFrameBytes) {
      throw const FormatException('Manual frame exceeds limit');
    }
    Uint8List bytes;
    if (parts[2] == 'z') {
      final sink = _BoundedOutput(maxSignalFrameBytes);
      final decoder = gzip.decoder.startChunkedConversion(sink);
      // Bound decoder input chunks as well as cumulative emitted output.
      for (var offset = 0; offset < encoded.length; offset += 128) {
        final end = offset + 128 < encoded.length
            ? offset + 128
            : encoded.length;
        decoder.add(Uint8List.sublistView(encoded, offset, end));
      }
      decoder.close();
      bytes = sink.bytes;
    } else {
      bytes = encoded;
    }
    if (bytes.isEmpty) throw const FormatException('Empty manual frame');
    if (!_closed) _inbound.add(SignalFrame(parts[3], bytes));
  }
}

class _BoundedOutput implements Sink<List<int>> {
  new(this.limit);
  final int limit;
  final _builder = BytesBuilder(copy: false);
  Uint8List get bytes => _builder.takeBytes();
  @override
  void add(List<int> data) {
    if (_builder.length + data.length > limit) {
      throw const FormatException('Decompressed frame exceeds limit');
    }
    _builder.add(data);
  }

  @override
  void close() {}
}
