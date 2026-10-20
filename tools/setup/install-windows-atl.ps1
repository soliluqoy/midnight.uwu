[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/verification-helpers.ps1"
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
Assert-VaultPath $vswhere | Out-Null
$instance = (Invoke-VaultNative $vswhere @('-latest', '-products', '*', '-version', '[17.0,18.0)', '-format', 'json') | ConvertFrom-Json | Select-Object -First 1)
if (-not $instance) { throw 'Visual Studio 2022 Build Tools is required before adding ATL.' }
$versionFile = Join-Path $instance.installationPath 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt'
Assert-VaultPath $versionFile | Out-Null
$version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
$atlHeader = Join-Path $instance.installationPath "VC/Tools/MSVC/$version/atlmfc/include/atlstr.h"
$atlLibrary = Join-Path $instance.installationPath "VC/Tools/MSVC/$version/atlmfc/lib/x64/atls.lib"
if ((Test-Path -LiteralPath $atlHeader) -and (Test-Path -LiteralPath $atlLibrary)) {
    Write-Host "ATL already present for MSVC $version."
    return
}
$principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Missing MSVC ATL (atlstr.h), required by Windows protected storage. Run this script from an Administrator PowerShell; no SDK reinstall is required.'
}
$installer = Join-Path (Split-Path -Parent $vswhere) 'setup.exe'
Assert-VaultPath $installer | Out-Null
# Only add ATL to the existing instance. Never repair, remove or force-close apps.
$arguments = @('modify', "--installPath=`"$($instance.installationPath)`"", '--channelId', $instance.channelId,
    '--add', 'Microsoft.VisualStudio.Component.VC.ATL', '--quiet', '--norestart')
$process = Start-Process -FilePath $installer -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -Wait -PassThru
if ($process.ExitCode -notin @(0, 3010)) { throw "ATL installation failed (exit $($process.ExitCode))." }
if ($process.ExitCode -eq 3010) { Write-Warning 'ATL installation requests a reboot before the next Windows build.' }
if (-not (Test-Path -LiteralPath $atlHeader) -or -not (Test-Path -LiteralPath $atlLibrary)) {
    throw "Installer returned without ATL for the selected MSVC $version; inspect the Visual Studio installer logs."
}
Write-Host "ATL ready for MSVC $version."
