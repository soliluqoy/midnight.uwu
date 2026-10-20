# Vault Messenger native application

Experimental Android and Windows Flutter messenger with verified local contacts,
authenticated direct text delivery and durable local history. Personal media
libraries remain a secondary, separately approved feature. Shared visual tokens
remain in `vault_ui`; that package's isolated study screens/tests are not the
production runtime. No sample identity, contact, conversation or successful
transfer is inserted into the app.

**Experimental, not a production release.** Phase 0 remains open under the
[implementation-first sequencing revision](../../P2P_VIDEO_SHARE_BUILD_PLAN.md).
No physical-device, hostile-network, background availability or release-security
gate is implied by an installable build. Keep both peer processes running.
Explicit best-effort OS availability support is described below; it is not
unattended hosting or a reachability guarantee. There is no push wakeup.

## Interface

**Chats**, **Libraries** and **My library** are the three primary destinations in
the approved [Quietly personal redesign](../../docs/INTERFACE_REDESIGN_PLAN.md).
**Requests & transfers**, **Identity & Settings** and **Connection setup** remain
reachable utilities, not competing primary tabs. Compact layouts open focused
tasks with Back; medium layouts use a rail and wide windows use a sidebar and
conversation master/detail. Contact details becomes a side pane when space
permits. Large text uses simpler layouts rather than squeezing fixed columns.

Chats searches verified local contacts, shows actual connection state, unread
counts, drafts and the latest message. Per-person draft text/editing selection
and timeline position survive destination changes and adaptive resize.
The composer sends at most 4096 UTF-8 bytes while connected. Text is selectable;
timestamps are sender-supplied, and Delivered means saved by the recipient app,
not read. Failed/interrupted or timed-out sends are **Unconfirmed · May have
arrived**. Use **Retry** on that message: the same ID prevents duplicate received
copies. Messages are not queued for automatic offline delivery.

Adding a verified contact permits direct text; it grants no library access.
**Pair a phone** shows a single-use QR code for ten minutes. **Scan pairing
code** reads it with the Android camera, or accepts the pasted code text on
Windows. Both devices then add each other. The host dials after its person
chooses **Add contact**, and the scanner waits for that connection until the
code expires; see the
[connection setup decision](../../docs/adr/0005-connection-setup-ux.md).
When Vault ignores or cannot finish a connection, it names one of five problems
with its remedy in the conversation header, Contact details, Connection setup
and the Chats list. The problems are a noncontact sender, a contact you
disconnected, no answer in time, no direct route between the networks, and an
unreachable connection-setup service.
Conversation actions retain Connect/Disconnect and contextual **Connection setup**.
**Contact details** is the canonical full fingerprint, connection, two-direction
library-access and revoke/export/remove surface. Pending Manual exchange frames
use one complete export/import queue. Utility Back/Escape returns to the
originating task; a late library result does not replace a newly selected task.
Stopping sharing keeps messenger-enabled sessions; explicit disconnect, contact
removal and revocation can close them.

**Libraries** offers known-person search, All / Ready to browse filters, actual
authorized cover previews and contextual Connect / Request access / Open library
actions. Ready means connected with an authorized index loaded, not a guarantee
that a grant cannot expire. **Check earlier approval** checks persisted access
without asking for a fresh grant. Remote libraries have a focused owner-labeled
view, filename/type filters over the loaded index, and 100-item pages.
Approved previews load automatically through two bounded request lanes; no
private preview is inferred from public discovery. Unavailable previews stay
explicit, with retry rather than sample artwork.

The whole media card—including its filename—opens a dark gallery. Previous/Next
follow the current filtered scope; photos support zoom, pan and Fit. Page Up/Down
or Alt+Left/Right navigate; photo arrow keys navigate, +/− zoom, 0 fits,
Shift+arrows pan, and Escape returns. Earlier task notices clear on viewer entry
instead of covering its controls.
Details disclose metadata and copy/availability limits in a wide side panel or a
bounded compact overlay. Videos retain native adaptive seek/time controls and
persistent labeled Play/Pause, volume and fullscreen actions.
Skipping an in-flight image cancels and awaits its transfer cleanup;
closing/changing videos releases their matching loopback listeners. A closed
peer session stops the viewer and blocks further loads.
Transient recovery instead shows **Reconnecting to the library**, retaining the
selected item. Once connected, the viewer reopens a newly authorized source.
Foreground video recovery retains position, volume and playback intent; switching
apps deliberately leaves playback paused. Explicit disconnect, revocation and
terminal failure remain final for that viewer.

**My library → Add media** distinguishes referenced folders from imported copies;
**Folders & imports** owns source management. **Start sharing** remains an explicit
scope-reviewed decision, separate from adding media, approving people and
discovery. A global **Stop sharing** control remains visible while publishing.
Requests show one whole-library, browse/play/download, 24-hour approval review.
Expired/ended requests leave the pending queue. Transfers show actual byte
progress; only their progress widgets rebuild on byte updates. Deleting one
content-addressed cache file also clears any other completion pointing at it.
Settings groups identity, appearance, connection, native availability, privacy
and experimental-build information into focused routes. No service scope,
identity/storage boundary or networking capability is changed by the redesign.

## Real core workflow

