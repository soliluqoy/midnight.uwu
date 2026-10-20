import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:vault_media_index/vault_media_index.dart';

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault-index-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  test(
    'copied import full and chunk hashes survive reload and source deletion',
    () async {
      final bytes = Uint8List.fromList(
        List.generate(mediaChunkBytes * 4 + 19, (i) => i % 251),
      );
      final source = await File('${temp.path}/sample.mp4').writeAsBytes(bytes);
      final library = VaultLibrary(Directory('${temp.path}/owned'));
      await library.load();
      final item = await library.addFile(source, name: 'Original.mp4');
      expect(item.id, sha256.convert(bytes).toString());
      expect(item.chunks.length, 5);
      expect(item.name, 'Original.mp4');
      await source.delete();
      final loaded = VaultLibrary(library.root);
      await loaded.load();
      expect(loaded.items.single.id, item.id);
      expect(
        await loaded.readChunk(loaded.items.single, 4),
        bytes.sublist(mediaChunkBytes * 4),
      );
      final changed = Uint8List.fromList(bytes)..[0] = 255;
      await File(item.path).writeAsBytes(changed);
      await expectLater(
        loaded.readChunk(loaded.items.single, 0),
        throwsStateError,
      );
    },
  );
  test('folder references do not copy; refresh preserves content id on rename '
      'and removes deletion', () async {
    final source = await Directory('${temp.path}/source').create();
    final file = await File('${source.path}/old.mp4')
        .writeAsBytes([1, 2, 3, 4]);
    final library = VaultLibrary(Directory('${temp.path}/index'));
    await library.load();
    await library.addFolder(source);
    final first = library.items.single;
    expect(first.sourceUri, file.uri.toString());
    expect(await Directory('${library.root.path}/content').list().length, 0);
    final renamed = await file.rename('${source.path}/new.mp4');
    await library.refresh();
    expect(library.items.single.id, first.id);
    expect(library.items.single.name, 'new.mp4');
    final loaded = VaultLibrary(library.root);
    await loaded.load();
    expect(await loaded.readChunk(loaded.items.single, 0), [1, 2, 3, 4]);
    await renamed.delete();
    await loaded.refresh();
    expect(loaded.items, isEmpty);
  });
  test('injected native URI access remains URI-aware and permission failure '
      'fails closed', () async {
    final access = _NativeSource();
    final library = VaultLibrary(
      Directory('${temp.path}/uri-index'),
      sourceAccess: access,
    );
    await library.load();
    await library.addSource('content://provider/tree/root');
    final item = library.items.single;
    expect(item.path, isEmpty);
    expect(item.sourceUri, startsWith('content://'));
    expect(await library.readChunk(item, 0), [9, 8, 7]);
    access.denied = true;
    await expectLater(
      library.readChunk(item, 0),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(library.refresh(), throwsA(isA<FileSystemException>()));
    expect(library.items.single.id, item.id);
    await library.removeSource('content://provider/tree/root');
    expect(library.items, isEmpty);
  });
  test('oversized native read and changed source metadata rejected '
      'before publication', () async {
    final access = _NativeSource()..shortRead = true;
    final library = VaultLibrary(
      Directory('${temp.path}/bad'),
      sourceAccess: access,
    );
    await library.load();
    await expectLater(
      library.addSource('content://provider/tree/root'),
      throwsStateError,
    );
    expect(library.items, isEmpty);
    expect(library.sources, isEmpty);
  });
}

class _NativeSource implements VaultSourceAccess {
  bool denied = false;
  bool shortRead = false;
  @override
  Stream<SourceEntry> enumerate(String uri) async* {
    if (denied) throw const FileSystemException('Permission revoked');
    yield const SourceEntry(
      uri: 'content://provider/document/a',
      name: 'a.mp4',
      size: 3,
      modifiedMillis: 42,
    );
  }

  @override
  Future<SourceStat> stat(String uri) async {
    if (denied) throw const FileSystemException('Permission revoked');
    return const SourceStat(size: 3, modifiedMillis: 42);
  }

  @override
  Future<Uint8List> readAt(String uri, int offset, int length) async {
    if (denied) throw const FileSystemException('Permission revoked');
    if (length > mediaChunkBytes) throw StateError('Unbounded read');
    return Uint8List.fromList(shortRead ? [9] : [9, 8, 7]);
  }
}
