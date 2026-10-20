import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_protocol/vault_protocol.dart';

class MemoryProtectedStore implements SecretStore {
  new([Map<String, String>? backing]) : values = backing ?? {};
  final Map<String, String> values;
  bool failWrites = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('Injected atomic-write failure');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

Matcher rejected(String reason) => throwsA(
  isA<WireReject>().having((e) => e.reason, 'reason', contains(reason)),
);

void main() {
  late MemoryProtectedStore store;
  late Identity owner;
  late Identity viewer;
  late AuthorizationRepository repository;
  setUp(() async {
    store = MemoryProtectedStore();
    owner = await IdentityRepository(store).loadOrCreate();
    viewer = await Identity.generate();
    repository = AuthorizationRepository(store, owner);
    await repository.load();
  });

  Future<GrantedAccess> approve() => repository.approve(
    viewerId: viewer.nodeId,
    resource: 'library/all',
    actions: ['browse', 'play', 'download'],
  );
  Future<void> check(
    GrantedAccess access, {
    AuthorizationRepository? using,
    Uint8List? peer,
    String resource = 'library/all',
    String action = 'download',
  }) => (using ?? repository).check(
    access: access,
    viewerId: peer ?? viewer.nodeId,
    resource: resource,
    action: action,
  );
  Future<AuthorizationRepository> restart() async {
    final storage = MemoryProtectedStore(store.values);
    final identity = await IdentityRepository(storage).loadOrCreate();
    final restarted = AuthorizationRepository(storage, identity);
    await restarted.load();
    addTearDown(restarted.close);
    return restarted;
  }

  tearDown(() => repository.close());

  test(
    'unrevoked grant remains valid across injected protected-store restart',
    () async {
      final access = await approve();
      await check(access);
      final restored = GrantedAccess.fromJson(
        jsonDecode(jsonEncode(access.toJson())) as Map<String, Object?>,
      );
      await check(restored, using: await restart());
      expect(restored.grant.epoch, access.grant.epoch);
      expect(restored.toJson().keys.toSet(), {'grant', 'mac'});
      expect(jsonEncode(restored.toJson()), isNot(contains('mintingKey')));
    },
  );

  test('persisted revocation rejects copied pre-restart token', () async {
    final access = await approve();
    final copied = GrantedAccess.fromJson(access.toJson());
    await repository.revoke(base64Url.encode(access.grant.grantId));
    await expectLater(check(copied), rejected('revoked'));
    await expectLater(
      check(copied, using: await restart()),
      rejected('revoked'),
    );
  });

  test(
    'persisted block rejects old tokens and approval until explicit unblock',
    () async {
      final access = await approve();
      await repository.block(viewer.nodeId);
      final restarted = await restart();
      await expectLater(check(access, using: restarted), rejected('revoked'));
      await expectLater(
        restarted.approve(
          viewerId: viewer.nodeId,
          resource: 'library/all',
          actions: ['browse'],
        ),
        rejected('blocked'),
      );
      await restarted.unblock(viewer.nodeId);
      await expectLater(check(access, using: restarted), rejected('revoked'));
      final newAccess = await restarted.approve(
        viewerId: viewer.nodeId,
        resource: 'library/all',
        actions: ['browse'],
      );
      await check(newAccess, using: restarted, action: 'browse');
    },
  );

  test(
    'viewer revocation allows later consent without resurrecting old tokens',
    () async {
      final tokens = await Future.wait(List.generate(3, (_) => approve()));
      await repository.revokeViewer(viewer.nodeId);
      final restarted = await restart();
      for (final token in tokens) {
        await expectLater(check(token, using: restarted), rejected('revoked'));
      }
      final fresh = await restarted.approve(
        viewerId: viewer.nodeId,
        resource: 'library/all',
        actions: ['download'],
      );
      await check(fresh, using: restarted);
    },
  );

  test(
    'revokeAll persists epoch and rejects old grants after restart',
    () async {
      final access = await approve();
      await repository.revokeAll();
      final restarted = await restart();
      await expectLater(check(access, using: restarted), rejected('epoch'));
      final fresh = await restarted.approve(
        viewerId: viewer.nodeId,
        resource: 'library/all',
        actions: ['download'],
      );
      expect(fresh.grant.epoch, access.grant.epoch + 1);
      await check(fresh, using: restarted);
    },
  );

  test(
    'wrong authenticated viewer, scope and tampered fields fail closed',
    () async {
      final access = await approve();
      await expectLater(
        check(access, peer: owner.nodeId),
        rejected('mismatch'),
      );
      await expectLater(
        check(access, resource: 'library/private'),
        rejected('scope'),
      );
      await expectLater(check(access, action: 'delete'), rejected('scope'));
      final changedMac = Uint8List.fromList(access.mac)..[0] ^= 1;
      await expectLater(
        check(GrantedAccess(grant: access.grant, mac: changedMac)),
        rejected('mac'),
      );
      final json = access.toJson();
      (json['grant']! as Map<String, Object?>)['resource'] = 'library/private';
      await expectLater(
        check(GrantedAccess.fromJson(json), resource: 'library/private'),
        rejected('mac'),
      );
    },
  );

  test(
    'concurrent approvals and revocation preserve durable updates',
    () async {
      final tokens = await Future.wait(List.generate(12, (_) => approve()));
      final restarted = await restart();
      for (final token in tokens) {
        await check(token, using: restarted);
      }
      final revocation = repository.revokeViewer(viewer.nodeId);
      final pendingCheck = check(tokens.first);
      await revocation;
      await expectLater(pendingCheck, rejected('revoked'));
      for (final token in tokens) {
        await expectLater(check(token, using: restarted), rejected('revoked'));
      }
    },
  );

  test('failed revocation commit poisons the repository', () async {
    final access = await approve();
    store.failWrites = true;
    await expectLater(
      repository.revoke(base64Url.encode(access.grant.grantId)),
      throwsStateError,
    );
    await expectLater(check(access), throwsStateError);
    store.failWrites = false;
    // Atomic store failure leaves the previous durable state, not a claimed
    // successful revoke. UI must surface the error and close existing streams.
    await check(access, using: await restart());
  });

  test(
    'missing authorization record with creation marker never remints',
    () async {
      await approve();
      final key = store.values.keys.singleWhere(
        (k) =>
            k.startsWith('vault.authorization.v1.') && !k.endsWith('.created'),
      );
      store.values.remove(key);
      await expectLater(
        AuthorizationRepository(store, owner).load(),
        throwsStateError,
      );
    },
  );

  test('tokens and approval inputs are immutable snapshots', () async {
    final viewerBytes = Uint8List.fromList(viewer.nodeId);
    final actions = ['download'];
    final pending = repository.approve(
      viewerId: viewerBytes,
      resource: 'library/all',
      actions: actions,
    );
    viewerBytes[0] ^= 1;
    actions[0] = 'delete';
    final access = await pending;
    await check(access);
    expect(() => access.grant.viewerId[0] ^= 1, throwsUnsupportedError);
    expect(() => access.grant.actions.add('delete'), throwsUnsupportedError);
    expect(() => access.mac[0] ^= 1, throwsUnsupportedError);
    final json = access.toJson();
    json['mintingKey'] = 'secret injection';
    expect(() => GrantedAccess.fromJson(json), throwsFormatException);
  });
}
