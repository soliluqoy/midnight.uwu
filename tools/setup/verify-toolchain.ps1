<#
.SYNOPSIS
  Verify installed tooling without elevation or changing the host.
.DESCRIPTION
  Every required failure affects exit status. PASS means installed tools only.
  Native smoke builds, attached hardware and Phase 0 results are separate gates.
#>
[CmdletBinding()]
param(
    [string]$DevRoot = $(if ($env:VaultDevRoot) { $env:VaultDevRoot } else { 'C:\dev' }),
    [string]$JsonOutput,
    [switch]$SkipEmulator,
    [switch]$RequirePhysicalAndroid
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\verification-helpers.ps1"
$results = [Collections.Generic.List[object]]::new()
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User') + ';' + $env:Path
$regJava = [Environment]::GetEnvironmentVariable('JAVA_HOME','User')
if ($regJava -and (Test-Path -LiteralPath "$regJava\bin\java.exe")) { $env:JAVA_HOME = $regJava }
$sdk = [Environment]::GetEnvironmentVariable('ANDROID_SDK_ROOT','User')
if (-not $sdk) { $sdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "$DevRoot\android-sdk" } }
$env:ANDROID_SDK_ROOT = $sdk
$env:ANDROID_HOME = $sdk

function Check {
    param([string]$Name, [scriptblock]$Probe, [string]$Fix, [switch]$Optional)
    try {
        $value = & $Probe
        if (-not (Test-VaultProbeResult $value)) { throw 'Probe returned false or empty output.' }
        $detail = ([string]($value -join ' ')).Trim()
        $status = 'PASS'
    } catch {
        $detail = "$($_.Exception.Message) Remedy: $Fix"
        $status = if ($Optional) { 'WARN' } else { 'FAIL' }
    }
    $results.Add([pscustomobject]@{name=$Name; status=$status; detail=$detail})
    Write-Host ("[{0}] {1}: {2}" -f $status, $Name, ($detail -replace '\r?\n', ' '))
}

