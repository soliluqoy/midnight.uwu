import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:vault_identity/vault_identity.dart';
import 'package:vault_protocol/src/envelope.dart';

/// Public capability token. Contains no owner minting material.
class GrantedAccess {
  /// Creates a token with an immutable, exactly 32-byte authenticator.
  new({required this.grant, required Uint8List mac}) : mac = _fixed(mac, 32);

  /// The validated capability scope and validity window.
  final Grant grant;

  /// The owner-generated HMAC; never contains the minting key.
  final Uint8List mac;

  /// Serializes the public token without any owner secret material.
  Map<String, Object?> toJson() => {
    'grant': {
      'version': grant.version,
      'ownerId': base64Url.encode(grant.ownerId),
      'viewerId': base64Url.encode(grant.viewerId),
      'grantId': base64Url.encode(grant.grantId),
      'resource': grant.resource,
      'actions': grant.actions,
      'issuedAt': grant.issuedAt,
      'expiresAt': grant.expiresAt,
      'epoch': grant.epoch,
    },
    'mac': base64Url.encode(mac),
  };

  /// Parses an exact token shape and validates its grant and byte lengths.
  // Retained as a static method for the shared token decoding API.
  // ignore: prefer_constructors_over_static_methods
  static GrantedAccess fromJson(Map<String, Object?> json) {
    if (json.length != 2 ||
        !json.containsKey('grant') ||
        !json.containsKey('mac')) {
      throw const FormatException('Invalid access token');
    }
    final g = json['grant'];
    const fields = {
      'version',
      'ownerId',
      'viewerId',
      'grantId',
      'resource',
      'actions',
      'issuedAt',
      'expiresAt',
      'epoch',
    };
    if (g is! Map<String, Object?> ||
        g.length != fields.length ||
        !fields.containsAll(g.keys) ||
        g['version'] is! int ||
        g['resource'] is! String ||
        g['issuedAt'] is! int ||
        g['expiresAt'] is! int ||
        g['epoch'] is! int ||
        g['actions'] is! List<Object?> ||
        (g['actions']! as List<Object?>).length > 16 ||
        (g['actions']! as List<Object?>).any((a) => a is! String)) {
      throw const FormatException('Invalid grant fields');
    }
    return GrantedAccess(
      grant: Grant(
        version: g['version']! as int,
        ownerId: decodePublicBytes(g['ownerId'], 32),
        viewerId: decodePublicBytes(g['viewerId'], 32),
        grantId: decodePublicBytes(g['grantId'], 16),
        resource: g['resource']! as String,
        actions: List<String>.from(g['actions']! as List<Object?>),
        issuedAt: g['issuedAt']! as int,
        expiresAt: g['expiresAt']! as int,
        epoch: g['epoch']! as int,
      ),
      mac: decodePublicBytes(json['mac'], 32),
    );
  }
}

class _State {
  new(this.owner, this.grants, this.revokedUntil);
  final OwnerState owner;
  final Map<String, GrantedAccess> grants;
  final Map<String, int> revokedUntil;
}

/// Durable owner-only capability authority using one protected-store record.
/// Stores the minting key, epoch, grants, revocations and blocks atomically.
/// Grants survive restart; revocations do not depend on an in-memory cache.
class AuthorizationRepository {
  /// Uses [store] to protect authority state belonging to [identity].
  new(this.store, this.identity);

  /// Protected storage for the owner-only minting material and authority state.
  final SecretStore store;

  /// The owner identity whose node ID namespaces the persisted state.
  final Identity identity;
  final _changes = StreamController<String>.broadcast();

  /// Notifications emitted only after grant or viewer changes are persisted.
  Stream<String> get changes => _changes.stream;
  bool _loaded = false;
  bool _failed = false;
  bool _closed = false;
  String get _key => 'vault.authorization.v1.${nodeIdText(identity.nodeId)}';
  String get _marker => '$_key.created';

  /// Loads or initializes authority state, failing closed on storage loss.
  Future<void> load() => withSecretStoreLock(store, () async {
    if (_closed) throw StateError('Authorization repository is closed');
    if (_failed) {
      throw StateError(
        'Authorization storage failed; '
        'restore storage and reopen the repository',
      );
    }
    try {
      final text = await store.read(_key);
      if (text == null) {
        if (await store.read(_marker) != null) {
          throw StateError(
            'Authorization state is missing; restore protected storage',
          );
        }
        final state = _State(
          OwnerState(secureRandomBytes(32), identity.nodeId, 0),
          {},
          {},
        );
        await _persist(state);
      } else {
        _decode(text);
      }
      await store.write(_marker, '1');
      _loaded = true;
    } on Object {
      _failed = true;
      rethrow;
    }
  });

