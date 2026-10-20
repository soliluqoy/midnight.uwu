#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Installs the complete Vault development toolchain on a fresh Windows 10/11 machine.

.DESCRIPTION
  Based on the host installation audited on 2026-10-18. Existing complete
  components are reused. Fresh-machine execution has not been repeated after
  the audit fixes; run verification and native smoke builds after installation.

  Installed by this script:
    - Flutter stable (bundles Dart)
    - Visual Studio 2022 Build Tools (MSVC + ATL + Windows SDK + CMake)
    - JDK 17 (Temurin)
    - Android SDK: platform-tools, platform 36, build-tools 36.0.0 + 36.1.0, NDK 28.2 + 29,
      emulator, system image android-36/google_apis/x86_64
    - Go, CMake, Ninja, 7-Zip (via winget)
    - clumsy 0.3 (Windows link shaping for Phase 0 spikes 2 and 5)

.NOTES
  TWO BUGS THIS SCRIPT EXISTS TO AVOID - both were hit on 2026-10-18:

  1. Visual Studio --installPath MUST be a single quoted argument.
     Passing 'C:\Program Files (x86)\...\BuildTools' as a bare array element
     silently truncated the path to 'C:\Program' and installed the entire
     toolchain there. Use C:\VSBuildTools (no spaces) or quote it properly.

  2. The Android `android.exe` CLI splits package lists on SPACE, not on ';'.
     'platforms;android-36' becomes four bogus packages. The new CLI wants
     SLASH-separated ids: platforms/android-36, build-tools/36.1.0, ndk/29.0.x,
     system-images/android-36/google_apis/x86_64.
     The legacy sdkmanager uses ';' and still works for listing.

  Also: Invoke-WebRequest stalls on this host for IPv6-only mirrors such as
  storage.googleapis.com. Use curl.exe -4 for all large downloads.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\setup\install-toolchain.ps1
#>

[CmdletBinding()]
param(
    # Where the Android build is rooted. Must not contain spaces.
    [string]$DevRoot = 'C:\dev',

    # Visual Studio install path. Must not contain spaces (see bug #1).
    [string]$VsPath = 'C:\VSBuildTools',

    # Skip the ~2 GB emulator + system image (use a physical device instead).
    [switch]$SkipEmulator,

    [string]$FlutterVersion = '3.47.7'
)

$ErrorActionPreference = 'Stop'
$curl = "$env:SystemRoot\System32\curl.exe"
$tmp = Join-Path $env:TEMP 'vault-setup'

function Step($msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Skip($msg) { Write-Host "    [--] $msg (already present)" -ForegroundColor DarkGray }
function Warn($msg) { Write-Host "    [!!] $msg" -ForegroundColor Yellow }

function Get-Archive {
    param([string]$Url, [string]$Out)
    & $curl -4 -f -L --retry 3 --retry-delay 5 --retry-all-errors -sS -o $Out $Url
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Out)) { throw "download failed: $Url" }
    return $Out
}

New-Item -ItemType Directory -Path $DevRoot, $tmp -Force | Out-Null

