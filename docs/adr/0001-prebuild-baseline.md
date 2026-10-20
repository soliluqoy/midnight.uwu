# ADR 0001: Prebuild baseline and gates

Date: 2026-10-18. Status: accepted prebuild correction; empirical gates remain open.

## Context

The original scaffold described an approved direct media library but included
cryptographic errors, unverified platform promises, contradictory TURN support,
obsolete dependency/workspace instructions and installation checks that could
ignore failed commands. The user requested research, tool verification and fixes
before starting implementation. See the [sourced audit](../../reports/Vault%20prebuild%20architecture%20audit.md).

## Decisions

Preserve the strongest existing product constraints: no operator backend/accounts,
direct-only media and zero product telemetry. TURN is excluded from v1, including
user-supplied settings. Public listing is explicit opt-in and best effort. Optional
future TURN requires an explicit constraint change; it is not silently introduced.

Prioritize authenticated byte-range VOD with seek on Android and Windows. Optional
live file broadcasting must prove actual source/audio injection, hardware/CPU
behavior, encoding reuse and cap-respecting fan-out. It can be removed if infeasible.

Correct the protocol: Ed25519 signatures are 64 bytes; the HMAC minting secret stays
with the owner; grants are viewer/resource/epoch-bound and revocations persisted.
Authenticate sessions against signed SDP/fingerprints. Require deterministic inner
encoding, replay/idempotency rules and adversarial vectors before Phase 1.
Nostr requires a separate bound secp256k1 identity and exact protocol encryption.
Addressed public-relay signaling needs end-to-end encryption, not merely TLS.

Critical control uses a reliable channel. A 256 KiB integrity chunk is application-
fragmented into bounded messages <=16 KiB including headers and negotiated limits.
Backpressure polls the native getBufferedAmount method, not the cached property.
Typed signaling allowlists and direct selected-pair assertions enforce media routing.

Use a bounded common-endpoint pilot directory. Remove unsupported node-hash/text
sharding, global completeness claims and fake bootstrap assumptions. Define public
metadata, expiry, deduplication and abuse budgets before scaling.

Android background availability is a Phase 0 product gate. Choose valid FGS types,
test physical Android 15/16 service budgets and Doze, and disclose supported modes.
State survives suspension; uninterrupted inbound reachability is not assumed.
SAF sources are URI handles with explicit permission/seekability failures.

Correct budget arithmetic: a 20 Mbps path at a 70% cap budgets 14 Mbps; the former
high-rung estimate permits at most four viewers, before extra margin. Six is a hard
session ceiling. Index enumeration, metadata, thumbnails and hashing have separate
budgets; no fabricated combined 20k-item/60s claim.

Use exact locally resolved Melos 8.9.0 and lints 11.0.0 with Dart >=3.13.0.
The production workspace is tooling only. Defer generators/runtime dependencies until a
joint resolved graph and exact-plugin Windows/Android native builds pass.
Installation checks fail on required-component/native-command failures. Separate
tools-only success, empty-template builds, plugin compatibility and Phase 0 evidence.

## Consequences and open decisions

The plan now supports a defensible first product path, with explicit reachability
and availability limits. It does not constitute completed protocol design or a
claim that Phase 0 passed. Freeze cryptographic library/key storage/wire profile,
player/cache adapter, source hashing, service types, exact dependencies and test
fixtures in follow-up ADRs before feature code. Initial native probes and Go interop
were subsequently implemented; see [ADR 0002](0002-phase0-native-findings.md).
Feature CI remains unimplemented.

Already received media cannot be recalled; reinstallation with a fresh identity
requires new approval. This is part of the consent model, not a defect to hide.
