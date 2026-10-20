import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:vault_identity/src/identity.dart';

/// Implementations must protect confidentiality/integrity, atomically replace one
/// value, and report write failures. Never implement this with plaintext prefs.
abstract class SecretStore {
  /// Reads the protected value for [key], or null if it does not exist.
  Future<String?> read(String key);

  /// Atomically replaces the protected value for [key], reporting failures.
  Future<void> write(String key, String value);

  /// Removes the protected value for [key], reporting failures.
  Future<void> delete(String key);
}

final _locks = Expando<_StoreQueue>();

class _StoreQueue {
  Future<void> tail = Future<void>.value();
  Future<T> run<T>(Future<T> Function() operation) {
    final next = tail.then((_) => operation());
    tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}

/// Serializes repositories sharing the same store object in this Dart isolate.
/// The native app must have one store instance/writer; cross-process storage
/// transactions are not supplied by the SecretStore interface.
Future<T> withSecretStoreLock<T>(
  SecretStore store,
  Future<T> Function() operation,
) => (_locks[store] ??= _StoreQueue()).run(operation);

/// Generates between 1 and 64 bytes using cryptographically secure randomness.
Uint8List secureRandomBytes(int count) {
  if (count < 1 || count > 64) {
    throw ArgumentError.value(count, 'count');
  }
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(count, (_) => random.nextInt(256)),
  );
}

/// Persists one identity and refuses replacement after protected key loss.
class IdentityRepository {
  /// Uses [store] for confidential key material and the creation marker.
  new(this.store);

  /// The protected store shared by this repository's serialized operations.
  final SecretStore store;
  Identity? _identity;
  static const _key = 'vault.identity.v1';
  static const _marker = 'vault.identity.created.v1';

  /// Loads validated key material or creates it only if no prior marker exists.
  Future<Identity> loadOrCreate() => withSecretStoreLock(store, () async {
    if (_identity != null) {
      return _identity!;
    }
    var text = await store.read(_key);
    if (text == null) {
      if (await store.read(_marker) != null) {
        throw StateError(
          'Identity key material is missing. Restore protected storage; '
          'no new identity was created.',
        );
      }
      text = jsonEncode({
        'version': 1,
        'signingSeed': base64Url.encode(secureRandomBytes(32)),
        'encryptionIkm': base64Url.encode(secureRandomBytes(32)),
      });
      await store.write(_key, text);
    }
    if (text.length > 1024) {
      throw const FormatException('Invalid identity record');
    }
    final Object? map = jsonDecode(text);
    if (map is! Map<String, Object?> ||
        map.length != 3 ||
        map['version'] != 1) {
      throw const FormatException('Invalid identity record');
    }
    final signing = decodePublicBytes(map['signingSeed'], 32);
    final encryption = decodePublicBytes(map['encryptionIkm'], 32);
    final identity = await Identity.fromSeeds(signing, encryption);
    await store.write(_marker, '1');
    _identity = identity;
    return identity;
  });
}

/// Strict bounded canonical base64url used for public and protected records.
Uint8List decodePublicBytes(Object? value, int size) {
  if (value is! String || value.length > ((size + 2) ~/ 3) * 4) {
    throw const FormatException('Invalid byte field');
  }
  final bytes = base64Url.decode(value);
  if (bytes.length != size || base64Url.encode(bytes) != value) {
    throw const FormatException('Noncanonical byte field');
  }
  return Uint8List.fromList(bytes).asUnmodifiableView();
}

/// A public contact with a verified key binding, not an assertion of trust.
class ContactCard {
  new _(this.binding, this.name, this.nodeId);

  /// The authenticated association of signing and encryption keys.
  final KeyBinding binding;

  /// The validated display name, limited to 128 UTF-8 bytes without controls.
  final String name;

  /// The canonical node identifier derived from the binding's signing key.
  final String nodeId;

