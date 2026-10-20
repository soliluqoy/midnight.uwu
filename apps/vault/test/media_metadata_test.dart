import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/platform/media_metadata.dart';
import 'package:vault_media_index/vault_media_index.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'unsupported media has no invented dimensions, duration or artwork',
    () async {
      final result = await NativeMediaMetadata.extract(
        SourceEntry(
          uri: Uri.file('unsupported.document').toString(),
          name: 'unsupported.document',
          size: 10,
          modifiedMillis: 0,
        ),
      );
      expect(result.width, isNull);
      expect(result.height, isNull);
      expect(result.durationMillis, isNull);
      expect(result.poster, isNull);
      expect(result.unavailableReason, isNotEmpty);
    },
  );

  test(
    'a corrupt image reports unavailable instead of returning sample artwork',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'vault-invalid-image-',
      );
      try {
        final source = await File('${root.path}/invalid.jpg')
            .writeAsBytes([0, 1, 2, 3]);
        final result = await NativeMediaMetadata.extract(
          SourceEntry(
            uri: source.uri.toString(),
            name: 'invalid.jpg',
            size: 4,
            modifiedMillis: 0,
          ),
        );
        expect(result.poster, isNull);
        expect(result.width, isNull);
        expect(result.height, isNull);
        expect(result.unavailableReason, isNotEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
