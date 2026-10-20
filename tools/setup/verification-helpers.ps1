# Shared by the verifier and its regression checks. No machine changes here.
function Invoke-VaultNative {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [System.Text.Encoding]$OutputEncoding
    )
    $savedPreference = $ErrorActionPreference
    $savedOutputEncoding = [Console]::OutputEncoding
    try {
        # PowerShell 5.1 decodes native stdout using the console code page.
        if ($null -ne $OutputEncoding) { [Console]::OutputEncoding = $OutputEncoding }
        # java -version writes to stderr even on success in Windows PowerShell.
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $output = (& $FilePath @Arguments 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
        $nativeExit = $LASTEXITCODE
        if ($nativeExit -ne 0) { throw "$FilePath exited $nativeExit. $($output.Trim())" }
        if ([string]::IsNullOrWhiteSpace($output)) { throw "$FilePath returned no output." }
        return $output.Trim()
    } finally {
        $ErrorActionPreference = $savedPreference
        if ($null -ne $OutputEncoding) { [Console]::OutputEncoding = $savedOutputEncoding }
    }
}

function Assert-VaultDoctorPlatforms {
    param([string]$Doctor)
    foreach ($component in @('Android toolchain','Visual Studio - develop Windows apps')) {
        $header = '^\[[^\]]+\]\s+' + [regex]::Escape($component) + '(?:\s|$)'
        $line = ($Doctor -split '\r?\n' | Where-Object { $_ -match $header } | Select-Object -First 1)
        # ASCII source escapes remain safe if the script is saved without a BOM.
        if (-not $line -or $line -notmatch '^\[[\u2713\u221A]\]') {
            throw "Unhealthy or absent component: $component. $line"
        }
    }
    return 'Android and Windows checks healthy.'
}

function Test-VaultProbeResult {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [array]) {
        if ($Value.Count -eq 0) { return $false }
        foreach ($item in $Value) { if (-not (Test-VaultProbeResult $item)) { return $false } }
        return $true
    }
    return -not [string]::IsNullOrWhiteSpace([string]$Value)
}

function Assert-VaultPath {
    param([string]$Path, [ValidateSet('Leaf','Container')][string]$PathType = 'Leaf')
    if (-not (Test-Path -LiteralPath $Path -PathType $PathType)) { throw "Missing $PathType`: $Path" }
    return $Path
}
