<#
.SYNOPSIS
  Build an isolated empty Flutter app; does not create Vault feature code.
#>
[CmdletBinding()]
param(
    [string]$SmokeRoot = 'C:\dev\vault-toolchain-smoke',
    [string]$JsonOutput
)
$ErrorActionPreference = 'Stop'
if (-not $JsonOutput) { $JsonOutput = Join-Path $PSScriptRoot '..\..\docs\ops\build-verification.json' }
. "$PSScriptRoot\verification-helpers.ps1"
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User') + ';' + $env:Path
$regJava = [Environment]::GetEnvironmentVariable('JAVA_HOME','User')
if ($regJava) { $env:JAVA_HOME = $regJava }
if (Test-Path -LiteralPath $SmokeRoot) {
    $spec = Get-Content -LiteralPath "$SmokeRoot\pubspec.yaml" -Raw
    if ($spec -notmatch '(?m)^name: vault_toolchain_smoke\s*$') {
        throw 'SmokeRoot contains another project. Choose a fresh directory.'
    }
} else {
    Invoke-VaultNative flutter @('create','--empty','--platforms=android,windows','--project-name','vault_toolchain_smoke',$SmokeRoot) | Write-Host
}
Push-Location $SmokeRoot
$results = [Collections.Generic.List[object]]::new()
try {
    foreach ($buildArgs in @(@('analyze','--fatal-infos'), @('build','windows','--debug'), @('build','apk','--debug'))) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $passed = $false
        $output = ''
        try {
            $output = Invoke-VaultNative flutter $buildArgs
            Write-Host $output
            $passed = $true
        } catch {
            $output = $_.Exception.Message
            throw
        } finally {
            $watch.Stop()
            $results.Add([pscustomobject]@{
                command = "flutter $($buildArgs -join ' ')"
                passed = $passed
                seconds = [math]::Round($watch.Elapsed.TotalSeconds,1)
                output = $output
            })
        }
        Write-Host "Completed flutter $($buildArgs -join ' ') in $([math]::Round($watch.Elapsed.TotalSeconds,1)) s."
    }
} finally {
    Pop-Location
    [pscustomobject]@{
        checkedAt = (Get-Date).ToString('o')
        scope = 'Empty Flutter template only; no WebRTC/player plugins or Vault feature code.'
        project = $SmokeRoot
        checks = $results.ToArray()
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $JsonOutput -Encoding UTF8
}
Write-Host "Smoke artifacts: $SmokeRoot\build (empty template only; no plugin feasibility claim)."
