# Reproducible spike-only copy. Never edit the shared Pub cache.
$ErrorActionPreference = 'Stop'
$probeRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$cacheRoot = if ($env:PUB_CACHE) { $env:PUB_CACHE } else { Join-Path $env:LOCALAPPDATA 'Pub\Cache' }
$version = '1.6.2+hotfix.4'
$packageHash = 'ebf5ceef2897caae425ed65a38b2961c29d9d9a626159418ed460e1a65038c00'
$originalHash = '3BF14B9CFB83192BB554E6BA6A560B7ED7840DD686FE7446A898ABA955EB1115'
$source = Join-Path $cacheRoot "hosted\pub.dev\flutter_webrtc-$version"
$hashPath = Join-Path $cacheRoot "hosted-hashes\pub.dev\flutter_webrtc-$version.sha256"
$relativeJava = 'android\src\main\java\com\cloudwebrtc\webrtc\MethodCallHandlerImpl.java'
if (-not (Test-Path -LiteralPath $hashPath)) {
    throw "Cache the pinned source first: dart pub cache add flutter_webrtc --version $version"
}
if ((Get-Content -Raw -LiteralPath $hashPath).Trim() -ne $packageHash) { throw 'Unexpected hosted package checksum.' }
$sourceJava = Join-Path $source $relativeJava
if ((Get-FileHash -LiteralPath $sourceJava -Algorithm SHA256).Hash -ne $originalHash) { throw 'Upstream Java source has changed; refusing patch.' }
$text = [IO.File]::ReadAllText($sourceJava)
$replacements = @(
    @('boolean enableWARP, boolean zeroPlayoutDelay) {', 'boolean enableWARP, boolean zeroPlayoutDelay, boolean disableNetworkMonitor) {'),
    @('options.networkIgnoreMask = networkIgnoreMask;', "options.networkIgnoreMask = networkIgnoreMask;`n    options.disableNetworkMonitor = disableNetworkMonitor;"),
    @('audioOutputSampleRate, enableWARP, zeroPlayoutDelay);', 'audioOutputSampleRate, enableWARP, zeroPlayoutDelay, constraintsMap.hasKey("disableNetworkMonitor") && constraintsMap.getBoolean("disableNetworkMonitor"));')
)
foreach ($replacement in $replacements) {
    if ([regex]::Matches($text, [regex]::Escape($replacement[0])).Count -ne 1) { throw 'Patch context must match exactly once.' }
    $text = $text.Replace($replacement[0], $replacement[1])
}
$target = Join-Path $probeRoot '.plugin_overrides\flutter_webrtc'
$targetJava = Join-Path $target $relativeJava
if (-not (Test-Path -LiteralPath $target)) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Recurse
    [IO.File]::WriteAllText($targetJava, $text, [Text.UTF8Encoding]::new($false))
} elseif (-not (Test-Path -LiteralPath $targetJava) -or [IO.File]::ReadAllText($targetJava) -cne $text) {
    throw 'Existing local override differs; refusing to overwrite it.'
}
[ordered]@{
    upstreamVersion=$version; hostedArchiveSha256=$packageHash
    upstreamJavaSha256=$originalHash
    patchedJavaSha256=(Get-FileHash -LiteralPath $targetJava -Algorithm SHA256).Hash
    option='disableNetworkMonitor; default false; Android factory initialization only'
    scope='Experimental hotspot probe; connectivity-change recovery remains unverified'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target 'vault-patch.json') -Encoding UTF8
Write-Host 'Prepared project-local WebRTC hotspot option; upstream cache unchanged.'