# ---------------------------------------------------------------- winget bits
Step 'Base tooling via winget'
$wingetPkgs = @(
    'Git.Git', 'GoLang.Go', 'Kitware.CMake',
    'Ninja-build.Ninja', '7zip.7zip', 'Gyan.FFmpeg.Essentials'
)
foreach ($p in $wingetPkgs) {
    $already = winget list --id $p --exact --accept-source-agreements 2>$null |
               Select-String -SimpleMatch $p.Split('.')[-1]
    if ($already) { Skip $p; continue }
    Write-Host "    installing $p ..."
    winget install --id $p --exact --silent --accept-package-agreements `
                   --accept-source-agreements --disable-interactivity | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "winget install failed for $p (exit $LASTEXITCODE)" }
    Ok $p
}

# ---------------------------------------------------------------- JDK 17
Step 'JDK 17 (Temurin)'
$jdkPath = Join-Path $DevRoot 'jdk17'
$existingJdk = Get-ChildItem -LiteralPath $jdkPath -Directory -ErrorAction SilentlyContinue |
               Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\java.exe') } |
               Sort-Object Name -Descending | Select-Object -First 1
if ($existingJdk -or (Test-Path (Join-Path $jdkPath 'bin\java.exe'))) {
    Skip 'JDK 17'
} else {
    New-Item -ItemType Directory -Path $jdkPath -Force | Out-Null
    # NOTE: this endpoint returns a .zip, NOT an .msi, despite /binary/.
    # Saving it as .msi makes msiexec fail with exit code 1620.
    $zip = Join-Path $tmp 'jdk17.zip'
    Get-Archive 'https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse?project=jdk' $zip | Out-Null
    Expand-Archive $zip $jdkPath -Force
    Remove-Item $zip -Force
    Ok 'JDK 17'
}
$javaHome = if (Test-Path -LiteralPath (Join-Path $jdkPath 'bin\java.exe')) { $jdkPath } else {
    (Get-ChildItem -LiteralPath $jdkPath -Directory |
     Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\java.exe') } |
     Sort-Object Name -Descending | Select-Object -First 1).FullName
}
if (-not $javaHome) { throw 'No extracted JDK with bin\java.exe was found.' }
$env:JAVA_HOME = $javaHome
Ok "JAVA_HOME = $javaHome"

# ---------------------------------------------------------------- Flutter
Step "Flutter $FlutterVersion (stable, bundles Dart)"
$flutterRoot = Join-Path $DevRoot 'flutter'
if (Test-Path (Join-Path $flutterRoot 'bin\flutter.bat')) {
    Skip 'Flutter SDK'
} else {
    $zip = Join-Path $tmp "flutter_$FlutterVersion.zip"
    Get-Archive "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_$FlutterVersion-stable.zip" $zip | Out-Null
    $manifest = (& $curl -4 -f -sS 'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json') | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Could not retrieve official Flutter checksum manifest.' }
    $release = $manifest.releases | Where-Object { $_.version -eq $FlutterVersion -and $_.channel -eq 'stable' } | Select-Object -First 1
    if (-not $release.sha256 -or (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $release.sha256) {
        throw 'Flutter archive checksum does not match official manifest.'
    }
    # bsdtar is dramatically faster than Expand-Archive for a 1.8 GB zip.
    & tar.exe -xf $zip -C $DevRoot
    if ($LASTEXITCODE -ne 0) { throw 'Flutter archive extraction failed.' }
    Remove-Item $zip -Force
    Ok 'Flutter SDK'
}
$env:Path = "$flutterRoot\bin;$env:Path"
$flutterSafePath = $flutterRoot -replace '\\','/'
$existingSafePaths = @(git config --global --get-all safe.directory)
if ($existingSafePaths -notcontains $flutterSafePath) {
    git config --global --add safe.directory $flutterSafePath
    if ($LASTEXITCODE -ne 0) { throw 'Could not register the Flutter SDK Git directory.' }
}
& "$flutterRoot\bin\flutter.bat" config "--jdk-dir=$javaHome"
if ($LASTEXITCODE -ne 0) { throw 'Flutter JDK configuration failed.' }
Ok "Flutter at $flutterRoot"

# ---------------------------------------------- Visual Studio Build Tools
Step 'Visual Studio 2022 Build Tools (MSVC + Windows SDK + CMake)'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$haveVc = $false
if (Test-Path $vswhere) {
    $haveVc = [bool](& $vswhere -latest -products * -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\cl.exe' 2>$null)
}
if ($haveVc) {
    Skip "MSVC toolchain (already present)"
} else {
    $boot = Join-Path $tmp 'vs_BuildTools.exe'
    Get-Archive 'https://aka.ms/vs/17/release/vs_BuildTools.exe' $boot | Out-Null

    $vsArgs = @(
        '--quiet', '--wait', '--norestart', '--nocache',
        # NOTE: each element below MUST stay a single argument. See bug #1.
        "--installPath=$VsPath",
        '--add', 'Microsoft.VisualStudio.Workload.VCTools',
        '--add', 'Microsoft.VisualStudio.Component.VC.ATL',
        '--add', 'Microsoft.VisualStudio.Component.VC.CMake.Project',
        '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.26100',
        '--includeRecommended'
    )
    $p = Start-Process -FilePath $boot -ArgumentList $vsArgs -WindowStyle Hidden -Wait -PassThru
    if ($p.ExitCode -notin @(0,3010)) { throw "VS Build Tools installer failed with exit code $($p.ExitCode)" }
    if ($p.ExitCode -eq 3010) { Warn 'VS installation requests a reboot before verification.' }
    Ok "MSVC at $VsPath"
}

# Existing MSVC alone is insufficient for flutter_secure_storage_windows.
& "$PSScriptRoot\install-windows-atl.ps1"

# ---------------------------------------------------------------- Android SDK
Step 'Android SDK'
$sdk = Join-Path $DevRoot 'android-sdk'
$androidExe = Join-Path $sdk 'cmdline-tools\latest\bin\android.exe'

if (-not (Test-Path $androidExe)) {
    New-Item -ItemType Directory -Path (Join-Path $sdk 'cmdline-tools') -Force | Out-Null
    $zip = Join-Path $tmp 'cmdline-tools.zip'
    # Resolve the newest published build rather than hardcoding a number.
    $xml = & $curl -4 -f -sS 'https://dl.google.com/android/repository/repository2-3.xml'
    if ($LASTEXITCODE -ne 0) { throw 'Could not retrieve Android command-line tools metadata.' }
    $build = ([regex]::Matches($xml, 'commandlinetools-win-[0-9]+_latest\.zip') |
              ForEach-Object { $_.Value } |
              ForEach-Object { [int]($_ -replace '.*win-([0-9]+)_.*','$1') } |
              Measure-Object -Maximum).Maximum
    if (-not $build) { throw 'could not resolve the latest command-line tools build number' }
    Get-Archive "https://dl.google.com/android/repository/commandlinetools-win-$build`_latest.zip" $zip | Out-Null
    Expand-Archive $zip (Join-Path $tmp 'cmdt') -Force
    Move-Item (Join-Path $tmp 'cmdt\cmdline-tools') (Join-Path $sdk 'cmdline-tools\latest') -Force
    Remove-Item $zip -Force
    Ok "command-line tools $build"
}

