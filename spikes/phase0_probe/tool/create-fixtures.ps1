[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User') + ';' + $env:Path
$probeRoot = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $probeRoot 'assets'
New-Item -ItemType Directory -Force -Path $assets | Out-Null
$tail = Join-Path $assets 'tail.mp4'
$front = Join-Path $assets 'front.mp4'
# Synthetic moving test pattern + stereo tone; never read a user's media.
& ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=1280x720:rate=30' `
    -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 12 `
    -c:v libx264 -preset veryfast -crf 28 -pix_fmt yuv420p -g 60 `
    -c:a aac -b:a 96k -ac 2 $tail
if ($LASTEXITCODE -ne 0) { throw 'Synthetic fixture encode failed.' }
& ffmpeg -hide_banner -loglevel error -y -i $tail -c copy -movflags +faststart $front
if ($LASTEXITCODE -ne 0) { throw 'Fast-start remux failed.' }
$fixtureInfo = foreach ($fixture in @($front,$tail)) {
    $probe = & ffprobe -v error -show_format -show_streams -of json $fixture
    if ($LASTEXITCODE -ne 0) { throw 'Fixture inspection failed.' }
    [pscustomobject]@{
        name = Split-Path -Leaf $fixture
        sha256 = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToLowerInvariant()
        bytes = (Get-Item -LiteralPath $fixture).Length
        media = ($probe -join "`n" | ConvertFrom-Json)
    }
}
[pscustomobject]@{
    generatedAt = (Get-Date).ToString('o')
    ffmpeg = ((& ffmpeg -version) | Select-Object -First 1)
    source = 'Locally generated testsrc2 and sine; no user content.'
    fixtures = @($fixtureInfo)
} | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $assets 'fixtures.json')
Write-Host 'Generated front/tail moov H.264/AAC fixtures and hashes.'
