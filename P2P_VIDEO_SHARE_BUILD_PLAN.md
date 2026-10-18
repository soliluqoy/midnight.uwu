# BUILD PROMPT — "Vault": a serverless, autonomous P2P video/photo sharing app (Android + Windows)

> Paste everything below this line into your coding AI as the single instruction set.

---

## 0. ROLE & OBJECTIVE

You are the lead architect + senior engineer for a new cross-platform application. You will design and build, iteratively, a **video and photo sharing app that runs on Android and Windows with ZERO servers that we operate**.

The product, working name **"Vault"**:

- Each user runs the app on their own device.
- The app exposes a **local media folder** (photos + videos only). Users drop files into it using the OS file manager, exactly like a normal folder.
- The user can **publish** that folder (share the "connection") and **control who is allowed** to view it.
- Any other user can **search/discover** publishers and browse what they offer.
- Any allowed viewer can **stream** the media **on demand, at any time** (VOD-style, with seek), and optionally watch a **live** version of it.
- The system is **peer-to-peer AND multi-peer** (one owner → many viewers; viewers can also connect among themselves), fully **autonomous** (no accounts, no cloud, no admin, no telemetry, no telemetry endpoint, no licensing server), and **simple** for the end user.

**Assume modern broadband for everyone.** Do not design for 3G. Do not add a CDN, a backend, an account system, a database server, or a push-notification service. Anything that behaves like a server is only allowed if it is (a) a **public third-party relay we do not own** (Nostr relay, MQTT broker, STUN server), or (b) an **optional, user-supplied** setting.

---

## 1. HARD CONSTRAINTS (non-negotiable)

1. **No backend we write, host, or pay for.** No cloud functions, no S3/GCS, no Firebase, no managed DB, no auth provider, no crash reporting service, no remote config.
2. **All media bytes flow directly peer-to-peer** over WebRTC (DTLS-SRTP for media, DTLS for data channels). Never through a third party.
3. **No account.** Identity = a locally generated cryptographic keypair. It never leaves the device unencrypted-as-secret; the public key is the public identity.
4. **Offline-tolerant, restart-tolerant, network-flap-tolerant.** The app must survive process death, sleep, and network loss without corrupting state or leaking connections.
5. **Consistent user experience on both Android and Windows.** One visual language, one navigation model, one feature set — no "the Windows version can't do that."
6. **Consent is owner-enforced.** Access is a capability, not a UI state. A viewer who is not granted cannot even open the byte stream.
7. **Consent is also viewer-enforced.** A viewer can see (and revoke) who is connected to their device, kill any session instantly, and the owner never gets silent background access.

---

## 2. TECHNOLOGY DECISIONS (researched — commit to these, but still validate in Spike 0)

