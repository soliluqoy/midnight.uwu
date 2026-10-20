import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vault_identity/vault_identity.dart';

/// Never catches storage errors, resets corrupt keys, or substitutes
/// preferences.
class ProtectedStore implements SecretStore {
  const new({this.keyPrefix = 'vault.'});

  final String keyPrefix;

  static const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );

  @override
  Future<String?> read(String key) => storage.read(key: '$keyPrefix$key');

  @override
  Future<void> write(String key, String value) =>
      storage.write(key: '$keyPrefix$key', value: value);

  @override
  Future<void> delete(String key) => storage.delete(key: '$keyPrefix$key');
}
