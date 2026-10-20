# Vault development environment

Audited 2026-10-18 on DESKTOP-SDAVB2H, Windows10 Pro22H2 (10.0.19045),
8 logical CPUs and about16 GiB RAM. This record replaces the earlier blanket
"0 warnings" readiness claim. Installation, native builds and product feasibility
are separate checks.

## Reproduce

~~~powershell
dart pub get
dart run melos bootstrap
dart run melos run analyze
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup\test-verifier.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup\verify-toolchain.ps1 -JsonOutput docs\ops\toolchain-verification.json
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup\test-builds.ps1
~~~

Verification does not need Administrator. Use -RequirePhysicalAndroid to make
an absent authorized phone a failure. Default reports it as a warning. Build
checks generate an isolated template at C:\dev\vault-toolchain-smoke, not Vault.
The latest [installation JSON](toolchain-verification.json) has26 passing checks,
including the authorized physical phone, with0 failures and0 warnings. The
prebuild24-check result is [preserved separately](prebuild-toolchain-verification.json).
The installation JSON and
[build JSON](build-verification.json) are the dated evidence; do not infer plugin
or feature success from an empty-template build.

On Windows PowerShell 5.1, Flutter's UTF-8 doctor output must be captured with
UTF-8 decoding: an OEM console code page such as CP437 corrupts the healthy
checkmark and causes a false platform failure. The verifier scopes UTF-8 decoding
to the doctor command and restores the previous console encoding afterward.
Required Android/Windows components still fail when unhealthy or absent.

## Installed manifest

| Component | Observed version | Location |
|---|---|---|
| Flutter / Dart | 3.47.7 / 3.13.5 | C:\dev\flutter |
| VS2022 Build Tools / MSVC | 17.14.42 /14.44.35207 | C:\Program |
| MSBuild | 17.14.60.43110 | Discovered through vswhere |
| Windows SDK |10.0.26100.0 | C:\Program Files (x86)\Windows Kits\10 |
| CMake / Ninja |4.4.4 /1.13.2 | PATH, resolved by verifier |
| Temurin JDK17 |17.0.20.1 | C:\dev\jdk17\jdk-17.0.20.1+1 |
| Android platform/build-tools |35 and36 /36.0.0 and36.1.0 | C:\dev\android-sdk |
| Android SDK CMake |3.22.1 | SDK cmake/3.22.1; required by native plugins |
| NDK (originally installed) |29.0.14206865 | SDK ndk subdirectory |
| NDK (Flutter runner requirement) |28.2.13676358 | Installed explicitly during this audit; see below |
| Android CLI |1.0.16625370 | SDK cmdline-tools/latest/bin |
| ADB/platform-tools |1.0.41 /37.0.1 | SDK platform-tools |
| Android Emulator |37.2.12.0 | SDK emulator |
| Emulator image/AVD |Android36 Google APIs x86_64 /vault36 | SDK system-images and user AVD directory |
| Go |1.27.0 | C:\Program Files\Go |
| FFmpeg / ffprobe |9.0.1 Essentials | Winget Gyan.FFmpeg.Essentials; developer fixture generation only |
| Git |2.55.0.windows.5 | C:\Program Files\Git |
| 7-Zip |26.04 | C:\Program Files\7-Zip |
| clumsy/WinDivert |0.3 executable plus DLL/SYS present | C:\dev\tools\clumsy |
| WSL2 Ubuntu/tc |kernel6.18.54.1 /iproute2-6.19.0 | WSL Ubuntu |
| Local Melos/lints |8.9.0 /11.0.0 | Root pubspec.yaml and pubspec.lock |

The VS path C:\Program is unusual but functional and was discovered rather than
assumed. Do not reinstall solely to change its path. JDK and Android SDK user
variables are read fresh; Flutter's configured JDK is the verified Temurin path.

## Actual checks and limits

- flutter doctor -v: Android and Windows healthy; no doctor issues.
- Root dependency resolution, local Melos bootstrap and strict analysis passed.
- Verifier regression assertions:9 passed. A separate negative run rejected a
  deliberately missing required clumsy installation with nonzero exit status.
- Empty Windows debug template: first build passed in59.4s; recorded rerun12.9s.
- First Android debug template FAILED in309.4s because the default runner needed
  NDK28.2.13676358 while only29 was present. After explicit installation the APK
  build passed in247.5s; see build-verification.json. Gradle also installed its
  exact Build-tools36.0.0 requirement; installer/verifier now include36.0 and36.1.
  The initial failure is why file/doctor checks alone were insufficient.
- Go compiler/runtime smoke: go test crypto/ed25519 passed in15.996s.
- Actual tc netem accepted100Mbit,5ms,1% loss inside a disposable WSL network
  namespace. This did not shape ordinary host/WSL traffic and is not a NAT test.
- Emulator -accel-check: WHPX installed and usable. Headless vault36 cold boot
  reached sys.boot_completed=1; Android16/API36/x86_64 were read through adb.
  See emulator-verification.json. This is not physical-hardware validation.