### 2.1 Cross-platform app shell → **Flutter + Dart** (one codebase, Android + Windows)
- `flutter_webrtc` (currently `1.6.2+hotfix.x`, bundling **libwebrtc m150 / branch-150.7871.01**) is the only mature engine that gives **Android + Windows** from one codebase with: Unified Plan, DataChannel, **Simulcast**, screen capture, and hardware codecs on both platforms.
- Known gaps to design around (documented in the plugin's own issue tracker, pin versions accordingly):
  - Desktop `RTCRtpSender.setParameters()` **ignores encoding changes** (issue #2216) → we must recreate the sender/transceiver to change resolution/bitrate.
  - Desktop `onBufferedAmountLow` **never fires** (issue #2210) → we must **poll `bufferedAmount`** as the backpressure signal (treat the event as an optimization only).
  - Desktop `addTrack` runs on a detached thread and can race `createOffer` (issue #2216/2218) → serialize negotiation behind a single mutex/queue.
  - H.265/HEVC exists (since 1.1.0) but HW support is device-dependent; do not put it on the critical path.
  - Audio playback on Windows desktop has had regressions → verify in Spike 0 and keep an audio path per platform if needed.
- **Rejected alternatives (state why in the ADR):**
  - *Kotlin Multiplatform + Compose Multiplatform*: better desktop UX/native feel, but you would write and maintain **two** WebRTC integrations (Android `org.webrtc` + Windows/Media Foundation). Weeks of native work, permanent double maintenance.
  - *Electron + Trystero on Windows, Capacitor + custom bridge on Android*: fastest Web prototype (Trystero gives you free serverless discovery in JS), but two native bridges and JS↔native frame marshalling for every chunk. Acceptable **only** as a throwaway prototype for validating the discovery protocol.
  - *Tauri v2*: same two-bridge problem, smaller ecosystem for this.
  - *Pure libp2p/pion*: excellent, Go-native, but gives you no app UI on Windows and no Android story without a UI framework anyway.

### 2.2 P2P transport → **WebRTC** (never raw TCP/UDP sockets)
- Media: `RTCPeerConnection` tracks. Control/data: `RTCDataChannel`s.
- Always `RTCConfiguration`:
  - `iceServers`: public STUN only — `stun:stun.l.google.com:19302`, `stun:stun.cloudflare.com:3478`, `stun:stun.nextcloud.com:443`, plus any user-added STUN. **No bundled TURN.**
  - `sdpSemantics: Unified Plan`, `bundlePolicy: maxBundle`, `rtcpMuxPolicy: require`.
  - Enable **mDNS obfuscated host candidates** (default in libwebrtc) so LAN peers connect without leaking local IPs to the relay.
  - `iceTransportPolicy: all`; for known-LAN peers consider `iceTransportPolicy: relay`-free fast path via cached local candidates.
- ICE candidate pair selection: prefer `host` (LAN) → `srflx` → user-supplied TURN. Show the user *why* a connection failed ("your network likely uses symmetric NAT — add a TURN server in Settings → Advanced" — with the field left empty by default).

### 2.3 Discovery + signaling (the only place a third party is touched) → **pluggable `SignalingStrategy` interface**, MQTT first
Define one interface in Dart and implement 3 strategies behind it:

```dart
abstract class SignalingStrategy {
  Stream<SignalMessage> get inbound;
  Future<void> publish(SignalMessage m);
  Future<void> subscribe(Set<Topic> topics);
  Stream<bool> get connected;           // relay connectivity
  int get redundancy;                    // how many endpoints held simultaneously
}
```
Implementations:
1. **`MqttSignaling`** (default): public MQTT-over-TLS brokers with anonymous `connect`/anonymous-will. WSS endpoints to hardcode: `wss://broker.emqx.io:8084/mqtt`, `wss://test.mosquitto.org:8081/mqtt`, `wss://mqtt.eclipseprojects.io:443/mqtt`. Hold **2–3 concurrently**, fail over transparently, reconnect with exponential backoff + jitter (1s→60s cap). MQTT 5 QoS 0 for candidate trickling, QoS 1 for offers/answers/grants.
2. **`NostrSignaling`** (fallback): ephemeral kinds for SDP offers/answers/candidates, signed with the device identity key, published to 3–5 public relays; ignore retained messages; use `NIP-44`-style encryption for offer/answer payloads.
3. **`ManualSignaling`** (the "truly no infrastructure" escape hatch): the app renders a compressed offer blob as **QR + 12-word/short-code + a short text blob**; the other side scans/pastes it; answers flow back the same way. Used for air-gapped/firewalled cases and as the test oracle for the other two.

Rules for all strategies:
- Signaling payloads only. **Media and file bytes must never touch a relay.** Enforce this in code and in a unit test (a relay byte-budget assertion on the signaling client wrapper).
- Topic scheme is namespaced and versioned: `vault/v1/<scope>/<peerId>/offer|answer|candidate|announce|grant|revoke|query`.
- Every message is **signed with the device Ed25519 key** and carries `appVersion`, `protocolVersion`, `nonce`, `ts`, `expiresAt`. Reject unsigned/expired/future-dated messages. This replaces "accounts" with cryptographic identity.

### 2.4 Directory / search → **serverless presence directory over the same signaling transports**
No central index is possible, so we build a *federated, expiring, gossiped* directory on top of pub/sub:

- **Announce**: every publishing node publishes `announce` to `vault/v1/presence/<shard>/<nodeId>` every **30s** (QoS 0, never retained), heartbeat with `ttl = 90s`. Peers cache announcements in local SQLite with a hard expiry sweep every 15s.
- **Shard function**: `shard = first 2 chars of blake3(nodeId + epoch)` → 256 shards; each node subscribes to the shard of the query it is running **plus a rotating 1/8 sample of all shards** for background gossip/backfill. This bounds relay load while keeping discovery fast (~1 shard scan per query, ~30k announcements max in cache per shard in the worst case).
- **Query**: a `query` message is published to `vault/v1/query` with a bloom-filter of wanted terms (display name / tags). Nodes that hold matches reply **directly** with `announce`-style records to the querier (unicast over relay topic or, better, over an already-connected DataChannel).
- **Gossip fan-out**: every connected peer exchanges its 200 freshest announcements with each of up to 5 peers every 60s. This makes the directory self-healing and multi-hop with no index operator.
- **Result quality**: rank by (a) reciprocal path quality measured from `getStats()` on existing connections, (b) announced `uplinkMbps` and media count, (c) recent successful connect rate (locally observed). Never trust an announced bandwidth value for anything other than ranking — verify with real connection stats before streaming.
- **Cold-start problem**: a brand-new node has zero peers and thus hears nothing. Solve by (a) always connecting to a small set of **public "gateway" topics** whose messages are re-broadcast by any node that receives them (a 2-hop epidemic from any seed), and (b) seeding with a handful of well-known public Nostr relay/MQTT "beacon" topics. Document the residual limitation honestly in-app.

### 2.5 Access control (owner lets them in) → **capability tokens over DataChannel + in-band ACL
- Owner maintains an ACL in a signed document: `{ nodeId, displayName, role: viewer|approved|blocked, expiresAt, lastSeenIpHint }`, stored locally, versioned, and pushed to approved viewers on connect.
- A viewer seeking access: connects (DataChannel only, **no media tracks offered**), sends `request { profileMessage, nodeVersion }`. Owner sees an in-app prompt with a 60s countdown and can Approve / Deny / Always-allow-this-node.
- Approval issues a **capability token**: `HMAC-SHA256(streamSecret, nodeId || mediaId || level || issuedAt || expiresAt)` where `streamSecret` is a per-installation 32-byte random, exchanged inside the DTLS-encrypted channel. The viewer cannot stream without a valid token, and cannot reuse a token for another media id/level/expiry.
- Every token use is logged locally with a visible "Connected now" row; owner can revoke → all affected PeerConnections are closed within 1s.
- Blocking = refusing the DataChannel handshake + short-lived tombstone so a blocked node is not re-prompted.

### 2.6 Media delivery → **two engines, one interface**
```dart
abstract class MediaSource {                       // implemented twice
  Stream<Uint8List> read(int byteOffset, int length);
  int get length;
  Future<void> close();
}
```
- **Engine A — `ChunkedFileSource` (default, on-demand VOD).**
  Serves byte ranges over a reliable ordered DataChannel. **Zero transcode, zero CPU, plays at native source quality, seek is instant.**
- **Engine B — `LiveTranscodeSource` (optional, "watch together").**
  Decodes the file locally and re-publishes it as a live WebRTC track with simulcast.
- The player picks Engine A always; Engine B is offered as a toggle ("Watch Live") that shows latency and bitrate.

---

## 3. EFFICIENCY: BITRATE, CODEC, AND TRANSPORT BUDGETS (use these numbers, don't invent new ones)

### 3.1 Codec policy
- **H.264 (Constrained Baseline → Constrained High)** everywhere, via **hardware encode** (Android `MediaCodec`; Windows Media Foundation H.264 MFT). Rationale: lowest CPU/battery, works on every Android device, and interops with anything WebRTC-shaped later.
- **VP9** as the software fallback when HW H.264 encode is unavailable (plugin forces SW codec lists; Android HW VP9 is disabled by default upstream — that's fine).
- **Audio: Opus**, 48 kHz. VOD/streams: stereo 96 kbps CBR, mono 32 kbps for talk-style. Enable DTX for live talk, disable for file fidelity.
- Never transcode per viewer. One decode + one set of encoded frames, N senders.

### 3.2 Video ladder (H.264, 30 fps, CBR, keyframe every 2 s)
| Layer | rid | Resolution | maxBitrate | fps | scaleResolutionDownBy |
|---|---|---|---|---|---|
| low | `l` | 426×240 | 300 kbps | 15 | 4 |
| mid | `m` | 640×360 | 800 kbps | 30 | 2 |
| high | `h` | 1280×720 | 2_500 kbps | 30 | 1 |
| (opt) ultra | `u` | 1920×1080 | 4_500 kbps | 30 | 1 |

Wire overhead: RTP+UDP+SRTP+DTLS+IP ≈ **+12%** over the codec bitrate. Add **+5%** for retransmissions/ICE keepalives on the data channel side. So a 720p30 layer costs ≈ **2.9 Mbps on the wire**, realistically budget **3.0 Mbps**.

Per-viewer budget = `videoBitrate × 1.17 + audioBitrate × 1.17`.

### 3.3 Host uplink governor (the multi-peer core problem)
- On session start, measure uplink with a short **STUN-less bandwidth probe** (send 3 × 2 MB over the DataChannel, take the best RTT of 5) → `measuredUplinkMbps`.
- **Default cap = 70 % of measured uplink**, user-overridable (`auto / 1 / 2 / 5 / 10 / 25 Mbps / unlimited`).
- `maxViewers = floor(cap / perViewerCost)` for the current top layer. Hard cap **6 concurrent senders** in v1 (uplink + CPU + desktop decode threads).
- When viewer count exceeds capacity, do NOT degrade everyone: **first** push new viewers to `mid` or `low`, **then** demote the viewers with the worst measured RTT/jitter to a lower layer, **never** below `low`, **then** queue with a visible position and auto-connect when a slot frees.
- The whole rule lives in one pure, unit-tested Dart module: `UplinkGovernor.decide({cap, viewers, stats}) -> Map<peerId, Layer>`.

### 3.4 Adaptation settings (baked in from the start)
- Congestion control: **GCC / transport-wide CC** with `googTransportCc` interceptor. Polling `getStats()` **once per second**, exposed in a debug overlay (up/down, loss, RTT, jitter, NACK, PLI, actual vs target bitrate, freeze count).
- `degradationPreference`: **`maintainResolution`** for file content (drop fps before resolution), `maintainFramerate` for screen/live.
- **Send-side BWE cap**: `RTCRtpEncoding.maxBitrate` set from the governor; also set `maxFramerate`.
- **Keyframe policy**: IDR every 2 s; on VOD seek/chunk boundary, send **one** PLI request, throttled to 1 per 500 ms, and cap at 3 retries then fall back to Engine A (chunked) instead of stalling. Never request PLI faster than that — it makes the encoder collapse.
- **DataChannel tuning**: 16 KiB messages, sender window maintained by polling `bufferedAmount` (≤ 512 KiB high-water, resume ≤ 256 KiB), poll every 50 ms. Prefer **one** reliable ordered channel for file bytes + one unordered `maxRetransmits: 0` channel for stats/control so a stalled file transfer can never block keepalives. Use a second unordered channel for discovery gossip.
- **MTU**: rely on libwebrtc path MTU 1200 for mobile friendliness.

### 3.5 DataChannel throughput expectations (for UI copy and capacity math)
| Link | Single DC (SCTP) expected |
|---|---|
| Same Wi‑Fi LAN | 20–40 MB/s |
| 100 Mbps broadband | 6–11 MB/s |
| 4G/LTE | 1–4 MB/s |
| 2 GB RAM Android, mid device | 1.5–3 MB/s (CPU/GC bound) |
SCTP single association is the ceiling — do not shard into many channels for speed; measure, then shard **only** if a benchmark shows > 20 % headroom (target: keep 3 channels total).

### 3.6 Storage / indexing efficiency
- Index = SQLite (`drift`) per device: path, size, mtime, content hash, duration, width/height/fps/codec (parsed from container header only — never decode to find out), poster thumbnail.
- Hash = **BLAKE3** over first 1 MiB (fast id) + full hash computed lazily in the background. `mtime+size` short-circuits re-hash.
- Thumbnails: extract one 320 px JPEG (q≈70, ≈12–18 KB) at **22 % of duration** using platform thumbnails (MediaMetadataRetriever on Android, Media Foundation thumbnailer on Windows) **in a background isolate/thread pool**, concurrency 2, never on the UI isolate. Windows uses `ShellItemThumbnail` when available (fast, cached by Explorer).
- Folder watcher: Windows `ReadDirectoryChangesW` (via a small FFI package) + 5 s reconcile poll; Android SAF tree URI + **15 s reconcile poll** (no reliable change events) + MediaStore for newly added camera output. Debounce 500 ms.

### 3.7 Energy / background rules
- Windows: tray app, `QPC`/idle-aware, pause thumbnail work when unfocused, optional "Start with Windows".
- Android: **foreground service** with a persistent notification while publishing or while a viewer is streaming to this device; `WAKE_LOCK` only during active sessions; work must survive Doze → schedule index refresh via `WorkManager` with a 15-min periodic job and wake on SAF change hints.
- Screen-on-while-streaming is opt-in per session.

---

## 4. REPOSITORY & ARCHITECTURE

Monorepo, one Flutter app + pure-Dart libraries (so the protocol is unit-testable without a device):

```
apps/vault/                     Flutter app (android/, windows/, lib/)
packages/
  vault_identity/               Ed25519/X25519 keys, QR identity, safety-number verification
  vault_protocol/               wire format, message schemas (versioned), signing, HMAC tokens, codec
  vault_signaling/              SignalingStrategy + Mqtt / Nostr / Manual implementations
  vault_net/                    PeerMesh: PeerConnection lifecycle, negotiation queue, retry, stats
  vault_directory/              announce/query/gossip, SQLite presence cache, ranking
  vault_media_index/            scanner, watchers, BLAKE3, metadata parse, thumbnails
  vault_delivery/               ChunkedFileSource, LiveTranscodeSource, UplinkGovernor, chunk protocol
  vault_player/                 Flutter media player (Windows: Media Foundation/`video_player`; Android: ExoPlayer)
  vault_ui/                     design system, screens, settings, debug overlay
tools/
  interop_harness/              pion/webrtc + vnet + bwe-test based automated connection tests
docs/adr/                       every decision above, written down
```

Layering rule: `ui → (directory, delivery, player) → (net, signaling, media_index) → (protocol, identity)`. `vault_protocol` and `vault_identity` must have **zero** Flutter imports.

State management: **Riverpod** (code-gen), `go_router` for navigation. No global mutable singletons outside a DI container; every service is constructible in tests.

Concurrency: strict actor-ish model — **one `PeerMesh` isolate-free but single-threaded event queue** per connection for negotiation (fixes the detached-thread race), plus **separate isolates** for file reads/chunking, hashing, and thumbnailing. Never read files on the UI isolate.

---

## 5. PROTOCOL SPECIFICATION (write this down, then implement exactly)

All messages: CBOR or MessagePack (not JSON — smaller on the wire), with a 1-byte version, 2-byte type, 32-byte Ed25519 signature over the canonical payload. Reject anything unknown, unsigned, or with `ts` outside ±120 s.

### 5.1 Signaling-plane messages (through relay)
- `HELLO { protocolVersion, appVersion, nodeId, displayName, ports, capabilities, uplinkHint }`
- `OFFER / ANSWER { sdp, sdpType }` (trickle candidates follow as `CANDIDATE`)
- `CANDIDATE { candidate, mid, sdpMLineIndex }`
- `ANNOUNCE { ttl, shard, mediaIndexSummary, aclVersion, displayName, tags[], endpointHints[] }`
- `QUERY { termsBloom, shardSet, nonce }`
- `GRANT / REVOKE { mediaId?, token?, reason }`
- `BYE { reason }`

### 5.2 Data-plane messages (inside DTLS, never on relay)
- `DC_HELLO { nodeId, appVersion, token? }`
- `REQUEST_ACCESS { message, avatarHash }` → `ACCESS_RESULT { allowed, token, expiresAt, streamSecret, acl }`
- `INDEX_REQUEST { cursor, filter, pageSize }` → `INDEX_PAGE { items[], cursor, total }`
  (Browsing a library must **page** — never dump a 50 000-item manifest.)
- `MANIFEST_REQUEST { mediaId }` → `MANIFEST { id, title, container, durationMs, size, width, height, fps, videoCodec, audioCodec, posterBlob, chunkSize, chunkCount }`
- `RANGE_REQUEST { mediaId, offset, length, chunkIndex }` → `RANGE_CHUNK { mediaId, chunkIndex, bytes, isLast }`
- `RESUME { mediaId, haveChunk }`
- `PLAY_LIVE { mediaId, layerHint }` → `LIVE_READY { layer, actualBitrate }`
- `STATS_PUSH { fps, kbps, loss, rttMs, droppedFrames }` (unordered channel)
- `GOSSIP { announcements[<=32] }`
- `BYE { reason }`

### 5.3 Chunk protocol
- Chunk size **256 KiB**. Sender coalesces file reads with a 512 KiB read-ahead buffer per active session.
- Sender must support **concurrent requests from the same viewer** (prefetch of the next 2 chunks) to hide RTT over WAN.
- Each chunk carries `chunkIndex`; receiver verifies `BLAKE3` of the chunk (truncated to 16 bytes is enough) and requests a resend on mismatch; hard-fail after 2 retries and tell the player to re-request the manifest.
- Receiver writes to a temp file in its cache dir and plays progressively (local HTTP range feed or a progressive demuxer feeding the platform player). Cache eviction by LRU with a user-set budget (default 2 GB desktop / 512 MB mobile).
- Full-file "Download" mode reuses the exact same range protocol with a progress UI and no player.

---

## 6. FUNCTIONAL SCOPE (v1)

1. **Onboarding** (3 screens, no account): choose display name + avatar; app generates identity keypair and shows a QR + safety number; scan a friend's QR to add them as a known contact.
2. **Library tab**: the shared folder. Grid of posters, videos get a duration badge. Owner sees a "Publish" toggle + "Shared with N nodes" row. Auto-indexing with visible progress.
3. **Browse tab (search)**: text search over remote owners' names/tags; results show owner, # items, total duration, connection quality badge (from real `getStats` history), and a `Request access` button. Filters: photos / videos / any, sort by quality-of-connection.
4. **Access flow**: pending prompt on the owner's device (toast + full-screen if app open) with Approve / Deny / Always allow. Viewer sees a live "waiting" state with cancel.
5. **Player**: seek bar, thumbnail scrub preview, quality/speed toggle, "Save offline" (cached copy), live bitrate/RTT/freeze overlay (long-press to show), and a peer-presence chip ("+2 others are watching").
6. **Watch Live**: optional toggle; shows latency; auto-falls back to VOD mode if the uplink governor says no.
7. **Connections tab**: every live peer, what it's streaming, bytes sent/received, revoke/kick button, and a per-peer rate limit (`limitViewer(peerId, kbps)`).
8. **Settings**: shared folder picker, publish toggle, allowed/blocked list, auto-approve rules (only for contacts), uplink cap, cache size & clear, STUN server list, **TURN server (empty by default, user-supplied only)**, signaling strategy (Auto/MQTT/Nostr/Manual) + relay diagnostics, discovery shard debugging, debug overlay, export logs, factory reset.
9. **Autonomy guarantees**: tray/foreground-service presence so the host stays visible while publishing; heartbeat keeps the listing alive; viewers auto-retry with backoff; a "device was offline" state on stale results (never a hard error).

Explicitly **out of scope for v1**: offline playback of content you don't have cached, comments/likes, transcoding to other containers, live camera from the owner, TURN we run, iOS/Linux/macOS, web.

---

## 7. BUILD PHASES (each with a hard Definition of Done)

**Phase 0 — Feasibility spikes (do this before writing app code). 3–5 days**
Spikes, each a throwaway branch with a written result:
1. H.264 **hardware** encode + 720p30 send from Android → Windows, and Windows → Android, with `getStats` proving sustained bitrate.
2. Sustained DataChannel throughput on: same-LAN, 100 Mbps, and a throttled `tc`-shaped link. Record MB/s per platform.
3. `bufferedAmount` polling backpressure correctness under a 2 GB transfer; confirm the desktop event bug and that polling is sufficient.
4. MQTT-over-TLS signal round trip incl. trickle candidates, through 3 brokers with failover; measure announce→connect latency.
5. NAT matrix test: home NAT, CGNAT (use a container/cloud VM), symmetric NAT (use `otsturn`/a NAT appliance or a cloud double-NAT). Produce an honest **connectability matrix** to ship in-app.
6. Confirm audio playback on Windows desktop; write a fallback if broken.
DoD: `docs/adr/0001..000N` written, numbers measured, go/no-go per decision. **Kill or re-plan here, not later.**

**Phase 1 — P2P core, 1:1.** Identity, protocol codec, `PeerMesh` with a serialized negotiation queue, Manual + MQTT signaling, ICE/STUN, a data channel, `BYE`, keepalive, reconnect, stats. DoD: two Windows machines + Android↔Windows exchange a 1 GB file with resumable transfer, verified by hash, across a simulated network flap.

**Phase 2 — Library & index.** Folder pickers (SAF tree on Android, arbitrary dir on Windows), watchers, BLAKE3 index, metadata parse, thumbnails, SQLite, paging API. DoD: 20 000 items indexed in under 60 s on a mid Android phone without ANR; a deleted/renamed file is reconciled within 15 s.

**Phase 3 — Discovery + access control.** Announce/shard/gossip, query bloom, ranking, `REQUEST_ACCESS`/`GRANT` HMAC tokens, ACL UI, revoke, block, `onConnection` audit. DoD: with the app running on 10 simulated nodes, a cold-start node finds 8/10 within 60 s; an unapproved node provably receives **zero** media bytes (assert with a test).

**Phase 4 — VOD streaming.** Manifest, range protocol, chunk pipeline, cache, progressive playback, seek, resume, prefetch, download. DoD: a 4K 2-hour file starts in < 1.5 s on LAN, seek p99 < 1.2 s, zero memory growth over a 1-hour session (heap snapshot before/after).

**Phase 5 — Multi-peer live mode.** `LiveTranscodeSource`, simulcast ladders, `UplinkGovernor`, per-viewer rate limits, kick/revoke-under-load, Watch Live UI. DoD: one host → 6 simultaneous 720p30 viewers on a 20 Mbps uplink, all in sync, host CPU < 60 % on a 2019 mid laptop, 1080p60 **off** by default; when cap is exceeded, demotion+queueing behaves exactly per the rules and is covered by unit tests.

**Phase 6 — Hardening & autonomy.** Flutter lifecycle (background/foreground, process death, sleep), Windows tray + autostart + single-instance, Android foreground service + Doze, Android 15/16 permission edge cases (SAF revocation, scoped storage), i18n, accessibility, crash-safe local storage, settings import/export, packaging (MSIX for Windows, signed AAB for Android), telemetry-free diagnostics bundle, user docs.
DoD: 24 h soak test on both platforms with no leaked PeerConnections (assert connection count returns to baseline), no crash, no battery complaint above 8 %/h while idle-publishing.

**Phase 7 (optional / later).** Viewer-to-viewer cache sharing (make a cached item re-shareable), local LAN auto-discovery UI, user-supplied TURN wizard, libp2p-Kademlia as an alternative directory, "handoff" so a host can hand its listing to another node when going offline.

---

## 8. QUALITY GATES (CI)

- `dart analyze --fatal-infos`, strict analysis options, 100 % coverage on `vault_protocol`, `vault_identity`, `vault_delivery/UplinkGovernor`, chunk protocol.
- Golden tests for every wire message (encode → decode → byte-identical, plus "rejects unknown version/signature").
- Fuzz the protocol decoder (`libFuzzer` via `dart_fuzz` or `fuzzly`).
- Integration tests in `integration_test` on both Android and Windows runners.
- `tools/interop_harness`: pion/webrtc as the **other** side, plus `bwe-test` and pion `vnet` for scripted bandwidth/loss/RTT scenarios. Every spike claim in Phase 0 must be reproducible from this harness.
- Perf budgets enforced by benchmark tests: index throughput, chunk throughput, heap high-water, encode CPU.

---

## 9. RISK REGISTER (top 8, with mitigations already chosen)

1. **Symmetric NAT / CGNAT blocks many peer pairs.** → STUN-only by design; in-app honest explanation; user-supplied TURN field; LAN-first; document the residual limitation instead of pretending it away. (Accepted by constraint #1.)
2. **Multi-peer uplink saturation.** → governor + simulcast + hard 6-viewer cap + queueing (3.3).
3. **Desktop `setParameters` ignores encoding changes.** → recreate the transceiver on layer switch; wrap in one API so the workaround is one place. Re-test on every plugin bump.
4. **Missing `bufferedAmountLow` on desktop.** → polling backpressure everywhere (3.4). Never trust the event alone.
5. **Cold-start discovery failure** (no peers ⇒ hear nothing). → 2-hop epidemic re-broadcast + beacon topics; 60 s discovery SLA tested with 10 nodes (Phase 3).
6. **Public relay abuse / outage / rate limits.** → 3+ strategies behind one interface, endpoint lists hot-configurable (settings), announcement redundancy 2, degrade gracefully to Manual mode.
7. **HW codec heterogeneity on Android.** → runtime capability probe at startup, per-rung fallback ladder, forced SW codec list only as last resort.
8. **Plugin churn** (flutter_webrtc moves fast; noted Windows crashes in 1.6.2 hotfixes). → pin exact versions, wrap the plugin in `vault_net`/`vault_delivery` behind our own interfaces so an upgrade touches 2 files, and keep the pion interop harness green.

---

## 10. WORKING STYLE FOR YOU (the AI)

1. **Before any feature code**, produce: the ADR set, the final `pubspec.yaml` dependency list with exact pinned versions and a one-line justification each, the protocol message catalogue, and the directory/file tree with one-line responsibilities.
2. **Build Phase 0 spikes first and report real measured numbers.** Do not fabricate benchmarks. If a spike fails, say so and propose a plan change before writing more code.
3. Implement in **thin vertical slices that run on both platforms from day one** (no "I'll do Android later"). Every slice ends with a command the user can run.
4. Write **pure Dart with interfaces** for everything that touches the OS or the plugin; keep platform channels thin and isolated in `apps/vault/lib/platform/`.
5. Every non-obvious decision gets an ADR. Every magic number in §3 gets a named constant with a comment.
6. Prefer boring, well-understood, heavily-used libraries. No experimental crates in the data path.
7. Never introduce a hosted service, an API key, an account, or a `TODO(server)` in any form. If a feature seems to need one, implement the peer-to-peer or user-supplied version, or cut it and say why.
8. End every response with: what you built, how to run it on Android and on Windows, the measured numbers, and the next single best step.

---

## 11. SUCCESS CRITERIA (definition of "done" for the whole project)

- Install the app on an Android phone and a Windows PC; no account, no server, no configuration.
- Owner picks a folder, drops 50 videos in it, taps **Publish**.
- A second user on a different network finds them by search within ~60 s, gets approved with one tap, and streams any video with a working seek bar at 720p within 3 s.
- A third and fourth user do the same simultaneously; the host stays responsive, the uplink never exceeds the cap, and the UI explains any degradation.
- Pull the host's Wi‑Fi for 30 s: both apps recover automatically with no user action and no corrupted state.
- Revoke access on the host: the viewer's stream dies within 1 s and cannot be resumed.
- Uninstall and reinstall on the viewer side: no server state is required to keep working; the host never notices.
- Zero bytes of media or file content transit any relay — proven by an automated assertion in the signaling client.

---

### Appendix A — Hard-pinned starting dependencies (verify latest versions before locking; record the check)
`flutter`, `flutter_webrtc ^1.6.2`, `flutter_riverpod` + `riverpod_generator`, `go_router`, `drift` + `sqlite3_flutter_libs`, `blake3` (pure-Dart port), `mqtt_client` (or `dart_mqtt`), `nostr` Dart SDK, `protobuf`/`msgpack_dart`, `cryptography`/`ed25519_edwards` + `cryptography_flutter`, `freezed`/`json_serializable`, `video_player` + `video_player_media_kit`/`media_kit` (Windows), `window_manager` (tray/desktop), `flutter_windowmanager`, `workmanager` (Android), `path_provider`, `crypto` (built-in), `logging`, `sentry` — **NO, omit Sentry: no telemetry**, `intl`.

### Appendix B — Numbers cheat sheet
- STUN: Google / Cloudflare / Nextcloud (public, free, no account).
- Announce interval 30 s · TTL 90 s · sweep 15 s · gossip 60 s · 5 fan-out · 200 entries/msg.
- Access prompt countdown 60 s · revoke propagation < 1 s.
- Chunk 256 KiB · read-ahead 512 KiB · high-water 512 KiB · low-water 256 KiB · poll 50 ms.
- Backpressure poll 50 ms · stats poll 1 s · IDR 2 s · PLI throttle 500 ms, max 3.
- Layers 300/800/2500/4500 kbps · overhead ×1.17 · cap 70 % of measured uplink · max 6 viewers.
- Thumbnails 320 px q70, 22 % of duration, concurrency 2.
- Cache 2 GB desktop / 512 MB mobile, LRU.
- Windows watcher event + 5 s reconcile · Android SAF poll 15 s.