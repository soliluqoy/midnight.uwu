# Midnight

![Midnight wordmark with crescent moon and star](design/brand/midnight/lockup.svg)

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

**Experimental software, not a production release.** Native builds and initial
runtime checks do not establish general internet reachability, reliable background
availability, independent cryptographic review or release readiness. The broader
physical-device, NAT/firewall, lifecycle, security and performance gates remain open.

Midnight was previously named Vault. Source paths, Dart package names, the Android
package ID (`dev.vault.vault`) and the Windows executable (`vault.exe`) retain that
name; the app's visible name is Midnight.

## What it does

- **Chats:** verified local contacts, single-use QR pairing, direct text delivery,
  recipient-save acknowledgements and persistent conversation history.
- **Libraries:** browse approved peers' photos and videos, view images, seek video,
  resume interrupted downloads and explicitly save copies outside the app cache.
- **My library:** reference selected folders or import copies, then explicitly
  start sharing and approve library access. Publication, approval and public
  discovery are separate decisions.
- **Adaptive native interface:** compact task routes, rail/sidebar navigation,
  large-text layouts and retained drafts and conversation position.

See the [native app guide](apps/vault/README.md) for the full workflow, storage
boundaries, platform behavior and recorded verification.

## Privacy and connection limits

- No accounts, operated backend, bundled API keys, telemetry, crash reporting or
  remote configuration services.
- Identity keys use OS-protected storage. Local chat history is **not encrypted
  at rest**. Identity loss has no automatic recovery.
- Chat text, acknowledgements and media use authenticated direct WebRTC sessions.
  No TURN or relay fallback: some network pairs cannot connect.
- Manual signaling is the default. The optional internet preset uses
  `broker.emqx.io:8883`, a third-party public MQTT broker, only after confirmation.
  You can also configure your own compatible broker.
- MQTT carries encrypted connection signaling and separately opted-in public
  listings, never chat text or media. A broker can observe connection metadata;
  it has no availability guarantee.
- Android publishing uses a visible foreground service; Windows offers explicit
  tray and sleep-prevention controls. Neither guarantees unattended availability.
- Library approval covers browse/play/download of the selected library, including
  future imports and source refreshes, for the grant's lifetime. Revocation cannot
  erase received or exported copies.

## Build and run

Development targets **Android and Windows** with Flutter/Dart. The workspace
requires Dart `>=3.13.0 <4.0.0`; see the [toolchain record](docs/ops/ENVIRONMENT.md)
and [dependency notes](docs/ops/DEPENDENCIES.md) for the recorded environment.
Windows builds require Visual Studio C++ tools, the Windows SDK and **v143 ATL**;
Android builds require the Android SDK and the app's configured NDK.

Run from PowerShell:

```powershell
git clone https://github.com/soliluqoy/midnight.uwu.git
cd midnight.uwu
flutter pub get
dart run melos bootstrap
powershell -NoProfile -ExecutionPolicy Bypass -File tools/setup/verify-toolchain.ps1
```

Melos `8.9.0` is pinned locally in `pubspec.yaml`; use `dart run melos`, not a global
runner. The app and all nine library packages share the committed `pubspec.lock`.
For a fresh machine, consult the [setup instructions](docs/ops/ENVIRONMENT.md)
before installing tools. Do not reinstall a working toolchain.

If Windows plugin symlink privileges block setup after dependency resolution,
use the existing project-local workaround:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File apps/vault/tool/prepare-windows-links.ps1
```

Build the real application, not the isolated empty toolchain smoke project:

```powershell
cd apps/vault
flutter build windows --release --no-pub --target=lib/main.dart
flutter build apk --release --split-per-abi --target-platform 'android-arm64,android-x64' --no-pub --target=lib/main.dart
```

Run Windows with the executable and its sibling DLLs and `data/` directory intact:

```powershell
& .\build\windows\x64\runner\Release\vault.exe
```

Android APKs are written to `apps/vault/build/app/outputs/flutter-apk/`, relative to
the repository root. They use developer/debug signing, **including release-mode
APKs**, not production signing.

**Preserve existing identities when updating.** Never uninstall or clear app data
to resolve an Android version downgrade. Follow the
[native build and install instructions](apps/vault/README.md#build-and-run),
including the ATL repair and Android version-code guidance.

## Connect two devices

1. Keep both apps running. In **Chats**, choose **Pair a phone** on one device
   and **Scan pairing code** on the other, or copy/paste the pairing code.
   Confirm the peer fingerprints; a display name alone proves nothing.
2. Choose connection setup explicitly. The confirmed internet preset exchanges
   signaling through the public broker; Manual mode requires exchanging every
   queued frame and its replies within the retry deadlines.
3. Open the contact and choose **Connect**, then send text once authenticated.
   **Delivered** means the recipient app saved it. **Unconfirmed** may mean it
   arrived; explicit Retry reuses the message ID to avoid duplicate received copies.
4. To share media, add sources in **My library**, choose **Start sharing**, and
   approve the other person's access request. Adding a contact alone grants no
   library access.

See the [detailed workflow](apps/vault/README.md#real-core-workflow) for pairing,
manual signaling, permissions, downloads and revocation.

## Development checks

Run from the repository root after resolving dependencies:

```powershell
dart run melos run analyze
dart run melos run format
powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify-core.ps1
```

For setup/verifier changes, also run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/setup/test-verifier.ps1
```

The core verifier covers the production workspace. Separate transport probes
and the interop harness have their own README commands. Empty-template builds,
automated checks and synthetic probes do not close product feasibility gates.

## Repository map

| Path | Purpose |
|---|---|
| [`apps/vault/`](apps/vault/README.md) | Native Flutter app for Android and Windows |
| `packages/vault_*` | Nine shared packages: identity, protocol, signaling, networking, directory, media indexing, delivery, playback and UI |
| [`design/brand/midnight/`](design/brand/midnight/README.md) | Midnight artwork and icon generation |
| [`design/vault/`](design/vault/README.md) | Browser interface study with simulated peer state; not the native runtime |
| [`spikes/phase0_probe/`](spikes/phase0_probe/README.md) | Native transport, playback and lifecycle probes |
| [`tools/interop_harness/`](tools/interop_harness/README.md) | Go/Pion interoperability harness |
| [`docs/FILE_TREE.md`](docs/FILE_TREE.md) | Implemented components versus planned work |

Identity and protocol remain pure Dart. The native WebRTC boundary is
`packages/vault_net/lib/src/webrtc_adapter.dart`. MQTT handles signaling and
opt-in public discovery; media delivery stays direct.

## Plans and evidence

The [product and build plan](P2P_VIDEO_SHARE_BUILD_PLAN.md) is authoritative.
Its [implementation-first revision](P2P_VIDEO_SHARE_BUILD_PLAN.md#63-implementation-first-sequencing-revision)
permits real core implementation before the full Phase 0 matrix is complete;
it does **not** pass those gates.

- [Architecture audit](reports/Vault%20prebuild%20architecture%20audit.md) and
  [baseline decision](docs/adr/0001-prebuild-baseline.md).
- [UI/UX plan](docs/UI_UX_BUILD_PLAN.md) and
  [Quietly personal interface redesign](docs/INTERFACE_REDESIGN_PLAN.md).
- [Initial Phase 0 observations](docs/spikes/phase0-2026-10-18/README.md).
- [Native app verification record](apps/vault/README.md#verification).

Physical-device, hostile-network, background lifecycle, security and performance
acceptance remain separate from implementation and developer-build evidence.
