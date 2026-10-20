import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:vault_media_index/src/index_store.dart';
import 'package:vault_media_index/src/media_metadata.dart';

export 'src/media_metadata.dart';

/// Integrity block size used by indexing, manifests and delivery.
const int mediaChunkBytes = 256 * 1024;

/// Maximum blocks in one content generation (16 GiB).
const maxMediaChunks = 65536;

/// Maximum files retained in one library index.
const maxLibraryItems = 20000;

/// Aggregate bound on resident and persisted integrity digests.
const maxLibraryHashEntries = 131072;

/// Injected decoder that returns actual bounded metadata or explicit absence.
typedef MediaMetadataExtractor = Future<MediaMetadata> Function(
  SourceEntry source,
);

/// Hashes the canonical identifier, byte length and ordered block hashes.
String manifestDigest(String id, int size, List<String> chunks) => sha256
    .convert(
      utf8.encode(
        jsonEncode({
          'id': id,
          'size': size,
          'chunkBytes': mediaChunkBytes,
          'chunks': chunks,
        }),
      ),
    )
    .toString();
bool _hash(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
void _name(String value) {
  if (value.isEmpty ||
      utf8.encode(value).length > 256 ||
      RegExp(r'[\x00-\x1f]').hasMatch(value)) {
    throw ArgumentError(
      'Media name must be 1–256 UTF-8 bytes without control characters',
    );
  }
}

/// Stable size and modification timestamp reported by a source provider.
class SourceStat {
  /// Creates a source snapshot without opening or copying its bytes.
  const new({required this.size, required this.modifiedMillis});

  /// Exact byte length, or a negative value when the provider cannot supply it.
  final int size;

  /// Provider modification timestamp used to invalidate indexed generations.
  final int modifiedMillis;
}

/// Enumerated source document with an actual URI and user-visible name.
class SourceEntry extends SourceStat {
  /// Creates a document snapshot returned by a filesystem or SAF adapter.
  const new({
    required this.uri,
    required this.name,
    required super.size,
    required super.modifiedMillis,
  });

  /// Actual file or content URI; never a disguised filesystem path.
  final String uri;

  /// Original document display name, validated before indexing.
  final String name;
}

/// Native adapters must retain actual SAF tree permissions, bound enumeration,
/// and implement random access. Permission loss/nonseekable input must throw.
abstract class VaultSourceAccess {
  /// Enumerates real documents and throws on permission loss or source limits.
  Stream<SourceEntry> enumerate(String rootUri);

  /// Reads current size and modification state without reading media bytes.
  Future<SourceStat> stat(String uri);

  /// Returns at most one integrity block from the requested absolute offset.
  Future<Uint8List> readAt(String uri, int offset, int length);
}

/// Filesystem-only adapter that refuses native content URIs.
class FileSourceAccess implements VaultSourceAccess {
  File _file(String uri) {
    final parsed = Uri.parse(uri);
    if (parsed.scheme != 'file') throw ArgumentError('Not a filesystem URI');
    return File.fromUri(parsed);
  }

  @override
  Stream<SourceEntry> enumerate(String rootUri) async* {
    final parsed = Uri.parse(rootUri);
    if (parsed.scheme != 'file') {
      throw ArgumentError('Not a filesystem directory URI');
    }
    var count = 0;
    await for (final entity in Directory.fromUri(
      parsed,
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (++count > maxLibraryItems) {
        throw StateError('Source entry limit exceeded');
      }
      final value = await entity.stat();
      yield SourceEntry(
        uri: entity.uri.toString(),
        name: entity.uri.pathSegments.last,
        size: value.size,
        modifiedMillis: value.modified.millisecondsSinceEpoch,
      );
    }
  }

  @override
  Future<SourceStat> stat(String uri) async {
    final value = await _file(uri).stat();
    if (value.type != FileSystemEntityType.file) {
      throw FileSystemException('Source disappeared', uri);
    }
    return SourceStat(
      size: value.size,
      modifiedMillis: value.modified.millisecondsSinceEpoch,
    );
  }

  @override
  Future<Uint8List> readAt(String uri, int offset, int length) async {
    if (offset < 0 || length < 0 || length > mediaChunkBytes) {
      throw RangeError('Unbounded source read');
    }
    final file = await _file(uri).open();
    try {
      await file.setPosition(offset);
      return await _readBlock(file, length);
    } finally {
      await file.close();
    }
  }
}

/// Immutable indexed content, its source and integrity/extraction artifacts.
class LibraryItem {
  /// Creates an indexed generation from complete streaming hash results.
  new({
    required this.id,
    required this.name,
    required this.size,
    required this.mimeType,
    required this.path,
    required List<String> chunks,
    this.sourceUri,
    this.sourceRoot,
    this.modifiedMillis,
    String? generation,
    this.metadata = const MediaMetadata(
      unavailableReason: 'No extractor configured',
    ),
    this.posterDigest,
    this.posterSize,
    this.posterPath,
  }) : chunks = List.unmodifiable(chunks) {
    _generation = generation;
  }

  /// Collision-safe full-content SHA-256 identifier.
  final String id;

  /// Original bounded display name.
  final String name;

  /// Complete media length in bytes.
  final int size;

  /// MIME type inferred from the source name.
  final String mimeType;

  /// Real filesystem path for imports/file sources; empty for native URIs.
  final String path;

  /// Referenced file/content URI, or null for a durable owned import.
  final String? sourceUri;

  /// Registered folder/tree that owns the reference.
  final String? sourceRoot;

  /// Source timestamp captured when hashing completed.
  final int? modifiedMillis;

  /// Ordered SHA-256 integrity hashes, one per complete or final partial block.
  final List<String> chunks;

  /// Actual extracted dimensions, duration and explicit unsupported status.
  final MediaMetadata metadata;

  /// SHA-256 of the encoded poster, when a real artifact exists.
  final String? posterDigest;

  /// Exact bounded poster byte length.
  final int? posterSize;

  /// Owned poster artifact path; never sent to peers.
  final String? posterPath;
  String? _generation;

  /// Canonical authenticated manifest digest for this content generation.
  String get generation => _generation ??= manifestDigest(id, size, chunks);

  /// Serializes public index metadata without media or poster bytes.
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'size': size,
    'mime': mimeType,
    'chunks': chunks,
    'source': sourceUri,
    'root': sourceRoot,
    'modified': modifiedMillis,
    'generation': generation,
    'metadata': metadata.toJson(),
    'posterDigest': posterDigest,
    'posterSize': posterSize,
  };
}

/// Durable copied imports plus referenced Windows folders / injected SAF trees.
/// Media bytes are never read whole. Local hashing runs in a worker isolate;
/// Native-source work handles one 256 KiB block between asynchronous reads.
class VaultLibrary {
  /// Opens an app-owned index with optional native source and decoder bridges.
  new(this.root, {this.sourceAccess, this.metadataExtractor});

  /// App-owned database, import and poster directory.
  final Directory root;

  /// Native URI bridge; filesystem sources use the built-in adapter.
  final VaultSourceAccess? sourceAccess;

  /// Actual platform decoder used during staged indexing.
  final MediaMetadataExtractor? metadataExtractor;
  final _posterSizes = <String, int>{};
  int _posterByteTotal = 0;
  final _files = FileSourceAccess();
  final _items = <String, LibraryItem>{};
  final _sources = <String>[];
  final _persisted = <String, String>{};
  bool _closed = false;
  Future<void>? _closeFuture;
  String get _databasePath => '${root.path}/library.sqlite';
  Future<void> _tail = Future.value();

  /// Immutable snapshot of all bounded indexed records.
  List<LibraryItem> get items => List.unmodifiable(_items.values);

  /// Number of currently indexed content records.
  int get length => _items.length;

  /// Looks up an indexed generation without copying the whole library.
  LibraryItem? byId(String id) => _items[id];

  /// Reads a bounded, name-ordered SQL page.
  List<LibraryItem> page(int offset, {int limit = 16}) {
    if (offset < 0 || limit < 0 || limit > 16) {
      throw RangeError('Invalid library page');
    }
    return List.unmodifiable(
      readIndexIds(
        _databasePath,
        offset,
        limit,
      ).map((id) => _items[id]).whereType<LibraryItem>(),
    );
  }

  /// Registered real filesystem folders and native tree URIs.
  List<String> get sources => List.unmodifiable(_sources);
  File _content(String id) => File('${root.path}/content/$id');
  VaultSourceAccess _access(String uri) {
    if (Uri.parse(uri).scheme == 'file') return _files;
    if (Uri.parse(uri).scheme != 'content' || sourceAccess == null) {
      throw StateError('Native source access unavailable for $uri');
    }
    return sourceAccess!;
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    if (_closed) return Future<T>.error(StateError('Library closed'));
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Loads the SQLite index, migrating the transient JSON format once.
  Future<void> load() => _serial(() async {
    await Directory('${root.path}/content').create(recursive: true);
    final posters = await Directory('${root.path}/posters')
        .create(recursive: true);
    _posterSizes.clear();
    _posterByteTotal = 0;
    await for (final entry in posters.list()) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      final size = await entry.length();
      if (!_hash(name) ||
          size > mediaChunkBytes ||
          size <= 0 ||
          _posterByteTotal + size > 128 * 1024 * 1024 ||
          _posterSizes.length >= maxLibraryItems) {
        await entry.delete();
        continue;
      }
      _posterByteTotal += size;
      _posterSizes[name] = size;
    }
    final metadata = File('${root.path}/index.json');
    final backup = File('${root.path}/index.json.previous');
    if (!await metadata.exists() && await backup.exists()) {
      await backup.rename(metadata.path);
    }
    final migrate =
        !await File(_databasePath).exists() && await metadata.exists();
    _items.clear();
    _sources.clear();
    _persisted.clear();
    var legacy = <Map<String, Object?>>[];
    if (migrate) {
      if (await metadata.length() > 32 * 1024 * 1024) {
        throw const FormatException('Legacy index too large');
      }
      final text = await metadata.readAsString();
      final decoded = await _decodeInWorker(text);
      final raw = decoded is List<Object?>
          ? decoded
          : (decoded! as Map<String, Object?>)['items']! as List<Object?>;
      legacy = raw.map((row) => row! as Map<String, Object?>).toList();
      if (decoded is Map<String, Object?>) {
        _sources.addAll((decoded['sources']! as List<Object?>).cast<String>());
      }
    } else {
      final path = _databasePath;
      _sources.addAll(await _sourcesInWorker(path));
    }
    if (_sources.length > 128 || legacy.length > maxLibraryItems) {
      throw const FormatException('Library limit exceeded');
    }
    _sources.forEach(_access);
    var total = 0;
    for (var offset = 0; offset <= maxLibraryItems; offset += 128) {
      final path = _databasePath;
      final rows = migrate
          ? legacy.sublist(
              min(offset, legacy.length),
              min(offset + 128, legacy.length),
            )
          : await _pageInWorker(path, offset);
      if (offset + rows.length > maxLibraryItems) {
        throw const FormatException('Library limit exceeded');
      }
      for (final row in rows) {
        final id = row['id']! as String;
        final size = row['size']! as int;
        final chunks = (row['chunks']! as List<Object?>).cast<String>();
        total += chunks.length;
        if (!_hash(id) ||
            size <= 0 ||
            chunks.length != (size + mediaChunkBytes - 1) ~/ mediaChunkBytes ||
            chunks.length > maxMediaChunks ||
            total > maxLibraryHashEntries ||
            chunks.any((v) => !_hash(v))) {
          throw const FormatException('Invalid library metadata');
        }
        _name(row['name']! as String);
        final source = row['source'] as String?;
        final sourceRoot = row['root'] as String?;
        if (source != null &&
            (sourceRoot == null || !_sources.contains(sourceRoot))) {
          throw const FormatException('Unregistered source');
        }
        final path = source == null
            ? _content(id).path
            : (Uri.parse(source).scheme == 'file'
                  ? File.fromUri(Uri.parse(source)).path
                  : '');
        if (source == null &&
            (!await File(path).exists() || await File(path).length() != size)) {
          if (!migrate) _persisted[id] = '';
          continue;
        }
        final generation = row['generation'] as String?;
        if (generation != null && !_hash(generation)) {
          throw const FormatException('Invalid manifest digest');
        }
        final probe = row['metadata'] == null
            ? const MediaMetadata(unavailableReason: 'Metadata not extracted')
            : MediaMetadata.fromJson(row['metadata']! as Map<String, Object?>);
        _validateMetadata(probe);
        final poster = row['posterDigest'] as String?;
        final posterSize = row['posterSize'] as int?;
        final hasPoster =
            poster != null &&
            _hash(poster) &&
            _posterSizes[poster] == posterSize;
        _items[id] = LibraryItem(
          id: id,
          name: row['name']! as String,
          size: size,
          mimeType: row['mime']! as String,
          path: path,
          chunks: chunks,
          sourceUri: source,
          sourceRoot: sourceRoot,
          modifiedMillis: row['modified'] as int?,
          generation: generation,
          metadata: probe,
          posterDigest: hasPoster ? poster : null,
          posterSize: hasPoster ? posterSize : null,
          posterPath: hasPoster ? '${root.path}/posters/$poster' : null,
        );
        if (!migrate) _persisted[id] = _fingerprint(_items[id]!);
      }
      if (rows.length < 128) break;
    }
    if (migrate) {
      await _persist();
      for (final suffix in ['', '.previous', '.next']) {
        final file = File('${metadata.path}$suffix');
        if (await file.exists()) await file.delete();
      }
    }
    if (!migrate && _persisted.length != _items.length) await _persist();
    await _prunePosters();
  });

  /// Streams a durable import and commits its complete content hash.
  Future<LibraryItem> addFile(File source, {String? name}) => _serial(() async {
    if (_items.length >= maxLibraryItems) {
      throw StateError('Library limit reached');
    }
    await _prunePosters();
    final displayName = name ?? source.uri.pathSegments.last;
    _name(displayName);
    await Directory('${root.path}/content').create(recursive: true);
    final tempPath =
        '${root.path}/content/.import-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    final sourcePath = source.path;
    final budget =
        maxLibraryHashEntries -
        _items.values.fold<int>(0, (sum, item) => sum + item.chunks.length);
    final result = await _copyInWorker(sourcePath, tempPath, budget);
    final temp = File(tempPath);
    final destination = _content(result.id);
    final existed = await destination.exists();
    if (existed) {
      await temp.delete();
    } else {
      await temp.rename(destination.path);
    }
    try {
      final item = await _enrich(
        LibraryItem(
          id: result.id,
          name: displayName,
          size: result.size,
          mimeType: _mime(displayName),
          path: destination.path,
          chunks: result.chunks,
          generation: result.generation,
        ),
      );
      final previous = _items[item.id];
      _items[item.id] = item;
      try {
        await _persist();
      } on Object catch (_) {
        if (previous == null) {
          _items.remove(item.id);
        } else {
          _items[item.id] = previous;
        }
        rethrow;
      }
      return item;
    } on Object catch (_) {
      if (!existed && await destination.exists()) await destination.delete();
      rethrow;
    }
  });

  /// References a real filesystem folder without copying its media.
  Future<void> addFolder(Directory folder) => addSource(folder.uri.toString());

  /// Registers and indexes an actual folder or durable native tree URI.
  Future<void> addSource(String rootUri) => _serial(() async {
    _access(rootUri);
    if (!_sources.contains(rootUri)) {
      if (_sources.length >= 128) throw StateError('Source root limit');
      _sources.add(rootUri);
      try {
        await _refresh();
      } on Object catch (_) {
        _sources.remove(rootUri);
        rethrow;
      }
    } else {
      await _refresh();
    }
  });

  /// Reconciles registered sources atomically, retaining snapshots on failure.
  Future<void> refresh() => _serial(_refresh);
  Future<void> _refresh() async {
    await _prunePosters();
    final next = <String, LibraryItem>{
      for (final item in _items.values)
        if (item.sourceRoot == null) item.id: item,
    };
    final oldByUri = <String, LibraryItem>{
      for (final item in _items.values)
        if (item.sourceUri != null) item.sourceUri!: item,
    };
    var count = next.length;
    var total = next.values.fold<int>(
      0,
      (sum, item) => sum + item.chunks.length,
    );
    for (final rootUri in _sources) {
      final adapter = _access(rootUri);
      await for (final entry in adapter.enumerate(rootUri)) {
        if (++count > maxLibraryItems) throw StateError('Library entry limit');
        if (entry.size == 0) continue;
        if (entry.size < 0 || entry.size > mediaChunkBytes * maxMediaChunks) {
          throw StateError('Unbounded source size');
        }
        _name(entry.name);
        if (Uri.parse(entry.uri).scheme != Uri.parse(rootUri).scheme) {
          throw StateError('Source adapter returned invalid URI');
        }
        final old = oldByUri[entry.uri];
        LibraryItem item;
        if (old != null &&
            old.size == entry.size &&
            old.modifiedMillis == entry.modifiedMillis &&
            old.name == entry.name) {
          item = old;
        } else {
          final available = maxLibraryHashEntries - total;
          final result = Uri.parse(entry.uri).scheme == 'file'
              ? await _referenceInWorker(entry, available)
              : await _hashReference(adapter, entry, available);
          final path = Uri.parse(entry.uri).scheme == 'file'
              ? File.fromUri(Uri.parse(entry.uri)).path
              : '';
          item = LibraryItem(
            id: result.id,
            name: entry.name,
            size: result.size,
            mimeType: _mime(entry.name),
            path: path,
            chunks: result.chunks,
            sourceUri: entry.uri,
            sourceRoot: rootUri,
            modifiedMillis: entry.modifiedMillis,
            generation: result.generation,
          );
        }
        if (metadataExtractor != null &&
            (item.metadata.unavailableReason != null ||
                !identical(item, old))) {
          item = await _enrich(item);
        }
        total += item.chunks.length;
        if (total > maxLibraryHashEntries) {
          throw StateError('Library hash budget');
        }
        next.putIfAbsent(item.id, () => item);
      }
    }
    final previous = Map<String, LibraryItem>.of(_items);
    _items
      ..clear()
      ..addAll(next);
    try {
      await _persist();
    } on Object catch (_) {
      _items
        ..clear()
        ..addAll(previous);
      rethrow;
    }
  }

  /// Removes indexed references without deleting provider-owned source media.
  Future<void> removeSource(String rootUri) => _serial(() async {
    final previousSources = _sources.toList();
    final removed = _items.values
        .where((item) => item.sourceRoot == rootUri)
        .toList();
    _sources.remove(rootUri);
    _items.removeWhere((_, item) => item.sourceRoot == rootUri);
    try {
      await _persist();
    } on Object catch (_) {
      _sources
        ..clear()
        ..addAll(previousSources);
      for (final item in removed) {
        _items[item.id] = item;
      }
      rethrow;
    }
    await _prunePosters();
  });

  /// Removes the index record and only deletes bytes owned by copied imports.
  Future<void> remove(String id) => _serial(() async {
    final item = _items.remove(id);
    try {
      await _persist();
    } on Object catch (_) {
      if (item != null) _items[id] = item;
      rethrow;
    }
    if (item != null &&
        item.sourceUri == null &&
        await File(item.path).exists()) {
      await File(item.path).delete();
    }
    await _prunePosters();
  });

  /// Revalidates source state and returns exactly one integrity-checked block.
  Future<Uint8List> readChunk(LibraryItem item, int index) async {
    if (!_items.containsKey(item.id)) throw StateError('Item removed');
    if (index < 0 || index >= item.chunks.length) {
      throw RangeError.index(index, item.chunks);
    }
    Uint8List bytes;
    if (item.sourceUri != null) {
      final access = _access(item.sourceUri!);
      final current = await access.stat(item.sourceUri!);
      if (current.size != item.size ||
          current.modifiedMillis != item.modifiedMillis) {
        throw StateError('Source changed; refresh the library');
      }
      bytes = await access.readAt(
        item.sourceUri!,
        index * mediaChunkBytes,
        min(mediaChunkBytes, item.size - index * mediaChunkBytes),
      );
    } else {
      bytes = await readLibraryChunk(item, index);
    }
    if (bytes.length !=
            min(mediaChunkBytes, item.size - index * mediaChunkBytes) ||
        sha256.convert(bytes).toString() != item.chunks[index]) {
      throw StateError('Source changed or corrupted');
    }
    return bytes;
  }

  Future<LibraryItem> _enrich(LibraryItem item) async {
    final extractor = metadataExtractor;
    if (extractor == null) return item;
    final uri = item.sourceUri ?? File(item.path).uri.toString();
    final result = await extractor(
      SourceEntry(
        uri: uri,
        name: item.name,
        size: item.size,
        modifiedMillis: item.modifiedMillis ?? 0,
      ),
    );
    _validateMetadata(result);
    var reason = result.unavailableReason;
    String? posterDigest;
    int? posterSize;
    String? posterPath;
    final encoded = result.poster;
    if (encoded != null) {
      final bytes = Uint8List.fromList(encoded);
      validateMediaPoster(bytes);
      final digest = sha256.convert(bytes).toString();
      if (!_posterSizes.containsKey(digest) &&
          (_posterByteTotal + bytes.length > 128 * 1024 * 1024 ||
              _posterSizes.length >= maxLibraryItems)) {
        reason = 'Poster storage budget exceeded';
      } else {
        final directory = await Directory('${root.path}/posters')
            .create(recursive: true);
        final file = File('${directory.path}/$digest');
        if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
        if (!_posterSizes.containsKey(digest)) _posterByteTotal += bytes.length;
        _posterSizes[digest] = bytes.length;
        posterDigest = digest;
        posterSize = bytes.length;
        posterPath = file.path;
      }
    }
    if (result.width == null &&
        result.height == null &&
        result.durationMillis == null &&
        posterDigest == null) {
      reason ??= 'No supported metadata available';
    }
    return LibraryItem(
      id: item.id,
      name: item.name,
      size: item.size,
      mimeType: item.mimeType,
      path: item.path,
      chunks: item.chunks,
      sourceUri: item.sourceUri,
      sourceRoot: item.sourceRoot,
      modifiedMillis: item.modifiedMillis,
      generation: item.generation,
      metadata: MediaMetadata(
        width: result.width,
        height: result.height,
        durationMillis: result.durationMillis,
        unavailableReason: reason,
      ),
      posterDigest: posterDigest,
      posterSize: posterSize,
      posterPath: posterPath,
    );
  }

  /// Reads a bounded encoded preview and verifies its persisted digest.
  Future<Uint8List> readPoster(LibraryItem item) async {
    if (_closed ||
        !_items.containsKey(item.id) ||
        item.posterPath == null ||
        item.posterSize == null) {
      throw StateError('Poster unavailable');
    }
    final file = File(item.posterPath!);
    if (await file.length() != item.posterSize ||
        item.posterSize! > mediaChunkBytes) {
      throw StateError('Poster size changed');
    }
    final bytes = await file.readAsBytes();
    if (sha256.convert(bytes).toString() != item.posterDigest) {
      throw StateError('Poster integrity failure');
    }
    return bytes;
  }

  String _fingerprint(LibraryItem item) => jsonEncode([
    item.generation,
    item.name,
    item.mimeType,
    item.sourceUri,
    item.sourceRoot,
    item.modifiedMillis,
    item.metadata.toJson(),
    item.posterDigest,
    item.posterSize,
  ]);
  Future<void> _persist() async {
    final changed = <Map<String, Object?>>[];
    final fingerprints = <String, String>{};
    for (final item in _items.values) {
      final fingerprint = _fingerprint(item);
      fingerprints[item.id] = fingerprint;
      if (_persisted[item.id] != fingerprint) changed.add(item.toJson());
    }
    final deleted = _persisted.keys
        .where((id) => !_items.containsKey(id))
        .toList();
    final sources = _sources.toList();
    final path = _databasePath;
    await _updateInWorker(path, changed, deleted, sources);
    _persisted
      ..clear()
      ..addAll(fingerprints);
  }

  Future<void> _prunePosters() async {
    final posters = _items.values
        .map((item) => item.posterDigest)
        .whereType<String>()
        .toSet();
    for (final digest
        in _posterSizes.keys
            .where((digest) => !posters.contains(digest))
            .toList()) {
      final file = File('${root.path}/posters/$digest');
      if (await file.exists()) await file.delete();
      _posterByteTotal -= _posterSizes.remove(digest)!;
    }
  }

  /// Waits for queued writes and closes this index against subsequent work.
  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    await _tail;
    _items.clear();
    _sources.clear();
    _persisted.clear();
  }

  static String _mime(String name) =>
      switch (name.toLowerCase().split('.').last) {
        'mp4' || 'm4v' => 'video/mp4',
        'mkv' => 'video/x-matroska',
        'webm' => 'video/webm',
        'mp3' => 'audio/mpeg',
        'flac' => 'audio/flac',
        'wav' => 'audio/wav',
        'm4a' => 'audio/mp4',
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'webp' => 'image/webp',
        'gif' => 'image/gif',
        _ => 'application/octet-stream',
      };
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class _HashResult {
  new(this.id, this.size, this.chunks)
    : generation = manifestDigest(id, size, chunks);
  final String id;
  final int size;
  final List<String> chunks;
  final String generation;
}

Future<_HashResult> _copyAndHash(
  String source,
  String destination,
  int budget,
) async {
  final input = await File(source).open();
  final output = await File(destination).open(mode: FileMode.write);
  final hashes = <String>[];
  final sink = _DigestSink();
  final full = sha256.startChunkedConversion(sink);
  var size = 0;
  var complete = false;
  try {
    while (true) {
      final bytes = await _readBlock(input, mediaChunkBytes);
      if (bytes.isEmpty) break;
      if (hashes.length >= maxMediaChunks || hashes.length >= budget) {
        throw StateError('Media hash budget exceeded');
      }
      size += bytes.length;
      hashes.add(sha256.convert(bytes).toString());
      full.add(bytes);
      await output.writeFrom(bytes);
    }
    full.close();
    if (size == 0) throw ArgumentError('Empty media cannot be published');
    await output.flush();
    complete = true;
    return _HashResult(sink.value!.toString(), size, hashes);
  } finally {
    await input.close();
    await output.close();
    if (!complete && await File(destination).exists()) {
      await File(destination).delete();
    }
  }
}

Future<_HashResult> _hashReference(
  VaultSourceAccess access,
  SourceEntry entry,
  int budget,
) async {
  final hashes = <String>[];
  final sink = _DigestSink();
  final full = sha256.startChunkedConversion(sink);
  for (var position = 0; position < entry.size; position += mediaChunkBytes) {
    if (hashes.length >= maxMediaChunks || hashes.length >= budget) {
      throw StateError('Media hash budget exceeded');
    }
    final length = min(mediaChunkBytes, entry.size - position);
    final bytes = await access.readAt(entry.uri, position, length);
    if (bytes.length != length) {
      throw StateError('Source cannot provide seekable stable reads');
    }
    hashes.add(sha256.convert(bytes).toString());
    full.add(bytes);
  }
  final after = await access.stat(entry.uri);
  if (after.size != entry.size ||
      after.modifiedMillis != entry.modifiedMillis) {
    throw StateError('Source changed while indexing');
  }
  full.close();
  return _HashResult(sink.value!.toString(), entry.size, hashes);
}

Future<Uint8List> _readBlock(RandomAccessFile file, int length) async {
  final bytes = Uint8List(length);
  var offset = 0;
  while (offset < length) {
    final count = await file.readInto(bytes, offset, length);
    if (count == 0) break;
    offset += count;
  }
  return offset == length ? bytes : Uint8List.sublistView(bytes, 0, offset);
}

/// Copied/filesystem-only helper. URI sources must use VaultLibrary.readChunk.
Future<Uint8List> readLibraryChunk(LibraryItem item, int index) async {
  if (item.path.isEmpty) {
    throw StateError('Native URI requires injected source access');
  }
  if (index < 0 || index >= item.chunks.length) {
    throw RangeError.index(index, item.chunks);
  }
  final file = await File(item.path).open();
  try {
    await file.setPosition(index * mediaChunkBytes);
    final bytes = await _readBlock(
      file,
      min(mediaChunkBytes, item.size - index * mediaChunkBytes),
    );
    if (sha256.convert(bytes).toString() != item.chunks[index]) {
      throw StateError('Local media changed or corrupted');
    }
    return bytes;
  } finally {
    await file.close();
  }
}

void _validateMetadata(MediaMetadata value) {
  if ((value.width == null) != (value.height == null) ||
      (value.width != null &&
          (value.width! < 1 ||
              value.width! > 32768 ||
              value.height! < 1 ||
              value.height! > 32768)) ||
      (value.durationMillis != null &&
          (value.durationMillis! < 0 ||
              value.durationMillis! > 30 * 86400000)) ||
      (value.poster != null && value.poster!.length > mediaChunkBytes) ||
      (value.unavailableReason != null &&
          utf8.encode(value.unavailableReason!).length > 512)) {
    throw const FormatException(
      'Unbounded or invalid extracted media metadata',
    );
  }
}

// Keep isolate closures outside instance/adapter contexts so native callbacks,
// method channels and pending library futures can never be captured and sent.
Future<Object?> _decodeInWorker(String text) =>
    Isolate.run<Object?>(() => jsonDecode(text));
Future<List<String>> _sourcesInWorker(String path) =>
    Isolate.run(() => readIndexSources(path));
Future<List<Map<String, Object?>>> _pageInWorker(String path, int offset) =>
    Isolate.run(() => readIndexPage(path, offset));
Future<_HashResult> _copyInWorker(
  String source,
  String destination,
  int budget,
) => Isolate.run(() => _copyAndHash(source, destination, budget));
Future<_HashResult> _referenceInWorker(SourceEntry entry, int budget) =>
    Isolate.run(() => _hashReference(FileSourceAccess(), entry, budget));
Future<void> _updateInWorker(
  String path,
  List<Map<String, Object?>> changed,
  List<String> deleted,
  List<String> sources,
) => Isolate.run(() => updateIndex(path, changed, deleted, sources));
