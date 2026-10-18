<#
.SYNOPSIS
  Verifies the complete Vault development toolchain and prints a go/no-go table.

.DESCRIPTION
  Run this after tools/setup/install-toolchain.ps1 (or a manual install).
  Every check prints PASS / FAIL / WARN. Exit code 0 means the toolchain can
  build and run Vault on both Android and Windows.

  Phase 0 of the build plan says: "Kill or re-plan here, not later."
  This script is the machine-checkable half of that instruction.
#>

$ErrorActionPreference = 'Continue'
$script:Fail = 0
$script:Warn = 0

# Where the non-default tooling lives. Keep in sync with install-toolchain.ps1 -DevRoot.
# NOTE: read JAVA_HOME from the registry, not the process env. A long-lived parent
# process (an IDE, a CI agent) can carry a stale JAVA_HOME for a JDK that has since
# been uninstalled, and the inherited value will win over the correct one.
$DevRoot = if ($env:VaultDevRoot) { $env:VaultDevRoot } else { 'C:\dev' }
$env:VaultDevRoot = $DevRoot
$env:ANDROID_SDK_ROOT = if ([Environment]::GetEnvironmentVariable('ANDROID_SDK_ROOT','User')) {
    [Environment]::GetEnvironmentVariable('ANDROID_SDK_ROOT','User')
} else { "$DevRoot\android-sdk" }
$regJava = [Environment]::GetEnvironmentVariable('JAVA_HOME','User')
$env:JAVA_HOME = if ($regJava -and (Test-Path (Join-Path $regJava 'bin\java.exe'))) {
    $regJava
} elseif ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
    $env:JAVA_HOME
} else { "$DevRoot\jdk17\jdk-17.0.20.1+1" }

function Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }

function Check {
    param([string]$Name, [scriptblock]$Probe, [string]$Fix, [switch]$Critical)
    try {
        $r = & $Probe
        if ($r -and "$r".Trim()) {
            Write-Host ("  [PASS] {0,-34} {1}" -f $Name, "$r".Trim()) -ForegroundColor Green
        } else {
            Write-Host ("  [FAIL] {0,-34} -> {1}" -f $Name, $Fix) -ForegroundColor Red
            if ($Critical) { $script:Fail++ }
        }
    } catch {
        Write-Host ("  [FAIL] {0,-34} -> {1} ({2})" -f $Name, $Fix, $_.Exception.Message) -ForegroundColor Red
        if ($Critical) { $script:Fail++ }
    }
}

function WarnCheck {
    param([string]$Name, [scriptblock]$Probe, [string]$Note)
    try {
        $r = & $Probe
        if ($r -and "$r".Trim()) { Write-Host ("  [PASS] {0,-34} {1}" -f $Name, "$r".Trim()) -ForegroundColor Green }
        else { Write-Host ("  [WARN] {0,-34} -> {1}" -f $Name, $Note) -ForegroundColor Yellow; $script:Warn++ }
    } catch {
        Write-Host ("  [WARN] {0,-34} -> {1}" -f $Name, $Note) -ForegroundColor Yellow
        $script:Warn++
    }
}

# Refresh PATH from the registry so a freshly-installed tool is visible.
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')

Write-Host "Vault toolchain verification" -ForegroundColor White
Write-Host ("Host: {0} | {1} logical CPUs" -f $env:COMPUTERNAME, $env:NUMBER_OF_PROCESSORS)

Section "Base tooling"
Check "git"      { (git --version) }                       "winget install Git.Git"                          -Critical
Check "7-Zip"    { (& 'C:\Program Files\7-Zip\7z.exe' | Select-String -Pattern '7-Zip').ToString().Trim() } "winget install 7zip.7zip"

Section "Flutter / Dart"
Check "flutter"  { (flutter --version 2>&1 | Select-String 'Flutter' | Select-Object -First 1) } "Install to C:\dev\flutter and add bin to PATH" -Critical
Check "dart"     { (dart --version 2>&1) }                "Comes with Flutter"                              -Critical
Check "flutter doctor (android)" { (flutter doctor -v 2>&1 | Select-String 'Android toolchain' | Select-Object -First 1) } "Run: flutter doctor --android-licenses"

