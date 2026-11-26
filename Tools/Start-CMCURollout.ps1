<#
.SYNOPSIS
Monatlicher Rollout: Deployments entfernen, Detection auf neue UBR setzen, Ring-Deployments neu anlegen.

.DESCRIPTION
Warum die Deployments neu angelegt werden: Ein Required-Deployment, dessen Deadline abgelaufen ist,
wird nach einer Detection-Aenderung sofort erzwungen. Ohne Neuanlage wuerden alle Ringe gleichzeitig
installieren. Daher: (1) alle Deployments der Application entfernen, (2) Detection setzen,
(3) Deployments mit neuen Terminen je Ring anlegen.

Termine relativ zum Patchday (zweiter Dienstag des Monats, ueberschreibbar mit -PatchDay).

.EXAMPLE
.\Start-CMCURollout.ps1 -SiteCode P01 -ProviderMachineName cm01.contoso.local `
    -Targets @{ 26100 = 7171; 26200 = 7171 } -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param
(
    [Parameter(Mandatory = $true)][string]$SiteCode,
    [Parameter(Mandatory = $true)][string]$ProviderMachineName,
    [Parameter(Mandatory = $true)][hashtable]$Targets,

    [string]$ApplicationName = 'Windows 11 Cumulative Update',
    [string]$DeploymentTypeName = 'PSADT',
    [string]$CollectionPrefix = 'W11-CU',

    # Standard: zweiter Dienstag des aktuellen Monats
    [datetime]$PatchDay,

    # Uhrzeit fuer Verfuegbarkeit/Deadline (lokale Clientzeit)
    [timespan]$AvailableTime = '08:00',
    [timespan]$DeadlineTime = '12:00'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CMCU.Common.ps1')

if (-not $PatchDay) { $PatchDay = Get-PatchTuesday }
$PatchDay = $PatchDay.Date

# Ringplan: Tage relativ zum Patchday. Wartungsfenster: $true = Installation/Neustart ausserhalb erlaubt.
$rings = @(
    @{ Collection = "$CollectionPrefix | Ring 0 - IT";       Available = 1;  Deadline = 1;  OutsideMW = $true }
    @{ Collection = "$CollectionPrefix | Ring 1 - Pilot";    Available = 2;  Deadline = 4;  OutsideMW = $true }
    @{ Collection = "$CollectionPrefix | Ring 2 - Breit";    Available = 7;  Deadline = 10; OutsideMW = $true }
    @{ Collection = "$CollectionPrefix | Ring 3 - Kritisch"; Available = 10; Deadline = 10; OutsideMW = $false }
)

$detectionScript = Get-CUDetectionScriptText -Targets $Targets
$targetText = ($Targets.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key).$($_.Value)" }) -join ', '

$origLocation = Get-Location
Connect-CMCUSite -SiteCode $SiteCode -ProviderMachineName $ProviderMachineName

try
{
    if (-not (Get-CMApplication -Name $ApplicationName -Fast)) { throw "Application [$ApplicationName] nicht gefunden." }
    foreach ($r in $rings)
    {
        if (-not (Get-CMDeviceCollection -Name $r.Collection)) { throw "Sammlung [$($r.Collection)] nicht gefunden." }
    }

    Write-Host "Patchday: $($PatchDay.ToString('yyyy-MM-dd')) | Ziel: $targetText"

    # 1. Bestehende Deployments entfernen
    $existing = @(Get-CMApplicationDeployment -Name $ApplicationName)
    foreach ($d in $existing)
    {
        if ($PSCmdlet.ShouldProcess("$ApplicationName -> $($d.CollectionName)", 'Deployment entfernen'))
        {
            Remove-CMApplicationDeployment -InputObject $d -Force
            Write-Host "Deployment entfernt: $($d.CollectionName)"
        }
    }

    # 2. Detection setzen
    if ($PSCmdlet.ShouldProcess("$ApplicationName / $DeploymentTypeName", "Detection auf $targetText setzen"))
    {
        Set-CMScriptDeploymentType -ApplicationName $ApplicationName -DeploymentTypeName $DeploymentTypeName `
            -ScriptLanguage PowerShell -ScriptText $detectionScript
        Write-Host "Detection gesetzt: $targetText"
    }

    # 3. Ring-Deployments anlegen
    foreach ($r in $rings)
    {
        $avail = $PatchDay.AddDays($r.Available).Add($AvailableTime)
        $deadline = $PatchDay.AddDays($r.Deadline).Add($DeadlineTime)
        if ($deadline -lt $avail) { $deadline = $avail }

        if ($PSCmdlet.ShouldProcess($r.Collection, "Deployment anlegen (verfuegbar $avail, Deadline $deadline)"))
        {
            New-CMApplicationDeployment -Name $ApplicationName -CollectionName $r.Collection `
                -DeployAction Install -DeployPurpose Required `
                -AvailableDateTime $avail -DeadlineDateTime $deadline -TimeBaseOn LocalTime `
                -UserNotification DisplayAll `
                -OverrideServiceWindow $r.OutsideMW -RebootOutsideServiceWindow $r.OutsideMW `
                -Comment "LCU-Ziel $targetText (Patchday $($PatchDay.ToString('yyyy-MM-dd')))" | Out-Null
            Write-Host ("Deployment: {0,-28} verfuegbar {1:yyyy-MM-dd HH:mm}  Deadline {2:yyyy-MM-dd HH:mm}  ausserhalb WF: {3}" -f `
                    $r.Collection, $avail, $deadline, $r.OutsideMW)
        }
    }
}
finally
{
    Set-Location -Path $origLocation
}