1. Startup awaits protected identity, contact and owner-authorization storage,
   public preferences, durable conversation history and the library index.
   Storage errors show a blocking retry screen; they do not start networking,
   use a blank preview,
   automatically reset keys or fall back to plaintext. An exclusive OS file lock
   is acquired before protected state is read: a second process fails closed with
   “Vault is already running.” The same store object is shared by all repositories.
2. In **Chats**, choose **Pair a phone** on one device and **Scan pairing
   code** on the other. The scanner shows the host's complete fingerprint,
   and the host confirms the scanner's fingerprint before adding it. The code
   works once and expires after ten minutes. Without a camera, use
   **Copy code as text** and **Enter pairing code**. To exchange cards by hand
   instead, choose **Share my contact** and **Add person**, then compare the
   **complete fingerprint** through an independent trusted channel. A matching
   display name proves nothing.
   Contact/card export never contains private keys. There is intentionally no
   private-key backup/export/import operation or automatic identity recovery.
3. In **Settings → Network**, choose **Connect over the internet**, manual
   signaling or **Use my own broker**. Manual stays the default for new and
   existing configurations. The first-run Chats screen and Connection setup
   offer the internet preset as the primary button. The preset uses
   `broker.emqx.io:8883`, a third-party public broker that Vault does not
   operate and that has no availability guarantee; Vault switches to it only
   after you confirm. Pairing may move the scanner to the broker named in the
   code, after showing it. Export/import public configuration independently
   from contacts; disconnect before changing transport. No account, backend,
   TURN service or credentials are bundled. MQTT requires a reachable broker
   with a trusted TLS certificate and permitted anonymous access. The broker
   carries encrypted connection signaling and, only with separate opt-in,
   signed public listings; never chat text/receipts, library/media/grants.
   Configuration contains only public fields.
4. Open a person in **Chats** and choose **Connect**. Use **Connection setup**
   for transport controls and Manual frame export/import.
   Manual mode
   requires exporting **every queued frame**, importing replies, and exchanging
   acknowledgements within retry deadlines; keep both apps active. The full
   pending export queue is visible. Removing a frame is only export-queue cleanup,
   never a claim of protocol acknowledgement. MQTT readiness is displayed
   separately from authenticated peer session state. Async signaling failures and
   negotiation failure reasons are visible. Explicit disconnect persists a public
   per-peer inbound-offer block before closing; it survives process restart and
   is cleared only by explicit Connect, not preference import or network recovery.
   Stopping signaling remembers current peers, disconnects all and stops
   publication; launch never automatically dials or publishes.
   Once authenticated, use the conversation composer to send and receive text.
   Both apps must be running and directly reachable; Manual setup is not a
   mailbox. MQTT can exchange connection frames automatically when configured,
   but never stores chat for an offline recipient.
5. In **My library → Add media**, choose **Add folder** to reference originals
   without copying the whole library, or **Import media copies** for durable
   app-private copies. Windows uses the native folder picker; Android retains the
   explicitly chosen SAF tree read grant. Refresh referenced folders explicitly
   through **Folders & imports** after source changes.
   The index computes real content/chunk digests and persists metadata in SQLite.
   Real per-file metadata and bounded posters are extracted and persisted when a
   supported codec is available; unsupported previews are explicitly unavailable,
   never replaced with sample artwork. Remote preview loading is an authenticated,
   approved delivery operation, never public discovery metadata.
   Local and remote library views page 100 entries at a time. Start publication only
   after acknowledging scope and received-copy limitations. Initially all media
   is **local only**. Publication alone does not authorize a peer. A viewer must
   request library access and the owner explicitly approve the authenticated
   fingerprint. An approval covers browse/play/download of the **whole selected
   library, including source refreshes and future imports**, for the default 24 hours. Valid grants
   survive normal restart until expiry/revocation, but publication never starts
   automatically. Pending requests and approvals made this run are distinguished
   from persistent grant state. Any contact can be explicitly revoked, even if
   their approval was made in an earlier run.
6. Browse an approved remote index; video uses authenticated loopback playback
   while viewing an image explicitly downloads a verified full image into cache.
   Image decoders cannot use the Range server's bounded partial-response contract.
   Neither viewing nor downloading implies a user-saved copy. Video seeking
   uses HTTP Range reads and may fetch additional chunks. Downloads expose byte
   progress and cancellation; matching interrupted content may resume. Failures,
   denials, unapproved sessions and unavailable peers are not converted to success.
7. A completed cached download is **not a user-saved copy**. Choose **Save copy…**
   and an OS destination. Android uses `ACTION_CREATE_DOCUMENT`; Windows uses the
   native save picker. Success is reported only after copying finishes; cancellation
   does not count as saved. Delete completed cache files independently from saved
   copies. The displayed completion list is intentionally this-run-only, not a
   fabricated persistent download history.
8. Stop publication to stop future serving (remembered grants are not silently
   revoked), or revoke a contact to persistently invalidate their access and stop
   serving them. Closed/failed sessions remove remote browse results and stop the
   player surface. Received/buffered bytes and exported files cannot be remotely
   erased. Use revocation before forgetting a contact; Remove contact performs
   both automatically.

