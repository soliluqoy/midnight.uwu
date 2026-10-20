# vault_net

Native, data-only WebRTC sessions for Windows and Android. This package is
experimental: implementation and deterministic security regressions do not close
the Phase 0 physical-device, lifecycle, performance or availability gates.
`flutter_webrtc` is imported only by `lib/src/webrtc_adapter.dart`.

## Public API and lifecycle

`PeerMesh(identity:, signaling:, resolveBinding:, stunUrls:)` owns a
`SignalingClient` and all of its RTC resources. The resolver must return only
explicitly trusted contact bindings; importing a contact is not a substitute for
comparing its node-ID fingerprint through a trusted channel. Start the mesh with
`await mesh.start()`. Subscribe to `mesh.sessions` before connecting, and attach a
packet consumer immediately for each incoming/outgoing session. `connect(card)`
returns a **negotiating** `PeerSession`, without waiting for a manual exchange.

A session exposes `peerId`, `sessionId`, `state`, `states`, `failureReason`,
`packets`, `sendControl(Map<String,Object?>)`, `sendBulk(Uint8List)`,
`sendEphemeral(Map<String,Object?>)` and `close()`. A failed session also
exposes `problem`, a `ConnectionProblem` when the cause has a known remedy:
`negotiationTimedOut`, `noDirectRoute` (native ICE failed before any
connection) or `signalingUnavailable`. `mesh.problems` reports
`youDisconnected` when an offer from an explicitly disconnected contact is
ignored, and `notAContact` when signaling ignores a noncontact. States are negotiating,
authenticating, connected, closed and failed. Read `failureReason` on failure;
SDP, addresses and application payloads are not put in diagnostics. State and
session streams are broadcast; packets have one consumer (delivery, which routes
the messenger control namespace to the app's chat service). No application
traffic is sent before `connected`; messaging cannot bypass mutual authentication.

`selectedCandidateTypes` is an immutable sanitized snapshot with `local` and
`remote` candidate-type strings from the last successfully validated selected
route. It contains no IP addresses, candidate IDs, or SDP. It is empty before
verification, during recovery and after closure; reading it does not replace
the live route checks that gate traffic.

`session.close()` is an explicit disconnect: it disables automatic recovery and
new incoming sessions for that peer in this mesh. Persist that user intention in
public configuration and restore it at construction with
`PeerMesh(initiallyDisconnectedPeerIds: savedPeerIds, ...)` **before** `start()`.
The constructor copies the IDs; `disconnectedPeerIds` returns an immutable policy
snapshot. A subsequent explicit `mesh.connect(card)` re-enables the peer.
`mesh.close()` closes every session without creating new disconnect intentions,
cancels subscriptions/timers, releases native channels/peer connections and
closes signaling. Do not separately close shared signaling while the mesh is in
use. There is no background networking service or implicit availability claim.

## Authentication and direct-only enforcement

Offers and answers contain complete gathered ICE SDP in authenticated encrypted
signaling; no trickled candidates are accepted. Negotiation is serialized,
bounded and generation checked. Simultaneous offers converge on the
lexicographically smaller node ID as offerer. Initial negotiation has a three
minute deadline (including manual exchange); native ICE gathering is limited to
60 seconds and channel opening/mutual authentication to 30 seconds. Native STUN
retries on unrouted Windows virtual adapters took about 43 seconds in a physical
trial despite usable Wi-Fi candidates; the complete SDP must not be truncated.

Each endpoint generates a fresh random 32-byte challenge. Ed25519 proofs bind
both full SDP SHA-256 digests, both SHA-256 DTLS fingerprints, both identity
public keys, the expected offerer, session ID, ICE generation and directionally
ordered challenges. Both proofs and authenticated readiness are required before
`connected`. Reflections, repeated challenges/proofs, changed contact bindings,
untrusted peers and application frames before mutual authentication fail closed.
The local challenge is sent before its proof, including when a remote challenge
arrives while other native channels or asynchronous trust checks are still pending.
The trusted binding is re-resolved before sends/receives and periodically.
Mesh setup verifies its signature and derived node ID once. Subsequent operations
compare the complete immutable binding (both keys, issue time and signature)
against that verified pin; changed/missing bindings fail closed without repeating
Ed25519 verification and node-ID hashing for every fragment.

Only credential-free `stun:`/`stuns:` URLs are allowed (maximum eight); pass
`stunUrls: []` for local host-candidate-only tests. The default is
`stun:stun.l.google.com:19302` (a public STUN discovery service, not signaling or a
media relay). TURN URLs and relay/unknown candidate types in SDP are rejected.
A selected native candidate pair must be **verifiable**, succeeded, and reference
known local and remote host/srflx/prflx candidates. Selection requires
`transport.selectedCandidatePairId` or an explicit candidate-pair `selected`
flag. Merely nominated pairs are insufficient. Missing/ambiguous reports, relay
routes or unknown candidate types reject the session; configuration alone is
never treated as proof of a direct path. Native stats gate every send and inbound
application dispatch and are monitored every second while connected. This is a
check-before-send boundary, not an atomic promise against a native path changing
between stats collection and the native send. No TURN servers are configured.
A fully identified direct selected pair can temporarily report `waiting` or
`in-progress` during native nomination changes. Traffic remains paused while fresh
reports are revalidated for at most three seconds per check. Only `succeeded`
permits traffic; missing/ambiguous/failed/unknown/relay reports remain terminal
policy failures.

A native disconnect/failure after authentication pauses application traffic
immediately, retaining the existing session and authentication for a ten-second
route-recovery window. Native connectivity must return and a fresh selected
direct pair must pass validation before traffic resumes. Pending direct checks
also enter this recovery path rather than permanently closing a healthy session.
No signaling exchange is needed when the existing route recovers in that window.
Old queued sends and receives cannot cross an interruption boundary.

If the outage persists, the original offerer uses the actual native `restartIce()`
plus an ICE-restart offer; the answerer can request this through authenticated
signaling. Every restart advances generation and requires fresh mutual
authentication. Three restart negotiations per recovery episode are allowed;
successful authentication resets that budget, so separate recovered interruptions
do not exhaust a session-lifetime limit. Stale-generation SCTP frames are
discarded and future-generation frames fail closed. Recovery waits up to two
minutes for signaling readiness, within a five-minute overall restart budget.
A full restart still requires another manual exchange when manual is selected;
MQTT carries it automatically while signaling is reachable. Old route/monitor
operations cannot terminate or authorize a replacement recovery epoch.
Transient publish/reconnect diagnostics do not defeat the signaling client's own
bounded retries; exhausted retries remain terminal.
An unverifiable/relay route is a terminal security failure, not a reason to relax
policy or silently fall back to another transport.

## Bounds and consumer requirements

There are exactly three channels: reliable ordered `critical` control/auth,
reliable ordered `bulk`, and unordered `ephemeral` with **maxRetransmits=0**.
The pinned interface omits zero in its default serializer; the adapter preserves
it explicitly. Every native message is binary and at most 16 KiB **including** a
five-byte type/generation header. Exported `maxPeerPayloadBytes` is 16,379:
fragment bulk at that size or smaller, and keep control/ephemeral serialized
UTF-8 JSON within that size. Delivery owns fragment IDs, integrity and resumption;
this transport does not silently split or reassemble application messages.

Each channel has at most 64 locally queued packets: 256 KiB for bulk, 64 KiB
for critical/ephemeral. Native buffer capacity uses the same per-channel limits,
with awaited `getBufferedAmount()` polling every 20 ms under pressure and a
20-second stall deadline. It never relies on a cached counter or native low-buffer
callback. Individual native buffer/stats/send calls also have deadlines.
The inbound work queue is at most 64 packets/256 KiB. The packet stream never
buffers before subscription or while paused: missing/paused consumers terminate
the session, so attach a listener promptly and do not pause it. Consumer-owned
work must be bounded separately. Control JSON must be an object, finite and at
most 24 levels deep; local traversal is size bounded before serialization.

`session.transportDiagnostics` returns an immutable, bounded local snapshot of
cumulative operation counts, total/max monotonic microseconds, and application
frame/byte counts. `trust*`, `route*`, `buffer*`, `nativeSend*`, `sendQueue*`,
`receive*` and `receiveQueue*` measurements distinguish contact lookup, selected
route queries, native buffering/send cost and queue/dispatch delay. Take snapshots
before/after a transfer for deltas: non-application counters include authentication
and periodic route monitoring. Counters contain no payloads, IDs, addresses or
wall-clock timestamps, emit no logging/network telemetry, and never bypass live
route enforcement.

## Checks and native prerequisites

From the workspace root, after dependency resolution:

```powershell
flutter test --no-pub packages/vault_net/test
flutter analyze --no-pub packages/vault_net
```

Pure policy/authentication/frame tests exercise actual Ed25519 proofs, mutation
of every transcript binding, replay/reflection/readiness rejection, route change
rejection, unknown selected paths, TURN/SDP policy, UTF-8 packet limits and stale
restart generations. The adapter regression checks the real zero-retransmit
serializer. A lifecycle race test delays the current trusted-contact lookup and
asserts that explicit disconnect causes zero native factory calls; its method
channel is a forbidden-call tripwire, not a fake data transport.
`handshake_ordering_test.dart` runs two real session state machines and signed
Manual signaling with a simulated native-channel boundary. Explicit channel/trust
gates verify challenge-before-proof order, authenticated control delivery and
closure while waiting. Route tests distinguish temporarily pending direct checks
from terminal invalid/relay reports.
Recovery regressions exercise repeated brief outages without new signaling,
send refusal during loss, sustained loss with fresh generation-bound
authentication, explicit disconnect during recovery and relay rejection after
native connectivity returns.
These are not substitutes for native trials;
the [physical cross-network record](../../apps/vault/README.md#physical-cross-network-trial-2026-10-19)
documents actual Windows/Android transfers, playback, consent and revocation.

Native smoke must run two distinct trusted identities with real `PeerMesh` and
manual-signaling exports bridged/imported, attach packet consumers, await both
connected states, send control plus multiple bulk packets, compare bytes, and
close both meshes. Then exercise actual delivery consent/revoke and file/hash
verification in the app. Native method channels do not run in host unit tests.
Required: Flutter/Dart from the workspace, Windows C++ Flutter build tools or an
Android SDK/NDK and device/emulator, plus the exact pinned WebRTC native artifacts.
Physical Windows/Android path changes, Doze/FGS and hotspot behavior remain native
acceptance gates, not assertions made by this README.

`VAULT_HOTSPOT` defaults **false**. Setting it true is only the separately prepared
Phase 0 Android native-patch experiment (`spikes/phase0_probe`); the production
package neither installs that override nor disables the normal network monitor
by default. Restart the process after changing a native factory option.
