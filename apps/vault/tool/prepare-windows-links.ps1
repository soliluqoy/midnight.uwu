# Same project-local junction pattern used by the native probe. No machine-policy changes.
$ErrorActionPreference = 'Stop'
$appRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$metadata = Get-Content -Raw -LiteralPath (Join-Path $appRoot '.flutter-plugins-dependencies') | ConvertFrom-Json
$linkRoot = [IO.Path]::GetFullPath((Join-Path $appRoot 'windows\flutter\ephemeral\.plugin_symlinks'))
if (-not $linkRoot.StartsWith($appRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Plugin link destination escaped the app project.'
}
New-Item -ItemType Directory -Force -Path $linkRoot | Out-Null
foreach ($plugin in $metadata.plugins.windows) {
    if ($plugin.name -notmatch '^[a-z0-9_]+$') { throw 'Unexpected plugin name.' }
    $target = [IO.Path]::GetFullPath($plugin.path).TrimEnd('\','/')
    if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw "Missing package: $target" }
    $link = Join-Path $linkRoot $plugin.name
    if (Test-Path -LiteralPath $link) {
        $existing = Get-Item -LiteralPath $link -Force
        if (-not ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing to replace an ordinary directory: $link"
        }
        if ([IO.Path]::GetFullPath([string]$existing.Target).TrimEnd('\','/') -eq $target) { continue }
        [IO.Directory]::Delete($link)
    }
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    Write-Host "Linked installed plugin $($plugin.name) with a project-local junction."
}
