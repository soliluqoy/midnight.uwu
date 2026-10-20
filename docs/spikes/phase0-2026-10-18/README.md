# Phase 0: first physical Android and Windows results

Measured2026-10-18. Initial native feasibility passes; Phase 0 remains open.
These probes use synthetic files/bytes and local USB signaling. They do not
implement Vault identity, consent or authenticated P2P media delivery.

## Hardware and versions

Windows10 Pro22H2 desktop,8 logical CPUs/~16GiB RAM; Xiaomi13TPro,
model23078PND5G/MT6985, Android16/API36, HyperOS3.0.301. The PC was connected
to the phone's hotspot. USB was connected and supplied power; it forwarded only
the loopback test-control API. WebRTC data crossed the hotspot directly.
[Topology evidence](topology.json) records the hotspot host candidate without IPs.

Flutter3.47.7/Dart3.13.5; flutter_webrtc1.6.2+hotfix.4; Android engine150.7871.01,
Windows engine150.7871.03; media_kit1.2.6, video2.0.1, libs_video1.0.7;
crypto3.0.7; Go1.27.0/Pion4.2.24. The probe's lockfile and Go module/sum pin
their graphs. Android hotspot testing enables a recorded experimental local
plugin patch. [Patch hashes](webrtc-hotspot-patch.json),
[binary/lockfile hashes and checks](builds-and-checks.json).

## Results

Each rate below is one unshaped trial, in MiB/s, not a capacity guarantee. Transfers
stream deterministic patterns in messages<=16KiB with a512KiB native-buffer window
and polling. Both endpoints compute SHA-256; selected ICE candidate types are
verified host/host. No STUN or TURN servers are configured in these probes.

