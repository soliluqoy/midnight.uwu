# Pion interop probe

Local test tool pinned to Pion WebRTC v4.2.24. It sends deterministic synthetic
patterns and verifies SHA-256 in both directions. No user media, public broker,
STUN or TURN server is used. The HTTP control API binds only to loopback; ICE
establishes the actual peer path. SDP/candidate addresses are not persisted.

Run from this directory:

~~~powershell
go test ./... -v -timeout 90s
go build -o bin\vault-interop.exe .
.\bin\vault-interop.exe
~~~

Use spikes/phase0_probe/tool/run-interop.ps1 from another terminal to connect the
Flutter probe to port48933, or a phone forwarded to48932. Each transfer is capped
at256 MiB in this first probe. Reliable ordered critical/bulk channels and one
unreliable unordered ephemeral channel are negotiated. Bulk messages are16 KiB.

This is a Phase0 protocol fixture, not Vault's production protocol. Identity,
approval/capability tokens, reconnect, media-range service and abuse defenses are
not implemented here. It is not yet a calibrated loss/NAT/2GiB test harness.
