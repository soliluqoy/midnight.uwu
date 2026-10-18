# Vault — Repository File Tree

> Generated from `P2P_VIDEO_SHARE_BUILD_PLAN.md` §4, §5, §7 and §10.1.
> Every node below carries a one-line responsibility, as required by §10.1.
> Layering rule (§4): `ui → (directory, delivery, player) → (net, signaling, media_index) → (protocol, identity)`.
> Hard constraint: **`vault_protocol` and `vault_identity` have ZERO Flutter imports.**

---

## Root

```
artemis/
├── README.md                        # Setup, build and run Vault on Android + Windows.
├── .gitignore                       # build/, .dart_tool/, Gradle, IDE, signing material.
├── .editorconfig                    # Uniform Dart / YAML / shell / Go formatting.
├── melos.yaml                       # Monorepo orchestration: bootstrap, gen, test, analyze.
├── analysis_options.yaml            # Strict analysis; `fatal-infos`; shared lint set (§8).
├── pubspec.yaml                     # Dev-only tooling deps (melos, lints, very_good_analysis).
└── P2P_VIDEO_SHARE_BUILD_PLAN.md    # The authoritative build plan this repo implements.
```

---

## `apps/vault` — the only shippable application

```
apps/vault/
├── pubspec.yaml                    # App deps, each pinned exactly with one-line justification.
├── analysis_options.yaml            # App-level overrides layered on the root analysis rules.
├── lib/
│   ├── main.dart                    # Entry point: flags/env, bootstrap, runApp.
│   ├── app.dart                     # App shell: theme, router, global overlays, l10n delegates.
│   ├── bootstrap.dart               # Ordered async startup + crash-safe restore of persisted state.
│   ├── router.dart                  # go_router table + `vault://` deep links for peer invites.
│   ├── di/
│   │   └── providers.dart           # Riverpod providers; the single DI seam (no other singletons).
│   ├── platform/                    # ALL platform channels live here and nowhere else (§10.4).
│   │   ├── folder_picker.dart       # Interface + factory selecting the per-OS implementation.
│   │   │   ├── folder_picker_windows.dart   # Arbitrary-directory picker.
│   │   │   └── folder_picker_android.dart    # SAF tree URI + persisted read permission.
│   │   ├── directory_watcher.dart            # Interface: event stream + reconcile cadence.
│   │   │   ├── directory_watcher_windows.dart # ReadDirectoryChangesW via FFI + 5 s reconcile.
│   │   │   └── directory_watcher_android.dart  # SAF 15 s reconcile + MediaStore camera output.
│   │   ├── thumbnailer.dart                  # Interface for poster-frame extraction.
│   │   │   ├── thumbnailer_android.dart      # MediaMetadataRetriever, frame at 22 % duration.
│   │   │   └── thumbnailer_windows.dart      # Media Foundation / ShellItemThumbnail (cached).
│   │   ├── codec_probe.dart                  # Runtime H.264 HW-encode capability probe (Risk 7).
│   │   ├── foreground_service.dart           # Android FGS + persistent notification lifecycle.
│   │   ├── tray.dart                         # Windows tray icon, autostart, menu actions.
│   │   └── single_instance.dart              # "Only one running instance" guard on both OSes.
│   ├── features/                    # One directory per §6 functional-scope item.
│   │   ├── onboarding/               # §6.1 name + avatar, identity QR, safety number, add contact.
│   │   ├── library/                  # §6.2 shared-folder grid, duration badges, Publish toggle, index progress.
│   │   ├── browse/                   # §6.3 remote search, owner result cards, quality badge, Request access.
│   │   ├── access/                   # §6.4 approve/deny prompt, 60 s countdown, viewer waiting state.
│   │   ├── player/                   # §6.5 seek bar, scrub thumbnails, Save offline, stats overlay.
│   │   ├── live/                     # §6.6 Watch Live toggle, latency readout, VOD fallback.
│   │   ├── connections/              # §6.7 live peers, bytes in/out, revoke/kick, per-peer rate limit.
│   │   ├── settings/                 # §6.8 folder, ACL, uplink cap, cache, STUN/TURN, signaling strategy.
│   │   └── debug/                    # Relay diagnostics, shard debugger, debug overlay, log export.
│   └── l10n/                        # Generated localizations; no hard-coded user-facing strings.
├── android/                         # Android host project (Kotlin Gradle, manifest, FGS, SAF).
├── windows/                         # Windows runner host (CMake, tray, Media Foundation).
├── test/                            # Unit/widget tests needing no device and no channel.
├── integration_test/                # integration_test suites run on Android and Windows runners.
├── assets/                          # Bundled fonts, icons, generated protocol samples.
└── tool/                            # Dev scripts: codegen runner, MSIX + signed-AAB packaging.
```

---

## `packages/` — nine libraries, layered

```
packages/
├── vault_identity/                  # Cryptographic identity: keys, nodeId, safety numbers, QR.
│   └── lib/src/
│       ├── identity.dart            # Identity value object: nodeId, displayName, avatarHash.
│       ├── key_store.dart           # Interface for loading/persisting the device keypair.
│       │   ├── key_store_file.dart  # Encrypted-at-rest file key store.
│       │   └── key_store_secure.dart# DPAPI (Win) / Android Keystore key store.
│       ├── signer.dart              # Ed25519 sign/verify over the §5 envelope.
│       ├── node_id.dart             # nodeId derivation from public key + encoding rules.
│       ├── safety_number.dart       # Human-comparable safety-number grouping.
│       ├── qr.dart                  # Identity QR encode/decode + compact blob framing.
│       └── contacts.dart            # Known-contact store; auto-approve is scoped to this.
│   └── test/                        # 100 % coverage target; golden key-derivation vectors.
│
├── vault_protocol/                  # Wire format, message schemas, signing, HMAC capability tokens.
│   └── lib/src/
│       ├── envelope.dart            # 1-byte version + 2-byte type + 32-byte Ed25519 signature.
│       ├── codec.dart               # CBOR/MessagePack codec interface (never JSON, §5).
│       │   └── msgpack.dart         # Concrete MessagePack encode/decode.
│       ├── messages/
│       │   ├── signaling.dart       # §5.1 HELLO/OFFER/ANSWER/CANDIDATE/ANNOUNCE/QUERY/GRANT/REVOKE/BYE.
│       │   └── data_plane.dart      # §5.2 DC_HELLO/REQUEST_ACCESS/INDEX/RANGE/MANIFEST/PLAY_LIVE/STATS/GOSSIP.
│       ├── signing.dart             # Signature verification + ts ±120 s window enforcement.
│       ├── capability_token.dart    # HMAC-SHA256 token over streamSecret‖mediaId‖level‖iat‖exp.
│       ├── versions.dart            # protocolVersion / appVersion negotiation + compatibility gate.
│       ├── topic_scheme.dart        # `vault/v1/<scope>/<peerId>/<verb>` namespacing.
│       ├── constants.dart           # Every §3 magic number as a named constant with a comment.
│       └── errors.dart              # Typed rejection reasons (unsigned/expired/unknown/future).
│   └── test/                        # Golden wire vectors, fuzz entry point, 100 % coverage.
│
├── vault_signaling/                 # SignalingStrategy + Mqtt / Nostr / Manual implementations.
│   └── lib/src/
│       ├── signaling_strategy.dart   # The §2.3 abstract interface (inbound/publish/subscribe/…).
│       ├── backoff.dart              # Exponential backoff 1 s→60 s with jitter, shared by all impls.
│       ├── endpoint_lists.dart       # Hardcoded broker/relay lists + user-supplied additions (Settings).
│       ├── relay_byte_budget.dart    # Hard byte accounting + assertion that only signaling crosses a relay.
│       ├── diagnostics.dart          # Per-relay connectivity/latency for the Settings diagnostics UI.
│       └── strategies/
│           ├── mqtt_signaling.dart    # Default: 2–3 public MQTT-over-TLS brokers, QoS 0/1, failover.
│           ├── nostr_signaling.dart   # Fallback: ephemeral kinds, NIP-44-style encryption, 3–5 relays.
│           └── manual_signaling.dart  # Escape hatch: QR / short code / text blob, and test oracle.
│   └── test/                        # Failover, backoff, byte-budget assertion, topic-scheme tests.
│
├── vault_net/                       # PeerMesh: PeerConnection lifecycle, negotiation queue, stats.
│   └── lib/src/
│       ├── peer_mesh.dart            # The mesh: one PeerConnection per remote node, lifecycle + teardown.
│       ├── negotiation_queue.dart    # Serialized SDP negotiation behind one mutex (fixes Risk/§2.1 race).
│       ├── peer_connection.dart      # Thin wrapper over RTCPeerConnection + tracks + channels.
│       ├── ice_config.dart           # §2.2 RTCConfiguration: STUN-only, Unified Plan, maxBundle, require.
│       ├── data_channel.dart         # 3 channels: reliable file, unordered control, gossip.
│       ├── stats_poller.dart         # 1 Hz getStats() polling + debug-overlay model.
│       ├── keepalive.dart            # Heartbeat, reconnect, and flap recovery (§1 constraint 4).
│       ├── retry_policy.dart         # Backoff on negotiation failures; classified by failure reason.
│       ├── webrtc_adapter.dart       # The ONLY file importing flutter_webrtc (Risk 8 firewall).
│       └── nat_diagnostics.dart      # Classifies failure → "symmetric NAT likely, add TURN" (§2.2).
│   └── test/                        # Fake-adapter tests: queue serialization, teardown, leak assertions.
│
├── vault_directory/                 # Announce / query / gossip, SQLite presence cache, ranking.
│   └── lib/src/
│       ├── announcer.dart            # 30 s ANNOUNCE heartbeat, ttl 90 s, QoS 0, never retained.
│       ├── sharder.dart              # blake3(nodeId+epoch) → first 2 chars, 256 shards, 1/8 sample.
│       ├── query.dart                # QUERY bloom-filter publication + direct replies to querier.
│       ├── bloom.dart                # Wanted-terms bloom filter construction.
│       ├── gossip.dart               # 60 s fan-out of 200 freshest entries to ≤5 peers, ≤32/msg.
│       ├── gateway_topics.dart       # Public gateway/beacon topics solving the cold-start problem.
│       ├── presence_cache.dart       # In-memory view over the SQLite cache with hard expiry.
│       ├── presence_db.dart          # drift schema + 15 s expiry sweep.
│       └── ranker.dart               # Rank by measured path quality, then uplink hint, then success rate.
│   └── test/                        # Sharding, sweep, bloom, gossip fan-out, ranking determinism.
│
├── vault_media_index/               # Scanner, watchers, BLAKE3, metadata parsing, thumbnails.
│   └── lib/src/
│       ├── scanner.dart              # Background-isolate scan of the shared folder.
│       ├── folder_source.dart        # Enumerates media items from a platform folder handle.
│       ├── directory_watcher.dart    # Consumes the app/platform watcher; debounce 500 ms.
│       ├── reconcile.dart            # 5 s Win / 15 s Android reconcile; detects add/rename/delete.
│       ├── hash.dart                 # BLAKE3: first 1 MiB fast id + lazy full hash; mtime+size short-circuit.
│       ├── metadata.dart             # Container-header-only parse of duration/size/fps/codec/res.
│       ├── thumbnails.dart           # 320 px q70 poster at 22 % duration, pool concurrency 2, off-UI isolate.
│       ├── index_db.dart             # drift schema for the media index + paging cursor queries.
│       └── media_item.dart           # MediaItem value object; never touches IO.
│   └── test/                        # Hash short-circuit, metadata parse fixtures, paging correctness.
│
├── vault_delivery/                  # ChunkedFileSource, LiveTranscodeSource, UplinkGovernor.
│   └── lib/src/
│       ├── media_source.dart          # The §2.6 interface implemented by both engines.
│       ├── chunked_file_source.dart   # Engine A: zero-transcode byte-range source over DataChannel.
│       ├── live_transcode_source.dart # Engine B: decode + republish as a simulcast live track.
│       ├── chunk_protocol.dart        # §5.3 256 KiB chunks, index, per-chunk BLAKE3 verify, retry.
│       ├── read_ahead_buffer.dart     # 512 KiB read-ahead coalescing + 2-chunk prefetch.
│       ├── cache.dart                # Progressive temp-file cache, LRU, 2 GB desktop / 512 MB mobile.
│       ├── uplink_governor.dart       # PURE: decide({cap, viewers, stats}) → Map<peerId, Layer>.
│       ├── layer_ladder.dart          # §3.2 ladder as constants; sender re-creation on layer switch.
│       ├── sender_pool.dart           # Simulcast senders; recreates transceivers (Risk 3 workaround).
│       ├── backpressure.dart          # bufferedAmount polling at 50 ms, 512/256 KiB watermarks (Risk 4).
│       └── viewer_queue.dart          # Overflow policy: new→lower layer, then demote, then queue.
│   └── test/                        # 100 % coverage on governor, chunk protocol, backpressure (mandated).
│
├── vault_player/                    # Flutter media player + progressive playback plumbing.
│   └── lib/src/
│       ├── player_controller.dart     # Seek, speed, quality toggle, buffering state machine.
│       ├── progressive_source.dart    # Feeds cached chunks to the platform player (HTTP range / demux).
│       ├── seek.dart                  # Seek orchestration, prefetch invalidation, scrub preview.
│       ├── playback_stats.dart        # fps/kbps/freeze/jitter surfaced to the overlay.
│       └── platform/
│           ├── player_android.dart    # ExoPlayer / media3 backend.
│           └── player_windows.dart    # Media Foundation / video_player / media_kit backend.
│   └── test/                        # Controller state machine, seek, stats math.
│
└── vault_ui/                        # Design system, screens, settings, debug overlay.
    └── lib/src/
        ├── theme.dart                # One visual language, one type scale, light/dark.
        ├── design_system/            # Buttons, cards, chips, dialogs, tokens; no feature logic.
        ├── widgets/                  # Poster grid, duration badge, quality badge, presence chip.
        ├── screens/                  # Routable shells; each delegates to a feature package.
        ├── debug_overlay.dart        # Long-press stats: up/down, loss, RTT, jitter, NACK, PLI, freezes.
        └── a11y/                     # Semantics labels, focus order, text scaling guarantees.
    └── test/                        # Golden tests for the design system and key screens.
