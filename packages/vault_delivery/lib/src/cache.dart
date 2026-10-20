import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:vault_media_index/vault_media_index.dart';

/// Disk-only sparse cache: one verified chunk per file, globally bounded. An
/// authenticated caller must authorize use before entering this cache.
class SparseMediaCache {
  /// Creates a disk-only cache with a strict byte and 1024-entry budget.
  new(this.directory, {this.maxBytes = 256 * 1024 * 1024}) {
    if (maxBytes < mediaChunkBytes) {
      throw ArgumentError.value(maxBytes, 'maxBytes');
    }
  }

  /// App-owned sparse chunk directory.
  final Directory directory;

  /// Maximum committed and temporarily staged chunk bytes.
  final int maxBytes;
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() operation) {
    final future = _tail.then((_) => operation());
    _tail = future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return future;
  }

  /// Returns a matching rehashed chunk, deleting corrupt entries.
  Future<Uint8List?> read(
    String contentId,
    int index,
    String digest,
    int length,
  ) => _serial(() async {
    _validate(contentId, index, digest, length);
    final file = File('${directory.path}/$contentId-$index.chunk');
    if (!await file.exists()) return null;
    if (await file.length() != length) {
      await file.delete();
      return null;
    }
    final bytes = await file.readAsBytes();
    if (sha256.convert(bytes).toString() != digest) {
      await file.delete();
      return null;
    }
    await file.setLastModified(DateTime.now());
    return bytes;
  });

  /// Verifies and durably admits one chunk after reserving cache capacity.
  Future<void> put(
    String contentId,
    int index,
    String digest,
    Uint8List bytes,
  ) => _serial(() async {
    _validate(contentId, index, digest, bytes.length);
    if (sha256.convert(bytes).toString() != digest) {
      throw const FormatException('Corrupt chunk');
    }
    await directory.create(recursive: true);
    await _prune(reserveBytes: bytes.length, reserveEntries: 1);
    final file = File('${directory.path}/$contentId-$index.chunk');
    final temp = File('${file.path}.next');
    await temp.writeAsBytes(bytes, flush: true);
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
    await _prune();
  });

  /// Cleans interrupted writes and reapplies disk bounds on restart.
  Future<void> load() => _serial(() async {
    await directory.create(recursive: true);
    await for (final entry in directory.list()) {
      if (entry is File && entry.path.endsWith('.next')) await entry.delete();
    }
    await _prune();
  });
  Future<void> _prune({int reserveBytes = 0, int reserveEntries = 0}) async {
    final files = <(File, FileStat)>[];
    var total = 0;
    await for (final entry in directory.list()) {
      if (entry is! File) continue;
      final stat = await entry.stat();
      if (!RegExp(r'[0-9a-f]{64}-\d+\.chunk$').hasMatch(entry.path) ||
          stat.size > mediaChunkBytes) {
        await entry.delete();
        continue;
      }
      total += stat.size;
      files.add((entry, stat));
    }
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    var remaining = files.length;
    for (final row in files) {
      if (total <= maxBytes - reserveBytes &&
          remaining <= 1024 - reserveEntries) {
        break;
      }
      await row.$1.delete();
      total -= row.$2.size;
      remaining--;
    }
  }

  static void _validate(String id, int index, String digest, int length) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        index < 0 ||
        index >= maxMediaChunks ||
        length <= 0 ||
        length > mediaChunkBytes) {
      throw const FormatException('Invalid cache key or size');
    }
  }
}