- APK install and rendering eventually passed on the emulator. am start -W
  initially timed out after12.118s, but ActivityTaskManager logged Fully drawn
  at17.648s; see android-runtime-verification.json. Cold software rendering is
  slow and unsuitable for product performance claims. The temporary test app
  was removed and the emulator stopped after checking.
- Physical Xiaomi13TPro (23078PND5G, MT6985), Android16/API36 and HyperOS3.0.301
  is attached and authorized. Native hardware encoding, direct synthetic transfers,
  resident-file playback/seeks and a short background FGS transfer now have evidence.
  See the [Phase 0 record](../spikes/phase0-2026-10-18/README.md) for precise limits.
- clumsy driver files exist; live elevated capture/effect calibration is untested.
- The initial WebRTC/player probes have Android/Windows evidence. The authorized
  implementation-first core now composes real app services; new runtime/build
  observations are recorded in the app README, separately from Phase0 evidence.
  Broad network, source-provider, sustained-load and lifecycle/Doze trials remain open.

The user enabled Windows Developer Mode, but this token still cannot create
plugin symlinks (error1314). The probe uses validated project-local junctions;
no machine policy was changed. Its dependency wrapper handles that specific
post-resolution failure, then native builds use --no-pub.

## New build mismatch found and fixed

Flutter3.47.7's generated Android runner references default NDK28.2.13676358.
The newer SDK manager wrapper delegates to android.exe and cannot interpret the
semicolon package IDs Gradle uses for auto-install. Installing only the newer NDK29
does not satisfy a version-specific NDK request. Explicit installation:

~~~powershell
& C:\dev\android-sdk\cmdline-tools\latest\bin\android.exe sdk install --sdk=C:\dev\android-sdk ndk/28.2.13676358
~~~

The installer and verifier now include28.2 alongside29. Avoid editing Flutter's SDK
or forcing a different NDK simply to hide the missing required package.

## Link shaping

The clumsy launcher now requires the actual peerIPv4, uses documented0.3 lag/drop
flags and a finite timeout. Inspect without elevation or packet capture:

~~~powershell
tools\netem\clumsy-profile.ps1 -PeerAddress 192.0.2.1 -Profile lossy -DryRun
~~~

Profiles are lan, broadband, mobile and lossy. They apply delay/loss, not bandwidth
or CGNAT. Delay is per direction. A real run needs elevation and affects only
matching peer UDP for the timeout. Use tc for a calibrated cap on traffic actually
traversing the WSL harness interface:

~~~bash
wsl -d Ubuntu -u root -- bash tools/netem/netem-wsl2.sh apply eth0 100mbit 5ms 1%
wsl -d Ubuntu -u root -- bash tools/netem/netem-wsl2.sh clear eth0
~~~

Do not call a delay/loss profile a NAT topology. CGNAT/symmetric mapping tests need
an explicit routing/NAT fixture. Do not assume Windows-to-Android packets traverse WSL.

## Installer corrections

Nested JDK detection is now idempotent; VS detection uses the actual C++ toolchain,
not a path's existence; native download/extraction/winget/AVD exit codes are checked.
Flutter archives are verified against the official release checksum manifest.
Flutter's JDK is pinned explicitly. Existing AVDs are preserved. Licenses use the
official review/acceptance flow rather than fabricated acceptance hashes.
Large downloads use curl -4 with HTTP failure handling. Fresh-machine installation
was not rerun on this existing host; syntax and current-host smoke results are separate.

Android Studio, full VS IDE, Docker, Python and cloud credentials are not prerequisites
for this baseline. No TURN, server, cloud VM, account or telemetry service was provisioned.

Next: verify the integrated core under the
[implementation-first revision](../../P2P_VIDEO_SHARE_BUILD_PLAN.md#63-implementation-first-sequencing-revision),
then complete the deferred physical-device/network matrix before release claims.
The hotspot workaround remains experimental and is not a production default.

## Core integration prerequisite discovered

The experimental core's Windows build failed in
`flutter_secure_storage_windows_plugin.cpp` because `atlstr.h` is absent from
the selected MSVC14.44 toolset. This session's Windows token is not Administrator.
Existing MSVC, empty-template and earlier interface builds are not proof that
this new protected-storage dependency can build.

The native runner/tray sources were separately compiled with MSBuild's
`ClCompile` target: zero warnings/errors. This does not link the app or clear the
missing plugin prerequisite. Do not use an old build-output `vault.exe` as core
evidence.

From an Administrator PowerShell at repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/setup/install-windows-atl.ps1
```

This additive installer targets only `Microsoft.VisualStudio.Component.VC.ATL`
in the existing VS2022 instance. It verifies the active toolset's header and
library, never forces applications closed, and refuses non-administrator
installation before launching the installer. The guard and PowerShell parsing
were exercised; the elevated installation itself has not run. Fresh-machine
setup now includes ATL, and normal verification must no longer report a fully
ready Windows core toolchain without it.

The requested standard Windows elevation attempt returned “operation was
canceled by the user” before the elevated installer started. Approval in chat
does not grant OS administrator authority. The full Windows build remains
blocked; no automatic elevation retry or privilege bypass was attempted.
