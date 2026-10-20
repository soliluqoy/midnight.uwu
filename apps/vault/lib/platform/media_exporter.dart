import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// A completed cache download is not a user-saved copy. Save requires an OS
/// destination and succeeds only after the streaming copy has finished.
class MediaExporter {
  static const _channel = MethodChannel('dev.vault.vault/media_export');

  Future<String?> save(
    File file, {
    required String name,
    required String mimeType,
  }) async {
    // A peer-supplied display name never becomes a path.
    final safeName = name.replaceAll(RegExp(r'[\\/\x00-\x1f]'), '_');
    if (Platform.isAndroid) {
      return await _channel.invokeMethod<String>('saveMedia', {
        'name': safeName,
        'mime': mimeType,
        'source': file.path,
      });
    }
    final destination = await getSaveLocation(suggestedName: safeName);
    if (destination == null) return null;
    if (File(destination.path).absolute.path == file.absolute.path) {
      throw StateError('Choose a destination outside the app cache.');
    }
    await file.copy(destination.path);
    return destination.path;
  }
}
