/// Private contact presence and separate opt-in public MQTT pilot discovery.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:vault_identity/vault_identity.dart';
import 'package:vault_protocol/vault_protocol.dart';
import 'package:vault_signaling/vault_signaling.dart';

export 'src/public_directory.dart';

/// A contact's authenticated announcement, not proof of current reachability.
class ContactPresence {
  new _({
    required this.contact,
    required this.name,
    required this.expiresAt,
    required this.issuedAt,
  });

  /// The locally resolved, verified public contact.
  final ContactCard contact;

  /// The signed display name, not an identity or authorization decision.
  final String name;

  /// Exact origin-signed expiration in UTC.
  final DateTime expiresAt;

  /// Signed issuance time in Unix seconds.
  final int issuedAt;

  /// Stable node identifier derived from the contact's signing key.
  String get nodeId => contact.nodeId;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _validName(Object? value) =>
    value is String && value.length <= 80 && utf8.encode(value).length <= 80;

/// Bounded state and strict validation for already-authenticated announcements.
///
/// This does NOT authenticate raw envelopes. Obtain them first from
/// [SignalingClient.messages], which verifies the signature, sealing, recipient
/// and known-contact binding. Exposed separately so expiry
/// and admission decisions can be tested with an explicit clock.
class ContactPresenceCache {
  /// Creates an authenticated-input cache with a positive contact capacity.
  new({this.maxEntries = 256}) {
    if (maxEntries < 1) throw ArgumentError.value(maxEntries, 'maxEntries');
  }

  /// Maximum number of live contacts retained.
  final int maxEntries;
  final _entries = <String, ContactPresence>{};

  /// Returns a snapshot; reading never refreshes signed expiration.
  List<ContactPresence> entriesAt(DateTime now) {
    _prune(now);
    return List<ContactPresence>.unmodifiable(_entries.values);
  }

  void _prune(DateTime now) =>
      _entries.removeWhere((_, value) => !now.isBefore(value.expiresAt));

  /// Rejects unknown schema, mismatched contact keys, stale and excessive TTLs.
  /// At capacity existing contacts may refresh; new contacts are not admitted.
  bool accept(Envelope envelope, ContactCard contact, {required DateTime now}) {
    _prune(now);
    if (envelope.type != MsgType.announce ||
        !_sameBytes(envelope.sender, contact.binding.signingKey)) {
      return false;
    }
    final payload = envelope.payload;
    final expires = payload['expires'];
    final name = payload['name'];
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    if (payload.length != 3 ||
        payload['presence'] != true ||
        !_validName(name) ||
        expires is! int ||
        expires <= seconds ||
        expires > seconds + 90 ||
        envelope.expiresAt != expires ||
        envelope.issuedAt < 0 ||
        envelope.issuedAt > seconds ||
        expires <= envelope.issuedAt ||
        expires - envelope.issuedAt > 90) {
      return false;
    }
    final previous = _entries[contact.nodeId];
    if (previous != null && envelope.issuedAt < previous.issuedAt) return false;
    if (previous == null && _entries.length >= maxEntries) return false;
    _entries[contact.nodeId] = ContactPresence._(
      contact: contact,
      name: name! as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        expires * 1000,
        isUtc: true,
      ),
      issuedAt: envelope.issuedAt,
    );
    return true;
  }

  /// Removes all cached contact announcements.
  void clear() => _entries.clear();
}

/// Receives private announcements and sends only to explicitly chosen contacts.
///
/// Construct after configuring [SignalingClient]; its owner starts and closes
/// signaling. Publishing is disabled initially. Calling [announce] explicitly
/// is the only trigger for outgoing presence.
class ContactDirectory {
  /// Subscribes immediately without starting or taking ownership of signaling.
  new({
    required this._signaling,
    required this._resolveContact,
    int maxEntries = 256,
  }) : _cache = ContactPresenceCache(maxEntries: maxEntries) {
    _subscription = _signaling.messages.listen(
      _receive,
      onError: (Object error) {
        if (!_closed) {
          _cache.clear();
          _errors.add(error);
        }
      },
    );
  }

  final SignalingClient _signaling;
  final Future<ContactCard?> Function(String nodeId) _resolveContact;
  final ContactPresenceCache _cache;
  final _pending = Queue<Envelope>();
  final _errors = StreamController<Object>.broadcast();
  late final StreamSubscription<Envelope> _subscription;
  bool _draining = false;
  bool _publishing = false;
  bool _closed = false;
  int _publicationEpoch = 0;
  String _name = '';

  /// Contact lookup failures and signaling stream errors, never presence data.
  Stream<Object> get errors => _errors.stream;

  /// Current immutable snapshot, excluding announcements already expired.
  List<ContactPresence> get entries => _cache.entriesAt(DateTime.now().toUtc());

  /// Enables explicit per-contact publication without sending a heartbeat.
  // Preserve the established toggle API used by the application.
  // ignore: avoid_positional_boolean_parameters
  Future<void> setPublishing(bool enabled, {String name = ''}) async {
    _ensureOpen();
    _publishing = false;
    _publicationEpoch++;
    if (!enabled) return;
    if (!_validName(name)) {
      throw ArgumentError.value(name, 'name', 'Must be at most 80 UTF-8 bytes');
    }
    _name = name;
    _publishing = true;
  }

  /// Sends one sealed announcement to an explicitly selected known contact.
  Future<void> announce(ContactCard contact) async {
    _ensureOpen();
    if (!_publishing) throw StateError('Presence publication is disabled');
    final epoch = _publicationEpoch;
    final known = await _resolveContact(contact.nodeId);
    _ensureOpen();
    if (!_publishing || epoch != _publicationEpoch) {
      throw StateError('Presence publication changed while resolving contact');
    }
    if (known == null ||
        known.nodeId != contact.nodeId ||
        !_sameBytes(known.binding.signingKey, contact.binding.signingKey) ||
        !_sameBytes(
          known.binding.encryptionKey,
          contact.binding.encryptionKey,
        )) {
      throw StateError('Presence may only be sent to a known verified contact');
    }
    final random = Random.secure();
    await _signaling.send(
      peer: known.binding,
      type: MsgType.announce,
      sessionId: Uint8List.fromList(
        List<int>.generate(16, (_) => random.nextInt(256)),
      ),
      payload: <Object, Object?>{
        'presence': true,
        'name': _name,
        'expires': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 90,
      },
    );
  }

  void _receive(Envelope envelope) {
    if (_closed || envelope.type != MsgType.announce) return;
    // Bound waiting lookups independently of SignalingClient's wire budgets.
    if (_pending.length >= _cache.maxEntries) return;
    _pending.add(envelope);
    if (!_draining) unawaited(_drain());
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (!_closed && _pending.isNotEmpty) {
        final envelope = _pending.removeFirst();
        try {
          final id = nodeIdText(await nodeIdOf(envelope.sender));
          if (_closed) return;
          final contact = await _resolveContact(id);
          if (_closed) return;
          if (contact != null && contact.nodeId == id) {
            _cache.accept(envelope, contact, now: DateTime.now().toUtc());
          }
        } on Object catch (error) {
          if (!_closed) _errors.add(error);
        }
      }
    } finally {
      _draining = false;
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Contact directory is closed');
  }

  /// Stops this directory only, without taking ownership of shared signaling.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _publishing = false;
    _publicationEpoch++;
    _pending.clear();
    _cache.clear();
    await _subscription.cancel();
    await _errors.close();
  }
}