| Probe | Observed result | Evidence and boundary |
|---|---|---|
| Tool installation |26 PASS,0 failures,0 warnings | [Full verifier](../../ops/toolchain-verification.json); driver effect calibration is separate |
| Current native builds | Android34.8s; Windows37.5s, both PASS | [Builds/checks](builds-and-checks.json); initial full builds were slower |
| Flutter/Pion/verifier checks |6 Flutter tests,3 Pion tests,9 verifier assertions PASS; Flutter analysis PASS | Range semantics, zero-retransmit serialization, real Pion round trip and corrupt digest rejection |
| Windows native loopback |16MiB each way,6.26/6.68MiB/s | [Windows suite](windows-suite.json); same-device only |
| Android native loopback |16MiB each way,4.71/5.27MiB/s | [Hotspot-mode Android suite](android-suite-hotspot.json); same-device only |
| Windows→Android / Android→Windows |32MiB each way,5.93/5.49MiB/s, hashes match | [Physical pair](windows-android.json); hotspot LAN, not Internet/NAT matrix |
| Android→Pion / Pion→Android |32MiB each way,8.60/7.45MiB/s, hashes match | [Phone/Pion](android-pion.json); physical hotspot link |
| Windows→Pion / Pion→Windows |32MiB each way,8.75/8.31MiB/s, hashes match | [Windows/Pion](windows-pion.json); same host, cross-stack |
| Resident MP4 playback/seek | Front/tail-moov files play on both platforms | [Windows](windows-suite.json), [Android](android-suite-hotspot.json); complete resident bytes, not sparse P2P cache |
| P2P sparse Range playback (Windows loopback) | Front/tail MP4 play through a 4x64KiB LRU cache fed by a WebRTC DataChannel; 3 cold seeks each, 191-193ms; peak resident 256KiB | [Windows P2P range](windows-p2p-range-loopback.json); one app, two peers, same device. Seek times sit on the harness's >=120ms advance floor; no network latency, no phone, no percentiles |
| P2P sparse Range playback (physical Android) | Android plays front/tail MP4 from Windows over WebRTC via the 4x64KiB cache; startup 766/1606ms; cold seeks 636/350/556ms (front), 667/346/603ms (tail); peak resident 256KiB; 192 chunk fetches for two 2.4MB files | [Android P2P range](android-p2p-range.json); phone hotspot LAN, one run, Windows hosts. ICE pair type not recorded in this run; no percentiles, audible playback or cold-seek over shaped links |
| 2 GiB block-verified transfer, cancel and resume (Windows to Android) | 2,048 of 2,048 1 MiB blocks verified; receiver root matched sender root. Resumed from block 1397 after the hotspot dropped: 651 MiB in 144s, 4.52 MiB/s. Control ping RTT p50/p95/max 19.6/39.7/493ms under load; sender RSS 347 to 358MB; Android receiver peak RSS 538MB in a 40 MiB run vs 548MB at 2 GiB; selected pair host/host | [Resumed run](windows-android-2gib-resume.json), [first run](windows-android-2gib-first-run-hotspot-drop.json) |
| Authenticated MQTT 5 signaling (local broker) | TLS, password and topic ACL enforced; 40% loss still 9/9 ACKed, trickle exactly once; failover 893ms; replay, garbage, oversize and flood rejected; 10-node cold start found 8 in 19.1s, 10 in 25.4s | [auth](mqtt-auth.json), [loss](mqtt-loss.json), [failover](mqtt-failover.json), [abuse](mqtt-abuse.json), [discovery](mqtt-discovery.json); [ADR 0004](../../adr/0004-mqtt-signaling-findings.md); one run each, one shared broker, PC only |
| Public MQTT 5 brokers | broker.emqx.io:8883 and test.mosquitto.org:8886 gave CONNACK, SUBACK and QoS 1 echo (298/269ms); test.mosquitto.org:8883 failed the Dart TLS handshake | [Public probe](mqtt-public.json); a 32-byte synthetic payload on a random topic; availability is not guaranteed |
| Crypto and wire profile | 95 pure-Dart tests: Ed25519 RFC 8032, HPKE RFC 9180 A.2, 29 RFC 8949 CBOR vectors, rejection and replay vectors, grant MAC vectors | [ADR 0003](../../adr/0003-crypto-and-wire-profile.md), [wire spike](../../../spikes/phase0_wire/README.md); not audited, no DTLS-fingerprint session challenge yet |
| Android hardware H.264 encode |150 frames at 720p in 5.013s,29.92fps; c2.mtk.avc.encoder | [Hardware trial](android-hardware-encode.json); constant frames, no thermal/bitrate/live-ingestion claim |
| Short background dataSync FGS |8MiB each way behind Home succeeds; service stopped afterward | [Lifecycle trial](android-background.json), [transfer](android-background-pion.json); USB-powered, interactive, not Doze |

The latest resident playback trial rendered its first frame after1090/741ms on
Windows and869/773ms on Android, for front/tail files respectively. Six observed
Windows seek-resume times were192–196ms; Android246–390ms. Each fixture is a
12-second1280x720 H.264/AAC synthetic MP4 of2,377,568 bytes. The player reports
decoded48kHz stereo. Sound was muted; audible playback is unverified. These are
warm resident-file seek observations, not cold network seek percentiles. Windows
requested tail metadata then resumed near the file head, demonstrating real Range
behavior. [Fixture descriptions and hashes](../../../spikes/phase0_probe/assets/fixtures.json).

## Findings repaired or isolated

The first Android probe aborted because its manifest omitted ACCESS_NETWORK_STATE.
The repaired manifest passes actual native tests. [Preserved failure](android-initial-failure.json),
[capabilities](android-capabilities.json), [normal-mode suite](android-suite.json).

The normal Android network monitor omitted hotspot ap0; cross-device ICE failed.
A checksum-guarded local plugin option exposes disableNetworkMonitor, default
false. With VAULT_HOTSPOT=true, ap0 is gathered and physical direct transfers pass.
[Before](android-pion-hotspot-before.json), [after](android-pion.json),
[decision, sources and limits](../../adr/0002-phase0-native-findings.md). The failed
trial's original JSON contains only a generic HTTP500; the runner now also captures
response errors and peer states for future failures. Do not infer a general NAT or
firewall diagnosis from that initial result. Network-flap recovery remains unverified.

