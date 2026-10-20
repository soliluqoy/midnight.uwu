import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:vault_media_index/vault_media_index.dart';

/// Persisted SAF capability, never an invented local filesystem path.
class AndroidSourceAccess implements VaultSourceAccess {
  static const channel = MethodChannel('dev.vault.vault/library_sources');

  @override
  Stream<SourceEntry> enumerate(String rootUri) async* {
    final rows = await channel.invokeListMethod<Map<Object?, Object?>>(
      'enumerateTree',
      {'uri': rootUri},
    );
    if (rows == null) throw StateError('Source provider returned no listing.');
    for (final row in rows) {
      yield SourceEntry(
        uri: row['uri']! as String,
        name: row['name']! as String,
        size: row['size']! as int,
        modifiedMillis: row['modifiedMillis']! as int,
      );
    }
  }

  @override
  Future<SourceStat> stat(String uri) async {
    final row = await channel.invokeMapMethod<String, Object?>('sourceStat', {
      'uri': uri,
    });
    if (row == null) throw StateError('Source provider returned no metadata.');
    return SourceStat(
      size: row['size']! as int,
      modifiedMillis: row['modifiedMillis']! as int,
    );
  }

  @override
  Future<Uint8List> readAt(String uri, int offset, int length) async {
    final bytes = await channel.invokeMethod<Uint8List>('sourceReadAt', {
      'uri': uri,
      'offset': offset,
      'length': length,
    });
    if (bytes == null) throw StateError('Source provider returned no bytes.');
    return bytes;
  }

  static Future<String?> chooseFolder() async {
    if (Platform.isAndroid) {
      final result = await channel.invokeMapMethod<String, Object?>(
        'pickSourceTree',
      );
      return result?['uri'] as String?;
    }
    final path = await getDirectoryPath(
      confirmButtonText: 'Use as library source',
    );
    return path == null ? null : Directory(path).uri.toString();
  }

  static Future<void> release(String uri) async {
    if (Platform.isAndroid && Uri.parse(uri).scheme == 'content') {
      await channel.invokeMethod<void>('releaseSourceTree', {'uri': uri});
    }
  }
}
