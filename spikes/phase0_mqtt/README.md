# Vault Phase 0 MQTT signaling spike

Throwaway Dart probe for [ADR 0004](../../docs/adr/0004-mqtt-signaling-findings.md). It uses the
[wire spike](../phase0_wire/README.md) for sealed, signed envelopes. Not the production package.

Build the local test broker once (Go, TLS, one test credential, `vault/v1/` only, no retain):

```powershell
cd tools/mqtt_testbroker
go build -o mqtt-testbroker.exe .
```

Run a scenario from this directory (it starts and stops its own brokers on 18883/18884):

```powershell
dart pub get
dart analyze
dart run bin/mqtt_probe.dart <auth|loss|failover|abuse|discovery|public> out.json
```

`public` contacts broker.emqx.io and test.mosquitto.org with a 32-byte synthetic payload.
Generated test certificates and keys live under `build/` and are git-ignored.