Section "Windows desktop build (MSVC)"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
Check "vswhere"  { (& $vswhere -latest -products * -property displayName) } "Install VS 2022 Build Tools (VCTools workload)" -Critical
Check "MSVC toolset" { (& $vswhere -latest -products * -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\cl.exe' | Select-Object -First 1 | Split-Path -Leaf) } "VCTools workload missing"
Check "Windows SDK"  { (Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Lib" -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'um\x64\kernel32.lib') } | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty Name) } "Install the Windows SDK component (Microsoft.VisualStudio.Component.Windows11SDK.*)"
Check "CMake"    { (cmake --version | Select-Object -First 1) } "winget install Kitware.CMake"
Check "Ninja"    { (ninja --version) }                    "winget install Ninja-build.Ninja"

Section "Android SDK"
Check "JAVA_HOME"      { $env:JAVA_HOME }                          "Set to a JDK 17 install"                        -Critical
Check "java"           { (java -version 2>&1 | Select-String 'version' | Select-Object -First 1) } "JDK 17 required for Gradle" -Critical
Check "ANDROID_SDK_ROOT" { $env:ANDROID_SDK_ROOT }                 "Set to C:\dev\android-sdk"
Check "sdkmanager"     { (& "$env:ANDROID_SDK_ROOT\cmdline-tools\latest\bin\sdkmanager.bat" --version 2>&1 | Select-String '^\d') } "Install cmdline-tools"
Check "adb"            { (adb version 2>&1 | Select-String 'Android Debug Bridge') } "sdkmanager platform-tools"
Check "platform android-36" { (Test-Path "$env:ANDROID_SDK_ROOT\platforms\android-36") } "sdkmanager platforms;android-36"
Check "build-tools 36"     { (Test-Path "$env:ANDROID_SDK_ROOT\build-tools\36.1.0") } "sdkmanager build-tools;36.1.0"

Section "Android emulator (Phase 0 needs a second Android node)"
Check "emulator binary" { (Test-Path "$env:ANDROID_SDK_ROOT\emulator\emulator.exe") } "sdkmanager emulator"
Check "system image"    { (Test-Path "$env:ANDROID_SDK_ROOT\system-images\android-36\google_apis\x86_64") } "sdkmanager system-images;android-36;google_apis;x86_64"
Check "AVD defined"      { (& "$env:ANDROID_SDK_ROOT\emulator\emulator.exe" -list-avds 2>&1 | Select-Object -First 1) } "avdmanager create avd -n vault36 -k system-images;android-36;google_apis;x86_64"
WarnCheck "hypervisor available" { (Get-CimInstance Win32_ComputerSystem).HypervisorPresent } "Emulator will fall back to software rendering (unusable). Attach a physical device over USB instead."

Section "Interop harness (pion) + link shaping"
Check "go"      { (go version) }                                    "winget install GoLang.Go"                       -Critical
Check "clumsy"  { (Test-Path "$env:VaultDevRoot\tools\clumsy\clumsy.exe") } "Extract clumsy-0.3-win64-a.zip to C:\dev\tools\clumsy"
WarnCheck "WSL2 tc netem" { (wsl -d Ubuntu -- bash -lc 'command -v tc || echo missing' 2>&1) } "sudo apt-get install -y iproute2 inside WSL2 Ubuntu"

Section "Result"
Write-Host ""
if ($script:Fail -eq 0) {
    Write-Host "  RESULT: PASS  (warnings: $script:Warn)" -ForegroundColor Green
    Write-Host "  Next: run Phase 0 spikes. Start with spikes/spike01_hw_encode." -ForegroundColor White
} else {
    Write-Host "  RESULT: FAIL  (critical failures: $script:Fail, warnings: $script:Warn)" -ForegroundColor Red
    Write-Host "  Do not start Phase 0 until this passes. See docs/ops/ENVIRONMENT.md." -ForegroundColor White
}
exit $script:Fail