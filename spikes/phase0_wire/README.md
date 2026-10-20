# Vault Phase 0 crypto and wire spike

Throwaway pure-Dart code behind [ADR 0003](../../docs/adr/0003-crypto-and-wire-profile.md).
It is not the production `vault_identity` or `vault_protocol` package.

```powershell
dart pub get
dart analyze
dart test
```

`test/vectors.json` holds golden bytes from fixed test seeds. Regenerate it only
on purpose with `dart run tool/write_vectors.dart`; the golden test fails on drift.
The seeds are public test keys. Not independently audited.
