# Vault build plan

Reviewed 2026-10-18. This is the authoritative product build plan. The
[research report](reports/Vault%20prebuild%20architecture%20audit.md) explains the
evidence and [ADR 0001](docs/adr/0001-prebuild-baseline.md) records this baseline.
All performance numbers below are targets or initial tunables unless accompanied
by a reproducible result. Phase0 has initial native probe results. Section6.3
authorizes real core implementation before the full feasibility matrix is complete.
Production-path services are experimental; implementation and smoke evidence must
not be confused with passing the measured definitions of done. See the
[measured record](docs/spikes/phase0-2026-10-18/README.md) and
[hotspot decision](docs/adr/0002-phase0-native-findings.md).

The [UI/UX build plan](docs/UI_UX_BUILD_PLAN.md) defines the companion design track:
Manyverse-inspired patterns, navigation, consent, screen states, platform behavior
and acceptance criteria. It does not replace this plan's scope or feasibility gates.

## 0. Intention and priority

Build a direct one-to-one messenger for Android and Windows. Each user has a
protected local identity, explicitly adds verified contacts and exchanges text
over authenticated direct WebRTC sessions. Conversations and local history are
the primary experience. Adding a contact permits direct messages, not media access.

Retain the personal photo/video library as a secondary, separately approved
feature. Owners choose media and explicitly publish; approved viewers browse and
play original files with seek. Viewer redistribution remains deferred.

The first useful outcome is a bidirectional authenticated conversation, with
recipient-persisted delivery acknowledgements and history surviving restart.
Both devices must be running and directly reachable. There is no server mailbox,
remote push wakeup or automatic offline resend. Already received history is local.

## 1. Hard constraints

1. No backend, cloud storage, account, API key or push service that we operate/pay for.
2. All media, thumbnails and file bytes travel directly over WebRTC. No TURN in v1,
   including user-supplied TURN. Reject relay candidates and stop protected transfer
   if the selected path becomes relayed. Public services carry only allowed signaling.
3. Identity is a local Ed25519 keypair. Secret keys remain protected on-device;
   public keys are public. A fresh installation without restored keys is a new identity.
4. Preserve state through interruption, process death and restart; recovery happens
   when the OS permits execution and a network path returns.
5. One visual language and feature model on Android and Windows, with honest OS-specific
   availability states.
6. Owner consent is enforced before any private index, poster, manifest, range or live track.
7. Viewer disconnect stops further transfer and automatic reconnect until explicitly allowed.
8. No telemetry, analytics, remote crash reporting, licensing endpoint or remote config.
   Diagnostics are local, redacted, and exported only by the user.

Revocation stops future delivery. Already transmitted, cached, saved or captured content
cannot be recalled. Do not imply DRM or remote deletion.

## 2. Technology decisions and feasibility boundaries

### 2.1 Flutter, native transport and player

