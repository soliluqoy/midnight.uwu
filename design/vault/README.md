# Vault interface study

An isolated, dependency-free browser design prototype for the
[UI/UX build plan](../../docs/UI_UX_BUILD_PLAN.md). Not the production Flutter app,
not a Phase 0 probe, and not evidence that a product feasibility gate passed.

## Run

From the repository root in PowerShell:

```powershell
node design/vault/server.cjs
```

Open <http://127.0.0.1:4178>. Stop this server with Ctrl+C. To use another port:

```powershell
$env:VAULT_DESIGN_PORT = '4180'
node design/vault/server.cjs
```

The server binds only to loopback and serves only this directory. It accepts
GET/HEAD, supports single byte ranges for real browser seeking, and has no upload,
proxy, API, telemetry or external asset requests. No npm installation or Flutter
process is needed. All photos and the silent sample video are bundled locally.

## What to explore

- **My Library:** collections, photo/video filters, filename search, newest/name
  sorting, grid/list layouts and explicit publication review.
- **People:** separate identity comparison, connection and access states; contact
  labeling, partial-discovery explanation and manual-signaling explanation.
- **Activity:** approve/deny/block requests, remembered sample approval, session
  disconnect and downloaded-file request history.
- **Settings:** light/dark appearance, independent public-listing consent, sample
  cache clearing/uplink setting and a local study-diagnostics export.
- **Media:** actual local image viewing/zoom and browser video play/pause, seek,
  fullscreen and save. The bundled film is a 12-second silent still-image video,
  not a remote stream. Unsupported/corrupt files have a decode-error state.

The first view deliberately contains an **explicitly labeled illustrative
walkthrough library and fictional people**, not a scan of your device. The
production empty-start requirement is available through Walkthrough controls ->
Start empty. Choose files or Add folder to exercise actual browser-local file
selection; file bytes are not uploaded. Folder selection uses the browser's
folder picker, not Windows native app integration or Android SAF.

Study state is kept under `vault.interface-study.v1` in browser localStorage.
Contacts, download-request names, choices and playback positions may persist
there; imported file contents and object URLs do not survive a reload. Reload
sample library or Start empty resets study state. Clearing browser site data also
resets it. The diagnostics export contains only perspective, platform, connection,
access and publication simulation flags, not names, paths, files or keys.

## Paired walkthrough

1. Start with the illustrative Alex/Windows owner library. Review sharing,
   acknowledge the received-copy limit, and start the publication simulation.
   Public directory listing remains a separate, off-by-default choice.
2. Open Activity and review Sam's pending sample request. Compare the illustrative
   identity if desired, then approve browse/play/save for **Alpine days**. Other
   collections do not appear in the viewer's authorized library.
3. Open **Walkthrough controls** in the study bar and choose **Sam · viewer**.
   Open Alex's library. Photos and the local silent video can actually be viewed;
   peer connectivity and authorization are simulations, not cryptographic checks.
4. Seek the video, then open its **Session** study controls. Select Network
   interruption. Restore connection through the study controls, reopen the film,
   and observe that its playback position is restored without autoplay.
5. Disconnect explicitly from People. Reload: the intentional-disconnect state
   persists. Restore connection in the study controls does not override it; use
   Connect explicitly.
6. Return to Alex's perspective and revoke via Activity -> Manage access. Switch
   back to Sam: new private thumbnails/items are hidden. Existing downloaded
   files are not erased. The control also removes the remembered sample rule.
7. Explore No direct route, Source permission lost, deny/block and empty-start
   states. The platform selector changes presentation labels; resize the browser
   to change layout. It does not run an Android/Windows native shell.

Per-perspective local publication, directory-listing and manual-verification
choices are separate. The sample authorization relationship is specifically
Alex publishing to Sam; reversing which device platform owns media can be studied
with the platform controls, but no real two-device exchange occurs.

## Observed verification

Browser smoke observations on 2026-10-18, not usability research or native tests:

- Desktop library and player rendered; 360px/390px compact layouts and a compact
  approval dialog/settings screen rendered without horizontal document overflow
  in the inspected states. Light and dark appearance were inspected.
- Search narrowed results to the matching photo; the video filter selected only
  the video. Approval exposed only Alpine days; revocation exposed no media cards.
- The local video decoded and played; a seek to six seconds and position recovery
  after a simulated interruption worked. An initial seek issue was fixed by
  adding actual byte-range responses to this local preview server.
- Intentional disconnect persisted across reload; the network-recovery study
  control did not reconnect it automatically.
- An actual local JPEG was imported through the browser file input and decoded
  from a blob URL. Saving it produced a JPEG with the same SHA-256 as the source.
  File import did not enable publication or public listing.
- Publication required the received-copy acknowledgement; directory listing
  required its own deliberate confirmation. Owner identity comparison did not
  silently verify the other perspective's contact.

Browser state walks cannot establish authorization security, direct-only WebRTC,
SAF permission handling, actual transfer cancellation, Android service behavior,
Windows tray integration, audible remote playback or native accessibility.
Real QR/key creation and full manual-offer exchange are deliberately explanatory,
not fabricated functioning integrations. The one-hour sample expiry and storage
figures are illustrative; no production grant timer/cache implementation is claimed.
This is not completion of every UX-1/2/3 acceptance criterion; human review, full
wireframe annotations, large-text/RTL/native-assistive validation remain unverified.

## Media attribution

Bundled photos are used under the [Unsplash license](https://unsplash.com/license).
Author and original photo links are in [assets/credits.json](assets/credits.json):
Pascal Debrunner, Clay Elliot, Girma Nigusse and Mitchell Orr. The sample video was
generated locally from Pascal Debrunner's photo with FFmpeg. No content or code
was copied from Manyverse; only the sourced interaction inspiration in the UI/UX
plan was adapted.
