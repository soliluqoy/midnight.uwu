# vault_media_index

Actual local media indexing for Windows filesystem folders, injected Android SAF trees, and optional durable copied imports. Content identifiers are full streaming SHA-256, not prefix fingerprints. Integrity manifests use 256 KiB chunk SHA-256 digests and a canonical generation digest.

## Consumption

Construct `VaultLibrary(Directory appSupport, sourceAccess: nativeAdapter, metadataExtractor: extractor)` and await `load()`. `addFile(File, {String? name})` makes an owned durable copy; it is not a retained-URI folder source. `addFolder(Directory)` indexes real local references without copying. `addSource(String rootUri)`, `refresh()` and `removeSource(String)` manage native URI roots. `sources`, `items`, `byId`, `page` and `length` expose actual indexed records. Close delivery before `library.close()`.

`VaultSourceAccess` implements `enumerate(rootUri) -> Stream<SourceEntry>`, `stat(uri) -> Future<SourceStat>` and `readAt(uri, offset, length) -> Future<Uint8List>`. `SourceEntry` has URI, name, size and modifiedMillis. The app must obtain and persist SAF tree permissions and perform native random-access reads. `content://` is never converted to a filesystem path: `LibraryItem.path` is empty for native URIs. Native permission loss and nonseekable/short reads throw explicitly. `readChunk(item, index)` checks source size/mtime and the actual chunk digest; refresh reconciles additions, renames, changes and deletions. Removing a reference never deletes source media. Identical content is deduplicated by full hash.

SQLite3 **3.7.1** uses native assets on Windows/Android, WAL and FULL synchronous commits. SQL reads page the index (128 records during load, <=16 for browsing), and background-isolate transactions upsert only changed records and delete removed IDs. The initial transient JSON index migrates once and is removed after commit. No JSON file remains the persistence authority. Local file hashing/copying runs off the UI isolate; native-source work processes one bounded chunk between asynchronous native reads. No whole-media allocation occurs.

## Metadata and posters

Inject `MediaMetadataExtractor = Future<MediaMetadata> Function(SourceEntry)`. Actual decoder results include optional width/height/durationMillis and encoded JPEG/PNG poster bytes. Unsupported providers/codecs return `unavailableReason`; no dimensions/posters are invented. The app supplies actual native/decoder extraction. Results are validated before persistence: both media dimensions 1–32768, duration <=30 days, poster <=256 KiB, reason <=512 UTF-8 bytes. Encoded PNG IHDR/JPEG frame dimensions must additionally be <=512px on both axes before any UI decode.

SQLite retains decoder metadata and poster digests/sizes; encoded poster files are separately content-addressed. `LibraryItem.metadata` omits resident poster bytes, and `posterPath`/`readPoster` expose only real artifacts; `readPoster` rechecks its SHA-256. Poster storage is capped at 128 MiB and 20,000 artifacts, with orphan pruning. A budget exhaustion is explicit metadata unavailability, not a fake preview. Delivery separately authorizes every remote thumbnail operation.

## Bounds and verification

Library: 20,000 entries, 128 roots, 65,536 chunks per item (16 GiB), 131,072 aggregate chunk digests, SQLite main-file page limit 64 MiB. Limit violations fail explicitly. Referenced-source snapshots remain unchanged when enumeration, hashing or permission access fails. Metadata comes from explicit imports/source refresh, not fabricated discovery.

Behavioral tests cover full/chunk hashes, durable import reload, referenced-folder rename/delete, URI permission errors, bounded reads and extracted artifact persistence/corruption. Tests and native physical indexing/playback checks are run by integration after package convergence; no physical performance claim is made here.
