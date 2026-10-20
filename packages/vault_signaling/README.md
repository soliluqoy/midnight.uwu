# vault_signaling

Real private connection signaling for Windows/Android Dart IO clients. This package
owns the addressed transport, strict signaling schemas, signed HPKE envelopes,
contact binding enforcement, ACK/retry/replay handling, explicit manual export
queue and opt-in public signed metadata transport. It does **not** own identity
storage, contacts, peer RTC authentication, media/control/grants, directory cache
or UI. Phase 0 remains open; public brokers are untrusted shared test
infrastructure, not an operated Vault backend.

## Dependencies

Workspace Dart SDK `^3.13.5`, `vault_identity`, `vault_protocol`,
`mqtt5_client` **5.1.0**, `typed_data` **1.4.0**, `event_bus` **2.0.1**.
Tests use `package:test`.
Ed25519 signatures and RFC 9180 single-shot HPKE come from `vault_protocol` /
`vault_identity`; no spike imports or application-provided cipher hooks exist.
TLS uses platform trusted roots and hostname verification. There is no plaintext
network transport, accept-bad-certificate, retained publication, TURN, telemetry or
relay fallback. Explicit public presence metadata is signed but unencrypted.

## Usage

```dart
final manual = ManualSignaling();
final signaling = SignalingClient(
  identity: identity,
  strategy: manual,
  resolveBinding: (nodeId) async {
    final cards = await contacts.list();
    for (final card in cards) {
      if (card.nodeId == nodeId) return card.binding;
    }
    return null;
  },
);
final failures = signaling.failures.listen((failure) {
  // Show failure.reason; peerId and sessionId identify affected negotiations.
});
final incoming = signaling.messages.listen(handleConnectionEnvelope);
await signaling.start();
await signaling.send(
  peer: verifiedContact.binding,
  type: MsgType.offer,
  sessionId: fresh16ByteSession,
  payload: {'sdp': completelyGatheredSdp},
);
// Display ALL manual.pendingExports and listen to manual.exports for additions.
// Exchange complete text with the contact, including answer AND ACK exports.
await manual.importText(receivedText);
// Explicitly remove exported ACKs after exchange if desired:
manual.removeExport(exchangedAckText);
// On disconnect: cancel UI subscriptions and close the signaling owner.
await signaling.close();
await incoming.cancel();
await failures.cancel();
```

`send` completes after the first successful transport publish, **not** ACK. This
allows manual UI to show exports immediately. `pendingCount` measures messages
awaiting authenticated ACKs. Later transport/retry failures go to `failures`;
there are no unobserved async retry exceptions. Initial publish errors also fail
`send`. Never display private payloads as diagnostic messages.

For MQTT, replace the strategy with:

```dart
final mqtt = MqttSignaling([
  MqttEndpoint('broker.emqx.io'), // TLS 8883
  MqttEndpoint('test.mosquitto.org', port: 8886),
]);
```

These are ADR 0004's verified **Phase 0** public MQTT5 ports, not a claim of current
availability. Mosquitto 8883 was not reliable with this Dart TLS client; use 8886.
`MqttSignaling.publicTestEndpoints` returns that same ordered list. Peers must
share a working broker; alternatives are **not federated**. Clients on disjoint
brokers do not discover or reach each other. Private topics are
`vault/v1/in/<52-character-base32-nodeId>`; brokers see routing metadata, IPs and
ciphertext sizes, but not plaintext envelopes. Readiness means successful CONNACK
**and SUBACK**, never merely sending SUBSCRIBE. TLS clean sessions, QoS1 and
`retain:false` are mandatory. Reconnect rotates endpoints with full-jitter
400ms–6s backoff. Initial readiness has a 20s deadline; later reconnect remains
active until explicit close. `connectionChanges`, `connected` and sanitized
`diagnostics` report transport state. Call `close` after failed startup too.
MQTT library socket/listener/timer creation and publishes run in guarded zones so
async library write failures reach the failure stream and reconnect handling.

## Exact payload allowlist

All payload maps are validated on **send and receive**. Extra keys, unknown types
and caller-generated ACKs are rejected. Byte limits below count UTF-8, not only
UTF-16 code units.

| Type | Payload |
| --- | --- |
| offer / answer | `{'sdp': String}`; at most 20 KiB complete SDP |
| candidate | `{'candidate': String, 'sdpMid': String?, 'sdpMLineIndex': int?}`; candidate at most 2048 bytes, mid at most 64, index 0–255; optional fields may be omitted |
| hello | `{'nonce': Uint8List(32)}` |
| bye | `{}` or `{'reason': String?}`; reason at most 160 bytes |
| announce | `{'presence': true, 'name': String, 'expires': int}`; name at most 80 bytes, Unix expiry in the next 90s |
| introduce | `{'card': String, 'mac': Uint8List(32)}`; card text at most 2048 bytes |
| ACK (internal only) | `{1: Uint8List(16)}` referencing the original message ID |

