# WebRTC transport, VOD and live-media feasibility audit

Research date: 2026-10-18. Scope: `P2P_VIDEO_SHARE_BUILD_PLAN.md`, `packages/vault_delivery/README.md`, `packages/vault_net/README.md`, `packages/vault_player/README.md`. No app implementation or device benchmarks were performed. Statements under Inferences are architectural deductions or proposed changes, not measured performance.

## What is the intended product, and which promises need qualification?

### Takeaway
Vault is intended to be a personal media publisher with local ownership and explicit viewing consent, available on Android and Windows without an operator backend. The core useful path is authenticated direct file-range delivery and seekable playback; global search and synchronous multi-viewer transcoding add substantial independent feasibility risk.

### Cited Findings
- The local plan requires direct media, no operator backend, local cryptographic identities, owner approval, seekable VOD, and optional live mode; it postpones viewer cache sharing until Phase 7. Therefore v1 multi-peer primarily means one origin with several independently connected viewers. — [Build plan](../../P2P_VIDEO_SHARE_BUILD_PLAN.md)
- TURN explicitly forwards application packets between a client and peer when a direct path is unavailable. — [RFC 8656, sections 1 and 2](https://www.rfc-editor.org/rfc/rfc8656.html#section-1)
- STUN alone does not solve NAT traversal. — [RFC 8489, abstract and section 13](https://www.rfc-editor.org/rfc/rfc8489.html#section-13)

### Inferences
- Replace absolute "on demand, at any time" with "on demand while the publisher device is awake, publishing, and reachable; cached copies remain usable offline." A peer-only origin cannot serve uncached bytes while powered off. Source requirement: [Build plan, objective and hard constraints](../../P2P_VIDEO_SHARE_BUILD_PLAN.md).
- The plan simultaneously says "all media bytes direct, never through third parties" and allows user-supplied TURN. Preserve the stronger direct-only constraint for the default build. Treat a user-supplied TURN transport as a separately approved future policy change, or explicitly rewrite the guarantee to disclose encrypted relayed media. Do not claim TURN is signaling-only.
- A direct connection proves connectivity to that peer, not general worldwide reachability. A failed ICE attempt does not diagnose symmetric NAT with certainty. Proposed UI: "No direct route could be established. Network/firewall restrictions may be preventing it." Do not blame one NAT type without evidence.
- Distinguish playback modes in the interfaces: `ByteRangeSource` should expose `readAt`, length and cancellation; `LiveSession` should expose tracks, timeline and lifecycle. One byte-stream interface cannot meaningfully describe a live RTP track. Proposed wording: "Two delivery modes share authorization and session lifecycle; VOD is byte-addressed, live mode is track/timeline addressed."

### Gaps
- No real-device evidence yet supports availability, codec breadth, six viewers, synchronized playback, seek latency, or the stated throughput table. Those remain targets.
- "Watch together" needs a defined playback clock, leader actions, drift bounds and resynchronization. Sending the same source to separate WebRTC connections does not establish a cross-viewer synchronization contract.

## What are the actual SCTP limits, fragmentation and control-delivery requirements?

### Takeaway
The plan conflates 256 KiB integrity/cache chunks with 16 KiB DataChannel messages and puts critical control on a lossy channel. Define explicit application fragmentation and a separate reliable control channel, and poll the native buffer with the correct async API.

### Cited Findings
- SCTP channels within an association share congestion control. Without message interleaving, large messages can monopolize the association; RFC 8831 recommends limiting messages to 16 KB. Zero retransmissions plus unordered delivery is explicitly UDP-like. Reliable control is a documented use case. — [RFC 8831, sections 3.2, 5 and 6](https://www.rfc-editor.org/rfc/rfc8831.html)
- An endpoint must not exceed the peer's advertised `a=max-message-size`; omission means 64K, while zero means unlimited subject to implementation memory limits. — [RFC 8841, section 6.1](https://www.rfc-editor.org/rfc/rfc8841.html#section-6.1)
- The exact plugin release's `.bufferedAmount` getter returns cached `_bufferedAmount`. `await getBufferedAmount()` calls the platform method and refreshes that cache. — [flutter_webrtc v1.6.2+hotfix.4, RTCDataChannel implementation](https://raw.githubusercontent.com/flutter-webrtc/flutter-webrtc/v1.6.2%2Bhotfix.4/lib/src/native/rtc_data_channel_impl.dart)
- The desktop missing buffered-amount callback report is issue **#2206**, not #2210. The reporter identifies the missing C++ observer override; it is an issue report, not proof that every platform/version is affected. — [Upstream issue #2206](https://github.com/flutter-webrtc/flutter-webrtc/issues/2206)

### Inferences
- Proposed replacement: "Integrity/cache chunks remain 256 KiB. Each chunk is fragmented into application envelopes of at most `min(16 KiB, negotiated max-message-size)` total serialized bytes, including headers. Envelope fields include session/request ID, media/version ID, chunk index, fragment index/count, total length and payload. Reassembly is bounded by negotiated concurrent requests, size and timeout. Hash only after the entire chunk is assembled."
- Define three channels: (1) reliable ordered **critical control** for auth, access, manifest/range requests, cancel, resume, errors and acknowledgments; (2) reliable ordered **bulk** fragments; (3) unordered `maxRetransmits:0` **ephemeral** stats/heartbeats/bounded gossip. If control may be unordered, it still needs reliability plus explicit correlation/idempotence. Three channels share the same congestion window; they do not give strict control-latency isolation.
- Proposed replacement: "Use `await dataChannel.getBufferedAmount()` for polling, initially every 50 ms. Before every send also track locally enqueued bytes, account for serialization overhead, bound total queued bytes per peer and app, and stop sending bulk above high-water. Resume below low-water. Events are hints. Handle closure/native errors/timeouts and cancel poll timers during teardown."
- A polling loop that reads only `.bufferedAmount` can read zero forever on affected desktop builds and defeat backpressure. Neither 512 KiB nor 50 ms is proven sufficient; benchmark both throughput and worst-case control latency under loss.
- Add chunk digest and content-generation fields to the actual manifest/range schema; the plan currently requires integrity verification without specifying where trusted chunk digests are conveyed. Use request IDs and cancellation generations to discard pre-seek responses safely. Bound offsets, lengths, outstanding requests and allocations.
- Never rely on an unreliable remote BYE/REVOKE for consent enforcement. The owner must deny new reads immediately and close local senders/PeerConnections. Already delivered cache bytes cannot be remotely revoked.
- SCTP encryption, Dart/native marshalling, disk IO, hashing and decoding all cost CPU. Replace "zero CPU, seek is instant" with "no transcoding; CPU and seek cost depend on transport, source format, player, storage and device."

### Gaps
- Interleaving support, effective message limits, polling cost and native queue growth have not been established for the exact Android and Windows build pair.
- The advertised 20–40 MB/s LAN and other throughput ranges have no reproducible source in this repository. Retain them only as hypotheses until measurement; record MiB/s versus MB/s explicitly.

## What does the current Flutter WebRTC stack actually guarantee?

### Takeaway
The current package is viable to spike on both target platforms, but package support is not proof of hardware encoding, native file-track ingestion, simulcast behavior, or encoder reuse across peer connections. Several references in the plan are wrong and need correction.

### Cited Findings
- Latest published release observed is **flutter_webrtc 1.6.2+hotfix.4**, released 2026-10-07; its changelog moves Windows/Linux to libwebrtc **m150.7871.03** and includes disposal/thread-safety fixes. — [Publisher changelog](https://pub.dev/packages/flutter_webrtc/changelog)
- The Windows `setParameters` encoding-change report is **#2210**. It reports encoding fields being discarded while Dart properties appear updated, and explicitly says Linux is inferred, not tested. — [Upstream issue #2210](https://github.com/flutter-webrtc/flutter-webrtc/issues/2210)
- #2216 concerns macOS microphone selection; #2218 concerns an HEVC freeze on a Samsung device. — [Issue #2216](https://github.com/flutter-webrtc/flutter-webrtc/issues/2216), [issue #2218](https://github.com/flutter-webrtc/flutter-webrtc/issues/2218)
- Exact tagged Windows native `AddTrack` runs work on a detached thread but completes the result after `pc->AddTrack`; `AddTransceiver` comments likewise describe awaiting completion before negotiation. — [Tagged peerconnection source](https://raw.githubusercontent.com/flutter-webrtc/flutter-webrtc/v1.6.2%2Bhotfix.4/common/cpp/src/flutter_peerconnection.cc)
- The desktop factory source uses the builtin video codec factory by default, an Intel factory behind a compile flag, and a Windows HEVC wrapper under another compile flag. This is not evidence of universal Media Foundation H.264 encoding in the shipped binary. — [Desktop SDK factory source](https://raw.githubusercontent.com/webrtc-sdk/libwebrtc/main/src/rtc_peerconnection_factory_impl.cc)
- Android's hardware factory checks actual codec/device capability and may return no matching encoder. — [libwebrtc Android hardware encoder factory](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/android/api/org/webrtc/HardwareVideoEncoderFactory.java)
- Upstream feature requests seek explicit Windows encoder selection and runtime encoder/keyframe APIs, showing these are not simple established Dart controls. — [Issue #2200](https://github.com/flutter-webrtc/flutter-webrtc/issues/2200), [issue #2204](https://github.com/flutter-webrtc/flutter-webrtc/issues/2204)
- Stats define encoder implementation and power-efficiency fields, but these may be absent and power efficiency is not an unconditional hardware certificate. — [W3C WebRTC stats, RTCOutboundRtpStreamStats](https://www.w3.org/TR/webrtc-stats/#outboundrtpstats-dict*)

### Inferences
- Exact pin for the spike should be `1.6.2+hotfix.4`, with lockfile and native artifact versions recorded. Do not use a caret and call the dependency hard pinned. Re-test known issues on this artifact rather than automatically introducing destructive transceiver recreation.
- Keep serialized negotiation, await native track/transceiver operations, and prevent teardown while operations are in flight. Describe this as lifecycle discipline; remove the unsupported claim that a queue alone fixes a known #2216/#2218 race.
- Proposed wording: "H.264 hardware acceleration is preferred where runtime support is verified; actual profile/encoder, fallback behavior, temperature and concurrent-session capacity are Phase 0 measurements. Do not promise hardware H.264 on every Android/Windows device."
- The proposed guarantee "never transcode per viewer; one set of encoded frames, N senders" requires a demonstrated encoded-frame fan-out integration. A shared raw video track can still feed distinct encoder instances per sender/connection. Treat encoder reuse as an explicit spike, not an architectural fact. Multiple independent VOD timelines also prevent one universal live encoder from serving arbitrary seeks.
- Live file input requires proving the native decoded-video **and audio** injection path, A/V timestamp synchronization, seek/restart behavior and track cleanup on both platforms. A working camera or screen-capture demo is insufficient evidence for this requirement.
- PLI belongs to RTP live recovery, not file-byte chunk boundaries. Move the chunk/seek PLI policy to the live pipeline only, and first verify the plugin exposes a supported path. Do not promise exact 2-second IDRs or Opus CBR controls until they can be configured and observed.

### Gaps
- No measured evidence yet proves actual Windows H.264 encoder selection, encoded-frame sharing, six simultaneous hardware sessions, or plugin-level file/audio source adapters.
- No benchmark establishes VP9 software as a safe fallback for the intended battery/CPU budget; VP8/H.264 software or declining live mode may be more practical, depending on measured devices.

## How should fan-out budgets and media adaptation change?

### Takeaway
The stated six-viewer/20-Mbps acceptance target contradicts the plan's own 70% cap, and the ladder resolutions contradict the supplied scale factors. VOD and live mode require distinct cost models.

### Cited Findings
- The specification scales both video dimensions by `scaleResolutionDownBy`; an active encoding can add a separately sent RTP stream. `maxBitrate` is an encoding cap rather than guaranteed throughput. — [W3C WebRTC, encoding parameters](https://www.w3.org/TR/webrtc/#dom-rtcrtpencodingparameters)
- The plan specifies 2.5 Mbps high video, 96 kbps stereo audio, overhead ×1.17, 70% cap and six high viewers on a 20-Mbps host. — [Build plan, sections 3 and 7](../../P2P_VIDEO_SHARE_BUILD_PLAN.md)

### Inferences
- Arithmetic using the plan's own values: one high viewer costs `(2.5 + 0.096) × 1.17 = 3.03732 Mbps`; six require **18.22392 Mbps**. A 20-Mbps host's cap is **14 Mbps**, admitting at most **four** all-high viewers before additional control costs. Six all-high viewers need at least **26.034 Mbps measured uplink** at a 70% cap, even before safety margin and any additional simulcast layers. Keep six as a hard session maximum, not a guarantee.
- If every peer receives all 300/800/2500 kbps simulcast layers, per-peer video is 3.6 Mbps, not 2.5. Sending all layers point-to-point does not provide an SFU that discards unwanted encodings. Decide whether each viewer receives one selected rendition or the full simulcast set, then charge actual bytes for every active encoding.
- From 1280×720, scale 4 produces **320×180**, not 426×240. Correct the low rung to 320×180 (4×), or use 3× for approximately 426×240. Scale 2 gives 640×360. A 1920×1080 source changes every computed rung; normalize the source size or derive scales dynamically.
- Default VOD preserves source encoding/bitrate. It is unaffected by an H.264 live ladder and cannot offer lower quality without additional renditions or transcoding. Separate `vodBytesPerSecond` scheduling from live `video+audio` estimates. Source bitrate spikes matter even when average bitrate fits.
- The 3×2MB probe measures that peer path (host uplink, viewer downlink, RTT, congestion and CPU), not the host ISP's entire uplink. Compute transferred bytes/elapsed monotonic time and use conservative repeated samples; "best RTT of 5" is not bandwidth. Name it `measuredPathGoodputMbps`, allow a user uplink cap and adapt to aggregate observed traffic.
- Fixed 12%+5% overhead is a provisional budget heuristic. Do not add DTLS per media packet: DTLS establishes SRTP keys; live media uses SRTP. Base governor decisions on measured aggregate wire/application rates and observed loss/retransmission cost.
- Proposed Phase 5 DoD: "1, 2, 4 then up to 6 viewers on named hardware. All-high count must fit the measured cap. On a shaped 20-Mbps uplink with 70% default cap, demonstrate four high viewers or a valid mixed-tier/queued allocation, cap compliance, stable temperature/CPU, and bounded control/revoke latency." CPU <60% becomes hardware-specific, not universal.

### Gaps
- No source can validate the current latency/throughput/CPU/battery numbers independently of concrete hardware, content, network and implementation. Record device CPU/GPU/RAM, codec implementation, app/native versions, content hash/codec/GOP, directional rate/RTT/loss, warm/cold cache, sample counts and p50/p95/p99.

## Can arbitrary MP4 files really play progressively and seek on Android and Windows?

### Takeaway
Seekable VOD needs an actual random-access player adapter and tested format policy; writing an incomplete file is insufficient. Pin a real Windows backend and move this proof into Phase 0.

### Cited Findings
- Flutter's official `video_player` package lists Android/iOS/macOS/web, and the Flutter cookbook explicitly says Linux and Windows are unsupported. — [Publisher package](https://pub.dev/packages/video_player), [Flutter cookbook](https://docs.flutter.dev/cookbook/plugins/play-video)
- `video_player_media_kit` **2.0.0** supplies a media_kit backend for Windows and requires initialization plus the corresponding native library dependency. — [Publisher documentation](https://pub.dev/packages/video_player_media_kit)
- media_kit's documented source path is a URI, with optional HTTP headers; it supports desktop/mobile playback. This is not itself a demonstrated arbitrary Dart byte-stream source. — [Project README](https://github.com/media-kit/media-kit/blob/main/README.md)
- Android Media3 supports progressive MP4/FMP4 and other containers, provided contained sample formats are also supported. — [Android supported formats](https://developer.android.com/media/media3/exoplayer/supported-formats#progressive-container-formats)
- MP4 commonly puts its index at the end; `faststart` moves it to the beginning as a second pass. — [FFmpeg muxer documentation](https://www.ffmpeg.org/ffmpeg-formats.html#mov_002c-mp4_002c-ismv)
- ExoPlayer seeking requires loading destination bytes and decoding from the preceding keyframe; longer GOPs increase accurate-seek work. — [Android seeking explanation](https://developer.android.com/media/media3/exoplayer/troubleshooting#why-is-seeking-in-my-video-slow)
- HTTP range responses use `206 Partial Content` and Content-Range semantics, with `416` for unsatisfiable ranges. — [RFC 9110, ranges](https://www.rfc-editor.org/rfc/rfc9110.html#name-range)

### Inferences
- Proposed Phase 0 gate: select one backend per platform and prove a random-access file adapter feeding it from DataChannel ranges. Test MP4 with front and tail `moov`, fragmented MP4, long GOP, source H.264/HEVC variants, audio, large offsets and seek near EOF with a cold cache. Include inaccessible/unsupported format UI.
- A temporary file with zero-filled holes must never expose unavailable ranges as valid bytes. A byte-availability map must gate reads, coordinate fetches, cancel stale seeks and distinguish unavailable data from EOF. A growing sequential file alone cannot supply tail metadata or out-of-order seek reads reliably.
- If using loopback HTTP, explicitly allow an **in-process, loopback-only playback adapter** as an exception to the plan's "no raw sockets" phrasing. Bind only loopback, use an unguessable per-session URL/token, implement HEAD/Range/Content-Length/Content-Range/status codes and lifetime cleanup. No media is relayed through an external service. Otherwise commit to native player data-source integration and budget that work.
- Replace "zero transcode, native source quality, seek is instant" with "source bytes are preserved; playback is limited to supported containers/codecs, random-access support and available path goodput; startup and seek targets will be established with a fixture corpus."
- Distinguish WebRTC live-audio output (plugin/OS audio device) from VOD player audio. Prove both paths on Windows, including device change, mute, seek, restart, disposal and no microphone permission for playback-only operation. Native media dependency licensing/distribution must be recorded before packaging; media_kit is not Windows Media Foundation merely because it runs on Windows.
- Retain <1.5s LAN startup and <1.2s p99 seek as scoped targets only, attached to named fixtures/devices/cache state. Replace "zero memory growth" with a bounded post-warmup steady-state budget plus no monotonic retained-resource growth across repeated sessions.

### Gaps
- No end-to-end adapter or native-library packaging exists in the inspected scaffolding. No test yet establishes Windows audio or the intended MP4 seek SLA.

## What network claims and Phase 0 gates are defensible?

### Takeaway
STUN-only connectivity is intentionally incomplete. Keep failure handling honest, measure real devices and controlled topology, and separate tool availability from an implemented, calibrated harness.

### Cited Findings
- ICE's recommended type preference is host 126, peer-reflexive 110, server-reflexive 100, relay 0; nomination still depends on tested connectivity. — [RFC 8445, sections 5.1.2 and 8](https://www.rfc-editor.org/rfc/rfc8445.html#section-5.1.2.2)
- `iceTransportPolicy: relay` allows only relay candidates; it is not a direct/LAN shortcut. — [W3C WebRTC transport policy](https://www.w3.org/TR/webrtc/#rtcicetransportpolicy-enum)
- Cloudflare documents `stun.cloudflare.com:3478` as its public STUN endpoint. This says nothing about an SLA for Vault or that every listed STUN endpoint currently works. — [Cloudflare connection guide](https://developers.cloudflare.com/realtime/sfu/get-started/connection-patterns/#network-connectivity)
- STUN-less manual SDP exchange does not remove the network's need for an actual route. TURN's standard explicitly describes some endpoint-dependent mapping combinations where direct hole punching generally fails. — [RFC 8656, introduction](https://www.rfc-editor.org/rfc/rfc8656.html#section-1)

### Inferences
- Remove ambiguous "relay-free fast path via `iceTransportPolicy: relay`" wording. Use `all` for direct candidate gathering, let ICE test current candidates and report the selected type. Do not reuse cached candidates/ICE credentials across network changes as if they remain valid.
- Verify mDNS candidate masking on both native platforms from actual offer/candidate logs. Browser defaults are not evidence of native SDK defaults. Until proven, encrypt SDP/candidates and redact diagnostic IPs; mDNS also does not hide public IP addresses from a direct peer.
- Test LAN with no STUN, NAT pairs, endpoint-dependent mapping/filtering, IPv6, UDP blocked, VPNs, Wi-Fi↔cellular transition, process death and sleep. A container or double NAT does not automatically model CGNAT or symmetric mapping; record actual mapping/filter/firewall rules.
- Proposed Phase 0 sequence: (A) exact toolchain/pins and dual-platform smoke builds; (B) authenticated 1:1 control+bulk transfer with bounded memory and loss/backpressure; (C) VOD adapter, MP4 corpus and Windows live/VOD audio; (D) direct ICE topology matrix plus Manual/MQTT exchange; (E) native file video+audio ingestion, hardware evidence, layer switching and measured 1/2/4/6 viewer cost. Allow VOD-core go while marking live mode no-go or re-plan if (E) fails.
- Do not tie all Phase 0 success to 3–5 elapsed days; there must be adequate real Android and Windows devices, a second peer and controlled network access. Preserve the no-feature-code rule until outcomes are recorded as pass/fail/blocked with evidence.
- A Linux/Pion interop harness validates wire interoperability and controlled network behavior. It cannot alone prove Android SAF, actual Windows hardware encode, audio output, thermal behavior or platform-player seek. Require real-device fixture runs alongside it.

### Gaps
- Endpoint reachability, NAT success rate, actual mDNS behavior and mobile/background availability were not measured in this research. No credible percentage should be asserted for general STUN-only connectability.
- Parent audit owns installed tooling; WSL `tc` existence alone must not be labeled an operational NAT/throughput harness.

## How should the clumsy network launcher be corrected?

### Takeaway
clumsy 0.3 supports explicit lag/drop options and an auto-stop timeout. Its throttle feature is batch delay/drop, and even its separate bandwidth module is a drop policer rather than a paced link shaper; use scoped lag/drop locally and `tc` for calibrated bandwidth.

### Cited Findings
- Exact 0.3 argument parser accepts `--key value` pairs and stores keys without semantic validation. Thus invented options can fail silently. — [clumsy 0.3 utils.c](https://raw.githubusercontent.com/jagt/clumsy/0.3/src/utils.c)
- Parameterized startup applies `--filter`, starts capture, and supports `--timeout` in seconds; module enabling uses each module's short name (e.g. `--lag on`). — [clumsy 0.3 main.c](https://raw.githubusercontent.com/jagt/clumsy/0.3/src/main.c)
- Lag reads `lag-inbound`, `lag-outbound`, `lag-time` (milliseconds); drop reads `drop-inbound`, `drop-outbound`, `drop-chance` (percentage). — [lag.c](https://raw.githubusercontent.com/jagt/clumsy/0.3/src/lag.c), [drop.c](https://raw.githubusercontent.com/jagt/clumsy/0.3/src/drop.c)
- Throttle queues a time frame of packets and then releases or drops a batch. There is no kbit/s flag. — [throttle.c](https://raw.githubusercontent.com/jagt/clumsy/0.3/src/throttle.c)
- The separate bandwidth module uses KB/s and drops packets above a one-second rate window. Exact flags in source are `--bandwidth on --bandwidth-bandwidth N`, not `--throttle N`; this is not token-bucket pacing. — [bandwidth.c](https://raw.githubusercontent.com/jagt/clumsy/0.3/src/bandwidth.c)
- clumsy is system-wide, requires administrator access, cannot filter by process in the documented interface, and has loopback caveats. — [Official manual](https://jagt.github.io/clumsy/manual.html)

### Inferences
- Safe proposed launcher argv, replacing `<peerIPv4>` with the validated explicit test peer address, kept as one quoted filter argument:

```text
--filter "udp and !loopback and ((outbound and ip.DstAddr == <peerIPv4>) or (inbound and ip.SrcAddr == <peerIPv4>))" --lag on --lag-time 50 --lag-inbound on --lag-outbound on --drop on --drop-chance 1 --drop-inbound on --drop-outbound on --timeout 60
```

- This adds roughly 50ms each direction (~100ms additional RTT) and targets 1% loss in each direction. It does not create a 100-Mbps cap, and does not identify a process. Add known peer UDP ports when stable and validate actual affected traffic. Use separate IPv6 filters for IPv6 peers. Never silently default to a global `udp` filter.
- Launcher fixes: resolve `$clumsy` correctly, reject missing/invalid peer address or invalid rate/loss/duration, use literal argument construction with correct quoting, surface exit/error status and finite duration, and show the effective filter/profile. `--timeout` is a failsafe, not proof capture started successfully.
- Do not run a global impairment during prebuild tool verification. Check the binary/driver and dry-run launcher; run scoped impairment only during an explicit network experiment with a peer.

### Gaps
- These flags are verified against the official 0.3 tag, not against a live capture of the locally installed binary. Driver loading and actual packet effects still require a scoped calibration test.
