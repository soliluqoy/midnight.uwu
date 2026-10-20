# Vault platform, dependencies, and workspace audit

Research checked on 2026-10-18. Scope: Android publishing/storage lifecycle, Windows playback/native build requirements, published package/tool versions, and the current repository scaffold. Existing repository files were inspected but not edited by this researcher. Proposed corrections below are recommendations for the coordinator to apply.

## Can Android provide autonomous, always-available publishing?

### Takeaway

The current background-service prescription does not establish the promised availability. Android publishing needs a Phase 0 lifecycle/type feasibility gate, and the product should explicitly report when a device is suspended or unavailable. [Android foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types), [Doze documentation](https://developer.android.com/training/monitoring-device-state/doze-standby)

### Cited Findings

- For apps targeting Android 15+, `dataSync` and `mediaProcessing` foreground services each have a separate budget of six background hours per 24 hours. `Service.onTimeout(int,int)` requires prompt termination; this is not an unlimited publishing mechanism. [Foreground service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout)
- Android 14+ requires an appropriate foreground-service type and its permission. `dataSync` includes uploads/downloads and local file processing; `mediaPlayback` covers continued audio/video playback. `connectedDevice` covers interaction with external devices over network/Bluetooth/etc., with prerequisites. `specialUse` requires an explained use case reviewed by Google Play. Declaring playback while merely hosting files has no documented blanket exemption. [Foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types)
- Doze suspends network access, ignores wake locks, and defers JobScheduler work. WorkManager uses JobScheduler and does not run during Doze. A 15-minute periodic WorkManager task therefore cannot guarantee continuous MQTT presence or a 15-second folder freshness SLA. [Doze restrictions](https://developer.android.com/training/monitoring-device-state/doze-standby)
- Periodic WorkManager work has a minimum 15-minute interval and is explicitly inexact, including battery/Doze delays. [PeriodicWorkRequest](https://developer.android.com/reference/androidx/work/PeriodicWorkRequest)
- Starting on Android 16, long-running WorkManager workers using foreground services can exhaust app job quota; the documentation distinguishes directly started foreground services and user-initiated transfer jobs as possible alternatives. Moving every operation into WorkManager is not a quota workaround. [Long-running workers](https://developer.android.com/develop/background-work/background-tasks/persistent/how-to/long-running)
- Apps targeting Android 12+ generally cannot start foreground services from the background unless an exemption applies. A user-visible action is one exemption; an arbitrary incoming public MQTT packet is not listed as one. [Background foreground-service starts](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)
- Android 13+ lets users stop an app through the Active apps foreground-service manager. The process and playback stop without an application callback; scheduled jobs and alarms can still run later. This must not be treated as ordinary network failure that the app should silently defeat. [User-initiated stopping](https://developer.android.com/develop/background-work/services/fgs/handle-user-stopping)

### Inferences

- Replace the plan's “work must survive Doze → WorkManager” assertion with: preserve local state, expose explicit availability states, resume and re-announce when execution/network return, and never guarantee inbound reachability while the OS suspends the publisher. Keep WorkManager for deferred incremental maintenance. This follows from the documented Doze and job constraints. [Doze restrictions](https://developer.android.com/training/monitoring-device-state/doze-standby), [Long-running workers](https://developer.android.com/develop/background-work/background-tasks/persistent/how-to/long-running)
- Add an Android Phase 0 spike before application features: choose and justify a valid service type for active P2P sessions and idle publication separately; test screen-off, forced Doze, user stop, process death, reboot, service budget exhaustion, permission revocation, and recovery on Android 15/16. Test on a physical device, recording the actual OS, target SDK, battery settings, and service type. These tests decide supported availability modes; they do not justify misclassifying publishing as playback. [Foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types), [Foreground service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout)
- Treat continuous Android background hosting as an unresolved capability, not an implemented guarantee. `connectedDevice` may merit investigation for actual P2P-device interactions, but the documentation alone does not establish that Vault's proposed indefinite public directory hosting meets that use case or Play review expectations. [Foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types)

### Gaps

- No app manifest/service implementation or physical lifecycle test exists in the inspected scaffold, so a service type, OEM behavior, and battery cost cannot be validated yet. Initial local evidence: [file tree](../../docs/FILE_TREE.md), [environment notes](../../docs/ops/ENVIRONMENT.md).
- The 24-hour soak and “8%/hour idle publishing” budget are unmeasured targets. No public document can establish those device-specific results.

## Are Android folder access and indexing acceptance gates realistic?

### Takeaway

SAF requires a URI-based storage abstraction and permission-loss handling. Separate initial enumeration from hashes, metadata, and thumbnails; the proposed all-inclusive 20,000-item/60-second guarantee is not supported by measurements. [Android SAF guide](https://developer.android.com/training/data-storage/shared/documents-files), [current plan, sections 3.6 and Phase 2](../../P2P_VIDEO_SHARE_BUILD_PLAN.md)

### Cited Findings

- `ACTION_OPEN_DOCUMENT_TREE` grants access to the selected tree. Android 11+ excludes storage roots, the Download directory itself, and restricted Android/data and Android/obb locations. Android explicitly warns that enumerating large SAF trees can reduce performance. [SAF tree access and restrictions](https://developer.android.com/training/data-storage/shared/documents-files)
- Persistable URI grants can survive device restarts when taken explicitly, but access can still be lost when a document moves or is deleted. SAF document sizes may be unknown; providers can represent remote files. A desktop pathname is not an adequate universal Android identifier. [Persisting SAF permissions and examining metadata](https://developer.android.com/training/data-storage/shared/documents-files)
- A read-only `ContentResolver.openFileDescriptor` can yield a pipe or socket rather than a seekable disk file; transformed asset streams may also be non-seekable. Range reads must check capability rather than assume every selected URI supports random access. [ContentResolver API](https://developer.android.com/reference/android/content/ContentResolver)
- Android's metadata retriever returns a representative nearby frame, may return null, and recommends scaled frame retrieval for thumbnails. Closest-frame retrieval can be more expensive than sync-frame options. The exact 22%-of-duration frame is not universally guaranteed. [MediaMetadataRetriever API](https://developer.android.com/reference/android/media/MediaMetadataRetriever)
- Windows `IShellItemImageFactory::GetImage` accepts size and flags, not a time position. It uses a cached or extracted thumbnail and can fall back to an icon. Microsoft says extraction should run off the UI thread. An Explorer thumbnail cannot simultaneously guarantee the selected 22% timestamp. [GetImage API](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ishellitemimagefactory-getimage)

### Inferences

- Replace the index's universal `path` field with a tagged storage locator: Windows canonical path versus Android tree/document URI plus grant/capability state. File operations should support `readRange`, seekability, known/unknown length, cancellation, and permission failure. Reject unsupported remote/non-seekable providers or stage an explicitly user-approved local copy before publishing; do not silently promise direct random access. [ContentResolver API](https://developer.android.com/reference/android/content/ContentResolver), [SAF guide](https://developer.android.com/training/data-storage/shared/documents-files)
- The plan's prefix-hash rule alone reads up to 20,000 MiB (19.53 GiB) for 20,000 files of at least 1 MiB. Completing that in 60 seconds implies at least 333.3 MiB/s before full hashes, provider overhead, metadata, thumbnails, and database writes. This arithmetic is derived from the plan, not a measured benchmark. [Plan storage rules and Phase 2](../../P2P_VIDEO_SHARE_BUILD_PLAN.md)
- Define separate gates for: (1) first browseable page and UI responsiveness, (2) complete lightweight enumeration, (3) lazy metadata/poster completion, and (4) full-hash completion. State cold/warm cache, media mix, folder depth, local provider, device/storage model, corrupt inputs, and foreground/background conditions. Keep 20,000/60 seconds only as a hypothesis for a precisely named stage until a physical-device benchmark supports it. [SAF performance warning](https://developer.android.com/training/data-storage/shared/documents-files)
- Clarify “never decode to find metadata”: header parsing applies to metadata; poster extraction necessarily needs a decoded image/frame. Permit lazy poster decode in a bounded native background worker, allow null/unsupported metadata and placeholders, and treat cached Windows representative posters as acceptable or use a separate timestamp-aware decoder. [Android retriever](https://developer.android.com/reference/android/media/MediaMetadataRetriever), [Windows thumbnail API](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ishellitemimagefactory-getimage)
- Scope deletion/rename reconciliation targets to an executing app and a supported local provider. A fixed 15-second background guarantee conflicts with Doze deferral. [Doze restrictions](https://developer.android.com/training/monitoring-device-state/doze-standby)

### Gaps

- The repository has no storage bridge, device dataset, benchmark traces, or indexed database. No exact per-platform index throughput is verified.
- SAF change notifications and provider capabilities need implementation-specific tests; hints can accelerate reconciliation but do not create a universal freshness guarantee.

## Are Windows playback and native build choices established?

### Takeaway

Flutter is a valid Android/Windows shell, but the standard `video_player` package does not supply a Windows backend. Select a supported backend by a seek/progressive playback spike and validate the actual native plugin builds, not only `flutter doctor`. [Flutter Windows setup](https://docs.flutter.dev/platform-integration/windows/setup), [video_player registry](https://pub.dev/packages/video_player)

### Cited Findings

- Flutter's Windows documentation calls for Visual Studio's Desktop development with C++ workload, including the native compiler/toolchain, and validates detection with `flutter doctor -v` and `flutter devices`. Compiler/Windows SDK availability is separate from installing the Flutter/Dart SDK. [Windows setup](https://docs.flutter.dev/platform-integration/windows/setup)
- Published `video_player` 2.14.1 lists Android, iOS, macOS, and web; its plugin mapping contains no Windows implementation. The plan's “Windows: Media Foundation/video_player” is therefore not a completed dependency choice. [Package page](https://pub.dev/packages/video_player), [registry metadata](https://pub.dev/api/packages/video_player)
- `media_kit` 1.2.6 is published with Windows and Android support. Video integration is split across `media_kit`, `media_kit_video` (2.0.1), and platform native libraries via `media_kit_libs_video` (1.0.7); it should be evaluated as a complete dependency set rather than naming only the Dart player package. [media_kit](https://pub.dev/packages/media_kit), [video integration metadata](https://pub.dev/api/packages/media_kit_video), [native library metadata](https://pub.dev/api/packages/media_kit_libs_video)
- `window_manager` is a desktop window-control plugin (0.5.2); tray behavior is a separate package/API concern, such as published `tray_manager` 0.8.0. Installing window controls does not itself establish tray/autostart/single-instance functionality. [window_manager metadata](https://pub.dev/api/packages/window_manager), [tray_manager metadata](https://pub.dev/api/packages/tray_manager)

### Inferences

- Add Phase 0 VOD playback tests on both platforms: existing local file, progressive cache plus loopback range feed, initial and tail `moov` MP4, non-sequential seek, audio, cancellation, permission loss, and corrupt/unsupported media. Choose and pin the backend only after those tests; do not claim every original file/codec is playable merely because byte transport succeeds. [video_player supported platforms](https://pub.dev/packages/video_player), [media_kit supported platforms](https://pub.dev/packages/media_kit)
- Require a throwaway native build using the exact proposed WebRTC and player plugins for Windows and Android. `flutter doctor` detects toolchain basics but cannot establish plugin compatibility, native artifact retrieval, codecs, audio routing, or physical hardware encoding. [Flutter setup validation](https://docs.flutter.dev/platform-integration/windows/setup), [WebRTC package](https://pub.dev/packages/flutter_webrtc)

### Gaps

- Actual installed native tool versions and smoke build results are audited separately by the coordinator. This note does not claim the local machine passes those checks.
- No progressive demux/cache integration or hardware decoder/encoder measurements exist in the inspected repository.

## Do published versions and the repository workspace agree?

### Takeaway

The recorded Flutter release is real, but dependency claims and Melos configuration need corrections. Keep the current scaffold's resolved tooling small; pin application dependencies in the first real spikes rather than describing absent pubspec files as locked. [Flutter release manifest](https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json), [Melos migration documentation](https://pub.dev/packages/melos), [initial root pubspec](../../pubspec.yaml)

### Cited Findings

The following registry metadata was checked directly on 2026-10-18; “latest published” is not a claim that all combinations resolve or run together.

| Component | Published/current check | Implication | Source |
|---|---|---|---|
| Flutter/Dart | Flutter 3.47.7 stable, Dart 3.13.5, Windows release 2026-10-08; archive SHA-256 `c2c875da25a1a1448d18ee4e8f398b2f6fce888b4775d8f9130538e16d826cb4` | Recorded SDK versions are valid public releases. | [Official release manifest](https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json) |
| flutter_webrtc | 1.6.2+hotfix.4, published 2026-10-07, minimum Dart 3.3 | Pin this exact version for a spike; a caret expression is not an exact pin. | [Registry metadata](https://pub.dev/api/packages/flutter_webrtc) |
| libwebrtc in plugin | 1.6.1 moved to 150.7871.01; hotfix.4 records Windows/Linux m150.7871.03 | Update the plan's stale .01 engine attribution and record per-platform artifacts. | [Plugin changelog](https://pub.dev/packages/flutter_webrtc/changelog) |
| Melos | 8.9.0, minimum Dart 3.9 | Root local tooling dependency should be pinned; global “latest” is not reproducible. | [Registry metadata](https://pub.dev/api/packages/melos) |
| very_good_analysis | 11.0.0, minimum Dart 3.13 | Root SDK floor `>=3.9.0` understates the required SDK if this lint version is retained. | [Registry metadata](https://pub.dev/api/packages/very_good_analysis) |
| build_runner | 2.17.1, minimum Dart 3.11 | Existing `^2.4.13` floats broadly; remove until a generator is actually needed, or pin with a resolved generator set. | [Registry metadata](https://pub.dev/api/packages/build_runner) |
| drift | 2.35.2, minimum Dart 3.10; depends on sqlite3 ^3.4.0 | Current SQLite 3 integration does not need legacy `sqlite3_flutter_libs`. | [Registry metadata](https://pub.dev/api/packages/drift) |
| sqlite3_flutter_libs | 0.6.0+eol; version 0.6+ does nothing; obsolete with sqlite3 3.x | Remove from the starting list when adopting current Drift/SQLite. | [Publisher notice](https://pub.dev/packages/sqlite3_flutter_libs) |
| mqtt_client / mqtt5_client | mqtt_client 10.13.0 implements MQTT 3.1/3.1.1; mqtt5_client 5.1.0 implements MQTT 5 | Choose MQTT5 package if the plan retains MQTT5 semantics. | [mqtt_client](https://pub.dev/packages/mqtt_client), [mqtt5_client](https://pub.dev/packages/mqtt5_client) |
| flutter_windowmanager | 0.2.0 declares Dart >=2.12 <3.0 | Incompatible with the chosen Dart3 SDK; omit or replace through a separately evaluated native API. | [Registry metadata](https://pub.dev/api/packages/flutter_windowmanager) |
| blake3 / blake3_dart | `blake3` package endpoint returned 404; `blake3_dart` 1.0.0 exists | The plan names a missing package. Existing pure-Dart alternative's performance/security maturity is unproven by this audit. | [Requested package endpoint](https://pub.dev/api/packages/blake3), [blake3_dart package](https://pub.dev/packages/blake3_dart) |
| workmanager | 0.10.10, minimum Dart3.5, Flutter3.38; Android platform backend present | Package availability does not remove OS background quotas. | [Registry metadata](https://pub.dev/api/packages/workmanager) |

- Melos 7+ uses Pub workspaces. The migration instructions move `melos.yaml` content into the root pubspec `melos:` map, replace the old `packages:` list with `workspace:`, and add `resolution: workspace` to member pubspecs. Melos8 also changes script `exec` syntax and requires Dart3.9+. [Melos migration](https://pub.dev/packages/melos)
- Dart Pub workspaces need a root member list and `resolution: workspace` in each member. They create a shared root lockfile/package configuration. Workspace globs require Dart3.11+, while explicit paths support older workspace-capable SDKs. [Dart workspace documentation](https://dart.dev/tools/pub/workspaces)
- At inspection start, root pubspec contained `very_good_analysis: 11.0.0`, `build_runner: ^2.4.13`, `test: ^1.25.0`, and Flutter SDK `flutter_test`, but no Melos dependency/workspace. `melos.yaml` still carried the legacy package list. App/library directories contained README stubs rather than their advertised pubspecs; `docs/adr` was empty. Thus “flutter_webrtc is pinned” in environment notes was not backed by an app lockfile. [Root pubspec](../../pubspec.yaml), legacy melos.yaml (removed during this audit; see [current config](../../pubspec.yaml)), [recorded environment claim](../../docs/ops/ENVIRONMENT.md), [advertised file tree](../../docs/FILE_TREE.md)
- Desktop bug citations are misnumbered: encoding changes are issue #2210; missing buffered-amount notifications are #2206. #2216 concerns macOS microphone selection; #2218 concerns Samsung HEVC playback. Those two do not substantiate the plan's addTrack detached-thread race claim. [Encoding report](https://github.com/flutter-webrtc/flutter-webrtc/issues/2210), [buffer report](https://github.com/flutter-webrtc/flutter-webrtc/issues/2206), [actual #2216](https://github.com/flutter-webrtc/flutter-webrtc/issues/2216), [actual #2218](https://github.com/flutter-webrtc/flutter-webrtc/issues/2218)
- Exact tagged plugin source distinguishes the cached `bufferedAmount` property from asynchronous `getBufferedAmount()`: the former returns `_bufferedAmount`, while the latter invokes native `dataChannelGetBufferedAmount` and refreshes the cache. Polling only the property is not the promised workaround if the native event is absent. Use `await channel.getBufferedAmount()` in the backpressure adapter, handle closure/errors, and prove that the native value increases and drains under load. [Pinned 1.6.2+hotfix.4 implementation, lines 54-55 and 118-125](https://raw.githubusercontent.com/flutter-webrtc/flutter-webrtc/v1.6.2%2Bhotfix.4/lib/src/native/rtc_data_channel_impl.dart), [published API](https://pub.dev/documentation/flutter_webrtc/latest/flutter_webrtc/RTCDataChannel-class.html)

### Inferences

- Minimal current scaffold tooling proposal (coordinator should resolve and execute it): keep the root private package; set SDK `>=3.13.0 <4.0.0`; use `workspace: []` until real members exist; exact dev pins `melos: 8.9.0` and `very_good_analysis: 11.0.0`; `melos.useRootAsPackage: true`; migrate only meaningful root doctor/analyze scripts now. Remove speculative build_runner/test/flutter_test until real packages need them. This matches the registry floors and avoids claiming nonexistent package quality gates. [Melos configuration](https://melos.invertase.dev/configuration/overview), [Melos registry](https://pub.dev/api/packages/melos), [lint registry](https://pub.dev/api/packages/very_good_analysis)
- When scaffolding starts, add real member pubspecs atomically with explicit root workspace paths (or supported globs), `resolution: workspace`, their local dependencies, and package-specific test/generator dependencies. Commit the resolved root lockfile. Use `dart test` for genuinely pure-Dart libraries and Flutter test runners only where required; ensure scripts fail/report pending instead of passing after matching zero packages. [Dart workspaces](https://dart.dev/tools/pub/workspaces)
- Preserve conservative serialized negotiation and backpressure design as hypotheses, but link the correct issues and reproduce the exact pinned plugin behavior. Do not state that sender/transceiver recreation is a proven fix until measured; the existing report describes a native encoding write-back bug, not evidence that recreation restores every desired rate-control behavior. [Encoding bug](https://github.com/flutter-webrtc/flutter-webrtc/issues/2210), [buffer event bug](https://github.com/flutter-webrtc/flutter-webrtc/issues/2206)
- If a full 512 KiB send window can only be replenished on 50 ms polls after halting, an ideal full-drain cycle is limited to roughly 10 MiB/s (512 KiB / 0.05 s), before API/CPU overhead. Thus 20-40 MB/s same-LAN throughput cannot also be a guaranteed result of that strict polling schedule. This is a conditional arithmetic inference; tune the window/timer against measured throughput, memory and CPU. [Plan sections 3.4-3.5](../../P2P_VIDEO_SHARE_BUILD_PLAN.md)
- Add a dependency manifest distinguishing: exact resolved current tooling, exact spike dependencies, deferred product candidates, and rejected obsolete/incompatible packages. Record package source/archive checksum, native artifacts, SDK floors, license notes, and actual pub resolution/build evidence for the tested set. [Pub workspace shared resolution](https://dart.dev/tools/pub/workspaces)

### Gaps

- Current public versions alone cannot establish one jointly compatible Flutter/Riverpod/generator/Drift/player/native-plugin graph. Resolve a deliberately chosen set and build both targets before marking it verified.
- The precise addTrack detached-thread issue asserted by the plan was not substantiated by its supplied issue numbers; keep serialization as an engineering choice without inventing a supporting upstream citation.
- Pure-Dart BLAKE3 implementation maturity, full hashing throughput, hardware codecs, and six-viewer CPU/resource budgets remain unmeasured. Package marketing and issue descriptions are not application benchmark results.