Session IDs and message IDs are 16 bytes. ICE generation is 0–2^31−1. SDP may
contain direct-address metadata; sealing prevents the broker from reading it,
not the recipient. Media, private indexes, posters, grants and arbitrary control
maps belong on authenticated RTC channels, never signaling. SDP size limits are
intentional; unusually large candidate sets must be reduced by the RTC owner,
not silently truncated or fragmented through an unrestricted schema.

Private `announce` remains an explicit known-contact API through
`send(type: MsgType.announce, ...)`. Its signed sealed envelope authenticates all
fields, with envelope expiry equal to payload expiry.

## Explicit public MQTT discovery

Only an explicit `await signaling.setPublicDiscoveryEnabled(true)` opts into
`vault/v1/presence/#`. Manual signaling throws `UnsupportedError` when enabling;
it cannot discover public peers and never returns a fabricated discovery list.
Disabling immediately clears client public records/queued work and prevents
in-flight public verification from delivering. MQTT replaces the connection when
changing the public subscription; private retries cover this brief transition.
Enabling on a started connection awaits both private and public SUBACKs.
Already-delivered private messages may emit nonterminal
`signal acknowledgment publish failed` during that transition; the original
sender's retry triggers duplicate reACK, never repeated delivery.

```dart
await signaling.setPublicDiscoveryEnabled(true);
final publicSubscription = signaling.publicPresence.listen((record) {
  // A self-authenticated public identity, NOT an approved contact or access grant.
});
await signaling.announcePublicPresence(
  name: 'Alice', tags: ['films'], sharedCount: 4,
);
final current = signaling.publicPresenceRecords;
await signaling.setPublicDiscoveryEnabled(false);
await publicSubscription.cancel();
```

`publicPresence` emits `PublicPresenceRecord` with `nodeId`, verified `binding`,
`name`, immutable `tags`, `sharedCount`, `epoch`, `sequence`, `expiresAt` and
immutable `signedEnvelope`. The stateless
`verifyPublicPresenceRecord(bytes, now:, expectedNodeId:)` revalidates original
signed cache bytes, including signature, binding, topic signer and expiry; it
does not grant contact trust or replace client replay state. Directory ownership
is `vault_directory`: explicit browse/publish policy, heartbeat, bounded SQLite
cache/search, expiry and UI integration belong there. No automatic contact
creation, connection or media approval occurs.

The separate public allowlist is exactly `presence:true`, `name` (80 UTF-8 bytes),
`tags` (up to eight distinct nonempty strings, each 24 UTF-8 bytes), `sharedCount`
(0–1,000,000), `epoch`, `sequence`, `expires`, `encryptionKey` (32 bytes),
`bindingIssuedAt`, `bindingSignature` (64 bytes). The complete self-signed binding
and signed ANNOUNCE envelope bind the stable identity. No filenames, private
indexes, ACLs, grants, SDP, IP hints or arbitrary extra keys are allowed.
Public envelopes are broadcast ANNOUNCE only, zero session/generation, TTL at
most 90 seconds, current expiry, and a topic derived from the signing identity.
They are never retained or ACKed. Broker topic/signature substitution is rejected.

Public traffic has independent 2 KiB frame, 16 frames/32 KiB per-second and
16 queued-frame bounds, 256 active records and 512 live replay records. Ordering
is lexicographic `(epoch, sequence)`; epoch is process-start Unix microseconds,
sequence increases within that process. Epoch is not persisted identity-rotation
authority and no global monotonic claim is made under clock rollback. Replay
high-water records remain until signed expiry +120 seconds; full replay state
rejects admission instead of evicting live protection. These records remain
separate from private contact lookup and private `messages`.

Public metadata is visible to anyone sharing the broker; topics reveal identity,
and the broker can correlate IPs. Alternative brokers are not federated. Public
records expire without repeat publication, and no broker availability is implied.

## Security, lifecycle and limits

- Incoming signed sender identity must match a verified locally resolved contact
  binding; unknown or changed keys never reach `messages`. Sending also verifies
  that the supplied binding equals the current contact signing/encryption keys.
  A frame from an unknown sender becomes a `SignalingFailure` with
  `kind == SignalingFailureKind.unknownSender` and the authenticated signer as
  `peerId`.
