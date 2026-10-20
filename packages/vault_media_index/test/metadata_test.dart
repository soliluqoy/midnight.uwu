import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:vault_media_index/vault_media_index.dart';

void main() {
  late Directory temp;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault-metadata-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  test('actual encoded poster is bounded, content-addressed and persisted '
      'with decoder dimensions', () async {
    final source = await File('${temp.path}/one.png').writeAsBytes(png);
    final library = VaultLibrary(
      Directory('${temp.path}/index'),
      metadataExtractor: (entry) async {
        expect(entry.uri, startsWith('file:'));
        expect(entry.name, 'one.png');
        return MediaMetadata(width: 1, height: 1, poster: png);
      },
    );
    await library.load();
    final item = await library.addFile(source);
    expect(item.metadata.width, 1);
    expect(item.metadata.height, 1);
    expect(item.metadata.poster, isNull);
    expect(item.posterDigest, sha256.convert(png).toString());
    expect(await library.readPoster(item), png);
    await library.close();
    final loaded = VaultLibrary(library.root);
    await loaded.load();
    expect(loaded.items.single.metadata.width, 1);
    expect(await loaded.readPoster(loaded.items.single), png);
    await loaded.remove(loaded.items.single.id);
    expect(await Directory('${library.root.path}/posters').list().length, 0);
    await loaded.close();
  });
  test(
    'unsupported extraction is explicit and oversized poster rejects import',
    () async {
      final file = await File('${temp.path}/one.png').writeAsBytes(png);
      final unsupported = VaultLibrary(
        Directory('${temp.path}/unsupported'),
        metadataExtractor: (_) async => const MediaMetadata(
          unavailableReason: 'Codec unsupported by device',
        ),
      );
      await unsupported.load();
      final item = await unsupported.addFile(file);
      expect(item.metadata.unavailableReason, contains('unsupported'));
      expect(item.posterPath, isNull);
      await unsupported.close();
      final invalid = VaultLibrary(
        Directory('${temp.path}/invalid'),
        metadataExtractor: (_) async => MediaMetadata(
          width: 1,
          height: 1,
          poster: Uint8List(mediaChunkBytes + 1),
        ),
      );
      await invalid.load();
      await expectLater(invalid.addFile(file), throwsA(isA<FormatException>()));
      expect(invalid.items, isEmpty);
      await invalid.close();
    },
  );
  test(
    'small compressed posters cannot advertise an unbounded decoded surface',
    () {
      validateMediaPoster(png);
      final malicious = Uint8List.fromList(png);
      ByteData.sublistView(malicious).setUint32(16, 32768);
      expect(
        () => validateMediaPoster(malicious),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => validateMediaPoster(Uint8List.fromList([255, 216, 255, 217])),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
