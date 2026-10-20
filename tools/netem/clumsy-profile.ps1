<#
.SYNOPSIS
  Scoped clumsy 0.3 lag/drop validation. Real bandwidth caps use WSL tc.
.DESCRIPTION
  No profile claims to emulate NAT. Requires a specific peer IPv4, has a time
  limit, and touches traffic only when executed without -DryRun as Administrator.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [System.Net.IPAddress]$PeerAddress,
    [ValidateSet('lan','broadband','mobile','lossy')]
    [string]$Profile = 'lossy',
    [ValidateRange(-1,1000)][int]$LatencyMs = -1,
    [ValidateRange(-1,100)][double]$PacketLoss = -1,
    [ValidateRange(1,3600)][int]$DurationSeconds = 60,
    [string]$DevRoot = 'C:\dev',
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
if ($PeerAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'Supply the actual remote IPv4; this launcher intentionally scopes IPv4 only.'
}
$clumsy = Join-Path $DevRoot 'tools\clumsy\clumsy.exe'
if (-not (Test-Path -LiteralPath $clumsy)) { throw "Missing $clumsy" }
$profiles = @{
    lan = @{Delay=0;Loss=0}
    broadband = @{Delay=5;Loss=0}
    mobile = @{Delay=60;Loss=1}
    lossy = @{Delay=10;Loss=2}
}
$delay = if ($LatencyMs -ge 0) { $LatencyMs } else { $profiles[$Profile].Delay }
$loss = if ($PacketLoss -ge 0) { $PacketLoss } else { $profiles[$Profile].Loss }
$peer = $PeerAddress.ToString()
$filter = "udp and !loopback and ((outbound and ip.DstAddr == $peer) or (inbound and ip.SrcAddr == $peer))"
$cli = @('--filter', ('"' + $filter + '"'), '--timeout', "$DurationSeconds")
if ($delay -gt 0) { $cli += '--lag','on','--lag-time',"$delay",'--lag-inbound','on','--lag-outbound','on' }
if ($loss -gt 0) {
    $cli += '--drop','on','--drop-chance',($loss.ToString([Globalization.CultureInfo]::InvariantCulture)),
            '--drop-inbound','on','--drop-outbound','on'
}
Write-Host "clumsy $Profile for $peer for $DurationSeconds seconds."
Write-Host "Adds $delay ms per direction (about $($delay*2) ms RTT), drop $loss percent."
Write-Host 'No bandwidth cap or NAT emulation. Run the WSL harness through tc for bandwidth shaping.'
if ($DryRun) { Write-Output ($clumsy + ' ' + ($cli -join ' ')); exit 0 }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run elevated, or use -DryRun to inspect the command.' }
Start-Process -FilePath $clumsy -ArgumentList $cli -WindowStyle Hidden -PassThru
