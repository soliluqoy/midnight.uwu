[CmdletBinding()]
param(
    [string]$Initiator = 'http://127.0.0.1:48931',
    [string]$Responder = 'http://127.0.0.1:48933',
    [int]$Bytes = 33554432,
    [Parameter(Mandatory=$true)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
foreach ($endpoint in @($Initiator,$Responder)) {
    $uri = [Uri]$endpoint
    if (-not $uri.IsLoopback -or $uri.Scheme -ne 'http') { throw 'Only local/USB-forwarded test APIs are allowed.' }
}
function Invoke-Probe([string]$Endpoint,[string]$Path,$Body) {
    Invoke-RestMethod -Uri ($Endpoint + $Path) -Method Post `
        -Headers @{'x-vault-probe'='phase0-local'} -ContentType application/json `
        -Body ($Body | ConvertTo-Json -Depth 6 -Compress) -TimeoutSec 180
}
$record = [ordered]@{checkedAt=(Get-Date).ToString('o'); scope='Synthetic direct WebRTC interop; not production authentication or media delivery'; bytesPerDirection=$Bytes}
try {
    $record.participants = @()
    foreach ($endpoint in @($Initiator,$Responder)) {
        $state = Invoke-RestMethod -Uri ($endpoint+'/status') -Headers @{'x-vault-probe'='phase0-local'} -TimeoutSec 10
        $record.participants += @{endpoint=$endpoint;platform=$state.platform;androidNetworkMonitorDisabled=$state.androidNetworkMonitorDisabled}
    }
    Write-Host 'Gathering direct-only offer and answer over local control...'
    $offer = Invoke-Probe $Initiator '/rtc/offer' @{}
    $answer = Invoke-Probe $Responder '/rtc/answer' $offer
    Invoke-Probe $Initiator '/rtc/accept' $answer | Out-Null
    Write-Host "Sending $Bytes synthetic bytes from initiator..."
    $record.forward = Invoke-Probe $Initiator '/rtc/transfer' @{bytes=$Bytes}
    Write-Host "Sending $Bytes synthetic bytes from responder..."
    $record.reverse = Invoke-Probe $Responder '/rtc/transfer' @{bytes=$Bytes}
    $record.passed = $record.forward.passed -and $record.reverse.passed -and
        $record.forward.path.verified -and $record.reverse.path.verified -and
        $record.forward.sha256 -eq $record.reverse.sha256
    if (-not $record.passed) { throw 'Transfer/path verification was incomplete.' }
} catch {
    $record.passed = $false
    $record.error = $_.Exception.Message
    if ($_.ErrorDetails.Message) { $record.responseError = $_.ErrorDetails.Message }
    $record.peerStates = @()
    foreach ($endpoint in @($Initiator,$Responder)) {
        try {
            $state = Invoke-RestMethod -Uri ($endpoint+'/status') -Headers @{'x-vault-probe'='phase0-local'} -TimeoutSec 5
            $record.peerStates += @{endpoint=$endpoint;state=$state}
        } catch { Write-Warning 'Could not collect failed peer status.' }
    }
    throw
} finally {
    foreach ($endpoint in @($Initiator,$Responder)) {
        try { Invoke-Probe $endpoint '/rtc/reset' @{} | Out-Null } catch { Write-Warning 'Test peer reset failed.' }
    }
    $record | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath $OutputPath
}
$record | ConvertTo-Json -Depth 12
