# Vault Messenger

A direct one-to-one messenger for Android and Windows with protected local
identities, verified contacts and durable local conversation history. Text travels
over authenticated WebRTC, not a server mailbox. We operate no backend.

Both peers must be running and directly reachable to exchange new messages.
There is no push wakeup, TURN, cloud synchronization or automatic offline resend.
Delivered means saved by the recipient app, not read. Local history is
application-private SQLite, **not encrypted at rest**.

Personal photo/video libraries remain a secondary feature with separate owner
approval and direct delivery. An owner must be awake and publishing to serve
uncached files. Revocation stops future media delivery; received copies cannot
be recalled. Public discovery remains a separate best-effort opt-in.

The authoritative [build plan](P2P_VIDEO_SHARE_BUILD_PLAN.md) was reviewed on
2026-10-18. Read the [audit report](reports/Vault%20prebuild%20architecture%20audit.md)
and [baseline decision](docs/adr/0001-prebuild-baseline.md) before implementation.

The companion [UI/UX build plan](docs/UI_UX_BUILD_PLAN.md) adapts selected Manyverse
patterns for Vault's navigation, consent, availability and media flows. The
[interface-first sequencing revision](P2P_VIDEO_SHARE_BUILD_PLAN.md#62-interface-first-sequencing-revision)
produced the native UI. The authorized
[implementation-first revision](P2P_VIDEO_SHARE_BUILD_PLAN.md#63-implementation-first-sequencing-revision)
now permits real core services before the full feasibility matrix is complete.

## Current status

Phase 0 is underway. The [native probe](spikes/phase0_probe/README.md) and
[Go/Pion harness](tools/interop_harness/README.md) now run. Initial physical-phone
and Windows results, fixes and remaining gates are in the
[Phase 0 record](docs/spikes/phase0-2026-10-18/README.md).
The [native app](apps/vault/README.md) implements the approved
[Quietly personal redesign](docs/INTERFACE_REDESIGN_PLAN.md): **Chats, Libraries,
My library**, with persistent Requests & transfers, Identity & Settings and
contextual Connection setup. Compact task routes become a rail/sidebar and
master/detail workspace as space permits. Drafts, editing selection and timeline
position survive navigation and resize. The interface uses real experimental
services: durable conversations and recipient-save acknowledgements, protected
local identities, signed/encrypted Manual and MQTT signaling, a confirmed
one-tap public broker preset, QR pairing, named connection problems,
authenticated direct WebRTC, persisted media approval/revocation, SQLite indexing, bounded range
playback and resumable downloads. Folder references and imported copies remain
distinct; publication and public discovery are separate opt-ins.

The [implementation-first revision](P2P_VIDEO_SHARE_BUILD_PLAN.md#63-implementation-first-sequencing-revision)
authorizes this work before comprehensive Phase 0 acceptance trials. Those trials
are deferred, not passed; basic runtime and security checks remain required.
See the [app instructions](apps/vault/README.md) for the current supported surface
and exercised verification. The external empty toolchain smoke project is not Vault.

Android developer packages build for ARM64 and x86-64. Windows packaging requires
MSVC ATL for protected storage; see the narrow installer and current build
evidence in the app README. An old preview executable is not a verified core build.

## Reproduce the preflight

Run from this repository in PowerShell; installation verification needs no elevation:

~~~powershell
flutter pub get
dart run melos bootstrap
dart run melos run analyze
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup\test-verifier.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup\verify-toolchain.ps1
~~~

Melos 8.9.0 is a pinned local dependency, with configuration in pubspec.yaml.
Commit pubspec.lock. The app and all nine packages are explicitly registered in
the workspace with `resolution: workspace`. If Windows plugin symlink privileges block
setup, follow the app-local junction preparation in the
[native build instructions](apps/vault/README.md#build-and-run); do not reinstall
the toolchain or change machine policy.

Run package behavioral checks after resolving dependencies:

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-core.ps1
~~~

To build an isolated empty template for BOTH Android and Windows:

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup\test-builds.ps1
~~~

To run that template after building:

~~~powershell
cd C:\dev\vault-toolchain-smoke
flutter run -d windows
flutter devices
flutter run -d <authorized-android-device-id>
~~~

These commands do not run Vault or prove WebRTC/player plugin compatibility.
See [environment evidence](docs/ops/ENVIRONMENT.md) and
[dependency decisions](docs/ops/DEPENDENCIES.md). For a fresh machine,
tools/setup/install-toolchain.ps1 installs prerequisites with Administrator rights;
existing installations should use verification rather than reinstalling.

## Architecture

`apps/vault` composes nine package boundaries: identity, protocol, signaling,
networking, directory, media indexing, delivery, playback and shared UI.
Identity/protocol remain pure Dart. Only `vault_net/src/webrtc_adapter.dart`
imports the native WebRTC plugin. Text, acknowledgements and media use
authenticated direct sessions; MQTT carries bounded signaling and explicitly
public discovery metadata only. Protected secrets use OS storage; conversation
history and library/source state use local SQLite.

Continue Phase 1 core integration under the recorded sequencing override.
Outstanding Phase 0 NAT/firewall, physical Android availability, shaped-link,
security and performance gates remain required before release-readiness claims.
Native builds and local-file playback do not satisfy those gates.
