# Regression checks for false passes and false failures in the verifier.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\verification-helpers.ps1"
$assertions = 0
foreach ($bad in @($null, $false, '', '   ', @())) {
    if (Test-VaultProbeResult $bad) { throw 'False or empty probe passed.' }
    $assertions++
}
if (-not (Test-VaultProbeResult $true)) { throw 'True probe failed.' }
$assertions++
$failed = $false
try { Invoke-VaultNative "$PSHOME\powershell.exe" @('-NoProfile','-Command',"Write-Output 'plausible version'; exit 7") | Out-Null } catch { $failed = $true }
if (-not $failed) { throw 'Native command with failure exit code passed.' }
$assertions++
$failed = $false
try { Invoke-VaultNative 'vault-deliberately-missing-command' | Out-Null } catch { $failed = $true }
if (-not $failed) { throw 'Missing command passed.' }
$assertions++
$good = Invoke-VaultNative "$PSHOME\powershell.exe" @('-NoProfile','-Command',"Write-Output 'version 1'; exit 0")
if ($good -ne 'version 1') { throw 'Successful native command failed.' }
$assertions++

# Generate markers by codepoint so source-file encoding cannot mask a regression.
foreach ($marker in @([char]0x2713, [char]0x221A)) {
    $doctor = "[$marker] Android toolchain - develop for Android devices`r`n[$marker] Visual Studio - develop Windows apps"
    Assert-VaultDoctorPlatforms $doctor | Out-Null
    $assertions++
}
foreach ($component in @('Android toolchain','Visual Studio - develop Windows apps')) {
    foreach ($marker in @('!', 'X', [string][char]0x2717, '?', 'absent')) {
        $lines = foreach ($name in @('Android toolchain','Visual Studio - develop Windows apps')) {
            if ($name -ne $component) { "[$([char]0x2713)] $name" }
            elseif ($marker -ne 'absent') { "[$marker] $name" }
            else { "    $name mentioned in another component's detail" }
        }
        $failed = $false
        try { Assert-VaultDoctorPlatforms ($lines -join "`n") | Out-Null } catch { $failed = $true }
        if (-not $failed) { throw "Unhealthy or absent doctor component passed: $component ($marker)." }
        $assertions++
    }
}

# Reproduce UTF-8 native output under the Windows OEM code page, not just strings.
$originalEncoding = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(437)
    $utf8Command = '$bytes = [Text.Encoding]::UTF8.GetBytes(''['' + [char]0x2713 + '']''); $stream = [Console]::OpenStandardOutput(); $stream.Write($bytes, 0, $bytes.Length)'
    $good = Invoke-VaultNative "$PSHOME\powershell.exe" @('-NoProfile','-Command',$utf8Command) -OutputEncoding ([Text.UTF8Encoding]::new($false))
    if ($good -ne "[$([char]0x2713)]") { throw 'UTF-8 native output was decoded using the OEM code page.' }
    $assertions++
    if ([Console]::OutputEncoding.CodePage -ne 437) { throw 'Native success did not restore console encoding.' }
    $assertions++
    $failed = $false
    try {
        Invoke-VaultNative "$PSHOME\powershell.exe" @('-NoProfile','-Command',"$utf8Command; exit 7") -OutputEncoding ([Text.UTF8Encoding]::new($false)) | Out-Null
    } catch { $failed = $true }
    if (-not $failed) { throw 'UTF-8 native command with failure exit code passed.' }
    $assertions++
    if ([Console]::OutputEncoding.CodePage -ne 437) { throw 'Native failure did not restore console encoding.' }
    $assertions++
} finally { [Console]::OutputEncoding = $originalEncoding }
Write-Host "PASS: $assertions verifier regression assertions."