  Future<T> _run<T>(Future<T> Function(_State state) operation) =>
      withSecretStoreLock(store, () async {
        if (!_loaded || _failed || _closed) {
          throw StateError('Authorization repository is not ready');
        }
        final text = await store.read(_key);
        if (text == null) {
          _failed = true;
          throw StateError(
            'Authorization state disappeared; no minting key was regenerated',
          );
        }
        final state = _decode(text);
        return await operation(state);
      });

  /// Mints and persists a scoped grant unless the viewer is blocked.
  Future<GrantedAccess> approve({
    required Uint8List viewerId,
    required String resource,
    required List<String> actions,
    Duration lifetime = const Duration(hours: 24),
  }) {
    final viewerSnapshot = _fixed(viewerId, 32);
    final actionSnapshot = List<String>.unmodifiable(actions);
    return _run((state) async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (lifetime.inSeconds < 1 || lifetime.inSeconds > 30 * 86400) {
        throw ArgumentError.value(lifetime, 'lifetime');
      }
      if (state.owner.blocked.contains(base64.encode(viewerSnapshot))) {
        throw const WireReject('viewer blocked');
      }
      _prune(state, now);
      if (state.grants.length >= 4096) {
        throw StateError('Active grant limit reached');
      }
      Uint8List id;
      do {
        id = secureRandomBytes(16);
      } while (state.grants.containsKey(base64Url.encode(id)) ||
          state.revokedUntil.containsKey(base64Url.encode(id)));
      final grant = Grant(
        version: 1,
        ownerId: identity.nodeId,
        viewerId: viewerSnapshot,
        grantId: id,
        resource: resource,
        actions: actionSnapshot,
        issuedAt: now,
        expiresAt: now + lifetime.inSeconds,
        epoch: state.owner.epoch,
      );
      final access = GrantedAccess(
        grant: grant,
        mac: await grant.mac(state.owner.mintingKey),
      );
      final idText = base64Url.encode(id);
      state.grants[idText] = access;
      await _persist(state);
      _changes.add(idText);
      return access;
    });
  }

  /// Removes a grant from the durable active whitelist by its encoded ID.
  Future<void> revoke(String grantId) {
    final id = decodePublicBytes(grantId, 16);
    final canonical = base64Url.encode(id);
    return _run((state) async {
      final access = state.grants.remove(canonical);
      if (access != null) {
        state.revokedUntil[canonical] = access.grant.expiresAt;
      }
      await _persist(state);
      _changes.add(canonical);
    });
  }

  /// Revokes existing grants but permits later approval for this viewer.
  Future<void> revokeViewer(Uint8List viewerId) {
    final viewerSnapshot = _fixed(viewerId, 32);
    return _run((state) async {
      _revokeViewer(state, viewerSnapshot);
      await _persist(state);
      _changes.add(nodeIdText(viewerSnapshot));
    });
  }

  /// Blocks future approvals and durably revokes the viewer's active grants.
  Future<void> block(Uint8List viewerId) {
    final viewerSnapshot = _fixed(viewerId, 32);
    return _run((state) async {
      final text = base64.encode(viewerSnapshot);
      if (state.owner.blocked.length >= 4096 &&
          !state.owner.blocked.contains(text)) {
        throw StateError('Blocked viewer limit reached');
      }
      state.owner.blocked.add(text);
      _revokeViewer(state, viewerSnapshot);
      await _persist(state);
      _changes.add(nodeIdText(viewerSnapshot));
    });
  }

  /// Unblocking never restores any previously revoked grant.
  Future<void> unblock(Uint8List viewerId) {
    final viewerSnapshot = _fixed(viewerId, 32);
    return _run((state) async {
      state.owner.blocked.remove(base64.encode(viewerSnapshot));
      await _persist(state);
      _changes.add(nodeIdText(viewerSnapshot));
    });
  }

  /// Invalidates every issued grant by durably advancing the owner epoch.
  Future<void> revokeAll() => _run((state) async {
    if (state.owner.epoch == 0x7fffffffffffffff) {
      throw StateError('Authorization epoch exhausted');
    }
    state.owner.epoch++;
    state.grants.clear();
    state.revokedUntil.clear();
    await _persist(state);
    _changes.add('epoch');
  });

  /// Checks token authenticity, scope and the latest durable whitelist state.
  Future<void> check({
    required GrantedAccess access,
    required Uint8List viewerId,
    required String resource,
    required String action,
  }) {
    final viewerSnapshot = _fixed(viewerId, 32);
    return _run((state) async {
      await authorize(
        owner: state.owner,
        grant: access.grant,
        mac: access.mac,
        authenticatedViewer: viewerSnapshot,
        resource: resource,
        action: action,
        now: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      if (!state.grants.containsKey(base64Url.encode(access.grant.grantId))) {
        throw const WireReject('revoked or unknown grant');
      }
    });
  }

  void _revokeViewer(_State state, Uint8List viewerId) {
    final key = base64Url.encode(viewerId);
    final ids = state.grants.entries
        .where((e) => base64Url.encode(e.value.grant.viewerId) == key)
        .map((e) => e.key)
        .toList();
    for (final id in ids) {
      state.revokedUntil[id] = state.grants.remove(id)!.grant.expiresAt;
    }
  }

  void _prune(_State state, int now) {
    state.grants.removeWhere((_, value) => value.grant.expiresAt <= now);
    state.revokedUntil.removeWhere((_, until) => until <= now);
  }

  Future<void> _persist(_State state) async {
    _prune(state, DateTime.now().millisecondsSinceEpoch ~/ 1000);
    // The active whitelist is authoritative, so old revoked IDs can be dropped
    // without reviving tokens. This bounds historical metadata under churn.
    while (state.revokedUntil.length > 4096) {
      state.revokedUntil.remove(state.revokedUntil.keys.first);
    }
    final text = jsonEncode({
      'version': 1,
      'ownerId': base64Url.encode(identity.nodeId),
      'mintingKey': base64Url.encode(state.owner.mintingKey),
      'epoch': state.owner.epoch,
      'grants': state.grants.values.map((a) => a.toJson()).toList(),
      'revoked': state.revokedUntil,
      'blocked': state.owner.blocked.toList(),
    });
    if (text.length > 8 * 1024 * 1024) {
      throw StateError('Authorization storage limit reached');
    }
    try {
      await store.write(_key, text);
    } on Object {
      _failed = true;
      rethrow;
    }
  }

  _State _decode(String text) {
    if (text.length > 8 * 1024 * 1024) {
      throw const FormatException('Authorization state too large');
    }
    final Object? data = jsonDecode(text);
    const fields = {
      'version',
      'ownerId',
      'mintingKey',
      'epoch',
      'grants',
      'revoked',
      'blocked',
    };
    if (data is! Map<String, Object?> ||
        data.length != fields.length ||
        !fields.containsAll(data.keys) ||
        data['version'] != 1 ||
        data['epoch'] is! int ||
        (data['epoch']! as int) < 0 ||
        data['grants'] is! List<Object?> ||
        (data['grants']! as List<Object?>).length > 4096 ||
        data['blocked'] is! List<Object?> ||
        (data['blocked']! as List<Object?>).length > 4096 ||
        data['revoked'] is! Map<String, Object?> ||
        (data['revoked']! as Map<String, Object?>).length > 4096) {
      throw const FormatException('Invalid authorization state');
    }
    final ownerId = decodePublicBytes(data['ownerId'], 32);
    if (nodeIdText(ownerId) != nodeIdText(identity.nodeId)) {
      throw const FormatException('Wrong authorization owner');
    }
    final owner = OwnerState(
      decodePublicBytes(data['mintingKey'], 32),
      ownerId,
      data['epoch']! as int,
    );
    final grants = <String, GrantedAccess>{};
    for (final value in data['grants']! as List<Object?>) {
      if (value is! Map<String, Object?>) {
        throw const FormatException('Invalid persisted grant');
      }
      final access = GrantedAccess.fromJson(value);
      final grant = access.grant;
      if (nodeIdText(grant.ownerId) != nodeIdText(identity.nodeId) ||
          grant.epoch != owner.epoch ||
          grants.containsKey(base64Url.encode(grant.grantId))) {
        throw const FormatException('Invalid persisted grant owner/epoch/id');
      }
      grants[base64Url.encode(grant.grantId)] = access;
    }
    for (final value in data['blocked']! as List<Object?>) {
      if (value is! String || value.length != 44) {
        throw const FormatException('Invalid blocked viewer');
      }
      final bytes = base64.decode(value);
      if (bytes.length != 32 || base64.encode(bytes) != value) {
        throw const FormatException('Invalid blocked viewer');
      }
      owner.blocked.add(value);
    }
    final revoked = <String, int>{};
    for (final entry in (data['revoked']! as Map<String, Object?>).entries) {
      decodePublicBytes(entry.key, 16);
      if (entry.value is! int || (entry.value! as int) < 0) {
        throw const FormatException('Invalid revocation');
      }
      revoked[entry.key] = entry.value! as int;
      owner.revoked.add(base64.encode(decodePublicBytes(entry.key, 16)));
      if (grants.containsKey(entry.key)) {
        throw const FormatException('Active grant is revoked');
      }
    }
    return _State(owner, grants, revoked);
  }

  /// Closes change notifications and prevents further repository operations.
  Future<void> close() => withSecretStoreLock(store, () async {
    if (_closed) return;
    _closed = true;
    await _changes.close();
  });
}

Uint8List _fixed(Uint8List value, int size) {
  if (value.length != size) {
    throw const FormatException('Invalid authorization byte field');
  }
  return Uint8List.fromList(value).asUnmodifiableView();
}
