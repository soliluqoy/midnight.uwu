# vault_protocol

Experimental pure-Dart strict deterministic CBOR, signed/sealed envelopes and
durable owner-minted capabilities. Depends on `vault_identity`, never the reverse.
No runtime imports from the throwaway Phase 0 spike; its frozen byte vectors are
preserved in `test/vectors.json`. Not independently audited; Phase 0 stays open.

## Wire contract

Import `package:vault_protocol/vault_protocol.dart`; identity and HPKE types are
imported directly from `package:vault_identity/vault_identity.dart`.
`cborEncode` / `cborDecode` implement the RFC 8949 deterministic
subset: integers, byte/text strings, arrays, integer/text-keyed maps, booleans,
null. Reject non-minimal integers, duplicate/unsorted keys, invalid UTF-8, tags,
floats, indefinite lengths, trailing bytes and out-of-range integers. Limits:
64 KiB document, depth 8, 1024 total values including map keys.

`Envelope`, `encodeEnvelope`, `decodeEnvelope`, `EnvelopeChecks`, `seal`, `open`,
`MsgType`, `WireReject`, `Grant`, `OwnerState` and `authorize` retain the proven
profile from ADR 0003. Types remain hello=1, offer=2, answer=3, candidate=4,
announce=5, bye=6, ack=7, introduce=8. Full inner bytes are signed before
HPKE sealing.
Envelopes are at most 32 KiB; validity is at most 3600 seconds with 120 seconds
clock skew. Authentication bytes and nested payload collections are detached
read-only snapshots. Call `EnvelopeChecks.accept` after signature verification,
with the expected session, before any side effect. It rejects recipient/session
misbinding and replays with a bounded cache (4096 default; exhaustion rejects).
Expired messages cannot reenter after cache eviction.

The envelope layer does not authorize arbitrary payloads: `vault_signaling`
owns the strict per-message connection/presence schema allowlist and forbids media,
library and grant payloads on signaling. The in-memory replay cache is not a
durable inbox. Networking must create fresh authenticated sessions/challenges
after restart and reject packets for old sessions; timestamps alone are not a
restart replay defense.

## Pairing

`PairingInvite` is a host's verified contact card, broker host and port, a
32-byte token and an expiry. `encode` returns `vault-pair:1:<base64url CBOR>`.
`PairingInvite.parse(text, now:)` accepts at most 1024 characters, exact CBOR
keys, a verifying card, a DNS host name and an expiry no more than
`pairingLifetimeSeconds` (600) plus 120 seconds of clock skew ahead. It throws
`PairingCodeExpired` for a stale code and `FormatException` otherwise.
`Introduction.create` computes
`HMAC-SHA256(token, "vault-introduce-v1" ‖ recipient nodeId ‖ card bytes)`.
`Introduction.fromPayload` requires the card's signing key to be the envelope
signer. `ActivePairing` holds the host's in-memory token; `redeem` compares
the MAC in constant time, succeeds once, and does not consume the token on a
wrong MAC. See [ADR 0005](../../docs/adr/0005-connection-setup-ux.md).

## Durable authorization

`AuthorizationRepository(SecretStore, Identity)` requires `await load()`.

- `approve(viewerId:, resource:, actions:, lifetime:)` returns `GrantedAccess`;
  lifetime defaults to 24 hours and is bounded to 30 days.
- `check(access:, viewerId:, resource:, action:)` checks authenticated viewer,
  owner, HMAC, exact resource/action, time, persisted epoch, block/revocation and
  the persisted active-grant whitelist. Check each protected operation/chunk.
- `revoke(base64Url.encode(grant.grantId))` revokes a single capability.
- `revokeViewer(viewerId)` revokes all existing grants for a peer but permits
  later explicit approval; `block(viewerId)` also forbids new approvals.
- `unblock(viewerId)` permits new approval but never restores previous tokens.
- `revokeAll()` advances the persisted epoch and invalidates all prior tokens.
- `changes` emits the affected grant/peer ID or `epoch`; `close()` closes it.

`GrantedAccess(grant:, mac:)`, `toJson()` and `GrantedAccess.fromJson(map)` contain
public claims and MAC only, never the owner minting key. Grant bytes/actions are
immutable. Grants are reusable scoped capabilities, not single-use request IDs;
authenticated transport must separately reject packet/request replays.

One atomic protected-store record persists the owner-only random minting key,
stable epoch, active public grants, bounded revocation metadata and blocked
viewers. Valid unrevoked grants survive restart. Revoked/blocked tokens and tokens
from an explicitly invalidated epoch remain rejected after restart. Updates are
serialized across repositories sharing one store object; each operation rereads
durable state to avoid stale-instance lost updates. Revocation/block persistence
finishes before success is reported. On write failure, the repository stops
authorizing; callers must surface failure and close affected streams, not claim
revocation succeeded. Previously durable state remains authoritative on restart.

The `SecretStore` requirements and key backup/reset policy in `vault_identity`
apply. Use one protected store instance and one writer isolate/process. A missing
authorization record with its creation marker is an error, never a reminted key.
There is no automatic minting-key rotation or policy reset. Bounds are 4096 active
grants, 4096 blocked viewers, 4096 historical revoked IDs and 8 MiB protected
record. Expired history can be pruned without reviving tokens because the active
whitelist and MAC/expiry/epoch checks remain authoritative. Native storage errors
and size limits are surfaced rather than bypassed.

## Regression coverage

Preserved RFC 8949 positive/rejection vectors and golden envelope/binding/HMAC/
HPKE bytes, plus recipient/session/replay/tamper/scope checks, immutable snapshots,
injected-store restart, valid grant persistence, revoke/block/reapprove,
revoke-all epochs, concurrent approvals and failed atomic writes. Integration
owner runs `dart test packages/vault_protocol/test` after workspace resolution.