**Public MQTT discovery is a separate explicit opt-in in Libraries.** Listening for
listings and publishing your own listing are independent toggles, both initially
off and never restored as publication instructions. Listing publishes signed
public identity/binding, display name and indexed item count to the configured
broker's subscribers, not media or permission. A bounded SQLite cache reverifies
signed records and original expiry; search is local over recently received,
unexpired records, not global search. Compare the full fingerprint before explicitly
adding a discovery result as a contact. No auto-contact, auto-connect or auto-grant.
Manual signaling honestly does not support public discovery. There is no live
camera or microphone feature. The camera is used only on Android to scan a
pairing code, and frames are decoded on the device.

## Explicit native availability

Starting library publication first starts native availability; denied permission
or failed eligibility leaves delivery off. Native Stop/Quit/timeout/suspend events
disable delivery before the method-channel callback is acknowledged.

- **Android:** a user-started visible `dataSync` foreground service with Stop
  action and a bounded wake lock uses the existing UI engine. Notification
  permission is requested only for Publish, never at launch. Task removal stops
  the service. A local budget under six hours, Android shared data-sync quotas,
  Doze, force-stop, process death and vendor restrictions still apply; a service
  is not proof that the Dart engine or network will remain available. There is no
  boot receiver, restart-on-death or automatic publication.
- **Windows:** explicit Publish creates a notification-area icon and requests
  `ES_CONTINUOUS | ES_SYSTEM_REQUIRED` automatic-sleep prevention. Closing the
  publishing window asks whether to keep serving in the tray. Open/Stop/Quit
  remain available; Quit awaits delivery shutdown with a five-second native
  fail-safe if Dart is unresponsive. Explicit sleep/shutdown/policy remain in
  control. The opt-in login-launch toggle uses the current quoted executable in
  `HKCU Run\\Vault` and only opens the application, never publication, discovery
  or a connection. Stop releases the native sleep request.

Ordinary Android app switching and Windows focus loss/minimization do not request
publication shutdown. Short route interruptions pause traffic for up to ten
seconds while the existing authenticated direct route is revalidated; they no
longer immediately force a new signaling exchange. Longer outages use ICE restart
with fresh authentication. MQTT exchanges those frames automatically when
reachable; Manual mode still needs current frames exchanged for a full restart.
Stop, process/task removal, Android service budgets and Windows explicit sleep
remain subject to the limits above; returning never implicitly republishes.

## Storage and native boundaries

- Conversation history and local unread markers live in application-private,
  identity-scoped `messages-<nodeId>.sqlite3`, separate from public preferences
  and media grants.
  History is **not encrypted at rest**; OS disk/device access protections apply.
  Incoming messages are persisted before acknowledgement. Peer/message-ID
  deduplication survives restart; changed-body collisions fail. Sending rows
  interrupted by restart become unconfirmed. The store refuses new messages at
  10,000 rows rather than silently deleting history/deduplication records.
  Forgetting a contact does not remotely erase or automatically delete history.

- `ProtectedStore` implements the shared `SecretStore` through exactly pinned
  `flutter_secure_storage: 11.2.0`. Its SDK requirements (`Dart >=3.8.0`, Flutter
  `>=3.19.0`) fit this workspace. The package was not initially cached and is
  resolved by the root integration owner. Android uses the plugin's RSA-OAEP /
  AES-GCM defaults with **`resetOnError: false`**. Never change this to automatic
  corruption reset. Windows uses the plugin's protected platform storage. Private
  identity seeds and owner authorization secrets never go into application
  `shared_preferences`, clipboard exports, logs or ordinary files.
- `SharedPreferencesAsync` contains only the allowlisted `vault.public.v1` public
  config: name, transport, broker host/port, appearance and canonical explicit-
  disconnect fingerprints. Writes are serialized; importing preferences cannot
  clear an existing disconnect block. Imports reject extra
  fields (including seed/private-key fields), invalid types and oversized text.
  Contact public data is handled by the verified shared contact repository.
- Android source folders use `ACTION_OPEN_DOCUMENT_TREE` and
  `takePersistableUriPermission`. Recursive metadata enumeration is bounded to
  20,000 documents and depth 32; media reads are seekable blocks of at most
  256 KiB through `VaultSourceAccess`. Virtual, nonseekable or metadata-less
  providers fail explicitly rather than silently copying the whole source.
  Permission loss, disappearance and source modification fail verified reads;
  explicit refresh replaces the index atomically. Windows references selected
  filesystem folders through the shared file-source adapter. Removing a source
  removes its index entries and releases its Android tree grant, not originals.
- Individual Android `ACTION_OPEN_DOCUMENT` imports stream with a 64 KiB buffer
  into temporary app-private staging, then into durable library-owned copies;
  staging is deleted after import. A `content://` URI is **never passed to `File`**.
  Video playback verifies source chunks through bounded loopback Range reads.
  A selected local image is streamed into a temporary verified preview file and
  removed when its viewer closes; remote image viewing uses the visible verified
  download cache. No fake sparse media file or whole-library copy is needed.
  Folder refresh is explicit, not filesystem monitoring or collection discovery.
  `NativeMediaMetadata.extract(SourceEntry)` is injected into `VaultLibrary`.
  Android uses sampled `BitmapFactory` images and scaled `MediaMetadataRetriever`
  frames (video posters require API 27+, metadata works on the API 24 minimum).
  Windows uses bounded Flutter image codecs and a muted, scaled media_kit frame.
  Metadata/poster failure is recorded as unavailable; it is not fabricated success.