$env:ANDROID_HOME = $sdk
$env:ANDROID_SDK_ROOT = $sdk

# Use the official license flow. Do not synthesize license acceptance files.
& (Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat') --licenses
if ($LASTEXITCODE -ne 0) { throw 'Android license acceptance did not complete.' }

# NOTE: SLASH-separated ids. See bug #2.
# Flutter 3.47.7's generated runner defaults to NDK 28.2. Installing only 29
# makes Gradle call the deprecated sdkmanager shim with an incompatible ID.
# The pinned native plugins also compile against platform 35 and SDK CMake 3.22.1.
$pkgs = @('platform-tools', 'platforms/android-35', 'platforms/android-36', 'build-tools/36.0.0', 'build-tools/36.1.0', 'ndk/28.2.13676358', 'ndk/29.0.14206865', 'cmake/3.22.1')
if (-not $SkipEmulator) { $pkgs += 'emulator', 'system-images/android-36/google_apis/x86_64' }
Write-Host "    installing: $($pkgs -join ', ')"
& $androidExe sdk install "--sdk=$sdk" @pkgs
if ($LASTEXITCODE -ne 0) { throw "android sdk install failed with exit code $LASTEXITCODE" }
Ok 'Android SDK packages'

if (-not $SkipEmulator) {
    Write-Host '    creating AVD vault36 ...'
    $avd = Join-Path $sdk 'cmdline-tools\latest\bin\avdmanager.bat'
    $existingAvds = & (Join-Path $sdk 'emulator\emulator.exe') -list-avds
    if ($LASTEXITCODE -ne 0) { throw 'Could not list Android virtual devices.' }
    if ($existingAvds -notcontains 'vault36') {
        'no' | & $avd create avd -n vault36 -k 'system-images/android-36/google_apis/x86_64' -d pixel_7 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'AVD creation failed.' }
    }
}

# ---------------------------------------------------------------- clumsy
Step 'clumsy 0.3 (Windows link shaping)'
$clumsyDir = Join-Path $DevRoot 'tools\clumsy'
if (Test-Path (Join-Path $clumsyDir 'clumsy.exe')) {
    Skip 'clumsy'
} else {
    New-Item -ItemType Directory -Path $clumsyDir -Force | Out-Null
    $zip = Join-Path $tmp 'clumsy.zip'
    # clumsy.netrf.org and jitbit.net are unreachable from some networks;
    # the GitHub release is the reliable source.
    Get-Archive 'https://github.com/jagt/clumsy/releases/download/0.3/clumsy-0.3-win64-a.zip' $zip | Out-Null
    Expand-Archive $zip $clumsyDir -Force
    Remove-Item $zip -Force
    Ok 'clumsy'
}

# ---------------------------------------------------------------- env vars
Step 'Persistent environment variables'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() })
foreach ($add in @("$javaHome\bin", "$sdk\cmdline-tools\latest\bin", "$sdk\platform-tools",
                   "$sdk\emulator", "$flutterRoot\bin", (Join-Path $DevRoot 'tools'))) {
    if ($parts -notcontains $add) { $parts += $add }
}
[Environment]::SetEnvironmentVariable('JAVA_HOME',     $javaHome, 'User')
[Environment]::SetEnvironmentVariable('ANDROID_HOME',  $sdk,      'User')
[Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', $sdk,   'User')
[Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
Ok 'JAVA_HOME, ANDROID_HOME, ANDROID_SDK_ROOT, PATH'

Step 'Done'
Write-Host '  Open a NEW terminal (PATH changes do not apply to this one), then run:' -ForegroundColor White
Write-Host '    powershell -ExecutionPolicy Bypass -File tools\setup\verify-toolchain.ps1' -ForegroundColor White
Write-Host '    flutter doctor' -ForegroundColor White
