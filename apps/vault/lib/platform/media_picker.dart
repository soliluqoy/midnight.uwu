import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

class SelectedMedia {
  const new(this.file, this.name, {this.temporary = false});
  final File file;
  final String name;
  final bool temporary;
}

/// Explicit OS selection only. Android URIs are streamed by native code to a
/// temporary local file, then VaultLibrary imports its own durable copy.
abstract final class NativeMediaPicker {
  static const _channel = MethodChannel('dev.vault.vault/media_export');

  static Future<List<SelectedMedia>> pick() async {
    if (Platform.isAndroid) {
      final files = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'pickMedia',
      );
      return [
        for (final file in files ?? <Map<Object?, Object?>>[])
          SelectedMedia(
            File(file['path']! as String),
            file['name']! as String,
            temporary: true,
          ),
      ];
    }
    const media = XTypeGroup(
      label: 'Photos and videos',
      extensions: [
        'jpg',
        'jpeg',
        'png',
        'webp',
        'heic',
        'mp4',
        'mov',
        'mkv',
        'webm',
      ],
    );
    final files = await openFiles(acceptedTypeGroups: [media]);
    return [
      for (final file in files) SelectedMedia(File(file.path), file.name),
    ];
  }
}
