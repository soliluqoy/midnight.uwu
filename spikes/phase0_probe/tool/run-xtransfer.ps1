[CmdletBinding()]
param(
    [string]$Sender = 'http://127.0.0.1:48931',
    [string]$Receiver = 'http://127.0.0.1:48932',
    [long]$Bytes = 2147483648,
    # Bytes sent before each cancelled attempt (0 or less skips); the final attempt runs to completion.
    [long[]]$CancelAfter = @(734003200 + 307200),
    # Reuse an id to resume a transfer the receiver already holds blocks for.
    [string]$Id = ('x' + [guid]::NewGuid().ToString('N').Substring(0, 12)),
    [Parameter(Mandatory=$true)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
foreach ($endpoint in @($Sender,$Receiver)) {
    $uri = [Uri]$endpoint
    if (-not $uri.IsLoopback -or $uri.Scheme -ne 'http') { throw 'Only local/USB-forwarded test APIs are allowed.' }
}
$headers = @{'x-vault-probe'='phase0-local'}
function Invoke-Probe([string]$Endpoint,[string]$Path,$Body) {
    Invoke-RestMethod -Uri ($Endpoint + $Path) -Method Post -Headers $headers `
        -ContentType application/json -Body ($Body | ConvertTo-Json -Depth 6 -Compress) -TimeoutSec 1800
}
$id = $Id
$record = [ordered]@{checkedAt=(Get-Date).ToString('o'); scope='Synthetic block-verified transfer with cancel and resume; not production protocol'; bytes=$Bytes; id=$id; attempts=@()}
try {
    foreach ($endpoint in @($Sender,$Receiver)) {
        $state = Invoke-RestMethod -Uri ($endpoint+'/status') -Headers $headers -TimeoutSec 10
        $record.participants += @(@{endpoint=$endpoint;platform=$state.platform})
    }
    $offer = Invoke-Probe $Sender '/rtc/offer' @{}
    $answer = Invoke-Probe $Receiver '/rtc/answer' $offer
    Invoke-Probe $Sender '/rtc/accept' $answer | Out-Null
    foreach ($stop in $CancelAfter | Where-Object { $_ -gt 0 }) {
        Write-Host "Attempt: cancel after $stop bytes"
        $record.attempts += Invoke-Probe $Sender '/rtc/xtransfer' @{id=$id;bytes=$Bytes;stopAfterBytes=$stop}
    }
    Write-Host 'Final attempt: resume and complete'
    $final = Invoke-Probe $Sender '/rtc/xtransfer' @{id=$id;bytes=$Bytes}
    $record.attempts += $final
    $record.receiver = (Invoke-RestMethod -Uri ($Receiver+'/status') -Headers $headers -TimeoutSec 10).rtc.xRecv
    $record.passed = [bool]($final.passed -and $final.path.verified)
} catch {
    $record.passed = $false
    $record.error = $_.Exception.Message
    if ($_.ErrorDetails.Message) { $record.responseError = $_.ErrorDetails.Message }
    throw
} finally {
    foreach ($endpoint in @($Sender,$Receiver)) {
        try { Invoke-Probe $endpoint '/rtc/reset' @{} | Out-Null } catch { Write-Warning 'Test peer reset failed.' }
    }
    $record | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath $OutputPath
}
$record | ConvertTo-Json -Depth 12
