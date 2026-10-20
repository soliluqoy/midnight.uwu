# vault_delivery

Actual authenticated peer media browsing, protected manifests/posters/chunks, verified sparse disk caching, resumable downloads and loopback HTTP Range playback. Media traffic uses authenticated `vault_net` sessions, never signaling or public discovery.

## Consumption

Construct `VaultDelivery(library:, authorization:, cacheDirectory:)` and await `load()` so storage errors are surfaced before opening UI. Attach each `PeerSession` immediately with `attach(session)`, before requests arrive. Subscribe to `accessRequests` and `errors`. Owner publication is **off by default**; `setPublishing(true)` is explicit opt-in. A viewer calls `requestAccess(session)`; the owner must explicitly `approve(request)` or `deny(request)`.

For a pending-consent queue, subscribe to `accessRequestChanges` before attaching
sessions. It emits immutable queue snapshots after arrivals and every actual end:
two-minute expiry, approval/denial, viewer cancellation, connection interruption,
publication stop and shutdown. `accessRequests` remains incoming-only and is useful
for awaiting a new request, not maintaining a pending queue. Cancel subscriptions
on consumer disposal; delivery shutdown clears remaining requests and closes both
streams. Expiry does not disconnect the peer or change the 24-hour approval scope.

The native messenger attaches with
`attach(session, onMessengerControl: messenger.receiveControl)`. Delivery remains
the single packet-stream consumer and routes only `vault=messenger` control frames
to that callback; media frames retain the existing approval checks. The app
attaches messenger lifecycle first. Text uses contact/session trust, not a media
grant, and never travels through media bulk or signaling.


Approval durably persists a viewer-bound `library/all` grant for exact actions `browse`, `play` and `download` before the token is transmitted. `browse(session)` returns real `RemoteMedia` (id/name/size/mimeType/generation/chunkCount, actual optional dimensions/duration/poster digest). `poster(session,item)` returns only a verified bounded real thumbnail, or null when absent. `play(session,item)` returns a secret loopback URL for the actual media_kit backend. `download(session,item,{DeliveryCancellation? cancellation,onProgress})` returns a verified completed file. Call `cancellation.cancel()` to stop; a later call resumes the disk prefix. `close()` cancels work, closes playback listeners/peer sessions and waits for active download cleanup.

When a viewer closes or changes media, call `stopPlayback(session, uri)` after
disposing its native player. It releases only the matching loopback URL. Repeated
or late cleanup cannot close a newer listener or invalidate a pending replacement;
the peer connection and grants stay intact.

`negotiating` and `authenticating` pause delivery without detaching the peer or
changing remembered approval. On either transition, outstanding requests fail
with `DeliveryCancelled`, pending consent requests expire locally, owner reads
are cancelled, and existing/in-progress loopback playback is invalidated and
closed. Request and owner-read slots are released without waiting for a stalled
native send; late completions cannot satisfy a replacement request. After
`connected`, call `play(session,item)` again for a fresh authenticated manifest
and a new URL; each range still checks current permission before cached bytes.
Replacement playback joins prior listener teardown. Recovery never requests or
mints another grant. `closed` and `failed` detach permanently, so neither a stale
connected event nor an old playback URL can resume delivery.

`revoke(peerId)` persists all existing viewer-token revocations before cancelling that peer's owner reads and closing its sessions. Unrelated viewers are unaffected. `setPublishing(false)` blocks new protected reads immediately and cancels serving before returning. Delivery-only sessions close; sessions explicitly attached with a messenger callback remain connected for chat, without retaining media-serving permission. Neither stop path silently revokes remembered approvals. Publication must be explicitly enabled after restart. Viewer-bound tokens are persisted separately as public authenticated capabilities, never the owner's minting key; valid approvals survive normal restart, and persisted revocations reject restart/reconnect tokens. Owner mint material stays in the protected `AuthorizationRepository` store.

## Integrity, bounds and confidentiality

Every index page, manifest page, thumbnail, permission check and content fragment checks the authenticated session viewer plus exact owner grant scope/actions, expiry, epoch and revocation. Unknown generations/removed items are denied. Every fragment rechecks authorization and cancellation. No private filenames, manifests or bytes precede approval. Manifest pages collect at most 64 digests; the final canonical SHA-256 manifest digest must match the authenticated index root. SHA-256 chunk validation rejects corruption before bytes enter cache/playback, and completed downloads also verify full-content SHA-256.

Wire requests use random 128-bit request IDs, peer/session association and content generation. Bulk fragments have a 40-byte request/offset/total header with <=12 KiB payload; messages fit the networking 16 KiB budget. Assembly is strictly contiguous, length-limited to one 256 KiB chunk and SHA-256 checked; unknown/stale fragments never allocate an assembly. Four in-flight requests/owner reads, 16 sessions, 32 expiring pending approvals, and one active download are admitted. Approvals and cancellable work clean up timers/subscriptions.

Authenticated owners are still untrusted image inputs: `poster()` validates actual JPEG/PNG encoded dimensions (<=512px each axis), compressed length and digest before returning bytes, including cached posters.

Browse pages contain <=8 items, manifests <=64 hashes, individual posters <=256 KiB. The sparse cache defaults to **256 MiB / 1024 chunk files**, prunes before admitting writes and on restart, and rehashes cached bytes on every read. Cache keys cannot escape its directory. Range serving caps concurrent requests/responses, fetches only chunks needed for the requested interval and cancels on client abort/teardown. Serialized playback replacement and lifecycle invalidation close superseded/in-progress listeners, including detach/close races.

Downloads are separate explicit saved artifacts, not evictable playback cache. The configurable `maxDownloadBytes` defaults to **8 GiB aggregate saved/staging files**. The service refuses quota overflow instead of deleting saved files. It flushes each complete verified chunk; restart resume rehashes every existing prefix chunk against a newly authenticated manifest, truncates corrupt/partial tails and asks the owner again before completion. Cancellation of final full-file hashing is honored between streaming buffers.

Request timeouts report received/expected byte counts and elapsed time, without disclosing media identifiers or increasing the request deadline.

Revocation cannot recall bytes a viewer has already saved or copied. This app nevertheless requests a fresh owner permission check before using cached chunks/posters; it does not silently provide offline protected playback after revocation.

## Verification

Focused behavioral/security tests cover publication/approval, real disk transfer hashing, cold tail Range access, restart token rejection after revoke, cancellation/resume, corruption, viewer-token theft, bounded cache, playback replacement teardown, transient recovery with saturated request/owner-read slots and late sends, cached playback reauthorization after recovery, terminal disconnect and unrelated-viewer isolation. These transport-unit tests use an explicit in-memory peer fixture; they do not claim native WebRTC/decoder proof. Integration must additionally exercise two real authenticated native peer sessions, actual media_kit playback/audio, seek/cancel and physical Android SAF permissions. Phase 0 physical gates remain separate.

Pending-consent regressions drive the real two-minute timer with a deterministic
clock and verify that expiry neither approves nor disconnects its peer. Separate
cases cover approval, denial, cancellation, interruption, disconnect, publication
stop and shutdown. Snapshots remain immutable; the application runtime test
checks that its displayed pending queue also loses expired requests. Fake-clock
listeners detach before real storage/native teardown.
