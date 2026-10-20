[CmdletBinding()]
param(
    [switch]$SkipAnalyze,
    [switch]$SkipFormat
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dartPackages = @('vault_identity', 'vault_protocol', 'vault_signaling', 'vault_directory', 'vault_media_index')
$flutterPackages = @('vault_net', 'vault_delivery', 'vault_player', 'vault_ui', 'vault')

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program $($Arguments -join ' ') failed (exit $LASTEXITCODE)."
    }
}

Push-Location $root
try {
    if (-not $SkipAnalyze) {
        Invoke-Checked 'dart' @('analyze', '--fatal-infos', '.')
    }
    if (-not $SkipFormat) {
        Invoke-Checked 'dart' @('format', '--output=none', '--set-exit-if-changed', 'apps/vault/lib', 'apps/vault/test', 'packages')
    }
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($package in @($dartPackages + $flutterPackages)) {
        $relative = if ($package -eq 'vault') { 'apps/vault' } else { "packages/$package" }
        $directory = Join-Path $root $relative
        if (-not (Test-Path (Join-Path $directory 'pubspec.yaml'))) {
            throw "Missing workspace package: $package"
        }
        $tests = @(Get-ChildItem (Join-Path $directory 'test') -Filter '*_test.dart' -Recurse -File -ErrorAction SilentlyContinue)
        if ($tests.Count -eq 0) {
            throw "Missing behavioral tests for $package."
        }
        Push-Location $directory
        try {
            if ($flutterPackages -contains $package) {
                Invoke-Checked 'flutter' @('test', '--no-pub')
            } else {
                Invoke-Checked 'dart' @('test')
            }
        } catch {
            $failures.Add("$package`: $($_.Exception.Message)")
            Write-Warning $failures[$failures.Count - 1]
        } finally {
            Pop-Location
        }
    }
    if ($failures.Count -gt 0) {
        throw "Core behavioral checks failed:`n$($failures -join [Environment]::NewLine)"
    }
} finally {
    Pop-Location
}