- Release Android manifest declares `INTERNET` and `ACCESS_NETWORK_STATE`, disables
  backup/device-transfer data, and permits cleartext only for `127.0.0.1` and
  `localhost` player HTTP. External signaling stays TLS. User-started publication
  declares foreground-service/data-sync, notification and wake-lock permissions.
  `CAMERA` is declared for pairing and requested only when **Scan pairing
  code** opens the camera; the camera feature is optional. The manifest
  removes the plugin-declared `RECORD_AUDIO`, `WRITE_EXTERNAL_STORAGE` and
  implied `READ_EXTERNAL_STORAGE`. No blanket storage or microphone permission
  is requested. The scanner uses AndroidX CameraX and the pure-Dart `zxing2`
  reader, not Google ML Kit or Play services. The native
  minimum remains Android API 24. Direct-only WebRTC rejects relay or unverifiable
  selected routes; lack of a usable direct path is an honest connection failure.
- Identity loss is permanent without a separately designed recovery mechanism.
  Unlock the device and repair storage access before retrying startup; do not
  clear application data unless intending to replace this identity.

## Build and run

Use the pinned repository Flutter/Dart toolchain. From the repository root:

```powershell
flutter pub get
powershell -NoProfile -ExecutionPolicy Bypass -File apps/vault/tool/prepare-windows-links.ps1
```

A known Windows plugin-symlink privilege warning is handled by the existing
app-local junction script, not SDK reinstall or machine-policy changes. Only use
it after dependency resolution produced `.flutter-plugins-dependencies`. A real
dependency-resolution failure is not fixed by this workaround.

