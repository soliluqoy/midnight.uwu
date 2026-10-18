# Environment — Vault development toolchain

Verified on **2026-10-18** on `DESKTOP-SDAVB2H` / Windows 10 Pro 22H2 (10.0.19045), 8 logical CPUs, 15.9 GB RAM.

Reproduce with:

```powershell
powershell -ExecutionPolicy Bypass -File tools\setup\verify-toolchain.ps1
```

Current result: **PASS — 0 failures, 0 warnings.** `flutter doctor` reports **"No issues found!"**

---

## 1. Installed manifest

| Component | Version | Location | Why Vault needs it |
|---|---|---|---|
| Flutter | **3.47.7** stable | `C:\dev\flutter` | One codebase → Android + Windows (plan §2.1) |
| Dart | **3.13.5** | bundled with Flutter | Language + test runner |
| Visual Studio Build Tools | **2022 17.14.42** (MSVC 14.44.35207) | `C:\Program` | `flutter build windows` requires MSVC (plan §2.1) |
| Windows SDK | **10.0.26100.0** | `C:\Program Files (x86)\Windows Kits\10` | `windows.h`, `kernel32.lib`, `rc.exe` |
| CMake | 4.4.4 | `C:\Program Files\CMake` | Windows runner + FFI/native builds |
| Ninja | 1.13.2 | `C:\Program Files\Ninja` | CMake generator for FFI builds |
| MSBuild | 17.14 | `C:\Program\MSBuild` | Windows runner build |
| JDK (Temurin) | **17.0.20.1+1** | `C:\dev\jdk17\jdk-17.0.20.1+1` | Gradle / Android toolchain |
| Android SDK | platform **36**, build-tools **36.1.0** | `C:\dev\android-sdk` | Android build target |
| Android NDK | 29.0.14206865 | `C:\dev\android-sdk\ndk` | Native plugin builds |
| Android platform-tools | 37.0.1 (adb 1.0.41) | `C:\dev\android-sdk\platform-tools` | Device install / debugging |
| Android Emulator | 37.2.12.0 (build 16428233) | `C:\dev\android-sdk\emulator` | Second Android node for spikes |
| System image | `android-36/google_apis/x86_64` | `C:\dev\android-sdk\system-images` | AVD `vault36` |
| Go | 1.27.0 | `C:\Program Files\Go` | `tools/interop_harness` (pion/webrtc, vnet, bwe-test) |
| clumsy | 0.3 win64 | `C:\dev\tools\clumsy` | Windows link shaping (spikes 2 & 5) |
| Git | 2.55.0 | `C:\Program Files\Git` | — |
| 7-Zip | 26.04 | `C:\Program Files\7-Zip` | Archive extraction |
| WSL2 Ubuntu | WSL v2 | — | `tc netem` on the Linux side |

`flutter_webrtc` is pinned at **`1.6.2+hotfix.4`** (latest; published 2026-10-07), matching plan §2.1.

### Environment variables (user-level, persistent)

| Variable | Value |
|---|---|
| `JAVA_HOME` | `C:\dev\jdk17\jdk-17.0.20.1+1` |
| `ANDROID_HOME` / `ANDROID_SDK_ROOT` | `C:\dev\android-sdk` |
| `PUB_CACHE` | `%LOCALAPPDATA%\Pub\Cache` |
| `PATH` additions | `C:\dev\flutter\bin`, `C:\dev\jdk17\jdk-17.0.20.1+1\bin`, `C:\dev\android-sdk\cmdline-tools\latest\bin`, `C:\dev\android-sdk\platform-tools`, `C:\dev\android-sdk\emulator`, `C:\dev\tools` |

`flutter config --jdk-dir` is **pinned** to our Temurin JDK. This matters — see pitfall #4.

---

## 2. Emulator capability report

Required reading before starting Phase 0.

```
$ emulator -accel-check
accel: 0
WHPX(10.0.19045) is installed and usable.
```

**Hardware acceleration works.** Booting AVD `vault36` logs:

```
WHPX on Windows 10.0.19045 detected.
Windows Hypervisor Platform accelerator is operational
```

Boot results:

| Property | Value |
|---|---|
| Android release | **16** |
| SDK level | **36** |
| ABI | `x86_64` |
| Cold boot to `sys.boot_completed=1` | **~75 s** |
| adb serial | `emulator-5554` |

Launch command used:

```powershell
C:\dev\android-sdk\emulator\emulator.exe -avd vault36 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect
```

### The blocker: no hardware H.264 encoder on the emulator

```
$ adb shell "grep -h 'avc.encoder' /vendor/etc/media_codecs*.xml"
<MediaCodec name="c2.android.avc.encoder" type="video/avc" update="true">
```

`c2.android.avc.encoder` is the **software** (CPU) encoder. There is **no** `c2.qcom.*` / `c2.mtk.*`
hardware AVC encoder on this x86_64 image, and no `ro.hardware.gralloc` value.

**Consequence for Phase 0:** Spike 1 — *"H.264 **hardware** encode + 720p30 send"* — **cannot be
validated on the emulator.** Plan §3.1 makes hardware encode the policy and Risk 7 expects
heterogeneity, so this needs a **physical Android device** over USB with USB debugging enabled.

Everything else in Phase 0 is fine on the emulator:

