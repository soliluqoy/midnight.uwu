import 'dart:convert';
import 'dart:typed_data';

/// Strict deterministic CBOR subset (RFC 8949 section 4.2.1 core rules).
/// Supported: unsigned/negative ints, byte strings, text strings, arrays,
/// maps with int or text keys, false/true/null. Everything else is rejected.
class CborError implements Exception {
  const CborError(this.message);
  final String message;
  @override
  String toString() => 'CborError: $message';
}

const cborMaxDepth = 8;
const cborMaxItems = 1024;
const cborMaxBytes = 64 * 1024;

Uint8List cborEncode(Object? value) {
  final out = BytesBuilder(copy: false);
  _encode(value, out, 0);
  return out.toBytes();
}

void _head(BytesBuilder out, int major, int arg) {
  final m = major << 5;
  if (arg < 24) {
    out.addByte(m | arg);
  } else if (arg <= 0xff) {
    out
      ..addByte(m | 24)
      ..addByte(arg);
  } else if (arg <= 0xffff) {
    out
      ..addByte(m | 25)
      ..add([arg >> 8, arg & 0xff]);
  } else if (arg <= 0xffffffff) {
    out
      ..addByte(m | 26)
      ..add([arg >> 24, (arg >> 16) & 0xff, (arg >> 8) & 0xff, arg & 0xff]);
  } else {
    final b = ByteData(8)..setUint64(0, arg);
    out
      ..addByte(m | 27)
      ..add(b.buffer.asUint8List());
  }
}

int _compare(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

void _encode(Object? v, BytesBuilder out, int depth) {
  if (depth > cborMaxDepth) throw const CborError('nesting too deep');
  switch (v) {
    case null:
      out.addByte(0xf6);
    case final bool b:
      out.addByte(b ? 0xf5 : 0xf4);
    case final int i:
      if (i >= 0) {
        _head(out, 0, i);
      } else {
        _head(out, 1, -1 - i);
      }
    case final Uint8List b:
      _head(out, 2, b.length);
      out.add(b);
    case final String s:
      final bytes = utf8.encode(s);
      _head(out, 3, bytes.length);
      out.add(bytes);
    case final List<Object?> l:
      _head(out, 4, l.length);
      for (final e in l) {
        _encode(e, out, depth + 1);
      }
    case final Map<Object, Object?> m:
      final entries = <(Uint8List, Uint8List)>[];
      for (final e in m.entries) {
        if (e.key is! int && e.key is! String) {
          throw const CborError('map keys must be int or text');
        }
        final k = BytesBuilder(copy: false);
        _encode(e.key, k, depth + 1);
        final val = BytesBuilder(copy: false);
        _encode(e.value, val, depth + 1);
        entries.add((k.toBytes(), val.toBytes()));
      }
      entries.sort((a, b) => _compare(a.$1, b.$1));
      _head(out, 5, entries.length);
      for (final e in entries) {
        out
          ..add(e.$1)
          ..add(e.$2);
      }
    default:
      throw CborError('unsupported type ${v.runtimeType}');
  }
}

Object? cborDecode(Uint8List data) {
  final r = _Reader(data);
  final v = r.item(0);
  if (r.pos != data.length) throw const CborError('trailing bytes');
  return v;
}

class _Reader {
  _Reader(this.data);
  final Uint8List data;
  int pos = 0;

  int _byte() {
    if (pos >= data.length) throw const CborError('truncated');
    return data[pos++];
  }

  int _arg(int info) {
    if (info < 24) return info;
    final int width;
    switch (info) {
      case 24:
        width = 1;
      case 25:
        width = 2;
      case 26:
        width = 4;
      case 27:
        width = 8;
      default:
        throw const CborError('indefinite or reserved length');
    }
    var v = 0;
    for (var i = 0; i < width; i++) {
      v = (v << 8) | _byte();
    }
    if (width == 8 && v < 0) throw const CborError('integer out of range');
    final minimal =
        (width == 1 && v >= 24) ||
        (width == 2 && v > 0xff) ||
        (width == 4 && v > 0xffff) ||
        (width == 8 && v > 0xffffffff);
    if (!minimal) throw const CborError('non-minimal integer encoding');
    return v;
  }

  Uint8List _take(int n) {
    if (n > cborMaxBytes) throw const CborError('string too long');
    if (pos + n > data.length) throw const CborError('truncated');
    final out = Uint8List.sublistView(data, pos, pos + n);
    pos += n;
    return Uint8List.fromList(out);
  }

  Object? item(int depth) {
    if (depth > cborMaxDepth) throw const CborError('nesting too deep');
    final initial = _byte();
    final major = initial >> 5;
    final info = initial & 0x1f;
    switch (major) {
      case 0:
        return _arg(info);
      case 1:
        return -1 - _arg(info);
      case 2:
        return _take(_arg(info));
      case 3:
        final bytes = _take(_arg(info));
        try {
          return utf8.decode(bytes);
        } on FormatException {
          throw const CborError('invalid UTF-8');
        }
      case 4:
        final n = _arg(info);
        if (n > cborMaxItems) throw const CborError('array too long');
        return [for (var i = 0; i < n; i++) item(depth + 1)];
      case 5:
        final n = _arg(info);
        if (n > cborMaxItems) throw const CborError('map too long');
        final out = <Object, Object?>{};
        Uint8List? previous;
        for (var i = 0; i < n; i++) {
          final start = pos;
          final key = item(depth + 1);
          if (key is! int && key is! String) {
            throw const CborError('map keys must be int or text');
          }
          final encoded = Uint8List.sublistView(data, start, pos);
          if (previous != null) {
            final c = _compare(previous, encoded);
            if (c == 0) throw const CborError('duplicate map key');
            if (c > 0) throw const CborError('map keys not sorted');
          }
          previous = encoded;
          out[key!] = item(depth + 1);
        }
        return out;
      case 7:
        return switch (info) {
          20 => false,
          21 => true,
          22 => null,
          _ => throw const CborError('unsupported simple value or float'),
        };
      default:
        throw const CborError('tags are not allowed');
    }
  }
}
