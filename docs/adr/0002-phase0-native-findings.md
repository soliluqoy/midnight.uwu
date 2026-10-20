# ADR 0002: Initial native feasibility findings

Date: 2026-10-18. Status: accepted for experimental probes only. Phase 0 remains
open; no production go decision. [Raw results and scope](../spikes/phase0-2026-10-18/README.md).

## Findings and decisions

Use a throwaway app outside the production workspace to jointly resolve and build
flutter_webrtc1.6.2+hotfix.4, media_kit1.2.6, media_kit_video2.0.1,
media_kit_libs_video1.0.7 and crypto3.0.7. Commit its lockfile. Pion4.2.24 is a
separate pinned Go interop peer. Both native targets now build and run; this does
not approve the complete production dependency or licensing graph.

Android native WebRTC requires ACCESS_NETWORK_STATE as well as INTERNET. The
first probe omitted the former, causing a native abort. The manifest was repaired
and actual physical-device loopback/cross-device transfers now pass. Keep this
permission in the eventual native integration and preflight it before creating PCs.

webrtc_interface1.5.1 omits maxRetransmits=0 during serialization. Preserve that
zero in a spike-local override with a regression test. Request data-only offers
explicitly; reject unexpected audio/video m-lines in the transport probe.

Windows buffer-low callbacks were absent in measured transfers, while Android
callbacks occurred. Continue polling await getBufferedAmount() behind the adapter
with a bounded enqueue window. Neither platform's cached property alone is an
acceptable backpressure implementation. Measurements are not long-run memory proof.

The PC uses the test phone's hotspot. With the normal Android network monitor,
the gathered interfaces omitted hotspot ap0 and ICE failed. A factory option to
disable that monitor yielded an ap0 host candidate and successful direct phone↔PC
transfers. Preserve the failed run; report this as a controlled topology finding,
not proof of general NAT traversal. USB forwards only the loopback control API;
native WebRTC carries the test bytes across the hotspot link.

The pinned Flutter plugin does not expose the native option. A checksum-guarded
script copies its pinned source to an ignored project-local override and exposes
disableNetworkMonitor, default false. Only the Android experiment built with
--dart-define=VAULT_HOTSPOT=true enables it. Do not modify shared Pub cache sources
or make this a production default. The factory must be initialized before PCs;
switching modes requires app/factory restart. Connectivity-change detection and
ICE recovery must be proved for this mode before shipping it. The native option
exists in [WebRTC's factory API](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/android/api/org/webrtc/PeerConnectionFactory.java);
[upstream issue433](https://github.com/flutter-webrtc/flutter-webrtc/issues/433)
provided a precedent, not a guarantee that the workaround would work here.

Windows Developer Mode was reported enabled by the user, but this process still
received symlink error1314. Use verified project-local directory junctions for the
resolved plugin paths; do not repeat the toggle request or modify system policy.
Run this preparation after pub get and build with --no-pub. The helper replaces
only a verified link if the resolved dependency path changes.

Exact native builds additionally needed Android platform35 and SDK CMake3.22.1.
The installer/verifier now include them. FFmpeg/ffprobe9.0.1 create synthetic
fixtures only and are not bundled in Vault. Upstream Kotlin plugin migration and
CMake policy warnings remain compatibility maintenance work, not hidden passes.

## Limits and next decision

Resident-file loopback HTTP playback proves a native player/Range path, including
tail-moov requests. It does not prove a bounded sparse P2P cache, SAF source access
or cold network seek. Decoded stereo48kHz was observed with sound muted; audibility
is unverified. Five seconds of constant-frame hardware encoding does not establish
live file injection, bitrate compliance, thermal stability or fan-out.

A short Home-screen background transfer with dataSync FGS passed, with no battery
policy exemption. Notifications were disabled on this installation; notification
permission and user-visible stop controls need their own production integration.
Screen-off/Doze, timeout/quota, process death, user stop and recovery remain open.

Next prove bounded remote-range playback and cancellation across this physical
pair, then its cold seek/memory behavior. Continue authentication/wire vectors,
2GiB stress and lifecycle gates before starting production features.