Windows native buffer-low callbacks numbered zero in successful transfers;
Android callbacks fired. Both adapters poll native getBufferedAmount(). The
webrtc_interface serializer drops maxRetransmits=0; a local override and regression
test retain the zero. Data-only offers explicitly disable unwanted media sections.

Windows symlink error1314 persisted after the user's Developer Mode toggle.
Verified project-local junctions allowed native plugin builds. Shared packages
and machine policy were not modified. Native plugin builds required Android
platform35 and SDK CMake3.22.1; installation scripts/checks now include them and
developer-only FFmpeg/ffprobe. Upstream Kotlin/CMake compatibility warnings remain
documented maintenance work. No feature-readiness claim follows from the tool
verifier's zero-warning installation result.

Notifications were disabled for the short FGS trial. The service still ran, with
no battery-policy exemption, and the test explicitly stopped it. User-visible
notification permission/start/stop flows remain a production integration gate.

## Reproduce and continue

Use the [probe instructions](../../../spikes/phase0_probe/README.md) and
[Pion instructions](../../../tools/interop_harness/README.md). Run tests sequentially;
the two Flutter instances share port48931 on their separate devices, with the
phone API USB-forwarded to48932 and Pion listening on48933. Fixed control headers
are local test scaffolding only. Test runner cleanup closes each peer connection.

The [build plan](../../../P2P_VIDEO_SHARE_BUILD_PLAN.md) still requires:

1. Bounded sparse P2P Range delivery, cold seek, cancellation, cache eviction,
   source URI/revoked permission behavior and audible playback.
2. Authenticated session/encrypted signaling and deterministic wire/crypto/grant
   vectors, including unauthorized and revoked-peer rejection.
3. Shaped links and a documented real NAT/firewall matrix (2GiB integrity, resume and
   cancellation are now measured for Windows to Android only; see the 2GiB row).
4. Android screen-off/Doze, process death, user stop, reboot, background-start
   restrictions, timeout/quota, notification and recovery behavior.
5. Optional live file-track audio/video injection, Windows encoding, sustained
   thermal/bitrate/fan-out evidence, or an explicit decision to omit live.
6. Dependency/license/storage decisions and actual feature CI before Phase1.

Bounded sparse P2P Range delivery now works Windows-to-Windows on one device
(`POST /vod/host` on the serving peer, `POST /vod/remote` on the playing peer,
or `POST /vod/loopback` for both in one app). Finding: dart:io HttpServer does
not report a client abort until the response closes, so aborted reads were not
cancelled (`cancelledReads` stayed 0). Each ranged response is therefore capped
at 256KiB (`maxRangeResponseBytes`), bounding wasted remote fetches; a player
re-requests the rest. The physical pair (Android playing, Windows hosting) also
passed once. Next: Windows playing from the phone, selected-pair verification,
repeat runs for percentiles, audible playback, revoked-URI behavior, and the
other open gates above.

## 2GiB block-verified transfer

`POST /rtc/xtransfer {id, bytes, stopAfterBytes?}` sends position-dependent bytes as
1MiB blocks. The receiver hashes each block, checks it against the sender's claim,
and keeps verified blocks per id. A new attempt resumes at the verified-block count.
`stopAfterBytes` cancels in-band: the receiver drops the partial block after all
bytes sent so far arrive. Run it with `tool/run-xtransfer.ps1`.

First run: cancel at 700.3MiB left 700 verified blocks (partial block dropped).
The next attempt got to 1397 verified blocks before the phone hotspot turned off
and the connection failed. The receiver kept all 1397 blocks. A new connection
resumed from block 1397 and completed with a matching root, so resume after a
real connection loss worked once. Limits: one direction, one run, one link,
unshaped, USB-powered; Android to Windows and a 2GiB run without a drop are not
measured. Memory is process RSS only, not a leak analysis. This is not the
Phase 1 resumable-transfer protocol or its network-flap test.
