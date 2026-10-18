# Vault

**Serverless, autonomous P2P video & photo sharing — Android + Windows, zero servers we operate.**

Each user runs the app on their own device, points it at a local media folder, and publishes that
folder. Anyone allowed can search for them and stream on demand, with seek. Media bytes move
directly peer-to-peer over WebRTC; the only third party ever touched is a public signaling relay.

The full specification is [`P2P_VIDEO_SHARE_BUILD_PLAN.md`](P2P_VIDEO_SHARE_BUILD_PLAN.md).
The repository layout with one-line responsibilities is [`docs/FILE_TREE.md`](docs/FILE_TREE.md).

---

## Hard constraints (non-negotiable, §1)

1. No backend we write, host, or pay for.
2. All media bytes flow peer-to-peer over WebRTC. Never through a third party.
3. No account. Identity is a locally generated keypair.
4. Offline-tolerant, restart-tolerant, network-flap-tolerant.
5. Consistent experience on Android and Windows.
6. Consent is owner-enforced *and* viewer-enforced.
7. No telemetry, no analytics, no crash reporting, no remote config — ever.

---

## Repository layout

```
apps/vault/          the only shippable app (Android + Windows runners)
packages/
  vault_identity/    Ed25519/X25519 keys, nodeId, safety numbers, QR
  vault_protocol/    wire format, message schemas, signing, HMAC capability tokens
  vault_signaling/   SignalingStrategy + MQTT / Nostr / Manual
  vault_net/         PeerMesh, negotiation queue, ICE/STUN, data channels, stats
  vault_directory/   announce / shard / gossip / presence cache / ranking
  vault_media_index/ scanner, watchers, BLAKE3, metadata, thumbnails
  vault_delivery/    ChunkedFileSource, LiveTranscodeSource, UplinkGovernor
  vault_player/      playback, seek, progressive source, stats
  vault_ui/          design system, screens, debug overlay
tools/
  interop_harness/   Go + pion/webrtc as the other side of every connection test
  netem/             clumsy (Windows) + tc netem (WSL2) link shaping
  setup/             toolchain install + verification scripts
spikes/              Phase 0 feasibility spikes, each with a written result
docs/adr/            every non-obvious decision, written down before code
```

**Layering rule (§4):** `ui → (directory, delivery, player) → (net, signaling, media_index) → (protocol, identity)`.

* `vault_protocol` and `vault_identity` have **zero** Flutter imports.
* `flutter_webrtc` is imported by exactly **one** file: `packages/vault_net/lib/src/webrtc_adapter.dart`.

---

## Prerequisites

See [`docs/ops/ENVIRONMENT.md`](docs/ops/ENVIRONMENT.md) for the full manifest and
`tools/setup/verify-toolchain.ps1` for a machine-checkable go/no-go.

| Tool | Why | Installed to |
|---|---|---|
| Flutter 3.47.7 (Dart 3.13.5) | one codebase for Android + Windows with WebRTC | `C:\dev\flutter` |
| VS 2022 Build Tools (VCTools) | `flutter build windows` needs MSVC + Windows SDK | `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` |
| JDK 17 (Temurin) | Gradle / Android toolchain | `C:\dev\jdk17\jdk-17.0.20.1+1` |
| Android SDK (platform 36, build-tools 36.1.0, NDK 29, emulator, system image) | Android build + second test node | `C:\dev\android-sdk` |
| Go 1.27 | `tools/interop_harness` (pion/webrtc, vnet, bwe-test) | `C:\Program Files\Go` |
| CMake + Ninja | native/FFI builds (ReadDirectoryChangesW, thumbnails) | `C:\Program Files\CMake`, `...\Ninja` |
| clumsy 0.3 | Windows link shaping for spikes 2 & 5 | `C:\dev\tools\clumsy` |
| Git | — | `C:\Program Files\Git` |

Verify everything at once (run elevated):

```powershell
powershell -ExecutionPolicy Bypass -File tools\setup\verify-toolchain.ps1
```

---

## Running

```bash
# once
flutter doctor
flutter doctor --android-licenses

# Windows desktop
flutter run -d windows

# Android
flutter devices
flutter run -d <device-id>

# analysis + tests (quality gates, §8)
dart analyze --fatal-infos
flutter test
```

Bootstrap the monorepo once Dart is on PATH:

```bash
dart pub global activate melos
melos bootstrap
```

---

## How it works, in one paragraph

A node publishes a 30 s `ANNOUNCE` heartbeat over MQTT (or Nostr, or QR/manual) to a sharded
presence topic. Peers cache announcements in local SQLite with a 90 s TTL. A searcher publishes a
bloom-filter `QUERY`; matching nodes unicast their records back, and gossip keeps the directory
self-healing with no index operator. When a viewer wants media, the owner sees an Approve/Deny
prompt; approval issues an HMAC capability token scoped to one media id, level and expiry, and the
byte stream is served as 256 KiB chunks over a reliable ordered DataChannel — never transcoded,
never relayed.

---

## Current status

Phase 0 — feasibility spikes. No application code has been written yet, deliberately.
The plan says to kill or re-plan here, not later.