[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Device,
    [Parameter(Mandatory=$true)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$adb = 'C:\dev\android-sdk\platform-tools\adb.exe'
$base = 'http://127.0.0.1:48932'
$headers = @{'x-vault-probe'='phase0-local'}
$result = [ordered]@{
    checkedAt=(Get-Date).ToString('o')
    scope='Short USB-powered active dataSync FGS with Home foreground; not Doze, timeout, process-death or indefinite publishing proof'
}
try {
    & $adb -s $Device shell am start -W -n dev.vault.spike.vault_phase0_probe/.MainActivity | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not foreground the probe.' }
    $result.before = Invoke-RestMethod -Uri ($base+'/lifecycle') -Headers $headers -TimeoutSec 10
    Invoke-RestMethod -Method Post -Uri ($base+'/lifecycle/start') -Headers $headers -ContentType application/json -Body '{}' -TimeoutSec 10 | Out-Null
    Start-Sleep -Seconds 1
    & $adb -s $Device shell am start -a android.intent.action.MAIN -c android.intent.category.HOME | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not background the probe.' }
    Start-Sleep -Seconds 10
    $result.background = Invoke-RestMethod -Uri ($base+'/lifecycle') -Headers $headers -TimeoutSec 10
    $transferPath = Join-Path (Split-Path -Parent $OutputPath) 'android-background-pion.json'
    & "$PSScriptRoot\run-interop.ps1" -Initiator $base -Bytes 8388608 -OutputPath $transferPath | Out-Null
    $result.transfer = Get-Content -Raw -LiteralPath $transferPath | ConvertFrom-Json
    $result.passed = $result.background.transferServiceRunning -and $result.transfer.passed
    if (-not $result.passed) { throw 'Background foreground-service/transfer check failed.' }
} catch {
    $result.passed = $false
    $result.error = $_.Exception.Message
    throw
} finally {
    try {
        Invoke-RestMethod -Method Post -Uri ($base+'/lifecycle/stop') -Headers $headers -ContentType application/json -Body '{}' -TimeoutSec 10 | Out-Null
        $result.cleanupStopRequested = $true
        Start-Sleep -Seconds 1
        $result.after = Invoke-RestMethod -Uri ($base+'/lifecycle') -Headers $headers -TimeoutSec 10
        $result.cleanupStopped = -not $result.after.transferServiceRunning
        if (-not $result.cleanupStopped) { $result.passed = $false }
    } catch { $result.cleanupStopRequested = $false; $result.passed = $false }
    & $adb -s $Device shell am start -n dev.vault.spike.vault_phase0_probe/.MainActivity | Out-Null
    $result | ConvertTo-Json -Depth 15 | Set-Content -Encoding UTF8 -LiteralPath $OutputPath
}
if (-not $result.passed) { throw 'Background probe or service cleanup failed; see result JSON.' }
$result | ConvertTo-Json -Depth 15
