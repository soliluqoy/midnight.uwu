import 'dart:io';

class VaultAlreadyRunning implements Exception {
  const new();
}

/// Holds an OS lock before protected state is read or minted. The handle is
/// intentionally retained until all authorization writers have closed.
class VaultInstanceLock {
  new _(this._file);
  final RandomAccessFile _file;

  static Future<VaultInstanceLock> acquire(Directory root) async {
    await root.create(recursive: true);
    final file = await File('${root.path}/vault-instance.lock')
        .open(mode: FileMode.append);
    try {
      await file.lock();
      return VaultInstanceLock._(file);
    } on FileSystemException {
      await file.close();
      throw const VaultAlreadyRunning();
    } on Object {
      await file.close();
      rethrow;
    }
  }

  Future<void> close() async {
    try {
      await _file.unlock();
    } finally {
      await _file.close();
    }
  }
}
