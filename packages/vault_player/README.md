# vault_player

Real native playback through `media_kit` 1.2.6, plus an independent pure-Dart
verified-chunk HTTP adapter. No simulated playback backend, synthetic media cache,
whole-file read, or zero-filled sparse-file fallback is used.

## Native playback

`VaultPlayer()` initializes media_kit and owns a real `Player`, exposed by
`player` for the application's `media_kit_video` video widget. `open(Uri)` opens
and starts media; `close()` disposes native resources idempotently and permanently.
Backend initialization, opening and disposal failures propagate to the caller.
The application must package `media_kit_libs_video` 1.0.7 and use
`media_kit_video` 2.0.1; this package does not replace native audio/video setup.

## Verified remote ranges

Delivery code imports `package:vault_player/range_server.dart` directly. That
library uses only Dart SDK libraries and does not import media_kit or Flutter.
`vault_player.dart` also exports it for application convenience.

Create `VaultRangeServer(contentId: ..., length: ..., mimeType: ...,
fetchChunk: (index, cancellation) async => ..., chunkBytes: 262144)` and await
`start()` for the playback URI. Each server binds only `127.0.0.1` on an ephemeral
port, with a fresh cryptographically random 256-bit URL capability. Treat the URI
as a secret; no public discovery, external listener or CORS permission is added.
The adapter does not authenticate peers: delivery must check authorization and
verify the requested chunk's digest before returning its exact bytes. It checks
chunk length, including the shorter final chunk. It retains no chunk cache.

- At most four requests are active; additional requests receive an empty 503.
- Each GET returns at most 1 MiB, fetching only intersecting chunks sequentially
  with response backpressure. The default chunk size is 256 KiB; explicit chunk
  sizes must be positive and at most 1 MiB.
- Explicit, open-ended and suffix single byte ranges receive 206 with an accurate
  `Content-Range`. Invalid, multipart and unsatisfiable ranges receive empty 416
  with `bytes */length`. A GET without Range also receives a bounded 206 when
  the whole entity exceeds 1 MiB; the player must request subsequent ranges.
- HEAD reports metadata without fetching bytes (an un-ranged HEAD describes the
  whole entity). Empty content has a zero-length 200 and no satisfiable ranges.
- Wrong capability/resource/query receives an empty 404. Unsupported methods get
  405. Errors contain no internal exception or content information; an invalid
  chunk before body transmission gets empty 502, while a failure after body
  transmission closes a truncated response rather than fabricating bytes.
- Fetch and flush waits are cancelled after 30 seconds. `close()` cancels active
  reads and forcibly closes connections, including during startup. A server
  cannot be restarted after close.

`RangeCancellation` exposes `cancel()`, `check()`, `isCancelled` and `cancelled`.
Each response owns its cancellation token; response completion, errors, deadlines
and server shutdown cancel it. Fetchers must observe it to release their own
network/cache resources. Server shutdown does not wait for an uncooperative
fetcher. Dart's `HttpServer` cannot always detect a player abort until the
response closes: cancellation can therefore be delayed by one bounded response,
not an unbounded whole-file transfer. A new seek has no stale server cache or
prefetch queue to drain.

## Verification status

`test/range_server_test.dart` contains actual loopback `HttpClient` behavior tests
for cold seek chunk selection and bytes, HEAD, suffix/open ranges, response caps,
capability isolation, 416 handling, method restrictions, empty resources, invalid
chunks, four-request admission, shutdown, client abort and cancellation. The
package uses the workspace Flutter SDK `flutter_test` runner because media_kit's
package graph is Flutter-dependent; the range library itself is pure Dart.

These tests were added but not executed during implementation. Native backend
physical playback/audio smoke on Windows and Android remains pending, including
front/tail-moov MP4s and cold seeking with real peer delivery. Neither source code
nor deterministic loopback tests constitute that physical evidence; Phase 0
remains open.
