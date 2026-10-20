import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

Database _open(String path) {
  final db = sqlite3.open(path)
    ..execute('PRAGMA journal_mode=WAL')
    ..execute('PRAGMA synchronous=FULL')
    ..execute('PRAGMA max_page_count=16384')
    ..execute(
      'CREATE TABLE IF NOT EXISTS media '
      '(id TEXT PRIMARY KEY, name TEXT NOT NULL, body TEXT NOT NULL) STRICT',
    )
    ..execute('CREATE INDEX IF NOT EXISTS media_name ON media(name,id)')
    ..execute(
      'CREATE TABLE IF NOT EXISTS sources (uri TEXT PRIMARY KEY) STRICT',
    );
  return db;
}

/// No native handle escapes these bounded operations, so library shutdown or
/// app-directory cleanup never races a forgotten long-lived SQLite handle.
List<Map<String, Object?>> readIndexPage(String path, int offset) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    return db
        .select('SELECT body FROM media ORDER BY id LIMIT 128 OFFSET ?', [
          offset,
        ])
        .map((row) => jsonDecode(row['body'] as String) as Map<String, Object?>)
        .toList();
  } finally {
    db.close();
  }
}

/// Opens the schema and returns the bounded registered source roots.
List<String> readIndexSources(String path) {
  final db = _open(path);
  try {
    return db
        .select('SELECT uri FROM sources ORDER BY uri')
        .map((row) => row['uri'] as String)
        .toList();
  } finally {
    db.close();
  }
}

/// Returns one bounded name-ordered identifier page without reading media.
List<String> readIndexIds(String path, int offset, int limit) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    return db
        .select('SELECT id FROM media ORDER BY name,id LIMIT ? OFFSET ?', [
          limit,
          offset,
        ])
        .map((row) => row['id'] as String)
        .toList();
  } finally {
    db.close();
  }
}

/// Atomically updates changed records, removed identifiers and source roots.
void updateIndex(
  String path,
  List<Map<String, Object?>> changed,
  List<String> deleted,
  List<String> sources,
) {
  final db = _open(path)..execute('BEGIN IMMEDIATE');
  try {
    final upsert = db.prepare(
      'INSERT INTO media(id,name,body) VALUES (?,?,?) '
      'ON CONFLICT(id) DO UPDATE SET name=excluded.name,body=excluded.body',
    );
    final remove = db.prepare('DELETE FROM media WHERE id=?');
    final source = db.prepare('INSERT INTO sources(uri) VALUES (?)');
    try {
      for (final row in changed) {
        upsert.execute([row['id'], row['name'], jsonEncode(row)]);
      }
      for (final id in deleted) {
        remove.execute([id]);
      }
      db.execute('DELETE FROM sources');
      for (final uri in sources) {
        source.execute([uri]);
      }
    } finally {
      upsert.close();
      remove.close();
      source.close();
    }
    db.execute('COMMIT');
  } on Object catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    db.close();
  }
}
