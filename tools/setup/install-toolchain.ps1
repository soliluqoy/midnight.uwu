#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Installs the complete Vault development toolchain on a fresh Windows 10/11 machine.

.DESCRIPTION
  Encodes the exact procedure that was verified on 2026-10-18. Safe to re-run:
  each step is skipped if already satisfied.

  Installed by this script:
    - Flutter stable (bundles Dart)
    - Visual Studio 2022 Build Tools (MSVC + Windows SDK + CMake)
    - JDK 17 (Temurin)
    - Android SDK: platform-tools, platform 36, build-tools 36.1.0, NDK 29,
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
    & $curl -4 -L --retry 3 --retry-delay 5 --retry-all-errors -sS -o $Out $Url
    if ($LASTEXITCODE -ne 0) { throw "download failed: $Url" }
    return $Out
}

New-Item -ItemType Directory -Path $DevRoot, $tmp -Force | Out-Null

# ---------------------------------------------------------------- winget bits
Step 'Base tooling via winget'
$wingetPkgs = @(
    'Git.Git', 'GoLang.Go', 'Kitware.CMake',
    'Ninja-build.Ninja', '7zip.7zip'
)
foreach ($p in $wingetPkgs) {
    $already = winget list --id $p --exact --accept-source-agreements 2>$null |
               Select-String -SimpleMatch $p.Split('.')[-1]
    if ($already) { Skip $p; continue }
    Write-Host "    installing $p ..."
    winget install --id $p --exact --silent --accept-package-agreements `
                   --accept-source-agreements --disable-interactivity | Out-Null
    Ok $p
}

# ---------------------------------------------------------------- JDK 17
Step 'JDK 17 (Temurin)'
$jdkPath = Join-Path $DevRoot 'jdk17'
if (Test-Path (Join-Path $jdkPath 'bin\java.exe')) {
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
$javaHome = (Get-ChildItem $jdkPath -Directory | Select-Object -First 1).FullName
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
    # bsdtar is dramatically faster than Expand-Archive for a 1.8 GB zip.
    & tar.exe -xf $zip -C $DevRoot
    Remove-Item $zip -Force
    Ok 'Flutter SDK'
}
$env:Path = "$flutterRoot\bin;$env:Path"
git config --global --add safe.directory ($flutterRoot -replace '\\','/')
Ok "Flutter at $flutterRoot"

# ---------------------------------------------- Visual Studio Build Tools
Step 'Visual Studio 2022 Build Tools (MSVC + Windows SDK + CMake)'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$haveVc = $false
if (Test-Path $vswhere) {
    $haveVc = [bool](& $vswhere -latest -products * -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\cl.exe' 2>$null)
}
if ($haveVc -and $haveVc -isnot [bool] -or (Test-Path $VsPath)) {
    Skip "MSVC toolchain (already present)"
} else {
    $boot = Join-Path $tmp 'vs_BuildTools.exe'
    Get-Archive 'https://aka.ms/vs/17/release/vs_BuildTools.exe' $boot | Out-Null

    $vsArgs = @(
        '--quiet', '--wait', '--norestart', '--nocache',
        # NOTE: each element below MUST stay a single argument. See bug #1.
        "--installPath=$VsPath",
        '--add', 'Microsoft.VisualStudio.Workload.VCTools',
        '--add', 'Microsoft.VisualStudio.Component.VC.CMake.Project',
        '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.26100',
        '--includeRecommended'
    )
    $p = Start-Process -FilePath $boot -ArgumentList $vsArgs -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "VS Build Tools installer failed with exit code $($p.ExitCode)" }
    Ok "MSVC at $VsPath"
}

# ---------------------------------------------------------------- Android SDK
Step 'Android SDK'
$sdk = Join-Path $DevRoot 'android-sdk'
$androidExe = Join-Path $sdk 'cmdline-tools\latest\bin\android.exe'

if (-not (Test-Path $androidExe)) {
    New-Item -ItemType Directory -Path (Join-Path $sdk 'cmdline-tools') -Force | Out-Null
    $zip = Join-Path $tmp 'cmdline-tools.zip'
    # Resolve the newest published build rather than hardcoding a number.
    $xml = & $curl -4 -sS 'https://dl.google.com/android/repository/repository2-3.xml'
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

# Pre-write the accepted licenses so nothing blocks on an interactive prompt.
$lic = Join-Path $sdk 'licenses'
New-Item -ItemType Directory -Path $lic -Force | Out-Null
$hashes = "8933bad161af4178b1185d1a37fbf41ea5269c55`nd56f5187479451eabf01fb78af6dfcb131a6481e`n24333f8a63b6825ea9c5514f83c2829b004d1fee"
'android-sdk-license', 'android-sdk-preview-license', 'android-sdk-arm-dbt-license' |
    ForEach-Object { $hashes | Set-Content (Join-Path $lic $_) -Encoding ASCII }
Ok 'licenses accepted'

# NOTE: SLASH-separated ids. See bug #2.
$pkgs = @('platform-tools', 'platforms/android-36', 'build-tools/36.1.0', 'ndk/29.0.14206865')
if (-not $SkipEmulator) { $pkgs += 'emulator', 'system-images/android-36/google_apis/x86_64' }
Write-Host "    installing: $($pkgs -join ', ')"
& $androidExe sdk install "--sdk=$sdk" @pkgs
if ($LASTEXITCODE -ne 0) { throw "android sdk install failed with exit code $LASTEXITCODE" }
Ok 'Android SDK packages'

if (-not $SkipEmulator) {
    Write-Host '    creating AVD vault36 ...'
    $avd = Join-Path $sdk 'cmdline-tools\latest\bin\avdmanager.bat'
    'no' | & $avd create avd -n vault36 -k 'system-images/android-36/google_apis/x86_64' -d pixel_7 2>&1 | Out-Null
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