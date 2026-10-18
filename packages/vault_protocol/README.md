# vault_vault_protocol

Wire format and message schemas: versioned MessagePack envelope, Ed25519 signing, HMAC capability tokens, topic scheme, all named constants. Pure Dart, zero Flutter imports.

## Contract

- Zero Flutter imports.
- 100% test coverage target (mandated by section 8).
- Golden wire vectors: encode -> decode -> byte-identical, plus rejects-unknown-version and rejects-bad-signature.
- Fuzz entry point lives here.

