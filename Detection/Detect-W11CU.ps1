<#
.SYNOPSIS
MECM Detection Method (Script, PowerShell) fuer "Windows 11 Cumulative Update".

.DESCRIPTION
Installiert  = STDOUT-Ausgabe + Exit 0
Nicht inst.  = keine Ausgabe + Exit 0

Geprueft wird der aktive Patchstand (CurrentBuildNumber + UBR). Die UBR aendert sich erst nach dem Neustart.
Bei Exit 3010 wertet MECM die Detection nach dem Neustart erneut aus.

Monatliche Pflege: $Targets auf die UBR des Ziel-LCU setzen (Release-Notes / "Windows 11 update history"),
z.B. per Tools\Set-CMCUDetection.ps1.

Builds, die nicht in $Targets stehen, gelten als "installiert" (fail-safe: keine ungewollte Installation).
Steuerung, welche Builds behandelt werden, erfolgt ueber die Zielsammlung.
#>

# CurrentBuildNumber = minimale UBR   ### TARGETS-BEGIN ###
$Targets = @{
    26100 = 0   # Windows 11 24H2  -> UBR eintragen
    26200 = 0   # Windows 11 25H2  -> UBR eintragen
}
# ### TARGETS-END ###

$cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
if (-not $cv) { return }

$build = [int]$cv.CurrentBuildNumber
$ubr   = [int]$cv.UBR

if (-not $Targets.ContainsKey($build) -or $Targets[$build] -le 0)
{
    Write-Output "Not targeted: $build.$ubr"
    return
}

if ($ubr -ge $Targets[$build])
{
    Write-Output "Installed: $build.$ubr"
}
