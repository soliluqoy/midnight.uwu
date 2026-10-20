import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vault_identity/vault_identity.dart';

class MemoryProtectedStore implements SecretStore {
  new([Map<String, String>? backing]) : values = backing ?? {};
  final Map<String, String> values;
  bool failWrites = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('Injected protected-store failure');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

Uint8List filled(int value) => Uint8List.fromList(List.filled(32, value));
Uint8List hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);

void main() {
  test('Ed25519 RFC8032 seed and signature are unchanged', () async {
    final id = await Identity.fromSeeds(
      hex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'),
      filled(1),
    );
    expect(
      id.signingPublic,
      hex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a'),
    );
    expect(
      await id.sign([]),
      hex(
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555f'
        'b8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      ),
    );
  });

  test(
    'simultaneous loads and injected restart preserve both key pairs',
    () async {
      final store = MemoryProtectedStore();
      final ids = await Future.wait(
        List.generate(8, (_) => IdentityRepository(store).loadOrCreate()),
      );
      final restart = await IdentityRepository(
        MemoryProtectedStore(store.values),
      ).loadOrCreate();
      for (final identity in ids) {
        expect(identity.nodeId, restart.nodeId);
        expect(identity.encryption.publicKey, restart.encryption.publicKey);
        expect(await identity.sign([1, 2]), await restart.sign([1, 2]));
      }
    },
  );

  test(
    'missing or malformed private material never silently resets identity',
    () async {
      final store = MemoryProtectedStore();
      await IdentityRepository(store).loadOrCreate();
      await store.delete('vault.identity.v1');
      await expectLater(
        IdentityRepository(store).loadOrCreate(),
        throwsStateError,
      );
      store.values['vault.identity.v1'] = '{"version":1}';
      await expectLater(
        IdentityRepository(store).loadOrCreate(),
        throwsFormatException,
      );
    },
  );

  test(
    'storage errors are propagated rather than generating ephemeral identity',
    () async {
      final store = MemoryProtectedStore()..failWrites = true;
      await expectLater(
        IdentityRepository(store).loadOrCreate(),
        throwsStateError,
      );
      expect(store.values, isEmpty);
    },
  );

  test('authentication bytes are detached and unmodifiable', () async {
    final signing = filled(7);
    final encryption = filled(8);
    final future = Identity.fromSeeds(signing, encryption);
    signing[0] = 20;
    encryption[0] = 21;
    final identity = await future;
    final expected = await Identity.fromSeeds(filled(7), filled(8));
    expect(identity.nodeId, expected.nodeId);
    expect(identity.encryption.publicKey, expected.encryption.publicKey);
    expect(() => identity.signingPublic[0] ^= 1, throwsUnsupportedError);
    expect(() => identity.nodeId[0] ^= 1, throwsUnsupportedError);
    expect(() => identity.encryption.publicKey[0] ^= 1, throwsUnsupportedError);
    final binding = await identity.binding(issuedAt: 1);
    expect(() => binding.signature[0] ^= 1, throwsUnsupportedError);
    expect(await binding.verify(), isTrue);
  });

  test(
    'contact round trip exposes only public keys and verified nodeId',
    () async {
      final identity = await Identity.fromSeeds(filled(11), filled(12));
      final card = await ContactCard.create(
        identity,
        name: 'Verified elsewhere',
      );
      final encoded = await card.encode();
      final map = jsonDecode(encoded) as Map<String, dynamic>;
      expect(map.keys.toSet(), {
        'version',
        'nodeId',
        'name',
        'signingKey',
        'encryptionKey',
        'issuedAt',
        'signature',
      });
      final decoded = await ContactCard.decode(encoded);
      expect(decoded.nodeId, nodeIdText(identity.nodeId));
      expect(await decoded.binding.verify(), isTrue);
      map['nodeId'] = nodeIdText((await Identity.generate()).nodeId);
      await expectLater(
        ContactCard.decode(jsonEncode(map)),
        throwsFormatException,
      );
    },
  );

  test(
    'contact from public binding verifies it without private identity',
    () async {
      final identity = await Identity.generate();
      final binding = await identity.binding(issuedAt: 1);
      final card = await ContactCard.fromBinding(
        binding,
        name: 'Untrusted directory label',
      );
      expect(card.nodeId, nodeIdText(identity.nodeId));
      final forged = KeyBinding(
        binding.signingKey,
        filled(90),
        binding.issuedAt,
        binding.signature,
      );
      await expectLater(
        ContactCard.fromBinding(forged, name: 'Forged'),
        throwsFormatException,
      );
    },
  );

  test(
    'forged contacts, secret extra fields and excessive strings are rejected',
    () async {
      final card = await ContactCard.create(
        await Identity.generate(),
        name: 'Alice',
      );
      final map = jsonDecode(await card.encode()) as Map<String, dynamic>;
      map['encryptionKey'] = base64Url.encode(filled(91));
      await expectLater(
        ContactCard.decode(jsonEncode(map)),
        throwsFormatException,
      );
      final extra = jsonDecode(await card.encode()) as Map<String, dynamic>;
      extra['privateKey'] = 'do not import';
      await expectLater(
        ContactCard.decode(jsonEncode(extra)),
        throwsFormatException,
      );
      await expectLater(ContactCard.decode('x' * 16385), throwsFormatException);
      await expectLater(
        ContactCard.create(await Identity.generate(), name: 'x' * 129),
        throwsFormatException,
      );
      await expectLater(
        ContactCard.create(await Identity.generate(), name: 'x\n'),
        throwsFormatException,
      );
    },
  );

  test(
    'contacts persist, replace by identity, and remove across restart',
    () async {
      final store = MemoryProtectedStore();
      final identity = await Identity.generate();
      await ContactRepository(store)
          .add(await ContactCard.create(identity, name: 'first'));
      await ContactRepository(store)
          .add(await ContactCard.create(identity, name: 'renamed'));
      final restarted = ContactRepository(MemoryProtectedStore(store.values));
      final contacts = await restarted.list();
      expect(contacts.single.name, 'renamed');
      expect(contacts.clear, throwsUnsupportedError);
      await restarted.remove(contacts.single.nodeId);
      expect(await ContactRepository(store).list(), isEmpty);
    },
  );

  test('nodeId text requires canonical fixed length base32', () async {
    final identity = await Identity.generate();
    final text = nodeIdText(identity.nodeId);
    expect(nodeIdFromText(text), identity.nodeId);
    expect(() => nodeIdFromText(text.toUpperCase()), throwsFormatException);
    expect(() => nodeIdFromText('$text='), throwsFormatException);
    final finalIndex = 'abcdefghijklmnopqrstuvwxyz234567'.indexOf(
      text.substring(51),
    );
    final finalCharacter = 'abcdefghijklmnopqrstuvwxyz234567'[finalIndex | 1];
    final noncanonical = '${text.substring(0, 51)}$finalCharacter';
    expect(() => nodeIdFromText(noncanonical), throwsFormatException);
  });
}