- `introduce` is the one exception. Its binding comes from the payload card,
  whose signing key must equal the envelope signer. The client passes the
  verified `Introduction` to `onIntroduce`, acknowledges it only when the
  callback returns true, and never emits it on `messages`. Without a callback
  it is an unknown sender. At most four introductions per second reach the
  callback; a duplicate is acknowledged again without a second call.
  `introduce(host:, introduction:)` completes when the host acknowledges, or
  fails with `SignalingFailureKind.acknowledgmentTimeout` at the retry
  deadline.
- Complete private signed envelopes are HPKE sealed to the recipient. ACKs are equally
  signed/sealed and bound to expected sender, session and original message ID.
  Replayed accepted messages reACK but never repeat delivery/side effects.
- Every private wire frame is at most **24 KiB**. Before decryption the client limits to
  **64 frames / 256 KiB per second**, an inbound queue of **32**, **128** outgoing
  pending/building messages, and **4096** unexpired replay entries. A full replay
  cache rejects new messages instead of evicting live replay protection. Diagnostic
  notifications are capped at 16/second; terminal send/deadline failures are not
  suppressed by a receive flood. `SignalingFailure.terminal` distinguishes failed
  initial send/start or exhausted ACK deadline from recoverable retry/transport/
  ACK-publication diagnostics. Stream consumers must process promptly rather than
  pause forever.
- CONNECT advertises a **26 KiB maximum MQTT packet size**. A bounded TLS adapter
  scans fragmented Remaining Length before calling the dependency's buffer
  accumulation, rejecting oversized declared packets before body buffering.
  Coalesced/unconsumed input is capped at **52 KiB**, and unsolicited QoS2 is
  rejected before growing dependency receive state. MQTT's outgoing unacknowledged
  QoS1 publication queue is capped at **128**. These are enforced even when a
  malicious broker ignores the advertised maximum; not merely post-allocation
  application payload checks.
- Retry deadline defaults to **2 minutes** for MQTT, **10 minutes** for manual;
  constructor override is limited to 15 minutes. Retries back off to 10 seconds
  plus jitter. Envelope validity covers the retry window plus 30 seconds.
  Per-call publish and contact resolution have 5s bounds. ACK deadline failures
  are asynchronous and identify the peer/session. ACKs themselves are not ACKed.
- Close cancels retry timers/reconnect and queued work, cancels in-flight contact/
  crypto waits from the caller's perspective, and closes transport and streams.
  The client bounds strategy shutdown to 2s and never waits for a UI's paused
  stream subscription. Closed objects cannot restart. Underlying cryptographic
  operations may finish but cannot publish or deliver after close.
- Manual exports are complete versioned addressed `vault-signal:1:` text with
  optional gzip and base64url. No short-code rendezvous service is fabricated.
  Import text is at most **40 KiB**, compressed input/output at most **24 KiB**,
  with incremental bounded decompression (bombs rejected). Wrong recipients and
  malformed versions/codecs are rejected. Manual export queue is **128** frames,
  identical retry exports are coalesced, and `pendingExports` is an immutable
  snapshot. Authenticated ACK removes the associated outgoing export; ACK
  exports and timed-out frames remain until explicit `removeExport`. `close`
  clears this in-memory queue. It is not durable across process restart: UI must
  preserve exchanged text explicitly if needed and create a fresh negotiation
  after expiry. Manual exchange still needs a reachable direct RTC path.
- Global rate budgets can be starved by a malicious broker/client flood. Contact
  verification is not automatic social trust or permission to access media.
  Retry/replay state is in memory; session freshness/authentication belongs to
  `vault_net`. No operational broker availability or physical-network claims are
  made by this package.

## Behavioral checks

`test/signaling_test.dart` exercises real seeded identities and actual Manual
sealed-frame offer/answer/ACK flow, dropped ACK duplicate reACK, unknown contacts,
schema/media bypass rejection, malformed ciphertext, bounded decompression,
private presence, asynchronous stream/retry failures, recoverable ACK-publication
transition failures and close cancellation.
`test/public_presence_test.dart` additionally covers real signatures/bindings,
unknown public identity discovery without private trust, replay rejection,
signature/topic/expiry/schema rejection, signed-cache revalidation and explicit
Manual unsupported behavior. `test/mqtt_packet_buffer_test.dart` covers oversized
fragmented Remaining Length rejection before body accumulation, coalesced limits
and legitimate packet parsing. In-process transports force failure/drop/public
delivery conditions; crypto/schema/client behavior is real. No live broker is
needed for these deterministic tests. Integration owner runs `dart test
packages/vault_signaling/test` and workspace analysis after convergence; native
MQTT and RTC smoke/physical-network gates are separate, not claimed here.
