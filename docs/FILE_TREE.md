# Vault repository inventory

Reviewed 2026-10-19. This inventory distinguishes existing files from planned
implementation. Empty directories and README contracts are not working components.
The [build plan](../P2P_VIDEO_SHARE_BUILD_PLAN.md) is authoritative.

## Existing

| Path | Responsibility |
|---|---|
| README.md | Scope, preflight and honest implementation status |
| P2P_VIDEO_SHARE_BUILD_PLAN.md | Product constraints, corrected architecture and gates |
| docs/UI_UX_BUILD_PLAN.md | Sourced design research, messenger-first navigation, consent, screen/state contracts and UI acceptance criteria |
| docs/INTERFACE_REDESIGN_PLAN.md | Adopted Quietly personal redesign, primary-source/dating-app research, screen/recovery contracts and explicit remaining native/human acceptance gates |
| design/vault/ | Runnable local browser interface study, bundled illustrative media and labeled peer-state simulations; not the Flutter app or Phase 0 evidence |
| site/ | Static Midnight product site, preview downloads, install instructions and explicit privacy/reachability limits; deployed to GitHub Pages |
| apps/vault/lib/main.dart, production/ | Awaited protected bootstrap, real services, three primary destinations and persistent/contextual task utilities |
| apps/vault/lib/production/messenger_service.dart | Bounded durable SQLite conversations, persisted receive acknowledgements, peer/ID deduplication, unread state and explicit retry over authenticated sessions |
| apps/vault/lib/production/connection_problem.dart | The closed connection-problem table, bounded ignored-attempt notices and their single remedies |
| apps/vault/lib/production/pairing_join.dart, pairing_dialogs.dart, pairing_code.dart | Scanner pairing state machine, host QR and confirmation dialogs, pure-Dart QR encoding and frame decoding |
| apps/vault/lib/features/pairing/qr_scan_page.dart | Android-only camera scanner; permission requested when it opens |
| apps/vault/lib/production/messenger_pane.dart | Adaptive person-first conversation list, lazy timeline, real delivery state, per-person draft/selection and retained history position |
| apps/vault/test/ | Runtime/storage/messaging regressions, adaptive navigation/focus continuity, pending-consent lifecycle and shared-cache completion deletion |
| apps/vault/lib/platform/ | OS-protected secrets, single-writer process lock, persisted SAF sources, selection/export and publishing availability |
| apps/vault/lib/features/player/media_viewer.dart | Lazy authenticated/local gallery, zoom/pan/details, native video controls and source/session cleanup |
| packages/vault_player/ | Native-player wrapper and bounded loopback HTTP Range feed |
| apps/vault/android/, windows/ | Vault Messenger native runners, unchanged package/storage identity, Android user-started dataSync publication service and Windows tray/wake/autostart controls |
| apps/vault/tool/prepare-windows-links.ps1 | Project-local Windows plugin junction preparation |
| packages/vault_ui/lib/ | Shared warm-neutral/evergreen design system and separate historical interface-study screens/controller |
| packages/vault_ui/test/ | Historical study-state regressions plus light/dark and high-contrast semantic color-pair invariants |
| pubspec.yaml / pubspec.lock | Explicit app/nine-package workspace, local Melos/lints and exact resolved service/plugin graph |
| analysis_options.yaml | Strict analysis; future invariants are marked pending |
| tools/setup/verify-toolchain.ps1 | Required probes with native exit-code checks and optional JSON |
| tools/setup/verification-helpers.ps1 | Shared safe probes and path validation |
| tools/setup/test-verifier.ps1 | Regression assertions for false passes |
| tools/setup/test-builds.ps1 | Isolated empty Flutter Android/Windows builds |
| tools/setup/install-toolchain.ps1 | Fresh-machine installation and idempotent component detection |
| tools/package-release.ps1 | Package existing native release builds into a Windows x64 ZIP and split Android APK downloads with SHA-256 checksums |
| tools/setup/install-windows-atl.ps1 | Additive administrator-only ATL repair for protected Windows storage; no SDK reinstall or plaintext fallback |
| tools/netem/clumsy-profile.ps1 | Scoped lag/drop launcher with dry-run, no fake NAT/bandwidth |
| tools/netem/netem-wsl2.sh | Shape traffic that actually traverses the WSL harness interface |
| docs/ops/ENVIRONMENT.md | Installed tool evidence, limitations and reproduction |
| docs/ops/toolchain-verification.json | Dated machine-readable installation check |
| docs/ops/DEPENDENCIES.md | Resolved tooling, spike pins and rejected/deferred candidates |
| docs/adr/0001-prebuild-baseline.md | Prebuild architecture and feasibility decisions |
| research_notes/Vault prebuild architecture audit/ | Primary-source research notes |
| reports/Vault prebuild architecture audit.md | Synthesized audit |
| packages/*/README.md | Service contracts, implemented APIs, verification commands and evidence limits |
| spikes/phase0_probe/ | Runnable Android/Windows transport, Range/player and Android codec/lifecycle probes |
| tools/interop_harness/ | Runnable pinned Go/Pion direct synthetic transport peer and tests |
| docs/spikes/phase0-2026-10-18/ | Raw runtime results, topology, native patch provenance and limits |
| docs/adr/0002-phase0-native-findings.md | Decisions from initial native tests; Phase 1 remains gated |
| docs/adr/0005-connection-setup-ux.md | Internet broker preset, QR pairing, named connection problems and pairing-token threat notes |
| packages/vault_identity/ | Pure-Dart Ed25519/HPKE identity, protected-store repositories and verified public contact cards |
| packages/vault_protocol/ | Deterministic CBOR, signed/sealed envelopes, replay checks and persisted owner-minted authorization |
| packages/vault_signaling/ | Bounded encrypted Manual/TLS MQTT5 signaling and explicit public-presence transport |
| packages/vault_net/ | Authenticated direct-only native sessions, serialized negotiation, bounded channels and buffer polling |
| packages/vault_directory/ | Opt-in bounded signed presence, expiry, local search and public pilot directory |
| packages/vault_media_index/ | SQLite index, full/chunk hashes, owned imports and referenced Windows/Android sources |
| packages/vault_delivery/ | Consent-gated browse/manifests/fragments, immutable pending-request lifecycle snapshots, verified sparse cache, resumable downloads and revocation |
| tools/verify-core.ps1 | Explicit per-package behavioral test targets, analysis and format checks |
| .github/workflows/core.yml | Windows/Android developer-build CI and core behavioral checks; remote run evidence is separate |
| .github/workflows/pages.yml | Deploy site/ to GitHub Pages on master website changes or manual dispatch |

The legacy melos.yaml was removed; current Melos configuration is in pubspec.yaml.

## Remaining acceptance and deferred extensions

| Path | Responsibility |
|---|---|
| Physical Android/Windows and real network matrix | Complete each remaining measured gate below; source implementation is not acceptance evidence |
| apps/vault/ release packaging | User-owned signing material, distribution/license review and release artifacts |
| Optional live / Nostr / redistribution / directory scaling | Separately gated or deferred; no stub transport or fake live stream in the core app |
| tools/interop_harness/ link fixtures | Broader shaped/NAT/stress evidence beyond the existing direct peer |
| .github/workflows/ coverage and fuzzing | Coverage/fuzz targets remain separate from the implemented behavioral/build job |

Layering: ui -> directory/delivery/player -> net/signaling/media_index -> protocol/identity.
Identity and protocol have no Flutter imports. Only vault_net's webrtc_adapter.dart
imports flutter_webrtc. The byte profile follows ADR0003: deterministic CBOR,
32-byte public keys, 64-byte Ed25519 signatures, recipient/session binding,
bounded replay caches and owner-side persisted grants/revocation.

## Remaining spike gates

Initial native probes cover parts of these gates; the measured record above
states their limits. The broader gates below remain open.

1. Physical Android/Windows hardware encoding and file-track audio/video injection.
2. DataChannel throughput, control latency and bounded memory.
3. Native buffer polling, fragmentation, cancellation and 2 GiB integrity.
4. Encrypted MQTT/Manual signaling, endpoint failover and bounded pilot discovery.
5. Documented direct NAT/firewall topology and observed ICE selection.
6. Progressive VOD, cold/tail-moov seek and audio on both platforms.
7. Physical Android FGS/Doze/service-budget availability and recovery.
8. Crypto/protocol vectors and exact-plugin dual native builds.

Each remaining gate needs exact hardware, versions, commands, raw observations
and a go/no-go ADR. Installing the interface preview does not close a spike gate.