Write-Host "Vault installation verification on $env:COMPUTERNAME"
Check 'Git' { Invoke-VaultNative git @('--version') } 'Install Git.Git.'
Check '7-Zip' { Assert-VaultPath 'C:\Program Files\7-Zip\7z.exe' } 'Optional archive tool.' -Optional
Check 'Flutter and Dart pins' {
    $version = (Invoke-VaultNative flutter @('--version','--machine')) | ConvertFrom-Json
    if ($version.frameworkVersion -ne '3.47.7' -or $version.dartSdkVersion -notmatch '^3\.13\.5\b') {
        throw "Expected Flutter 3.47.7 / Dart 3.13.5; found $($version.frameworkVersion) / $($version.dartSdkVersion)."
    }
    "Flutter $($version.frameworkVersion); Dart $($version.dartSdkVersion)"
} 'Use the pinned SDK or deliberately update the manifest and repeat smoke builds.'
Check 'flutter doctor required platforms' {
    # Flutter emits UTF-8 even when Windows PowerShell's console uses CP437.
    $doctor = Invoke-VaultNative flutter @('doctor','-v') -OutputEncoding ([System.Text.UTF8Encoding]::new($false))
    Assert-VaultDoctorPlatforms $doctor
} 'Read flutter doctor -v and repair the named component.'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
Check 'MSVC C++ workload' {
    $found = Invoke-VaultNative $vswhere @('-latest','-products','*','-requires','Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-find','VC\Tools\MSVC\**\bin\Hostx64\x64\cl.exe')
    Assert-VaultPath ($found -split '\r?\n' | Select-Object -First 1)
} 'Install the VS 2022 C++ desktop workload.'
Check 'MSVC ATL protected-storage headers and libraries' {
    $installation = Invoke-VaultNative $vswhere @('-latest','-products','*','-version','[17.0,18.0)','-property','installationPath')
    $versionFile = Join-Path $installation 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
    Assert-VaultPath $versionFile | Out-Null
    $version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    Assert-VaultPath (Join-Path $installation "VC\Tools\MSVC\$version\atlmfc\include\atlstr.h") | Out-Null
    Assert-VaultPath (Join-Path $installation "VC\Tools\MSVC\$version\atlmfc\lib\x64\atls.lib")
} 'Run tools/setup/install-windows-atl.ps1 in Administrator PowerShell; no SDK reinstall is needed.'
Check 'MSBuild' {
    $found = Invoke-VaultNative $vswhere @('-latest','-products','*','-find','MSBuild\**\Bin\MSBuild.exe')
    Invoke-VaultNative ($found -split '\r?\n' | Select-Object -First 1) @('-version','-nologo')
} 'Repair VS Build Tools.'
Check 'Windows SDK headers and libraries' {
    $kits = "${env:ProgramFiles(x86)}\Windows Kits\10"
    $installed = Get-ChildItem -LiteralPath "$kits\Lib" -Directory | Sort-Object Name -Descending | Where-Object {
        (Test-Path -LiteralPath "$($_.FullName)\um\x64\kernel32.lib") -and
        (Test-Path -LiteralPath "$kits\Include\$($_.Name)\um\Windows.h") -and
        (Test-Path -LiteralPath "$kits\bin\$($_.Name)\x64\rc.exe")
    } | Select-Object -First 1
    if (-not $installed) { throw 'No complete x64 Windows SDK.' }
    $installed.Name
} 'Install Windows SDK 10.0.26100.0.'
Check 'CMake' { Invoke-VaultNative cmake @('--version') } 'Install Kitware.CMake.'
Check 'Ninja' { Invoke-VaultNative ninja @('--version') } 'Install Ninja-build.Ninja.'
Check 'JDK 17 executable' {
    Assert-VaultPath "$env:JAVA_HOME\bin\java.exe" | Out-Null
    $version = Invoke-VaultNative "$env:JAVA_HOME\bin\java.exe" @('-version')
    if ($version -notmatch 'version "17\.') { throw "JDK 17 required: $version" }
    $version
} 'Set JAVA_HOME and flutter config --jdk-dir to a working JDK 17.'
Check 'Android SDK manager' { Invoke-VaultNative "$sdk\cmdline-tools\latest\bin\sdkmanager.bat" @('--version') } 'Install Android command-line tools.'
Check 'ADB' { Invoke-VaultNative "$sdk\platform-tools\adb.exe" @('version') } 'Install platform-tools.'
Check 'Android platform 36' { Assert-VaultPath "$sdk\platforms\android-36\android.jar" } 'Install platforms;android-36.'
Check 'Pinned native plugin Android prerequisites' {
    Assert-VaultPath "$sdk\platforms\android-35\android.jar" | Out-Null
    Assert-VaultPath "$sdk\cmake\3.22.1\bin\cmake.exe" | Out-Null
    'Platform 35 and Android SDK CMake 3.22.1 present.'
} 'Install platforms/android-35 and cmake/3.22.1 with android sdk install.'
Check 'Build-tools 36.0.0 and 36.1.0' {
    foreach ($buildVersion in @('36.0.0','36.1.0')) {
        foreach ($binary in @('aapt2.exe','d8.bat','zipalign.exe','apksigner.bat')) {
            Assert-VaultPath "$sdk\build-tools\$buildVersion\$binary" | Out-Null
        }
    }
    'Both default-runner and selected newer build-tools have the required binaries.'
} 'Explicitly install build-tools/36.0.0 and build-tools/36.1.0 with android sdk install.'
Check 'NDK 29.0.14206865' {
    Assert-VaultPath "$sdk\ndk\29.0.14206865\toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe"
} 'Install ndk;29.0.14206865.'
Check 'Flutter default NDK 28.2.13676358' {
    Assert-VaultPath "$sdk\ndk\28.2.13676358\toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe"
} 'Run android sdk install --sdk=<sdk-path> ndk/28.2.13676358; Gradle auto-install is incompatible with the current CLI.'
if (-not $SkipEmulator) {
    Check 'Android emulator and hypervisor' {
        Invoke-VaultNative "$sdk\emulator\emulator.exe" @('-accel-check')
    } 'Enable WHPX/virtualization or use -SkipEmulator with a physical device.'
    Check 'Android 36 system image' { Assert-VaultPath "$sdk\system-images\android-36\google_apis\x86_64\system.img" } 'Install Android 36 Google APIs x86_64 image.'
    Check 'vault36 AVD' {
        $avds = Invoke-VaultNative "$sdk\emulator\emulator.exe" @('-list-avds')
        if ($avds -notmatch '(?m)^vault36\s*$') { throw 'vault36 AVD not defined.' }
        'vault36'
    } 'Create vault36 with avdmanager.'
}
Check 'Physical Android device' {
    $devices = Invoke-VaultNative "$sdk\platform-tools\adb.exe" @('devices','-l')
    $physical = $devices -split '\r?\n' | Where-Object { $_ -match '^\S+\s+device\b' -and $_ -notmatch '^emulator-' }
    if (-not $physical) { throw 'No authorized physical device; hardware codec/background gates unverified.' }
    $physical
} 'Attach and authorize a real Android phone.' -Optional:(-not $RequirePhysicalAndroid)
Check 'Go' { Invoke-VaultNative go @('version') } 'Install GoLang.Go.'
Check 'Synthetic media fixture tools' {
    $encoder = Invoke-VaultNative ffmpeg @('-version')
    $inspector = Invoke-VaultNative ffprobe @('-version')
    ($encoder -split '\r?\n')[0] + '; ' + ($inspector -split '\r?\n')[0]
} 'Install Gyan.FFmpeg.Essentials; fixture generation only, not bundled with Vault.'
Check 'clumsy and WinDivert files' {
    foreach ($binary in @('clumsy.exe','WinDivert.dll','WinDivert64.sys')) {
        Assert-VaultPath "$DevRoot\tools\clumsy\$binary" | Out-Null
    }
    'Executable/driver present; live shaping requires separate elevated validation.'
} 'Extract official clumsy 0.3 win64 archive.'
Check 'WSL2 and tc netem' {
    $kernel = Invoke-VaultNative wsl @('-d','Ubuntu','--','uname','-r')
    if ($kernel -notmatch 'WSL2') { throw "Ubuntu is not WSL2: $kernel" }
    Invoke-VaultNative wsl @('-d','Ubuntu','--','bash','-lc','command -v tc >/dev/null && tc -V')
} 'Install WSL2 Ubuntu and iproute2.'
Check 'Workspace lockfile and Melos' {
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Assert-VaultPath "$repoRoot\pubspec.lock" | Out-Null
    Push-Location $repoRoot
    try { Invoke-VaultNative dart @('run','melos','--version') } finally { Pop-Location }
} 'Run dart pub get in the repository root.'

$failures = @($results | Where-Object status -eq 'FAIL').Count
$warnings = @($results | Where-Object status -eq 'WARN').Count
$report = [pscustomobject]@{
    checkedAt = (Get-Date).ToString('o'); hostName = $env:COMPUTERNAME
    scope = 'Installed tools only; native smoke builds and Phase 0 gates are separate.'
    failures = $failures; warnings = $warnings; checks = $results.ToArray()
}
if ($JsonOutput) { $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonOutput -Encoding UTF8 }
Write-Host "RESULT: $(if ($failures) { 'FAIL' } else { 'PASS' }) ($failures failures, $warnings warnings)"
Write-Host 'Continue measured Phase 0 gates; installation checks do not establish product readiness.'
exit ([int]($failures -gt 0))
