import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/production/vault_runtime.dart';
import 'package:vault_identity/vault_identity.dart';

class _DeniedStore implements SecretStore {
  int writes = 0;
  @override
  Future<String?> read(String key) async {
    throw StateError('OS protected storage unavailable');
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
  }

  @override
  Future<void> delete(String key) async =>
      throw StateError('Must not delete identity');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unavailable protected state never mints replacement keys '
      'and releases startup lock', () async {
    final root = await Directory.systemTemp.createTemp(
      'vault-startup-security-',
    );
    final store = _DeniedStore();
    try {
      await expectLater(
        VaultRuntime.load(store: store, root: root),
        throwsStateError,
      );
      expect(store.writes, 0);
      // A second explicit retry reaches the real store, rather than remaining
      // locked or returning a blank/new-identity runtime.
      await expectLater(
        VaultRuntime.load(store: store, root: root),
        throwsStateError,
      );
      expect(store.writes, 0);
      final library = await FileStat.stat('${root.path}/library');
      expect(library.type, FileSystemEntityType.notFound);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
