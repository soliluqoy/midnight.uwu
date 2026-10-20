import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_delivery/vault_delivery.dart';
import 'package:vault_media_index/vault_media_index.dart';

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault-cache-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  test(
    'disk sparse cache stays bounded and verifies bytes again after restart',
    () async {
      final cache = SparseMediaCache(temp, maxBytes: mediaChunkBytes);
      await cache.load();
      final one = Uint8List(mediaChunkBytes)..fillRange(0, mediaChunkBytes, 1);
      final two = Uint8List(mediaChunkBytes)..fillRange(0, mediaChunkBytes, 2);
      final id = sha256.convert([42]).toString();
      final firstDigest = sha256.convert(one).toString();
      final secondDigest = sha256.convert(two).toString();
      await cache.put(id, 0, firstDigest, one);
      await cache.put(id, 1, secondDigest, two);
      var size = 0;
      await for (final file in temp.list()) {
        size += await (file as File).length();
      }
      expect(size, lessThanOrEqualTo(mediaChunkBytes));
      expect(await cache.read(id, 0, firstDigest, one.length), isNull);
      final stored = File('${temp.path}/$id-1.chunk');
      await stored.writeAsBytes(one);
      final restarted = SparseMediaCache(temp, maxBytes: mediaChunkBytes);
      await restarted.load();
      expect(await restarted.read(id, 1, secondDigest, two.length), isNull);
      expect(await stored.exists(), isFalse);
    },
  );
  test('bad digest, path keys and oversized data never reach disk', () async {
    final cache = SparseMediaCache(temp);
    await cache.load();
    final bytes = Uint8List.fromList([1, 2]);
    final digest = sha256.convert(bytes).toString();
    await expectLater(
      cache.put('../escape', 0, digest, bytes),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      cache.put(digest, 0, digest, Uint8List.fromList([3, 4])),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      cache.put(digest, 0, digest, Uint8List(mediaChunkBytes + 1)),
      throwsA(isA<FormatException>()),
    );
    expect(await temp.list().length, 0);
  });
}