Windows protected storage also requires **C++ ATL for the selected v143 toolset**,
not just MSVC. If `atlstr.h`/`atls.lib` is missing, run the narrow component
installer from an **Administrator PowerShell at repository root**:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/setup/install-windows-atl.ps1
```

It adds only `Microsoft.VisualStudio.Component.VC.ATL` to the existing VS2022
instance. It does not reinstall the SDK, force-close applications, change machine
policy or substitute plaintext storage. The ordinary verifier checks the active
toolset's actual ATL header/library, not an unrelated older toolset.

Build from `apps/vault/`:

```powershell
flutter pub get
flutter build apk --release --split-per-abi --target-platform 'android-arm64,android-x64' --no-pub --target=lib/main.dart
flutter build apk --debug --split-per-abi --target-platform 'android-arm64,android-x64' --no-pub
flutter build windows --release --no-pub --target=lib/main.dart
```

Package ID stays `dev.vault.vault`; launcher label is **Vault Messenger**. APKs are
in `build/app/outputs/flutter-apk/`; Windows executable is
`build/windows/x64/runner/Release/vault.exe` with its sibling DLLs and `data/`.
Builds intentionally use developer/debug signing, including release-mode APKs.
Do not describe them as production-signed releases.

```powershell
adb devices -l
adb -s <device-id> install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
adb -s <device-id> shell am start -n dev.vault.vault/.MainActivity
```

**Preserve identity when updating.** Compare installed/package version codes
before changing APK variants. Split ABIs add offsets to the base build number;
version 0.3.0 uses base4007: ARM64 is versionCode6007 and x86-64 is 8007.
Never resolve a downgrade by uninstalling or clearing application data.
Flutter run can automatically
uninstall after a downgrade rejection; use a matching-or-higher developer build
or `--use-application-binary` with the already selected debug APK instead.
The first temporary smoke build used base1 and Flutter automatically replaced the
older emulator-only preview after a downgrade rejection. No physical device was
touched. The base was raised before the final developer packages; do not repeat
that uninstall behavior on an identity-bearing installation.

## Verification

`tools/verify-core.ps1` analyzes/formats the actual workspace and runs every
implemented package and app behavioral suite. The native build commands above
target the real default app, not the separate design study.

### Connection setup verification (2026-10-20)

- `tools/verify-core.ps1` passed strict analysis, unchanged formatting of 100
  Dart files and 313 tests across the ten suites. The app suite has 52 tests.
- New regressions cover the connection problem table and its bounded notices,
  `PeerMesh` reporting `youDisconnected` and `notAContact` without creating a
  native peer, the internet preset in `PublicConfig`, strict pairing-invite
  parsing, introduction acceptance and every rejection case (wrong MAC,
  expired or reused secret, card that is not the signer, other types from a
  noncontact), the scanner state machine, and a QR round trip through a
  camera-like luminance frame.
- `flutter build windows --release` and the optimized ARM64 developer-signed
  APK built from `lib/main.dart`. The merged APK manifest adds only `CAMERA`
  to the earlier permissions, and its dex has no ML Kit, Google Play services
  or Firebase classes. The existing `flutter_webrtc` Kotlin Gradle Plugin
  warning remains.
- No device ran this change. The camera scanner, a two-device pairing and an
  LTE-to-Wi-Fi connection have not been observed. Carrier NAT can still leave
  no direct route; the app now reports that instead of timing out silently.

### Quietly personal implementation verification (2026-10-19)

- `tools/verify-core.ps1` passed strict analysis, unchanged formatting of 89 Dart
  files, and **278 tests** across the ten package/app suites. The app's 37 tests
  and strict analysis also passed after the final media-entry notice fix.
  New regressions cover draft/selection/history continuity, hidden-composer
  focus, toolbar Escape, wide contact-pane Back, late browse/approval replies,
  expired pending requests and shared-file cache deletion. Theme tests require
  at least 4.5:1 normal body-text contrast and 7:1 high-contrast body text.
- Isolated native profile runs used the real `VaultApp`, protected identities,
  authorization, SQLite, metadata extraction, authenticated native WebRTC and
  delivery. Both selected routes were verified **host/host**. Public preferences,
  isolated storage locations and the in-process signed/encrypted Manual-frame
  bridge were test adapters. Each pair ran in one native engine; this is not
  a two-device, STUN/NAT or general-network result.
- **Windows:** full fingerprint verification, draft/selection return, actual
  two-way text and recipient-save acknowledgements, the full Manual queue,
  Add media choice/cancellation, owner review → Contact details → Back,
  denial, explicit 24-hour approval and authorized browsing passed. Stop sharing
  blocked new protected reads while chat remained usable. Photo filename/card
  entry, zoom/pan/Fit, compact metadata, native video duration/seek/play/pause,
  revocation and recipient message-ID persistence after SQLite reopen passed.
  A native window capture showed the decoded 1280×720 H.264 video frame;
  its 12-second fixture has no audio. Windows UIA invocation separately changed
  photo zoom from 100% to 150%, verified in a fresh snapshot.
- **Android API 36 x86-64 software emulator:** verification, Manual exchange,
  authenticated two-way text, drafts, authorized photos/zoom/Fit, sharing-review
  cancellation, terminal revocation, SQLite reopen and Settings passed.
  **Video rendering is not accepted:** actual compositor capture showed a black
  video surface, and one paused seek timed out. Earlier player-state checks
  reached duration/seek/play/pause, but do not prove a decoded Android picture.
  The visible Play control responded; the cause of the black surface was not
  isolated. No physical Android, codec/audio or video-reliability pass is claimed.
  Native publication was not started: notification permission remained
  user-owned and ungranted.
- Wide/compact, light/dark, 200% text, high contrast and reduced-motion settings
  were exercised with actual widgets. Most scenario actions used
  `LiveWidgetController`; Windows window/UIA and Android compositor captures
  independently inspected the native surface. These are not Narrator/TalkBack,
  recruited usability, performance/DPI/RTL, real OS picker/save or background
  availability acceptance results. No unhandled Flutter errors were recorded.
- The disposable native entrypoint and fixture-only packaged outputs were
  removed. Owned protected records and temporary service data were cleaned;
  unrelated protected values and the user's running Windows Debug app were
  retained. Normal build commands target `lib/main.dart`.
  The previously recorded default-STUN native crash below remains unresolved.

Normal `lib/main.dart` developer artifacts were built after removing the native
fixture. Windows executable metadata reports `0.3.0+4007`; APK manifests report
`0.3.0`, package `dev.vault.vault`, minimum API 24 and target API 36.

| Target | Artifact, relative to this app | Version / versionCode |
|---|---|---|
| Windows x64 Release | `build/windows/x64/runner/Release/vault.exe`, with sibling DLLs and `data/` | 0.3.0+4007 |
| Android ARM64 Release | `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` | 0.3.0 / 6007 |
| Android x86-64 Release | `build/app/outputs/flutter-apk/app-x86_64-release.apk` | 0.3.0 / 8007 |

The normal x86-64 APK updated the emulator through `adb install -r`, without an
uninstall/data clear. Its actual Chats, Libraries and My library surfaces were
inspected, with sharing still off. The normal Windows Release executable
correctly refused a second app-storage writer while the user's Debug app remained
running. That protects identity, but is not a second normal-data Windows session.
The separately owned blocked Release window was closed; the user's app was not.
Builds retain developer signing and the existing `flutter_webrtc` future-Kotlin-
migration warning. No dependency/toolchain upgrade or production-release gate is
implied.

### Messenger conversion verification (2026-10-19)

- The actual Windows `VaultApp` composer sent text to a second generated identity
  over real native WebRTC. Both selected routes were verified host/host; the reply
  arrived and delivery states reflected persisted recipient acknowledgements.
  Stopping library sharing left the chat session usable.
- A completed isolated host-only native trial exercised composer Send, reverse
  reply, navigation to Libraries and back with a retained draft, and recipient
  runtime shutdown/reload with all three messages preserved. It captured wide,
  390px compact, dark/200%-text and disconnected-history surfaces with zero
  Flutter rendering errors. Native peers, cryptographic authentication, packet
  routing, SQLite and delivery acknowledgements were real; only the test
  identities/stores and the in-process Manual-frame bridge were isolated.
- The first default-runtime trial also delivered text both ways. A later
  default-STUN setup trial terminated in **`libwebrtc.dll` access violation
  `0xc0000005`, offset `0x1fcd`**, recorded by Windows Application event 1000.
  Its cause is unknown. The host-only exercise is not proof that this native
  stability issue is fixed or that general-network connection setup is reliable.
- No native GUI driver was installed. UI controls were exercised through their
  actual Flutter widget callbacks and screenshots captured the rendered surface,
  not OS mouse/keyboard automation. Local evidence is
  `.audit/messenger-native.json`, `.audit/messenger-native-*.png` and
  `.audit/messenger-native-crash.json`. The throwaway native source was removed;
  developer builds use normal `lib/main.dart`.
- The app suite passed 27 tests, including nine messenger regressions for
  persistence-before-ack, history/unread restart, lost-ack retry/deduplication,
  Unicode/byte/schema bounds, peer/session binding, interruption and capacity.
  The existing 16 delivery/cache tests also passed. All workspace behavioral
  suites passed through `tools/verify-core.ps1 -SkipAnalyze -SkipFormat`;
  the nine messenger tests passed again after final persistence-code formatting.
  These fixtures do not replace native or physical-device acceptance gates.
- Normal `lib/main.dart` Windows Debug and optimized ARM64 developer-signed APK
  builds succeeded. The existing WebRTC future-KGP-migration warning remains.
  No Android device was
  connected, installed, cleared or exercised for this change. WAN, separate
  device pairs, background availability and release-security gates remain open.

### Connection recovery verification (2026-10-19)

- The transport regression reproduced the old failure: a brief native disconnect
  could not restore the connected session without restarting negotiation.
- An isolated Windows native run used two generated identities, real WebRTC
  peers, signed/encrypted Manual frames bridged in process and verified host/host
  routes. A short injected route interruption resumed protected delivery on the
  same session. A sustained interruption invoked real native ICE restart,
  advanced generation and completed fresh mutual authentication; protected
  delivery succeeded afterward.
- The actual Windows gallery and native video decoder showed the recovery state,
  disposed the old source and reopened the selected video. Foreground recovery
  retained position and volume and continued playback. An injected inactive/
  resumed lifecycle retained approximately 11.167 seconds and volume 37 while
  leaving playback paused. Explicit disconnect released the source and showed
  the terminal connection-ended surface.
- Native loss flags and lifecycle events were injected through the debug VM
  service, not by disabling the user's network or operating another application.
  The viewer used a local generated MP4 with a real peer session; delivery's
  remote authorization/replacement paths are separate behavioral checks.
  Window content was captured through Flutter's rendered surface because the
  native GUI driver was unavailable. Evidence is local
  `.audit/connection-recovery-*` JSON/PNG files.
- Focused checks passed: 29 network tests, 16 delivery/cache tests and 18 app
  tests, including repeated recovery, delayed teardown, saturated request/read
  slots, late send failures, explicit disconnect and post-recovery revocation.
  Strict workspace analysis found no issues; all eight changed Dart files passed
  the formatter check. Delivery tests were run from `packages/vault_delivery`;
  a combined root invocation cannot resolve that component's SQLite native asset.
- Normal `lib/main.dart` builds passed: Windows Debug and optimized ARM64
  developer-signed APK, version **0.2.3** (Android code **6006**, base **4006**).
  Windows executable metadata reports `0.2.3+4006`. The existing WebRTC plugin
  future-KGP-migration warning remains. Temporary exercise source and generated
  video were removed; final binaries use the normal app, not the smoke entrypoint.
- No Android device was connected for this run. These observations do not prove
  physical phone app-switching, Doze, process-death recovery, WAN network-flap
  behavior or uninterrupted background streaming. User identities and library
  state were not used by the isolated exercise.

### Browse-first gallery verification (2026-10-19)

- Strict workspace analysis passed with no issues. All six changed Dart files
  passed the formatter check. App tests: **12 passed**; delivery/cache tests:
  **11 passed**; shared UI tests: **4 passed**. Delivery tests require
  `flutter test --no-pub`, not the standalone `dart test` runner.
- A temporary production-tree render exercise passed all four destinations at
  320/390/600/1280 logical pixels, dark mode at 200% text at 390/1280, an approved
  remote library, filename filtering/no-results and return-to-Explore navigation.
- Native Windows GUI checks used isolated identities/preferences, actual
  indexed image/video fixtures and an explicitly in-memory peer transport.
  Observed approved covers loading automatically, cover-to-library navigation,
  actual remote thumbnails, video filtering, photo viewing/zoom/next/details,
  and the native video decoder displaying a verified loopback source.
- A focused native local-video exercise observed Play/Pause state transitions,
  fullscreen entry and Escape exit, compact persistent controls, and Page Down
  switching from video to photo. Native seek dragging was not re-verified.
  These exercises are not a new WebRTC network or physical Android trial.
- Normal `lib/main.dart` builds passed: Windows **Debug** and the optimized
  ARM64 developer-signed APK. The existing `flutter_webrtc` future-KGP migration
  warning remains. The running user release app and its data were not replaced.

Captures are local `.audit/native-*` and `.audit/redesign-*` artifacts, with
fictional contact names confined to the isolated exercises. Temporary harness
entrypoints, test sources and fixture state were removed; no sample contacts or
media were added to the production application. Design rationale and primary
research links are in [the UI/UX plan](../../docs/UI_UX_BUILD_PLAN.md).

### Interface redesign verification (2026-10-19)

A temporary Flutter rendering harness exercised the real production widget tree
with isolated identity/library state and mocked native availability/preferences.
It imported two real image fixtures, added a contact, rendered all destinations
at 320/390/600/1280 logical-pixel widths, and checked dark mode at 1.7× text scale.
It also opened media metadata, cancelled sharing consent without starting
networking/publication, expanded a contact fingerprint and saved an edited name.
All seven existing app tests plus the smoke scenario passed; the four shared UI
tests passed. Render captures are local artifacts in `.audit/ux/`.
Strict workspace analysis (`dart run melos run analyze`) found no issues.
Changed Dart files were formatted.
The ARM64 optimized developer-signed APK and Windows release app built
successfully with `--no-pub`. They are build evidence only, not new native
interaction/network evidence. The APK build retains the existing
`flutter_webrtc` future Kotlin Gradle Plugin migration warning.

This is rendered-widget evidence, not a new physical-device/network trial.
The native GUI driver was unavailable; the existing running user app and its
identity were left untouched. The temporary harness was removed afterward.

### Observed core integration (2026-10-19)

- Final strict analysis found no issues; formatting checked 79 files unchanged.
- The core behavioral suites passed 223 tests: identity/HPKE vectors, wire/CBOR/
  grant vectors, persistent authorization/revocation, signaling bounds/reliability,
  discovery, source reconciliation, cache/Range/delivery, native-session policy
  and app configuration/startup failure behavior. Coverage percentage is not claimed.
- A live TLS MQTT5 run against `broker.emqx.io:8883` exchanged a signed HPKE-sealed
  offer, authenticated encrypted ACK and verified public listing between generated
  identities. Enabling discovery during an outstanding ACK caused recoverable
  reconnect/retry diagnostics; delivery still occurred once and pending ACKs drained.
  This is one short public-service run, not an availability/failover guarantee.
- A real Android36 x86-64 emulator run created two native peers in **one process**.
  Both selected host/host ICE paths. OS-protected identity readback, SQLite indexing,
  native 1280x720/12000ms MP4 metadata and poster extraction, mutual session
  authentication, unapproved-browse rejection, explicit approval, protected poster,
  cold tail HTTP Range bytes, verified multi-chunk download and post-revocation
  rejection all succeeded. This is not Android-to-Windows or Internet NAT evidence.
  Manual full-frame signaling was bridged locally by the exercise; it configured
  no STUN or TURN servers. Human copy/paste and physical pairing remain separate trials.
- The generated MP4 was 558,439 bytes. Source and download SHA-256 matched:
  `1fa6da9910a149aa42b4c961f610b372855c96744ddd23a34ad065b89c228fa6`.
  Verified download progress took about 1.5s in that debug/emulator run. Full awaited
  revoke/native closure took about 8.3s; the separate <=1s scheduling-stop target
  was not measured or established. No remote audible playback or seek-percentile
  result follows from an exact HTTP Range byte check.
- The first native attempt hit an unlocalized native timeout while the emulator
  also displayed a **System UI** ANR. A later transfer timed out under repeated
  per-fragment key-binding cryptography. Sessions now verify the immutable contact
  pin once, re-resolve/compare it on operations, and retain every direct-route and
  owner-grant check. The corrected native flow passed without increasing deadlines.
- Temporary exercise source and delivery tracing were removed after proof.
  Local generated evidence is `build/core-native-pass.json` and
  `build/vault-core-pass.png` at repository root; these are not committed fixtures.
  The screenshot still contains the emulator's separate System UI ANR overlay.
- Android ARM64/x86-64 debug packages and the optimized ARM64 release package
  built. The ARM64 release is 47.8MB, version0.2.0/code6002, API24 minimum/API36
  target, and its APK Signature Scheme v2 verifies with the Android Debug signer.
  The default app installed/launched on the emulator and rendered the real empty
  Library after protected bootstrap (`build/vault-core-app.png`); no permission
  prompt or successful peer state was inserted. The System UI ANR obscured controls.
  The full Windows build
  currently fails at the protected-storage plugin's missing `atlstr.h`; this
  non-administrator session cannot install ATL. The actual Windows runner/tray
  sources compiled with zero warnings/errors, but that is **not a linked app**.
  An older `vault.exe` left in build output is not a validated core artifact.
- Setup verifier regression checks passed nine assertions; PowerShell setup
  scripts parsed and the narrow ATL installer refused an unapproved non-admin
  install before changing the machine. The elevated installation was not run.
- An approved elevation attempt returned Windows' “operation was canceled by
  the user” before the elevated installer started. No automatic UAC retry,
  privilege workaround or insecure storage fallback was attempted.

Earlier interface-preview observations are not evidence for this core. Physical
Android/Windows pairing, broader NAT/firewall and shaped-link trials, codec/audio,
FGS/Doze/process-death behavior, soak/performance budgets, independent security
review, user-owned release signing and complete license review remain open.

### Optimized Android startup regression

The physical-phone release reported “Vault could not safely open storage” after
protected identity, contacts and authorization had loaded. The failure was the
`SharedPreferencesAsync` JNI settings getter, not a missing storage permission.
R8 had renamed Kotlin coroutine/result classes that the generated Dart JNI
bindings look up with literal JVM names and method descriptors.

`android/app/proguard-rules.pro` keeps the preferences registrar's descriptor
classes and the specific Kotlin suspend-call ABI used by `package:jni`.
Shrinking/optimization stays enabled; dependencies, preference namespaces,
protected keys and `resetOnError: false` are unchanged.

This regression needs the **optimized ARM64 APK on Android**: host-side Dart or
debug/emulator tests do not exercise R8's JNI renaming. Update in place using the
commands above, verify the actual Library screen (an Activity launch alone is
insufficient), toggle appearance, force-stop/relaunch and verify that appearance
persists. Restore the original appearance afterward. This exercises settings
read, write and post-restart read through the real native bridge.

The real protected-storage failure regression remains in
`test/startup_security_test.dart`. Wording-only startup-widget assertions were
removed rather than re-pinned. Startup diagnostics record only exception types
and stack frames; exception messages, details, settings values and keys are not
logged. “No permissions allowed” before choosing sources/publishing is expected:
private app storage/Keystore need no user-granted storage permission, source
access uses the system picker, and notifications are requested only for Publish.

The fix is packaged separately as **0.2.1/code6004**, newer than the diagnostic
0.2.0/code6003 build. Local strict analysis and formatting passed; the app's seven
behavioral tests passed. The optimized ARM64 build preserves the required JNI
names. On the reconnected physical Xiaomi 13T Pro, optimized code6004 rendered
the actual Library, persisted an appearance toggle across force-stop/relaunch,
and restored the original appearance successfully.

### Physical cross-network trial (2026-10-19)

Windows Wi-Fi and Xiaomi 13T Pro cellular were exercised with separate native
processes, isolated OS-protected test identities and library directories, and
the actual production `VaultRuntime`, networking, authorization and delivery
services. The existing user identity, contacts, preferences and library were not
reset. USB carried test control and complete encrypted Manual signaling, not
the media transport. A second run used real Internet TLS MQTT5 signaling through
`broker.emqx.io:8883`; no public listing was enabled.

The trial reproduced and corrected three connection failures:

- Twenty-second gathering aborted despite usable Wi-Fi candidates because STUN
  retries on unrouted Hyper-V interfaces had not completed. Complete gathering
  took about 43 seconds; the native bound is now 60 seconds, without disabling
  adapters or truncating SDP.
- Concurrent channel startup could send a proof before the local challenge.
  Challenge transmission now precedes the proof even when trust/channel readiness
  is asynchronous.
- Native nomination changes briefly selected a direct pair reported as
  `in-progress`. All traffic now pauses for bounded, fresh validation; only a
  verified `succeeded` direct pair permits traffic. Relay/unknown/missing/ambiguous
  and failed reports still fail closed. Recovery monitor failures are generation
  scoped, and recovery allows its two-minute signaling wait plus the normal
  three-minute negotiation budget.

Observed outcomes:

- Both peers authenticated over direct IPv6 host/host routes across these two
  networks. Manual runs connected in approximately 48–49 seconds, and the MQTT
  run in approximately 53 seconds, including Windows gathering.
- Unapproved browsing was denied. Explicit approval enabled browsing; a download
  cancelled after a verified chunk resumed and completed. Both directions
  verified the 558,439-byte MP4 with SHA-256
  `1fa6da9910a149aa42b4c961f610b372855c96744ddd23a34ad065b89c228fa6`.
- Both directions returned exact final 8,192 bytes with HTTP206 and
  `Content-Range: bytes 550247-558438/558439`.
- Real native players decoded 1280x720, 12-second video on Android and Windows;
  playback advanced after seeking to eight seconds. Actual rendered frames were
  captured. Volume was muted, so audibility is not established.
- Owner revocation closed both sessions. Reconnection rejected the old grant;
  fresh approval restored access. Normal isolated-process restarts preserved
  valid grants, exercised again over MQTT.
- Android publication initially refused the existing notification denial. After
  the user enabled notifications, the visible data-sync foreground service
  started and an approved browse succeeded while the app was on Home.
  A subsequent `SwipeUpClean` process removal stopped serving; Windows lost the
  session and the reopened phone had no automatically restored session.

Temporary control/diagnostic code and isolated secrets/library data were removed.
Local evidence is `build/cross-network-verification.json`,
`build/vault-phone-remote-playback.png` and
`build/vault-windows-remote-playback.png` at the repository root.
These are local evidence artifacts, not committed media fixtures.

The normal application was rebuilt as **0.2.2/code6005** (ARM64 optimized
developer-signed APK), installed in place, and observed rendering the Library.
The normal ARM64 debug artifact was also restored; neither APK contains the
temporary test entrypoint. The current Windows debug app built and launched
`lib/main.dart`; its live widget tree contained the real Library, not a startup
failure. Both apps were left with normal user state, not the test contacts/library.
Strict workspace analysis passed, all 25 networking tests passed, and all five
changed Dart files were formatted. The setup verifier's UTF-8/Windows console
decoding failure was corrected; its 25 regression assertions and live prerequisite
check passed. These checks do not replace the physical observations above.

This is one real network pair, not the complete Phase0 matrix. IPv4-only/CGNAT
coverage, network-flap recovery, 1–2GiB stress, long Doze/foreground-service quotas,
seek latency budgets, audible audio and exhaustive source/save-picker journeys
remain separate gates. No TURN relay or broader release-readiness claim follows.

## Assets and dependencies

The Lora font is from the
[Google Fonts / Lora Project Authors](https://github.com/google/fonts/tree/main/ofl/lora)
under the bundled SIL OFL, registered with Flutter's license registry. Previously
bundled study media are not displayed or indexed by the production app; their
attribution remains in `assets/media/credits.json` under the
[Unsplash license](https://unsplash.com/license). OS selection/export and native
player integration stay in this app. Service implementations live in the eight
shared production packages rather than in the UI controller.