```

---

## `tools/` — verification harness (the thing that keeps us honest)

```
tools/
├── interop_harness/                 # Go: pion/webrtc as the *other* side of every connection test.
│   ├── go.mod                        # Pinned pion/webrtc version — the interop contract.
│   ├── cmd/
│   │   ├── dcbench/main.go          # Spike 2: DataChannel MB/s across LAN/100 Mbps/throttled link.
│   │   ├── hwenc/main.go            # Spike 1: receive-side proof of sustained 720p30 bitrate.
│   │   ├── signaling/main.go        # Spike 4: MQTT-over-TLS round trip, trickle, failover.
│   │   ├── natmatrix/main.go        # Spike 5: scripted NAT matrix over vnet, emits connectability matrix.
│   │   └── conformance/main.go      # Golden wire vectors from vault_protocol against a Go decoder.
│   └── internal/
│       ├── pionpeer/                # Thin pion peer that answers our offer and streams.
│       ├── vnetscenarios/           # Scripted bandwidth / loss / RTT / NAT-topology scenarios.
│       └── harness/                 # Result capture, JSON output, thresholds, CI exit codes.
├── netem/                           # Link shaping: WSL2 `tc netem` wrapper + Windows `clumsy` runner.
└── fixtures/                        # Sample media, malformed protocol blobs, BLAKE3 test vectors.
```

---

## `spikes/` — Phase 0. Each branch is throwaway; each leaves a written result in `docs/spikes/`.

```
spikes/
├── spike01_hw_encode/               # H.264 HW encode 720p30 Android↔Windows both directions, getStats proof.
├── spike02_dc_throughput/           # DataChannel MB/s: same-LAN, 100 Mbps, tc-shaped throttled link.
├── spike03_backpressure/            # bufferedAmount polling correctness over a 2 GB transfer (Risk 4).
├── spike04_mqtt_failover/           # 3 brokers, failover, trickle candidates, announce→connect latency.
├── spike05_nat_matrix/              # Home NAT / CGNAT / symmetric NAT matrix → honest connectability table.
└── spike06_windows_audio/           # Windows desktop audio playback verification + fallback design.
```

---

## `docs/` — decisions written down before code

```
docs/
├── FILE_TREE.md                     # This document.
├── adr/
│   ├── 0000-template.md             # ADR skeleton: Context / Decision / Consequences / Revisit-when.
│   ├── 0001-flutter-over-kmp.md     # §2.1 — why Flutter + flutter_webrtc beat Kotlin Multiplatform.
│   ├── 0002-webrtc-over-raw-sockets.md # §2.2 — DTLS-SRTP media, DTLS data channels, STUN-only.
│   ├── 0003-signaling-strategy-interface.md # §2.3 — pluggable MQTT/Nostr/Manual behind one interface.
│   ├── 0004-gossiped-directory.md   # §2.4 — expiring, sharded, gossiped presence with no index operator.
│   ├── 0005-capability-tokens.md    # §2.5 — HMAC tokens as consent; owner- and viewer-enforced.
│   ├── 0006-dual-media-engines.md   # §2.6 — chunked VOD default, live transcode opt-in.
│   ├── 0007-no-telemetry.md         # §1 — no analytics, no crash reporting, no remote config, ever.
│   ├── 0008-riverpod-state.md       # §4 — state management, DI, and the no-global-singleton rule.
│   └── 0009-msgpack-over-json.md    # §5 — MessagePack envelope, signature, ±120 s window.
├── protocol/
│   ├── message-catalogue.md         # Every §5.1/§5.2 message: fields, types, direction, expiry.
│   ├── topic-scheme.md              # `vault/v1/<scope>/<peerId>/<verb>` naming rules.
│   ├── chunk-protocol.md            # §5.3 sequence diagram, retry state machine, BLAKE3 verify.
│   └── capability-token.md          # Token construction, scope, expiry, revocation propagation.
├── ops/
│   ├── android-emulator.md          # Running the Android side locally and on hardware.
│   ├── windows-troubleshooting.md   # MSVC/CMake/Media Foundation issues and fixes.
│   ├── nat-connectability.md        # The user-facing connectability matrix (from spike 05).
│   └── release-checklist.md         # MSIX + signed AAB packaging, per §7 Phase 6.
└── spikes/                          # One written result per Phase 0 spike, with real measured numbers.
```

---

## `.github/` — CI enforcing §8 quality gates

```
.github/
└── workflows/
    └── ci.yml                       # dart analyze --fatal-infos · unit+golden tests · coverage gates
                                    # on vault_protocol/identity/governor/chunk · fuzz job ·
                                    # interop_harness job · integration_test on both runners.
```

---

## Layering contract (enforced by `analysis_options.yaml`)

```
vault_ui ─┐
          ├──> vault_directory ─┐
vault_player ─┤                  ├──> vault_net ──┐
vault_delivery ─┘                 vault_signaling ┤
                                    vault_media_index ─┤
                                                      ├──> vault_protocol ──> vault_identity
```

* `vault_protocol` and `vault_identity` import **no** Flutter, **no** `flutter_webrtc`.
* `flutter_webrtc` is imported by exactly one file: `packages/vault_net/lib/src/webrtc_adapter.dart`.
* `vault_delivery` depends on `vault_net` + `vault_protocol`, never on `vault_ui`.
* `vault_ui` depends on features, never on `flutter_webrtc` or platform channels directly.