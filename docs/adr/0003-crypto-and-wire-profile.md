# ADR 0003: Crypto, identity and wire profile

Date: 2026-10-18. Status: accepted for the experimental core. The original
pure-Dart spike profile is promoted into `vault_identity` and `vault_protocol`;
the package READMEs document current APIs and verification. No independent
cryptographic review has been done.

## Context

The build plan (sections 2.3, 2.5, 5) requires an established encryption
construction with vectors, a deterministic inner encoding, replay defenses and
owner-minted grants before Phase 1. Public MQTT brokers see all signaling, so
addressed SDP/candidates must be end-to-end encrypted to a key bound to the
verified identity, and the complete inner envelope must be signed.

## Decisions

| Area | Decision | Evidence |
|---|---|---|
| Library | `cryptography` 2.9.0 (pure Dart, no native code), keeping `vault_identity` and `vault_protocol` pure Dart | `spikes/phase0_wire/pubspec.lock` |
| Signatures | Ed25519 (RFC 8032), 32-byte keys, 64-byte signatures | RFC 8032 test 1 reproduced |
| Encryption | HPKE (RFC 9180) base mode: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305, single-shot | RFC 9180 A.2 keys, `enc` and sequence-0 ciphertext reproduced; open verified |
| Sender authenticity | Inner Ed25519 signature over the whole envelope, then HPKE seal (sign-then-encrypt). HPKE auth mode is not used | Sealed round trip, tamper and redirect tests |
| Inner encoding | Strict deterministic CBOR subset (RFC 8949 4.2.1): ints, bstr, tstr, arrays, int/text-keyed maps, bool, null | 29 RFC 8949 appendix A vectors; 20 rejection vectors |
| nodeId | SHA-256(`vault/v1/node-id` ‖ Ed25519 public key), 32 bytes; text form is lowercase RFC 4648 base32 without padding | Golden vector |
| Encryption key binding | Ed25519 signature over domain `vault/v1/key-binding` ‖ CBOR{1: ed key, 2: x25519 key, 3: issuedAt} | Forged key and wrong-node tests |
| Grants | HMAC-SHA256 over `vault/v1/grant` ‖ canonical CBOR of version, owner, viewer, grantId, resource, actions, issuedAt, expiresAt, epoch; minting key stays with the owner | Golden MAC; 8 rejection cases |

### Why a custom CBOR subset

The package decoders do not enforce every canonical rule (minimal integers, key
order, duplicate keys, nesting and length limits). The subset is about 200 lines,
is checked against the RFC vectors, and rejects everything outside it, including
floats, tags, indefinite lengths and non-minimal integers.

### Envelope

`version(1) | type(2, big-endian) | sender Ed25519 key(32) | signature(64) | CBOR body`.
Body map keys: 1 recipient nodeId or null (broadcast), 2 messageId(16), 3 sessionId(16),
4 issuedAt, 5 expiresAt, 6 ICE generation, 7 payload map. The signature covers
`vault/v1/envelope\0 ‖ version ‖ type ‖ sender key ‖ body`.

Rejection order: size, version, type, strict CBOR, field types, signature,
validity window (at most 3600 s), clock skew of 120 s. Recipient, session and
replay checks follow through a bounded `(sender, messageId)` cache and run before
any side effect. The 120 s skew allowance does not replace replay prevention.

### Sealed signaling

`version(1) | 0x0100(2) | recipient nodeId(32) | enc(32) | ciphertext`. HPKE
`info` is `vault/v1/sealed\0 ‖ recipient nodeId`; `aad` is the three header bytes
plus the recipient nodeId. The plaintext is the signed inner envelope, so the
sender identity is hidden from the broker. A sender refuses to seal unless the
recipient key binding verifies and matches the recipient nodeId.

## Consequences and limits

- Compromise of a recipient's static X25519 key decrypts every sealed message
  sent to it. Normal restart preserves identity and authorization epoch. There is
  no automatic key reset, rotation or secret export; protected-store loss without
  an OS-restored backup means a new identity and fresh approvals.
- `vault_net` implements fresh mutual session challenges bound to both complete
  signed SDPs, DTLS fingerprints, identities, session and ICE generation.
- Owner minting keys, active grants, revocations, blocks and epochs are atomically
  persisted through the injected protected store. Revocation commits before
  affected transfer cancellation/session closure. The app enforces one writer.
- The package is not audited and pure-Dart timing behavior is not claimed constant-time.
  Equality checks on MACs in the spike are byte-wise constant-time by construction.
- Nostr remains a separate gated adapter requiring exact NIP-44 v2 and its own vectors.
- The 100% coverage target remains an acceptance target; adding vector tests does not prove it.

## Reproduce

```powershell
cd spikes/phase0_wire
dart pub get
dart analyze
dart test
dart run tool/write_vectors.dart   # only to regenerate test/vectors.json deliberately
```