| Spike | Emulator usable? |
|---|---|
| 1 — H.264 HW encode 720p30 | **No — needs a physical device** |
| 2 — DataChannel throughput | Yes |
| 3 — `bufferedAmount` backpressure | Yes |
| 4 — MQTT-over-TLS failover | Yes |
| 5 — NAT matrix | Partly; real CGNAT still needs a cloud double-NAT (plan §7.5) |
| 6 — Windows desktop audio | Yes (Windows side only) |

---

## 3. Pitfalls hit while installing (each cost real time)

These are reproduced as guards in `tools/setup/install-toolchain.ps1`.

**1. Visual Studio silently truncated its install path.**
Passing `--installPath 'C:\Program Files (x86)\...\BuildTools'` as a bare argument split on the
space. The installer reported **exit code 0 / "Successfully completed"** while installing the
*entire* toolchain to `C:\Program`:

```json
"installationPath": "C:\\Program",   // vswhere
```

Detect with `vswhere -all -products * -format json | findstr installationPath`.
Fix: use a path with no spaces (`C:\VSBuildTools`) or pass `"--installPath=$path"` as one token.

**2. The Android CLI splits package lists on space, not `;`.**
`platforms;android-36` became four bogus packages:

```
Package build-tools not found.  Package 36.1.0 not found.
Package ndk not found.  Package 29.0.14206865 not found.
```

The new `android.exe` CLI wants **slash-separated** ids:

```
platform-tools
platforms/android-36
build-tools/36.1.0
ndk/29.0.14206865
emulator
system-images/android-36/google_apis/x86_64
```

The legacy `sdkmanager` still understands `;` for *listing*; the two do not agree.

**3. The Adoptium download is a ZIP, not an MSI.**
`https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse`
returns `OpenJDK17U-jdk_x64_windows_hotspot_17.0.20.1_1.zip`. Saving it as `.msi` and calling
`msiexec` gives **exit code 1620**. Extract the zip instead.

**4. A stale inherited `JAVA_HOME` wins over the registry.**
The parent process carried `JAVA_HOME=C:\Program Files\Eclipse Adoptium\jdk-17.0.20.101-hotspot`
for a JDK that no longer existed, and `flutter doctor` failed with
*"Cannot execute ... to determine the version"* while the registry held the correct path.
Fix: `flutter config --jdk-dir=<path>` (persisted), and read `JAVA_HOME` from the **registry** in
scripts rather than trusting `$env:JAVA_HOME`.

**5. `Invoke-WebRequest` stalls on IPv6-only mirrors.**
`storage.googleapis.com` resolves to IPv6 on this host; the 1.8 GB Flutter download sat at 0 bytes
indefinitely. Use `curl.exe -4 -L` for every large download, and prefer `tar.exe -xf` over
`Expand-Archive` (much faster on large archives).

**6. Detached background jobs have no stdin.**
`android.exe sdk install` blocks forever at 0% CPU when launched from a detached background shell.
Run it in the foreground, or pre-write `licenses/android-sdk-license`.

---

## 4. Network reachability notes

`clumsy.netrf.org` and `www.jitbit.net` (clumsy's upstream hosts) **do not resolve** on this network.
The binary was obtained from the GitHub release instead:

```
https://github.com/jagt/clumsy/releases/download/0.3/clumsy-0.3-win64-a.zip
```

Reachable and used: `storage.googleapis.com`, `dl.google.com`, `aka.ms`, `go.dev`, `github.com`,
`pub.dev`, `mqtt.eclipseprojects.io`. Several resolve IPv6-only, hence pitfall #5.

---

## 5. Link shaping (Phase 0 spikes 2 & 5)

Two independent levers:

```powershell
# Windows NIC — requires Administrator
tools\netem\clumsy-profile.ps1 -Profile broadband100
tools\netem\clumsy-profile.ps1 -Profile lte4
tools\netem\clumsy-profile.ps1 -Profile lossy -PacketLoss 5
```

Profiles: `lan`, `broadband100`, `lte4`, `cgnat`, `lossy`.

```bash
# Linux side, inside WSL2
wsl -d Ubuntu -u root -- bash tools/netem/netem-wsl2.sh apply eth0 100mbit 5ms 1%
wsl -d Ubuntu -u root -- bash tools/netem/netem-wsl2.sh clear eth0
```

`tc` is present at `/usr/sbin/tc` in the WSL2 Ubuntu image.

---

## 6. Known deviation from the intended layout

Visual Studio Build Tools lives at **`C:\Program`** rather than
`C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` (pitfall #1).

This is functionally fine — `vswhere` reports it correctly, `flutter doctor` detects
*"Visual Studio Build Tools 2022 version 17.14.37806.7 / Windows 10 SDK version 10.0.26100.0"*,
and `flutter build windows` resolves the toolchain. The path has no spaces, which is the
safer configuration anyway.

If a canonical layout is wanted, reinstall with:

```powershell
"C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe" uninstall --installPath "C:\Program" --quiet --norestart
tools\setup\install-toolchain.ps1 -VsPath C:\VSBuildTools
```

---

## 7. Not installed (deliberately)

| Tool | Reason |
|---|---|
| Android Studio | The SDK is fully managed by `android.exe` / `sdkmanager`. Adds ~3 GB for a GUI on top of an AVD we drive headless. Add later if AVD/GUI management is wanted. |
| Full Visual Studio IDE | Build Tools contains the entire C++ toolchain. |
| Any TURN server | Plan §1.1 — we never run infrastructure. TURN is user-supplied and the field ships empty. |
| Sentry / analytics | Plan §1.7, Appendix A — no telemetry, explicitly omitted. |