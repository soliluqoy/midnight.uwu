# vault_identity

Experimental pure-Dart Ed25519 identity, bound X25519 encryption keys and RFC 9180
HPKE base mode (HKDF-SHA256 / ChaCha20-Poly1305), using `cryptography` 2.9.0.
There is no Flutter dependency or runtime import from the Phase 0 spike. This
is not independently audited cryptography; physical Phase 0 gates remain open.

## Public API

Import `package:vault_identity/vault_identity.dart`.

- `Identity.fromSeeds`, `Identity.generate`, immutable `signingPublic`, `nodeId`,
  `encryption`, `sign`, and signed `binding(issuedAt:)`.
- `KeyBinding.verify`, `verifyEd25519`, `nodeIdOf`, `nodeIdText` and
  `nodeIdFromText`. Text IDs are strict lowercase RFC 4648 base32, no padding.
- RFC-vector-backed `hpkeDeriveKeyPair`, `hpkeNewKeyPair`, `hpkeSeal`, `hpkeOpen`.
- Inject `SecretStore` into `IdentityRepository`; `loadOrCreate()` persists both
  independent 32-byte input seeds before exposing an identity.
- `ContactCard.create(identity, name:)`, `fromBinding(binding, name:)`, `encode()`,
  `decode(text)`; `ContactRepository(store).list()`, `.add(card)`, `.remove(nodeId)`.

Contacts contain only public keys, signed binding, derived node ID and a display
name. The name is an unauthenticated label, never an identity assertion: compare
the complete node ID through an independent trusted channel before trusting a
contact. Import rejects forged bindings, mismatched IDs, extra fields, invalid
key sizes, names exceeding 128 UTF-8 bytes, and text exceeding 16 KiB. Stored
contact lists are bounded to 512 entries and are reverified when loaded.

## Protected storage and key lifecycle

`SecretStore` must provide protected confidentiality/integrity, atomic replacement
of each value, durable successful writes and surfaced failures. The app injects
native secure storage; plaintext files and shared preferences are not valid
implementations. Repositories sharing one store object serialize operations.
Use one store instance and one writer isolate/process; the interface cannot
provide cross-process transactions. Store namespace keys are package-owned.

Malformed records and missing seed records with an existing creation marker
fail closed. A storage error never falls back to an ephemeral identity, overwrites
corrupt seeds, or automatically generates a replacement. If an entire protected
store is erased, it is indistinguishable from a genuinely new installation;
restoring an old public contact does not restore its private identity.

There is deliberately no automatic reset, exportable plaintext backup, signing
key rotation or encryption-key rotation API. Back up/migrate the complete native
protected store only using a platform mechanism that preserves its protection
and both seeds; unsupported migration must be presented as unavailable. Retain
the original store if migration fails. An explicit destructive app/OS reset or
unrestored reinstall creates a new identity and requires all peers to compare
and trust the new ID again. Do not replace individual seed values to “repair”
storage. Future key rotation requires an explicit authenticated migration and
contact re-verification, not a background key replacement.

Static recipient-key compromise permits decryption of recorded sealed messages;
HPKE base mode here does not promise forward secrecy across sessions. Private
key bytes exist in process memory and Dart does not guarantee their zeroization.
The low-level HPKE key-pair API intentionally remains available for vectors;
never serialize its private key into contacts or capabilities.

## Regression coverage

Tests preserve RFC 8032 and RFC 9180 vectors and exercise injected-store restart,
concurrent identity loads, missing/corrupt protected records, contact tampering,
canonical node IDs and immutable authentication bytes. Integration owner runs
`dart test packages/vault_identity/test` after workspace resolution.

