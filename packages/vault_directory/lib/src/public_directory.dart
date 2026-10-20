import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_signaling/vault_signaling.dart';

Database _openPresenceDatabase(String path, int maxEntries) {
  if (path.isEmpty || path == ':memory:') {
    throw ArgumentError.value(
      path,
      'databasePath',
      'A disk database path is required',
    );
  }
  final file = File(path);
  final maxBytes = maxEntries * 8192 + 262144;
  if (file.existsSync() && file.lengthSync() > maxBytes) {
    throw StateError(
      'Public presence database exceeds its configured disk budget',
    );
  }
  file.parent.createSync(recursive: true);
  final database = sqlite3.open(path);
  try {
    database
      ..execute('PRAGMA page_size = 4096')
      ..execute('PRAGMA max_page_count = ${maxBytes ~/ 4096}')
      ..execute('PRAGMA journal_mode = DELETE')
      ..execute('PRAGMA auto_vacuum = FULL')
      ..execute('''
      CREATE TABLE IF NOT EXISTS public_presence (
        node_id TEXT PRIMARY KEY NOT NULL CHECK(length(node_id) = 52),
        expires_at INTEGER NOT NULL,
        signed_envelope BLOB NOT NULL CHECK(length(signed_envelope) BETWEEN 1 AND 2048)
      ) WITHOUT ROWID
    ''');
    return database;
  } on Object {
    database.close();
    rethrow;
  }
}

/// Bounded local cache for already signature-verified public presence records.
///
/// This class does not authenticate network input. Only admit records from
/// [SignalingClient.publicPresence], whose wire parser enforces metadata and
/// signature-work budgets. Expiration is always the origin's signed timestamp.
class PublicPresenceCache {
  /// Creates a cache with a positive maximum number of live records.
  new({this.maxEntries = 256}) {
    if (maxEntries < 1) throw ArgumentError.value(maxEntries, 'maxEntries');
  }

  /// Maximum number of distinct public identities retained.
  final int maxEntries;
  final _records = <String, PublicPresenceRecord>{};
  int _revision = 0;

  /// Removes expired records and reports whether the snapshot changed.
  bool prune(DateTime now) {
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    final previous = _records.length;
    _records.removeWhere((_, record) => record.expiresAt <= seconds);
    final changed = previous != _records.length;
    if (changed) _revision++;
    return changed;
  }

  /// Returns an immutable snapshot without changing signed expiry.
  List<PublicPresenceRecord> entriesAt(DateTime now) {
    prune(now);
    return List<PublicPresenceRecord>.unmodifiable(_records.values);
  }

  /// Admits only timely, newer authenticated records within the entry budget.
  bool accept(PublicPresenceRecord record, {required DateTime now}) {
    prune(now);
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    if (record.expiresAt <= seconds ||
        record.expiresAt > seconds + 90 ||
        record.epoch < 1 ||
        record.sequence < 1) {
      return false;
    }
    final previous = _records[record.nodeId];
    if (previous != null &&
        (record.epoch < previous.epoch ||
            (record.epoch == previous.epoch &&
                record.sequence <= previous.sequence))) {
      return false;
    }
    if (previous == null && _records.length >= maxEntries) return false;
    _records[record.nodeId] = record;
    _revision++;
    return true;
  }

  /// Searches the bounded local snapshot by name, tags or node identifier.
  List<PublicPresenceRecord> search(
    String query, {
    required DateTime now,
    int limit = 50,
  }) {
    if (query.length > 256) throw ArgumentError.value(query, 'query');
    if (limit < 1) throw ArgumentError.value(limit, 'limit');
    prune(now);
    final normalized = query.trim().toLowerCase();
    final matches = <PublicPresenceRecord>[];
    for (final record in _records.values) {
      if (normalized.isEmpty ||
          record.nodeId.contains(normalized) ||
          record.name.toLowerCase().contains(normalized) ||
          record.tags.any((tag) => tag.toLowerCase().contains(normalized))) {
        matches.add(record);
        if (matches.length >= limit) break;
      }
    }
    return List<PublicPresenceRecord>.unmodifiable(matches);
  }

  /// Removes every cached public record.
  void clear() {
    if (_records.isEmpty) return;
    _records.clear();
    _revision++;
  }
}

/// Explicitly opted-in public MQTT pilot discovery, separate from contacts.
///
/// Results are partial observations on the configured common broker, not global
/// discovery, verified human identities, reachable sessions or access grants.
/// This object owns public discovery toggles on its signaling client; do not
/// create multiple public-directory owners for the same client.
class PublicContactDirectory {
  /// Opens a bounded disk cache and subscribes to verified public metadata.
  new({
    required this._signaling,
    required String databasePath,
    int maxEntries = 256,
  }) : _cache = PublicPresenceCache(maxEntries: maxEntries) {
    _database = _openPresenceDatabase(databasePath, maxEntries);
    _subscription = _signaling.publicPresence.listen(
      _receive,
      onError: (Object error) {
        if (!_closed) _errors.add(error);
      },
    );
    _sweep = Timer.periodic(const Duration(seconds: 15), (_) {
      try {
        _pruneDatabase();
        _emit();
      } on Object catch (error) {
        _stopDiscoveryOnError(error);
      }
    });
  }

