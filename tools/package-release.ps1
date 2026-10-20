[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$rootPath = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\', '/')
if ($outputPath.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase) -or
    $outputPath.StartsWith($rootPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must be outside the source repository.'
}

$windowsPath = Join-Path $root 'apps/vault/build/windows/x64/runner/Release'
$apkPath = Join-Path $root 'apps/vault/build/app/outputs/flutter-apk'
$apkInputs = @(
    @{ Source = Join-Path $apkPath 'app-arm64-v8a-release.apk'; Name = 'midnight-android-arm64.apk' },
    @{ Source = Join-Path $apkPath 'app-x86_64-release.apk'; Name = 'midnight-android-x64.apk' }
)
$requiredFiles = @(
    (Join-Path $windowsPath 'vault.exe'),
    (Join-Path $windowsPath 'flutter_windows.dll'),
    (Join-Path $windowsPath 'data/app.so'),
    (Join-Path $windowsPath 'data/icudtl.dat')
) + @($apkInputs | ForEach-Object { $_.Source })
foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) {
        throw "Missing or empty release input: $file"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $windowsPath 'data/flutter_assets') -PathType Container)) {
    throw 'Missing Windows Flutter data/flutter_assets directory.'
}

# Archive only the build bundle, never OS application-data or identity directories.
# Keep all runtime DLLs and Flutter assets; omit stale branding and debug symbols.
$windowsFiles = @(Get-ChildItem -LiteralPath $windowsPath -File -Recurse -Force | Where-Object {
    $_.Name -ine 'midnight.exe' -and
    $_.Extension -notin @('.pdb', '.ilk', '.exp', '.lib', '.obj', '.log')
})
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipName = 'midnight-windows-x64.zip'
$temporaryZip = Join-Path $outputPath ([System.IO.Path]::GetRandomFileName() + '.zip')
try {
    $archive = [System.IO.Compression.ZipFile]::Open($temporaryZip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $windowsFiles) {
            $entryName = $file.FullName.Substring($windowsPath.Length + 1).Replace('\', '/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }
    Move-Item -LiteralPath $temporaryZip -Destination (Join-Path $outputPath $zipName) -Force
} finally {
    if (Test-Path -LiteralPath $temporaryZip) {
        Remove-Item -LiteralPath $temporaryZip -Force
    }
}
foreach ($apk in $apkInputs) {
    Copy-Item -LiteralPath $apk.Source -Destination (Join-Path $outputPath $apk.Name) -Force
}
$assetNames = @($zipName) + @($apkInputs | ForEach-Object { $_.Name })
$checksums = foreach ($name in $assetNames) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $outputPath $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $name"
}
[System.IO.File]::WriteAllLines((Join-Path $outputPath 'SHA256SUMS.txt'), [string[]]$checksums, [System.Text.Encoding]::ASCII)
Write-Host "Release assets written to $outputPath"