Use installed Flutter 3.47.7 / Dart 3.13.5 for the Android/Windows shell.
Pin flutter_webrtc exactly to 1.6.2+hotfix.4 for the initial spike; the recorded
Windows/Linux engine is m150.7871.03. Record Android artifacts separately.
[Publisher changelog](https://pub.dev/packages/flutter_webrtc/changelog).

Keep one plugin import seam in vault_net/src/webrtc_adapter.dart; consumers use
our interfaces. Await track/transceiver operations, serialize negotiation, and
make teardown cancel pending work. Reproduce upstream reports on the pinned build:
[encoding updates #2210](https://github.com/flutter-webrtc/flutter-webrtc/issues/2210)
and [buffer callbacks #2206](https://github.com/flutter-webrtc/flutter-webrtc/issues/2206).
Transceiver recreation is a measured workaround, not an unconditional operation.

Hardware H.264, simulcast, file-to-track audio/video injection, keyframe controls,
and encoded-frame sharing across connections are hypotheses to test. Never infer
them from package platform support. A camera demo does not prove file broadcasting.
Software codec fallback must satisfy measured CPU/thermal budgets or live mode is unavailable.

Windows playback needs an explicit backend; video_player alone has no Windows implementation.
Evaluate media_kit plus its video/native-library dependencies in the VOD spike.
VOD exposes ByteRangeSource (readAt, size, cancellation); live mode exposes
LiveSession (tracks, timeline, lifecycle). They share authorization, not a false
common byte-stream interface.

### 2.2 Direct WebRTC

Use Unified Plan, maxBundle, required RTCP mux and STUN-only ICE. Public STUN
endpoints are configurable candidates, not guaranteed services; verify each in Phase 0.
Record the selected candidate pair and handle network changes with fresh ICE generations.
mDNS behavior must be tested in the native plugin; it does not hide public/reflexive
addresses from an observer of clear SDP. If no direct route exists, say so without
claiming a certain NAT type. Manual signaling cannot repair an unreachable path.
[ICE](https://www.rfc-editor.org/rfc/rfc8445.html),
[TURN relays data](https://www.rfc-editor.org/rfc/rfc8656.html).

### 2.3 Signaling

Define an injectable SignalingStrategy with inbound messages, publish, subscribe,
connected state and endpoint diagnostics. MQTT first, Manual as a test oracle and
fallback; Nostr is a separately gated adapter.

MQTT5 requires a compatible client (candidate mqtt5_client 5.1.0, not MQTT3 mqtt_client).
Public EMQX/Mosquitto endpoints are testing infrastructure without our availability
guarantee. Verify current TLS/WSS paths and MQTT CONNACK/SUBACK/PUBACK behavior
before inclusion; the previous Eclipse path is unverified. Use bounded reconnect
backoff with jitter, endpoint redundancy and application-level deduplication.
QoS 0 is suitable for presence/stats. Trickle candidates require application
acknowledgment/retry/idempotence or a repeated final complete candidate set;
losing the only usable candidate can prevent connection. State-changing exchanges
also require acknowledgment, retries and idempotence. Never retain private messages.

All addressed SDP, candidates and private control must be end-to-end encrypted
to an encryption key bound to the verified Vault identity. Select an established,
reviewed construction/library and vectors in a Phase 0 ADR; no ad hoc crypto.
TLS to a public broker is insufficient. Sign the complete inner Vault envelope.

Nostr outer events use JSON and a separate secp256k1 Schnorr transport identity,
bound by a Vault-signed key binding. If selected, use exact NIP-44 v2 with its
required keys and vectors. Ephemeral events may still be logged by relays.
[NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md),
[NIP-44](https://github.com/nostr-protocol/nips/blob/master/44.md).

Manual mode exchanges the full compressed gathered offer and answer via text or
bounded multipart QR. A short phrase verifies a transcript; it cannot replace
arbitrary SDP without a rendezvous service. Peers still need a viable network path.

Enforce a typed signaling allowlist, individual size limits and total rate/byte
limits. Reject index, thumbnail and file payload kinds. A byte budget alone cannot
prove media exclusion. Test signaling schema boundaries and direct transport paths separately.

### 2.4 Directory/search

Public listing is an explicit opt-in. Explain that display name, selected tags,
coarse counts, stable identity and presence become public metadata. Never publish
filenames, paths, posters, ACLs, IP hints, grants or secrets.

For the bounded pilot, subscribe to the complete bounded presence namespace over
a common working endpoint, validate signed records, and search the local cache.
Initial heartbeat 30 s, origin-signed expiry <=90 s, expiry sweep 15 s. Only the
origin may refresh a record. Deduplicate, reject stale sequence/epoch updates,
limit entries/bytes/signature work/responses/prompts, and label partial results.

Do not derive a text-query shard from a hash of nodeId. Sharding, query Bloom
filters, cross-endpoint bridges and gossip-based scaling require separate design
and load evidence. Redundant brokers are not automatically federated. Topic names
do not create bootstrap nodes. If gossip is tested, batches contain <=32 records,
preserve original signatures/expiry and have bounded hops and aggregate budgets.

Pilot target: with ten online opted-in nodes sharing a reachable broker, a new node
finds >=8 within 60 s. Test disjoint endpoints, outage, spam, duplicate/replayed
records and cold start. This is not a global Internet discovery SLA.
[Public broker limitations](https://test.mosquitto.org/),
[EMQX public visibility](https://www.emqx.com/en/mqtt/public-mqtt5-broker).

### 2.5 Identity, authorization and revocation

Store Ed25519 identity plus separately bound encryption keys through protected OS
storage adapters. Freeze key derivation, nodeId encoding, rotation and backup policy
in an ADR. QR/safety numbers authenticate a key; display names do not.

Before protected access, verify a fresh peer challenge bound to the signed SDP,
DTLS fingerprints, expected peer and session. A self-asserted DC_HELLO nodeId is insufficient.
Media authorization states are unauthenticated, authenticated/no grant, approved,
revoked and blocked. Before media approval, allow only bounded handshake/access
requests and direct messages from explicitly added verified contacts. Messages
confer no media grant. Rate-limit owner prompts across rotating identities as
well as per peer.

Owner alone keeps a random 32-byte HMAC minting key. Never transmit it. A grant
contains version, ownerId, viewerId, grantId, exact resource scope/actions, issue
and expiry times, and a persisted owner-controlled authorization epoch. MAC an
unambiguous domain-separated canonical encoding. Return the grant/MAC only.
Check identity, MAC, scope, expiry, epoch, revoked state and block state before
every protected operation. Full ACLs stay local.

Persist revocation before cancelling reads/queues and closing sessions. Target
owner scheduling stop and affected session closure within 1 s; measure viewer
notification separately under network delay/loss. Replayed grants must fail after
restart, reconnect, resume and key rotation. A lost remote notice cannot defeat
local enforcement. Already received content is outside revocation.
[HMAC](https://www.rfc-editor.org/rfc/rfc2104.html),
[Ed25519](https://www.rfc-editor.org/rfc/rfc8032).

## 3. Transport, storage and resource budgets

### 3.1 Data channels and chunking

Use three channels on one association:
- Reliable ordered critical control: authentication, access, manifests, requests,
  cancellation, resume, errors and acknowledgments.
- Reliable ordered bulk: file fragments.
- Unordered zero-retransmit ephemeral messages: disposable stats/heartbeats and bounded gossip.

Channels share congestion control; separate channels do not guarantee control latency.
Integrity/cache chunks are 256 KiB, fragmented into messages whose TOTAL serialized
size is <=min(16 KiB, negotiated max-message-size), including headers.
Treat SDP max-message-size=0 as unlimited and omission as64 KiB when computing
that bound; a zero value does not prohibit messages. Carry session,
request and content-generation IDs, chunk/fragment indices, lengths and digest references.
Bound allocation, reassembly bytes/time, outstanding requests and retries. Cancel old
seek generations. Authenticate chunk digests in the protected manifest; a received
hash alone is not a trusted reference. Retry corruption at most twice, then fail clearly.

Initial read-ahead 512 KiB/session and prefetch two chunks are tunable, not promises.
Backpressure MUST poll await channel.getBufferedAmount(); the bufferedAmount property
is cached and can remain stale when callbacks are missing. Start at high-water512 KiB,
low-water256 KiB, poll50 ms, with local enqueue accounting and per-peer/global bounds.
Cancel timers on teardown and handle native failures. Benchmark/tune before freezing:
a strict 512 KiB/50 ms refill policy can itself limit throughput to about10 MiB/s.
[Exact plugin implementation](https://raw.githubusercontent.com/flutter-webrtc/flutter-webrtc/v1.6.2%2Bhotfix.4/lib/src/native/rtc_data_channel_impl.dart),
[RFC8831](https://www.rfc-editor.org/rfc/rfc8831.html),
[message-size negotiation](https://www.rfc-editor.org/rfc/rfc8841.html).

### 3.2 VOD playback and indexing

VOD sends original bytes without transcoding. Transport, hashing and decoding cost
CPU; source bitrate/container/codec and storage determine startup and seek latency.
A live quality ladder cannot lower original-file VOD bitrate.

Prove a bounded progressive cache plus loopback HTTP Range feed or native seekable
adapter on BOTH platforms. Handle MP4 initial/tail moov, sparse cold seeks, cancellation,
unsupported/corrupt codecs, audio and cache eviction. A loopback-only playback server
is local plumbing, never a remotely hosted backend. Default cache budgets: desktop2 GiB,
mobile512 MiB, user configurable.

Use local SQLite; candidates current Drift/SQLite3 do not require obsolete
sqlite3_flutter_libs. Android source handles are SAF content URIs, not filesystem paths:
persist grants, use ContentResolver descriptors, test random access, revoked permission,
provider latency, moved/deleted items and non-seekable sources.

Treat prefix BLAKE3 as a provisional fingerprint, never a globally unique or trusted
content ID. Bind immutable media generations to full verified hashes or collision-safe
local IDs; maintain per-chunk hashes. Metadata, thumbnails and hashing run off the UI
thread with bounded work. Short-circuit unchanged files using provider identity/size/mtime
where trustworthy; reconcile changes. Choose a tested BLAKE3 implementation before locking.

Stage indexing budgets: enumerate/basic records first, then metadata, then thumbnails,
then full hashes. The former20k-items/60s goal cannot include guaranteed hashes/posters:
20k one-MiB prefixes alone require19.53 GiB reads (333.3 MiB/s for60s).
Record each stage's dataset/storage/device and ANR/memory behavior.
Windows watcher plus reconciliation and Android incremental reconciliation must scale;
do not promise a full20k-item SAF scan every15 s. Fifteen seconds is an active-mode
small-change target to test. Background freshness is governed by the OS.

### 3.3 Optional live mode and uplink governor

Use H.264 where supported; verify actual encoder, profile, timestamp/audio injection,
thermal behavior and sender capacity. Do not assume one encoding is shared across peers.
If sync is offered, specify leader clock, seek/play controls, drift tolerance and resync.

Initial normalized720p ladder: low320x180@15fps/300kbps (scale4),
mid640x360@30fps/800kbps (scale2), high1280x720@30fps/2500kbps (scale1).
Optional1080p is separately gated. Count EVERY active simulcast encoding per peer.
RTP live PLI/keyframe recovery is unrelated to byte chunk boundaries; use only APIs
proven available. Fixed CBR,2s IDR and exact codec controls are targets to validate.

Keep UplinkGovernor pure and deterministic. Distinguish conservative path goodput
(bytes/monotonic elapsed time) from total host uplink. Best RTT is not bandwidth.
Use user cap and observed aggregate rates; initial automatic cap is70% of a justified
estimate. Do not probe an unapproved viewer by sending media or unbounded dummy traffic.

Planning example: (2.5+0.096)*1.17=3.03732Mbps per high viewer.
Six cost18.22392Mbps; a20Mbps uplink at70% gives14Mbps, at most FOUR high
viewers before extra overhead. Six require>=26.034Mbps measured before margin.
Six is a hard session ceiling, not a universal target. Admit lower layers or queue
according to cap, then demote worst observed paths, never silently exceed the cap.
Measure actual wire rates and CPU; VOD has a separate byte-scheduling budget.

### 3.4 Lifecycle and availability

Windows: tray, optional autostart, single instance, sleep/resume and crash-safe state.
Android: select a valid foreground-service type for active transfers and idle publishing
separately, with required permissions and user-visible start/stop. Do not label hosting
as mediaPlayback to evade limits. Android15+ dataSync/mediaProcessing have background
time budgets; connectedDevice applicability needs a documented use-case assessment.
Doze can suspend network and defer WorkManager; a15min periodic job is not a
continuous-presence guarantee. Wake locks do not bypass these restrictions.
Android16 adds long-worker quota considerations.

Phase0 must establish supported availability modes on a physical phone: screen-off,
forced Doze, process death, user stop, reboot, background-start denial, service timeout,
permission loss and recovery. Expose awake/publishing/suspended/offline states honestly.
Keep WorkManager for deferred maintenance. Do not automatically bypass user battery policy.
[FGS types](https://developer.android.com/develop/background-work/services/fgs/service-types),
[timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout),
[Doze](https://developer.android.com/training/monitoring-device-state/doze-standby).

## 4. Repository and dependencies

One app under apps/vault plus vault_identity, vault_protocol, vault_signaling,
vault_net, vault_directory, vault_media_index, vault_delivery, vault_player, vault_ui.
Layering: ui -> directory/delivery/player -> net/signaling/media_index -> protocol/identity.
Identity/protocol are pure Dart with zero Flutter imports. OS adapters live behind
interfaces; no global mutable services outside DI. Hash/read/thumbnail workers must
not block the UI isolate.

The repository contains the native Flutter app, nine service/UI package
boundaries, a separate browser design study, Android/Windows feasibility probes
and a pinned Go/Pion interop harness. Experimental core services are implemented
under section6.3; the [file tree](docs/FILE_TREE.md) separates those sources from
remaining acceptance evidence and deferred extensions.

Root pubspec pins Melos8.9.0 and very_good_analysis11.0.0, Dart>=3.13.0;
pubspec.lock records resolved tooling. Configuration is in pubspec, per current Melos.
apps/vault and all nine packages are explicit members with resolution:workspace.
Use dart run melos, not an unpinned global install. Add real test/codegen/coverage
commands only when their targets exist. Analysis of an empty scaffold is not feature validation.

Before feature code, freeze the exact jointly resolved dependency set with justifications,
lockfile/native artifact versions, licenses and both-target plugin builds.
The app/service graph is pinned in the root workspace lockfile.
Initial spike pin: flutter_webrtc1.6.2+hotfix.4. Exact interface pins and remaining
dependency/license gates are recorded in [dependency review](docs/ops/DEPENDENCIES.md).
The default app now composes real core services; the separate design study is
not transport evidence. Do not add missing blake3, Dart2-only
flutter_windowmanager, EOL sqlite3_flutter_libs or telemetry.

## 5. Protocol catalogue and freeze requirements

Use ONE deterministic inner binary profile chosen by ADR and golden vectors before
Phase1; default proposal deterministic CBOR RFC8949 section4.2.1. MessagePack requires
an equally explicit profile if chosen instead. Nostr outer JSON is a transport exception.
Wire header: one-byte version, two-byte type; Ed25519 public key32 bytes and signature
64 bytes. Sign domain-separated header/body excluding signature. Specify exact field
types/order/encoding, duplicate-key rejection, nesting/length limits and integer bounds.

Envelope includes sender, intended recipient/broadcast scope, messageId, sessionId,
issuedAt, expiresAt, and ICE generation where relevant. Deduplicate across transports
by authenticated(sender,messageId) for the signed acceptance window; bound caches and
persist grant/revocation replay defenses. Initial clock skew allowance120 s is not a
replacement for replay prevention. Reject mismatched identities/sessions, unknown
versions/types, invalid signatures and expired records before side effects.

Signaling catalogue: HELLO, OFFER, ANSWER, CANDIDATE, ANNOUNCE, BYE; QUERY and
bridging are deferred. Grants/private ACLs never travel as public directory records.
Data-plane catalogue: DC_HELLO/challenge proof; REQUEST_ACCESS ->
ACCESS_RESULT{allowed,grant?,expiresAt?,reason?}; INDEX_REQUEST/INDEX_PAGE with
bounded paging; MANIFEST_REQUEST/MANIFEST with content generation and authenticated
chunk digests; RANGE_REQUEST/RANGE_FRAGMENT with request IDs, offsets, bounds and
fragment framing; CANCEL, RESUME, ERROR/ACK; optional PLAY_LIVE/LIVE_READY; STATS_PUSH,
bounded GOSSIP, BYE. Define exact schemas and rejection vectors in a protocol ADR.
A catalogue is not yet an interoperable frozen byte specification.

## 6. Functional scope

Verified local contacts; direct one-to-one text conversations; durable local
history and unread state; explicit Connect/Disconnect; sending, delivered,
unconfirmed and received states; manual same-ID retry after uncertain delivery.
Delivered means the recipient app persisted the message, not that a person read it.

Secondary media features retain folder/import selection, explicit publication,
opt-in directory, owner approval, paged browse, VOD seek/download and revocation.
Chat does not require publication or a media grant. Stopping library sharing does
not stop a messenger-enabled connection; explicit disconnect and revocation can.
Optional live controls remain feasibility-gated.

Out of v1: camera broadcasting, comments/likes, cloud storage, remote push, TURN,
viewer redistribution, unsupported platforms, promises to serve from sleeping devices.
Downloaded/cached content follows explicit user save choices and cache budgets.

### 6.1 UI/UX design track

Follow [the dedicated UI/UX build plan](docs/UI_UX_BUILD_PLAN.md). Design journeys,
responsive specifications and browser/native interface previews before resuming
Phase0 testing, under the explicit sequencing revision below.

User-approved Quietly personal redesign (2026-10-19): use Chats (default),
Libraries and My library as the three primary Android/Windows destinations.
Activity remains a global Requests & transfers utility; Identity & Settings opens
from the local identity control. See the complete
[redesign contract](docs/INTERFACE_REDESIGN_PLAN.md). Wide chats pair the contact
list with timeline/composer; compact screens open one conversation with Back.
Preserve drafts and useful navigation context through destination changes and
resize. Keep human fingerprint comparison, authenticated direct connectivity
and library approval distinct. Publication and public discovery remain separate
opt-ins. Pending Manual frames remain actionable from Chats and a canonical
connection-setup utility. No social feed, replication, room/pub servers or extra
transports are introduced.

Accessibility, localization-safe layouts, privacy boundaries and recovery states
start with the first wireframes. Phase6 hardens and verifies them, not introduces
them. UX design/prototype evidence never substitutes for native feasibility or
authenticated delivery evidence.

### 6.2 Interface-first sequencing revision

User-directed revision, 2026-10-18: build the installable Android/Windows Flutter
interface first; resume Phase0 testing when the interface is ready for review.
This supersedes the previous prohibition on native UI implementation before
Phase0 completion, narrowly for the interface preview.

The native preview may implement shared visual components, navigation, consent
and failure-state walkthroughs, local media selection/viewing/playback/save, and
non-secret local UI preferences. Peer identity, connectivity, publication and
authorization remain explicitly labeled simulations, not production enforcement.
No production transport/protocol implementation or Phase0 go decision follows
from an APK, a native UI smoke run, or a successful local media operation.

All existing direct-only, owner-consent, persistence/security and lifecycle
acceptance criteria remain required before claiming working P2P delivery.
Do not rerun transport probes as part of this interface task.

### 6.3 Implementation-first sequencing revision

User-directed revision, 2026-10-18: proceed autonomously with the real core
system, using concurrent implementation slices, before completing the Phase0
test matrix. This supersedes the Phase0 prohibition on production implementation
and the interface-only scope restriction in section6.2. It does not pass a gate.

Phase1 is the next implementation phase: identity, protected persistence,
authenticated/encrypted Manual and MQTT signaling, direct sessions and bounded
resumable transfer. Integrate media indexing, consent/discovery and VOD in the
dependent Phase2–4 sequence rather than leaving simulated services in the app.
Basic runtime smoke checks, deterministic security checks and analysis remain
required during implementation. Broad physical-device/NAT/firewall, shaped-link,
lifecycle, soak and performance acceptance trials may follow integration.

Phase0 remains open. Implementation completion, smoke success and native builds
must be reported separately from each phase's measured definition of done.
Keep the no-backend, direct-only/no-TURN, explicit-consent, protected-storage and
fail-closed authorization constraints. Optional live remains gated and is not
part of the core VOD implementation. Do not claim background availability, general
Internet reachability, release readiness or independent cryptographic review.

### 6.4 Messenger product revision

The user's request to make Vault a messenger supersedes the earlier media-first
product priority and browse-first navigation, not the security or feasibility
constraints. Text and acknowledgements use the authenticated reliable control
channel, never MQTT, public discovery or a relay. The bounded versioned messenger
schema carries a random message ID, sender timestamp and at most 4096 UTF-8 text
bytes (canonical base64 on wire); acknowledgements contain only the message ID.
Session identity supplies sender/recipient association.

Persist incoming messages before acknowledging. Deduplicate by peer and message
ID across restart; a same-ID retry must not create another received copy.
Interrupted or timed-out delivery stays unconfirmed, never inferred delivered.
Local SQLite history is application-private but not encrypted at rest; protected
identity keys remain in OS storage. Refuse new history when its explicit bound
is reached rather than silently dropping deduplication records.

Messenger acceptance: exercise two actual authenticated native peers, composer
send and reverse reply, recipient-save acknowledgements, history after restart,
disconnect/offline states, same-ID retry, Unicode/byte limits and unread state.
Verify narrow/wide conversation surfaces and draft retention. Existing media
consent/revocation checks remain required. No group chat, calls, server mailbox,
cloud synchronization, push service or unattended/background availability claim.


## 7. Build phases and gates

Phase0 - feasibility evidence and remaining acceptance gates. Section6.3 permits
implementation before this matrix is complete; Phase0 remains open. Each spike
still needs exact commands, hardware, versions, raw results, limits and go/no-go ADR:

Initial evidence on2026-10-18: exact native plugin builds on both targets; physical
Android/Windows synthetic direct transfers; resident MP4 Range playback/seeks;
five-second Android hardware encode; short background dataSync transfer. The
hotspot needed an experimental local plugin option. These are partial results;
none establish authenticated P2P VOD, network recovery, sustained encoding or Doze.
The [result matrix](docs/spikes/phase0-2026-10-18/README.md) tracks remaining gates.

1. Hardware encode and file audio/video track injection Android<->Windows, encoder
   evidence, sustained720p30 and cleanup; real phone required. Optional live may be cut.
2. DataChannel goodput/memory/control latency on LAN and real shaped100Mbps/loss links.
3. Native buffer polling, bounded queue/reassembly, cancellation and2GiB transfer integrity.
4. Authenticated/encrypted MQTT round trip, trickle, retries, endpoint failure and
   bounded pilot discovery. Verify brokers rather than merely opening their ports.
5. Direct-connect matrix using documented NAT/firewall topology and observed pairs.
   Delay/loss is NOT CGNAT/symmetric-NAT emulation. Use a real/test NAT appliance
   or isolated routing fixture; public cloud VM is optional and not provisioned by default.
6. Progressive VOD and audio on BOTH platforms, tail-moov MP4, cold seek and source
   URI permission loss. Prove player/backend adapter before Phase4.
7. Android lifecycle/FGS/Doze availability modes on physical Android15/16, with service
   budgets, stops and recovery. This is a core product gate, not Phase6 cleanup.
8. Crypto/wire/storage/dependency ADRs and adversarial authorization design, plus
   exact plugin native builds on both targets.
Phase1 implementation is authorized by section6.3; its acceptance gates remain required.
Optional live failure may remove live from the first release while preserving core VOD.

Phase1 - identity, authenticated/encrypted manual+MQTT signaling, direct PeerMesh,
critical control, bounded bulk, stats and restart. DoD:1GiB hash-verified resumable
transfer Android<->Windows and two Windows devices across a network flap, with
unauthorized/private-data rejection and relayed-path rejection.

Phase2 - SAF/Windows media sources, staged index, metadata, posters, chunk digests,
SQLite/paging. DoD: documented20k-item workload, per-stage times/ANR/memory and
incremental rename/delete/revoked-permission behavior. Targets selected from Phase0 evidence.

Phase3 - bounded opt-in discovery and complete consent UI. DoD: documented10-node
pilot8/10 in60s plus outage/spam/replay tests; unapproved peer receives zero protected
index/poster/media bytes. Test owner secret isolation and revoked tokens after restart.

Phase4 - VOD cache/feed/seek/resume/download on both platforms. Initial LAN targets:
startup<1.5s, seek p99<1.2s for a specified playable4K/two-hour file. Record format,
cold/warm cache, bandwidth and hardware. One-hour soak must show bounded steady-state
memory, not literally zero allocation or zero heap fluctuation.

Phase5 - optional live fan-out/governor/sync only after gate. DoD: cap-respecting
measured viewer count/quality;20Mbps planning case <=four high viewers, six only on
adequate measured capacity or lower layers. Record actual encoding instances,
audio/simulcast bytes, thermal/CPU behavior and clock drift. CPU<60% is a target
for a named baseline machine, not a guarantee for every2019 laptop.

Phase6 - packaging, accessibility/i18n, tray/autostart, lifecycle hardening, crash-safe
storage and redacted diagnostics. Signed AAB/MSIX use user-owned signing material.
24h awake/available-mode soak, baseline connection count restored after disconnects,
bounded memory and measured idle battery against an agreed device baseline.
OS-suspended intervals are separately reported, not counted as reachability success.

Phase7 - deferred redistribution/delegation, scaling directory, LAN discovery/handoff.
Any TURN mode requires a separate explicit change to the hard direct-only constraint.

## 8. Quality gates

Strict analysis/format; meaningful pure-Dart protocol/identity tests and golden vectors;
100% target coverage on protocol, identity, governor and chunk logic once implemented.
Adversarial malformed/replay/copy-token/scope/epoch/restart tests and bounded fuzzing;
select a maintained Dart-compatible fuzz harness before promising libFuzzer integration.
Integration on Android and Windows. Go/Pion other-side interop with pinned go.mod/go.sum,
plus vnet/link fixtures where applicable. No claim that every hardware codec/battery
result is reproducible in a Go-only harness: native device tests remain required.
CI/performance/coverage jobs must be implemented and fail on missing targets.

## 9. Risk register

Direct-only reachability limits; Android background availability; public relay abuse/outage;
crypto/session binding mistakes; progressive player/container incompatibility;
SAF provider performance; live native injection/encoder sharing; fan-out uplink/thermal
limits; plugin/native artifact churn. Each has a Phase0 gate or explicit product limit above.

## 10. Working style

Write decisions and exact dependencies before feature code. Measure, never fabricate.
Use thin slices that run on both platforms; keep OS/plugin boundaries injectable.
Named constants for tunables. No operator infrastructure, accounts or telemetry.
Report what changed, how to verify/run on both targets, measured results and the next
single best step. Do not present tools-only checks or placeholder directories as finished features.

## 11. Success criteria

Two verified contacts on Android or Windows establish an authenticated direct
session, exchange text in both directions and see Delivered only after recipient
persistence. History survives process restart; uncertain sends remain visible and
can be explicitly retried without duplicate received copies. Disconnect stops
automatic connection attempts. No server state, relay or operated backend is required.

Secondary media acceptance remains: an available publishing owner explicitly
approves a viewer, who browses and plays supported original files with seek.
Network interruption recovery, revocation, typed signaling exclusion and selected
direct-route checks retain their existing gates. Messenger smoke evidence does not
pass physical Android/Windows, WAN, lifecycle, soak or release-security gates.

Appendix - tools: run tools/setup/verify-toolchain.ps1 for installation checks,
tools/setup/test-builds.ps1 for isolated empty Android/Windows builds, and
tools/setup/test-verifier.ps1 for verifier regressions. See docs/ops/ENVIRONMENT.md.
