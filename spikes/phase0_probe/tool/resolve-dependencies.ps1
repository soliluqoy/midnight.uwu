# Flutter can resolve packages but fail while creating Windows plugin symlinks.
# Accept only that specific post-resolution failure, then prepare local junctions.
$ErrorActionPreference = 'Stop'
$savedPreference = $ErrorActionPreference
$flutterCommand = (Get-Command flutter -CommandType Application -ErrorAction Stop).Source
try {
    $ErrorActionPreference = 'Continue'
    $output = (& $flutterCommand pub get 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
    $nativeExit = $LASTEXITCODE
} finally { $ErrorActionPreference = $savedPreference }
Write-Host $output
if ($nativeExit -ne 0) {
    if ($output -notmatch 'Got dependencies!' -or $output -notmatch 'Building with plugins requires symlink support') {
        throw "Dependency resolution failed (exit $nativeExit)."
    }
    Write-Warning 'Packages resolved; preparing Windows junctions for this process token.'
}
& "$PSScriptRoot\prepare-windows-links.ps1"