  /// Creates a contact with a freshly signed binding from [identity].
  static Future<ContactCard> create(
    Identity identity, {
    required String name,
  }) async {
    _checkName(name);
    return ContactCard._(
      await identity.binding(
        issuedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
      name,
      nodeIdText(identity.nodeId),
    );
  }

  /// Builds a public contact from an authenticated binding.
  ///
  /// Verification authenticates the keys but does not establish trust.
  static Future<ContactCard> fromBinding(
    KeyBinding binding, {
    required String name,
  }) async {
    _checkName(name);
    if (!await binding.verify()) {
      throw const FormatException('Invalid contact key binding');
    }
    return ContactCard._(
      binding,
      name,
      nodeIdText(await nodeIdOf(binding.signingKey)),
    );
  }

  /// Encodes this public contact, including its binding signature, as JSON.
  Future<String> encode() async => jsonEncode({
    'version': 1,
    'nodeId': nodeId,
    'name': name,
    'signingKey': base64Url.encode(binding.signingKey),
    'encryptionKey': base64Url.encode(binding.encryptionKey),
    'issuedAt': binding.issuedAt,
    'signature': base64Url.encode(binding.signature),
  });

  /// Parses bounded JSON and verifies its binding and derived node identifier.
  static Future<ContactCard> decode(String text) async {
    if (text.length > 16384 || utf8.encode(text).length > 16384) {
      throw const FormatException('Contact exceeds 16KiB');
    }
    final Object? map = jsonDecode(text);
    const fields = {
      'version',
      'nodeId',
      'name',
      'signingKey',
      'encryptionKey',
      'issuedAt',
      'signature',
    };
    if (map is! Map<String, Object?> ||
        map.length != fields.length ||
        !fields.containsAll(map.keys) ||
        map['version'] != 1 ||
        map['name'] is! String ||
        map['nodeId'] is! String ||
        map['issuedAt'] is! int ||
        (map['issuedAt']! as int) < 0) {
      throw const FormatException('Invalid contact fields');
    }
    final name = map['name']! as String;
    _checkName(name);
    final binding = KeyBinding(
      decodePublicBytes(map['signingKey'], 32),
      decodePublicBytes(map['encryptionKey'], 32),
      map['issuedAt']! as int,
      decodePublicBytes(map['signature'], 64),
    );
    if (!await binding.verify()) {
      throw const FormatException('Invalid contact key binding');
    }
    final id = nodeIdText(await nodeIdOf(binding.signingKey));
    if (id != map['nodeId']) {
      throw const FormatException('Contact identity mismatch');
    }
    return ContactCard._(binding, name, id);
  }

  static void _checkName(String name) {
    if (name.isEmpty ||
        name.length > 128 ||
        utf8.encode(name).length > 128 ||
        name.codeUnits.any((c) => c < 32 || c == 127)) {
      throw const FormatException(
        'Contact name must be 1..128 UTF-8 bytes without controls',
      );
    }
  }
}

/// Stores up to 512 verified contacts through serialized protected writes.
class ContactRepository {
  /// Uses [store] for the bounded, authenticated contact records.
  new(this.store);

  /// The protected store shared by this repository's serialized operations.
  final SecretStore store;
  static const _key = 'vault.contacts.v1';
  Future<List<ContactCard>> _read() async {
    final text = await store.read(_key);
    if (text == null) {
      return [];
    }
    if (text.length > 1024 * 1024) {
      throw const FormatException('Contact repository too large');
    }
    final Object? data = jsonDecode(text);
    if (data is! List<Object?> || data.length > 512) {
      throw const FormatException('Invalid contact repository');
    }
    final contacts = <ContactCard>[];
    final ids = <String>{};
    for (final entry in data) {
      if (entry is! String) {
        throw const FormatException('Invalid contact record');
      }
      final contact = await ContactCard.decode(entry);
      if (!ids.add(contact.nodeId)) {
        throw const FormatException('Duplicate contact identity');
      }
      contacts.add(contact);
    }
    return contacts;
  }

  /// Loads verified contacts as an unmodifiable list.
  Future<List<ContactCard>> list() => withSecretStoreLock(
    store,
    () async => List<ContactCard>.unmodifiable(await _read()),
  );

  /// Revalidates and inserts [card], replacing the same node identifier.
  Future<void> add(ContactCard card) => withSecretStoreLock(store, () async {
    final verified = await ContactCard.decode(await card.encode());
    final contacts = await _read();
    contacts.removeWhere((c) => c.nodeId == verified.nodeId);
    if (contacts.length >= 512) {
      throw StateError('Contact limit reached');
    }
    contacts.add(verified);
    await store.write(
      _key,
      jsonEncode(await Future.wait(contacts.map((c) => c.encode()))),
    );
  });

  /// Removes a contact by canonical node identifier.
  Future<void> remove(String nodeId) => withSecretStoreLock(store, () async {
    nodeIdFromText(nodeId);
    final contacts = await _read();
    contacts.removeWhere((c) => c.nodeId == nodeId);
    await store.write(
      _key,
      jsonEncode(await Future.wait(contacts.map((c) => c.encode()))),
    );
  });
}