  final SignalingClient _signaling;
  final PublicPresenceCache _cache;
  late final Database _database;
  Future<void>? _loadFuture;
  int _cacheGeneration = 0;
  int _emittedRevision = -1;
  bool _emittedDiscovering = false;
  final _changes = StreamController<List<PublicPresenceRecord>>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  late final StreamSubscription<PublicPresenceRecord> _subscription;
  late final Timer _sweep;
  Timer? _heartbeat;
  Future<void> _transportTail = Future<void>.value();
  Future<void> _announcementTail = Future<void>.value();
  bool _closed = false;
  bool _discovering = false;
  int _discoveryEpoch = 0;
  bool _publishing = false;
  bool _announcing = false;
  int _publicationEpoch = 0;
  String _name = '';
  List<String> _tags = const <String>[];
  int _sharedCount = 0;

  /// Revalidates bounded original signed envelopes, never trusting stored JSON.
  Future<void> load() {
    _ensureOpen();
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    final generation = _cacheGeneration;
    _pruneDatabase();
    _trimDatabase();
    final rows = _database.select(
      'SELECT node_id, signed_envelope FROM public_presence '
      'ORDER BY expires_at DESC, node_id LIMIT ?',
      <Object?>[_cache.maxEntries],
    );
    for (final row in rows) {
      if (_closed || generation != _cacheGeneration) return;
      final nodeId = row['node_id'] as String;
      try {
        final record = await verifyPublicPresenceRecord(
          row['signed_envelope'] as Uint8List,
          now: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          expectedNodeId: nodeId,
        );
        if (_closed || generation != _cacheGeneration) return;
        _cache.accept(record, now: DateTime.now().toUtc());
      } on Object catch (error) {
        if (_closed || generation != _cacheGeneration) return;
        _database.execute(
          'DELETE FROM public_presence WHERE node_id = ?',
          <Object?>[nodeId],
        );
        _errors.add(error);
      }
    }
    if (_discovering) _emit();
  }

  void _pruneDatabase() {
    _database.execute(
      'DELETE FROM public_presence WHERE expires_at <= ? '
      'OR length(signed_envelope) > ? OR length(signed_envelope) < 1',
      <Object?>[
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        maxPublicPresenceBytes,
      ],
    );
  }

  void _trimDatabase() {
    _database.execute(
      '''
      DELETE FROM public_presence WHERE node_id IN (
        SELECT node_id FROM public_presence
        ORDER BY expires_at DESC, node_id LIMIT -1 OFFSET ?
      )
    ''',
      <Object?>[_cache.maxEntries],
    );
  }

  /// Whether the caller has opted into displaying public discovery results.
  bool get discovering => _discovering;

  /// Whether explicit public profile publication and heartbeat are enabled.
  bool get publishing => _publishing;

  /// Current immutable, unexpired results, or empty while browsing is disabled.
  List<PublicPresenceRecord> get entries => _discovering
      ? _cache.entriesAt(DateTime.now().toUtc())
      : const <PublicPresenceRecord>[];

  /// Immutable snapshots after admission, expiry or discovery-policy changes.
  Stream<List<PublicPresenceRecord>> get changes => _changes.stream;

  /// Local operational failures delivered as data events.
  Stream<Object> get errors => _errors.stream;

  /// Searches only locally cached public metadata with a bounded result count.
  List<PublicPresenceRecord> search(String query, {int limit = 50}) =>
      _discovering
      ? _cache.search(query, now: DateTime.now().toUtc(), limit: limit)
      : const <PublicPresenceRecord>[];

