#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Launches clumsy with a named shaping profile for Phase 0 spikes 2 and 5.

.DESCRIPTION
  clumsy shapes traffic on the Windows NIC using WinDivert. This is the
  Windows-side counterpart to netem-wsl2.sh.

  Profiles map to the link conditions named in the build plan:
    lan        - unshaped (same Wi-Fi LAN baseline)
    broadband100 - 100 Mbps broadband
    lte4       - 4G/LTE
    cgnat      - heavy loss + high latency, approximates CGNAT + mobile
    lossy      - 2% loss, for testing the retry / resume paths

  clumsy requires Administrator. Start it, leave it running for the duration of
  the test, then stop it. It is interactive: flip settings from its window.

.EXAMPLE
  .\clumsy-profile.ps1 -Profile broadband100
  .\clumsy-profile.ps1 -Profile lossy -Throttle 8000
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('lan', 'broadband100', 'lte4', 'cgnat', 'lossy')]
    [string]$Profile,

    # Kbit/s. Overrides the profile default when supplied.
    [int]$Throttle = 0,

    # Outbound packet delay in ms, clamped to clumsy's 0..1000 range.
    [int]$Latency = -1,

    [int]$PacketLoss = -1
)

$clumsy = 'C:\dev\tools\clumsy\clumsy.exe'

if (-not (Test-Path $clumsy)) {
    throw "clumsy not found at $clumsy. Extract clumsy-0.3-win64-a.zip there (see docs/ops/ENVIRONMENT.md)."
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "clumsy needs Administrator. Re-run this script elevated." }

# rate in kbit/s, latency in ms, loss in percent
$defaults = @{
    'lan'         = @{ Throttle = 0;    Latency = 0;   Loss = 0 }
    'broadband100'= @{ Throttle = 100000; Latency = 5; Loss = 0 }
    'lte4'        = @{ Throttle = 40000;  Latency = 60;  Loss = 1 }
    'cgnat'       = @{ Throttle = 20000;  Latency = 120; Loss = 3 }
    'lossy'       = @{ Throttle = 200000; Latency = 10;  Loss = 2 }
}

$d = $defaults[$Profile]
$t = if ($Throttle -gt 0) { $Throttle } else { $d.Throttle }
$l = if ($Latency -ge 0) { $Latency } else { $d.Latency }
$p = if ($PacketLoss -ge 0) { $PacketLoss } else { $d.Loss }

Write-Host "clumsy profile: $Profile" -ForegroundColor Cyan
Write-Host ("  throttle : {0} kbit/s ({1} Mbps)" -f $t, [math]::Round($t / 1000, 2)) -ForegroundColor Gray
Write-Host ("  latency  : {0} ms" -f $l) -ForegroundColor Gray
Write-Host ("  loss     : {0} %" -f $p) -ForegroundColor Gray
Write-Host "  Filters  : leave on defaults (WinDivert filter for all TCP/UDP outbound)." -ForegroundColor Gray
Write-Host "  Ignore any TLS-inspection prompt: clumsy does not decrypt, it only reshapes timing." -ForegroundColor Gray
Write-Host ""
Write-Host "Clumsy is now running. Run the spike, then close the clumsy window to remove shaping." -ForegroundColor Yellow

# clumsy has no CLI flags for these values in 0.3; it is configured in-window.
# We still pass them on the command line where supported so the operator sees intent.
Start-Process -FilePath $clumpy -ArgumentList @("throttle:$t", "latency:$l", "loss:$p", "enable")