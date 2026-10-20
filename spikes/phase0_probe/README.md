# Vault Phase 0 native probe

Throwaway feasibility code for Windows and a physical Android phone. Uses only
generated H.264/AAC fixtures and deterministic test bytes. No camera, microphone,
gallery, public signaling, account or operator service is used.

## Exact dependencies

Flutter3.47.7/Dart3.13.5, flutter_webrtc1.6.2+hotfix.4, media_kit1.2.6,
media_kit_video2.0.1, media_kit_libs_video1.0.7, crypto3.0.7; transitive native
artifacts/checksums are captured by pubspec.lock and the result record. Windows
WebRTC artifact is m150.7871.03. Android native libraries are resolved by Gradle.
Android uses150.7871.01. A reproducible local source override adds only the
experimental Android disableNetworkMonitor factory option; its upstream package
and source hashes are in tool/prepare-webrtc-hotspot.ps1 and the result provenance.

## Prepare and build

Install FFmpeg Essentials9.0.1 (fixture generation only; not bundled in Vault),
Android platforms35/36, NDK28.2.13676358 and SDK CMake3.22.1. In this directory:

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tool\create-fixtures.ps1
dart pub cache add flutter_webrtc --version 1.6.2+hotfix.4
powershell -NoProfile -ExecutionPolicy Bypass -File tool\prepare-webrtc-hotspot.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tool\resolve-dependencies.ps1
flutter analyze --no-pub --fatal-infos
flutter test --no-pub
flutter build windows --debug --no-pub
flutter build apk --debug --target-platform android-arm64 --no-pub
~~~

For the tested phone-provided hotspot topology, add
--dart-define=VAULT_HOTSPOT=true to the Android build/run. Default false keeps
the normal native network monitor. Restart the app when changing this factory
option. Recovery after network changes is unverified; this is an experiment.
The generated override is ignored and never edits the shared Pub cache.

The link script uses project-local directory junctions if the current Windows
token cannot create Flutter plugin symlinks. It does not modify system policy or
installed packages. resolve-dependencies.ps1 accepts only the specific symlink
failure after successful resolution; other package errors fail. It then prepares
the links. Use --no-pub for subsequent Flutter commands.

Run Windows with the built vault_phase0_probe.exe or flutter run -d windows.
Run Android with flutter run -d <authorized-device-id> --debug --no-pub.
On Xiaomi, USB debugging, RSA authorization and Install via USB may need enabling.

## Local control and measurements

The Flutter test control API binds127.0.0.1:48931. Requests need the local-only
x-vault-probe: phase0-local header. This fixed header is test scaffolding, not an
authentication design. Ports are not bound to LAN. Forward the phone API over USB:

~~~powershell
adb -s <device-id> forward tcp:48932 tcp:48931
~~~

POST /suite runs native WebRTC loopback16 MiB each direction, then resident fixture
Range-feed playback, first rendered frame, 8/2/10-second seeks and decoded stereo
48kHz audio parameters. Audio is muted; audibility remains a separate check.
POST /encode runs a five-second Android MediaCodec H.264 hardware test with150
constant720p frames. This is not WebRTC file-track injection, bitrate or thermal proof.

POST /lifecycle/start starts a short dataSync FGS experiment; GET /lifecycle reads
actual service/idle/battery-policy/notification state; POST /lifecycle/stop ends it.
This service is time-budgeted, not an indefinite publishing strategy. No battery,
Doze, quota or device policy is overridden by the app.

For cross-stack tests, start tools/interop_harness/bin/vault-interop.exe, then:

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tool\run-interop.ps1 -OutputPath C:\path\windows-pion.json
powershell -NoProfile -ExecutionPolicy Bypass -File tool\run-interop.ps1 -Initiator http://127.0.0.1:48932 -OutputPath C:\path\android-pion.json
powershell -NoProfile -ExecutionPolicy Bypass -File tool\run-interop.ps1 -Responder http://127.0.0.1:48932 -OutputPath C:\path\windows-android.json
~~~

Cross-device SDP is exchanged only through local/USB control. Synthetic bytes flow
through real WebRTC, with selected candidate types checked and hashes compared.
Results distinguish same-device, same-host cross-stack and real cross-device paths.

The pinned webrtc_interface drops maxRetransmits=0 from toMap(); the spike-local
EphemeralInit override and regression test preserve that exact zero. Buffer polling
uses await getBufferedAmount(), never only the cached getter. Current APIs limit
synthetic transfers to256 MiB; this is not the required2GiB stress test.

## Limits

The VOD adapter serves complete resident synthetic files; it does not prove a P2P
sparse cache or cold network seeks. Loopback throughput is not LAN throughput.
This app does not implement Vault identity, consent grants, production protocol,
public discovery, SAF, Windows encoding, live ingestion or multi-peer fan-out.
Physical Android lifecycle/Doze/time-budget tests require their own evidence.
No Phase1 go decision follows automatically from these first passing probes.
