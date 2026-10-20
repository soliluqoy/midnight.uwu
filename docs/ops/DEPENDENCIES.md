# Dependency status and native core pins

Checked 2026-10-18. "Published candidate" means registry metadata was verified;
it does not mean the graph resolves together or that native plugins build/run.
Do not copy this table into an app pubspec and call it validated.

## Resolved repository tooling

| Dependency | Exact pin | Purpose and evidence |
|---|---|---|
| Flutter / Dart | 3.47.7 / 3.13.5 | Installed SDK; empty-template native builds are recorded in ENVIRONMENT.md |
| melos | 8.9.0 | Local workspace orchestration; dart pub get and bootstrap passed |
| very_good_analysis | 11.0.0 | Shared strict lints; needs Dart >=3.13 |

Root pubspec.lock is committed evidence of the resolved tooling graph.
All eventual workspace members need resolution: workspace. Code generators and
test dependencies belong to their actual consumers when introduced.

## Exact initial spike pin

| Dependency | Pin | Why |
|---|---|---|
| flutter_webrtc | 1.6.2+hotfix.4 | Android/Windows transport candidate; Windows/Linux engine m150.7871.03 |

This pin is installed in the throwaway [native probe](../../spikes/phase0_probe/README.md).
Both native targets build, loopback and cross-device synthetic transfers pass.
Android hotspot testing uses a recorded local source override; the production
dependency graph remains unfrozen.
[Publisher metadata](https://pub.dev/api/packages/flutter_webrtc),
[changelog](https://pub.dev/packages/flutter_webrtc/changelog).

The probe jointly resolves media_kit1.2.6, media_kit_video2.0.1,
media_kit_libs_video1.0.7 and crypto3.0.7 in its own pubspec.lock. Resident-fixture
playback/seeks pass on both targets; sparse P2P playback and audible output remain
unproven. Go interop pins Pion4.2.24 with go.mod/go.sum. FFmpeg Essentials9.0.1
is a developer-only synthetic fixture tool. See [ADR 0002](../adr/0002-phase0-native-findings.md)
for native artifacts, local patches and remaining gates.

## Crypto and wire spike pin

| Dependency | Pin | Why |
|---|---|---|
| cryptography | 2.9.0 | Pure-Dart Ed25519, X25519, HMAC, ChaCha20-Poly1305 for the Phase 0 [wire spike](../../spikes/phase0_wire/README.md); RFC 8032 and RFC 9180 vectors pass. See [ADR 0003](../adr/0003-crypto-and-wire-profile.md). Not audited. |

## MQTT signaling spike pins

| Dependency | Pin | Why |
|---|---|---|
| mqtt5_client | 5.1.0 | MQTT 5 client in the Phase 0 [MQTT spike](../../spikes/phase0_mqtt/README.md); works on Windows against two brokers. Leaks `SocketException` when a broker dies, so it needs a guarded zone. Android not tested. |
| mochi-mqtt/server/v2 | v2.7.9 (Go) | Local test broker in `tools/mqtt_testbroker`; test infrastructure only. |

## Resolved native core graph

User-directed sequencing revision: [main plan section6.3](../../P2P_VIDEO_SHARE_BUILD_PLAN.md#63-implementation-first-sequencing-revision).
The root workspace lockfile resolves the actual app and all nine service/UI
members. Resolution is observed; native runtime/build evidence is recorded
separately in the app README and does not pass the broader feasibility matrix.

| Dependency | Exact pin | Core purpose |
|---|---|---|
| file_selector | 1.1.0 | Windows native source/import/save pickers |
| shared_preferences | 2.5.6 | Non-secret configuration only; never identities or owner minting keys |
| flutter_secure_storage | 11.2.0 | OS-protected identity and owner-authorization records; Android reset-on-error disabled |
| cryptography | 2.9.0 | Pure-Dart RFC-profile identity/encryption/signatures and grant MACs |
| mqtt5_client | 5.1.0 | TLS MQTT5 private signaling and opt-in public presence |
| flutter_webrtc | 1.6.2+hotfix.4 | Single native direct-session adapter seam; no TURN |
| sqlite3 | 3.7.1 | Native-assets SQLite index and directory persistence; no sqlite3_flutter_libs |
| path_provider | 2.1.6 | Private application support/cache directories |
| media_kit | 1.2.6 | Native original-file/loopback Range playback |
| media_kit_video | 2.0.1 | Native video surface/controller |
| media_kit_libs_video | 1.0.7 | Android/Windows playback artifacts |
| crypto | 3.0.7 | Streaming content/chunk SHA-256 |
| camera | 0.12.1 | Android pairing-code scanner only; resolves `camera_android_camerax` 0.7.5+1 (AndroidX CameraX). No Windows implementation is added |
| zxing2 | 0.2.4 | Pure-Dart QR encoding of the pairing code and decoding of camera frames |
| vault_* | workspace paths | Explicit real-service boundaries and shared theme |

The pairing scanner was added on 2026-10-20 under the owner-approved
[connection setup decision](../adr/0005-connection-setup-ux.md). Android asks
for the camera permission only when **Scan pairing code** opens the camera.
The app manifest removes the `RECORD_AUDIO` and `WRITE_EXTERNAL_STORAGE`
permissions that the CameraX plugin declares for video recording, and marks
the camera feature optional. Frames are decoded on the device by `zxing2`;
no Google Play services or ML Kit component is in the graph.
[Camera metadata](https://pub.dev/api/packages/camera),
[zxing2 metadata](https://pub.dev/api/packages/zxing2).

[File selector metadata](https://pub.dev/api/packages/file_selector),
[preferences metadata](https://pub.dev/api/packages/shared_preferences).
Flutter/Material is the UI framework; no remote fonts, analytics, router or
state-management dependency is added. Lora is bundled under the SIL OFL with
its license; illustrative photos are bundled with Unsplash attribution.

Resolution and developer builds do not clear release licensing/signing,
source-provider behavior, audible playback, direct Internet connectivity,
service lifecycle or independent cryptographic review.

Windows `flutter_secure_storage_windows` requires ATL for the active v143 MSVC
toolset (`atlstr.h` and `atls.lib`). The core Windows build exposed this missing
prerequisite; older empty/UI builds did not exercise it. The ordinary verifier
now checks it, and `tools/setup/install-windows-atl.ps1` adds only that component
to the existing VS2022 instance with administrator authority. No plaintext
fallback, shared-cache patch or SDK reinstall is used.

## Production candidates and remaining proof

| Candidate | Observed version | Required validation |
|---|---|---|
| mqtt5_client | 5.1.0 | MQTT5, TLS/WSS, broker acknowledgments, loss/redundancy |
| media_kit | 1.2.6 | Android/Windows backend, Range feed, audio and seek |
| media_kit_video | 2.0.1 | Video integration with chosen backend |
| media_kit_libs_video | 1.0.7 | Complete native libraries; artifacts/licensing/distribution |
| drift | 2.35.2 | SQLite3 integration, crash recovery, migrations |
| blake3_dart | 1.0.0 | Correctness vectors, maturity, bounded-isolate/native alternatives, throughput |
| workmanager | 0.10.10 | Deferred maintenance only, subject to OS quotas |
| window_manager / tray_manager | 0.5.2 / 0.8.0 | Distinct window/tray APIs; autostart/single-instance still need design |

Sources: [MQTT5](https://pub.dev/api/packages/mqtt5_client),
[player](https://pub.dev/api/packages/media_kit),
[video](https://pub.dev/api/packages/media_kit_video),
[native libraries](https://pub.dev/api/packages/media_kit_libs_video),
[Drift](https://pub.dev/api/packages/drift),
[BLAKE3 candidate](https://pub.dev/api/packages/blake3_dart),
[Workmanager](https://pub.dev/api/packages/workmanager),
[window control](https://pub.dev/api/packages/window_manager),
[tray](https://pub.dev/api/packages/tray_manager).

State orchestration uses explicit service composition rather than a global
service locator. Identity/wire decisions are in ADR0003; MQTT findings in ADR0004.
Protected storage fails closed and the app enforces a process-level writer lock.
Release licensing, both-platform runtime evidence and broader fuzz/security
coverage remain required; dependency names alone establish none of those.

## Rejected starting entries

- flutter_windowmanager 0.2.0 requires Dart <3.0 and cannot resolve with this SDK.
- The package named blake3 was not available in the checked registry. A similarly
  named alternative is not automatically a mature replacement.
- sqlite3_flutter_libs 0.6.0+eol is obsolete/no-op with SQLite3 3.x; omit when using
  the current Drift/SQLite integration.
- mqtt_client is MQTT3.1/3.1.1; do not claim MQTT5 behavior from it.
- video_player alone supplies no Windows backend.
- crypto is a package, not a Dart built-in library.
- Sentry, Firebase, analytics and remote crash/configuration packages are forbidden.
- Barcode scanners built on Google ML Kit (for example `mobile_scanner` on
  Android) are rejected: ML Kit reports usage to Google, which is telemetry.
- flutter_zxing 3.1.0 was not chosen: it adds a native zxing-cpp FFI build on
  each platform, including Windows, and depends on `image_picker`. The
  pure-Dart `zxing2` reader needs neither.
- The `qr` package is unnecessary because `zxing2` also encodes QR codes.

See the [platform research](../../research_notes/Vault%20prebuild%20architecture%20audit/platform.md)
for official metadata, SDK floors and unresolved compatibility questions.