  Future<void> _configureTransport() {
    final operation = _transportTail.then(
      (_) => _signaling.setPublicDiscoveryEnabled(
        !_closed && (_discovering || _publishing),
      ),
    );
    // Keep later policy changes operable after subscription failures, while
    // returning the actual failure to the operation that requested it.
    _transportTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  /// Opts into browsing, independently of publishing a public profile.
  // Preserve the established toggle API used by the application.
  // ignore: avoid_positional_boolean_parameters
  Future<void> setDiscovering(bool enabled) async {
    _ensureOpen();
    final epoch = ++_discoveryEpoch;
    _discovering = enabled;
    if (!enabled) {
      _cacheGeneration++;
      _cache.clear();
      _emit();
      _database.execute('DELETE FROM public_presence');
    }
    try {
      if (enabled) await load();
      await _configureTransport();
      if (!_closed && epoch == _discoveryEpoch && _discovering) _emit();
    } on Object {
      if (enabled && epoch == _discoveryEpoch) {
        _discovering = false;
        _cache.clear();
        _emit();
      }
      rethrow;
    }
  }

  /// Publishes chosen public metadata immediately and on a 30-second heartbeat.
  /// Disabling leaves browsing unchanged and cannot recall signed records.
  Future<void> setPublishing(
    // Preserve the established toggle API used by the application.
    // ignore: avoid_positional_boolean_parameters
    bool enabled, {
    String name = '',
    List<String> tags = const <String>[],
    int sharedCount = 0,
  }) async {
    _ensureOpen();
    final epoch = ++_publicationEpoch;
    _heartbeat?.cancel();
    _heartbeat = null;
    _publishing = enabled;
    if (enabled) {
      _name = name;
      _tags = List<String>.unmodifiable(tags);
      _sharedCount = sharedCount;
    }
    try {
      await _configureTransport();
      if (!_closed && _publishing && epoch == _publicationEpoch) {
        await _announce();
        if (!_closed && _publishing && epoch == _publicationEpoch) {
          _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
            unawaited(_heartbeatAnnouncement());
          });
        }
      }
    } on Object {
      if (epoch == _publicationEpoch) {
        _publishing = false;
        _heartbeat?.cancel();
        _heartbeat = null;
        try {
          await _configureTransport();
        } on Object catch (error) {
          if (!_closed) _errors.add(error);
        }
      }
      rethrow;
    }
  }

  Future<void> _announce() {
    final epoch = _publicationEpoch;
    final name = _name;
    final tags = _tags;
    final count = _sharedCount;
    final operation = _announcementTail.then((_) async {
      if (_closed || !_publishing || epoch != _publicationEpoch) return;
      await _signaling.announcePublicPresence(
        name: name,
        tags: tags,
        sharedCount: count,
      );
    });
    _announcementTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _heartbeatAnnouncement() async {
    if (_closed || !_publishing || _announcing) return;
    _announcing = true;
    try {
      await _announce();
    } on Object catch (error) {
      if (!_closed) _errors.add(error);
    } finally {
      _announcing = false;
    }
  }

  void _receive(PublicPresenceRecord record) {
    if (_closed || !_discovering) return;
    try {
      if (_cache.accept(record, now: DateTime.now().toUtc())) {
        _database.execute('BEGIN IMMEDIATE');
        try {
          _pruneDatabase();
          _database.execute(
            '''
            INSERT INTO public_presence(node_id, expires_at, signed_envelope)
            VALUES (?, ?, ?)
            ON CONFLICT(node_id) DO UPDATE SET
              expires_at = excluded.expires_at,
              signed_envelope = excluded.signed_envelope
          ''',
            <Object?>[record.nodeId, record.expiresAt, record.signedEnvelope],
          );
          _trimDatabase();
          _database.execute('COMMIT');
        } on Object {
          _database.execute('ROLLBACK');
          rethrow;
        }
        _emit();
      }
    } on Object catch (error) {
      _stopDiscoveryOnError(error);
    }
  }

  void _stopDiscoveryOnError(Object error) {
    if (_closed) return;
    _discovering = false;
    _discoveryEpoch++;
    _cacheGeneration++;
    _cache.clear();
    _emit();
    _errors.add(error);
    unawaited(
      _configureTransport().then<void>(
        (_) {},
        onError: (Object failure, StackTrace _) {
          if (!_closed) _errors.add(failure);
        },
      ),
    );
  }

  void _emit() {
    if (_closed) return;
    _cache.prune(DateTime.now().toUtc());
    if (_emittedRevision == _cache._revision &&
        _emittedDiscovering == _discovering) {
      return;
    }
    _emittedRevision = _cache._revision;
    _emittedDiscovering = _discovering;
    _changes.add(
      _discovering
          ? List<PublicPresenceRecord>.unmodifiable(_cache._records.values)
          : const <PublicPresenceRecord>[],
    );
  }

  /// Builds public contact material only after an explicit user action.
  ///
  /// Independently compare the record's node ID and ask the user to choose
  /// [name]. This neither persists nor marks a contact trusted,
  /// connects to it, or grants any library access.
  Future<ContactCard> contactFor(
    PublicPresenceRecord record, {
    required String name,
  }) async {
    _ensureOpen();
    final contact = await ContactCard.fromBinding(record.binding, name: name);
    if (contact.nodeId != record.nodeId) {
      throw const FormatException('Public presence contact identity mismatch');
    }
    return contact;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Public directory is closed');
  }

  /// Releases this directory's database and public subscription.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _discovering = false;
    _discoveryEpoch++;
    _publishing = false;
    _publicationEpoch++;
    _heartbeat?.cancel();
    _sweep.cancel();
    _cache.clear();
    await _subscription.cancel();
    try {
      await _configureTransport();
    } finally {
      _database.close();
      await _changes.close();
      await _errors.close();
    }
  }
}
