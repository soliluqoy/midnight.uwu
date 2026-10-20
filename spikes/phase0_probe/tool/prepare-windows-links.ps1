# Project-local fallback when the current Windows token cannot create symlinks.
# Junctions reference the resolved plugin directories, including a declared local
# override. Never modify machine policy. Run after pub get, before --no-pub.
$ErrorActionPreference = 'Stop'
$probeRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$metadata = Get-Content -Raw -LiteralPath (Join-Path $probeRoot '.flutter-plugins-dependencies') | ConvertFrom-Json
$linkRoot = [IO.Path]::GetFullPath((Join-Path $probeRoot 'windows\flutter\ephemeral\.plugin_symlinks'))
if (-not $linkRoot.StartsWith($probeRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Plugin link destination escaped the probe project.'
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
        # Nonrecursive removal of the verified link itself, never its target.
        [IO.Directory]::Delete($link)
    }
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    Write-Host "Linked installed plugin $($plugin.name) with a project-local junction."
}
