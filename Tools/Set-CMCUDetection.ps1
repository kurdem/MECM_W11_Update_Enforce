<#
.SYNOPSIS
Setzt die Ziel-UBRs in der Detection Method des MECM Deployment Types.

.DESCRIPTION
Liest Detection\Detect-W11CU.ps1, ersetzt den Block zwischen TARGETS-BEGIN/END und schreibt das
Ergebnis per Set-CMScriptDeploymentType in den Deployment Type. Content muss nicht neu verteilt werden.

ACHTUNG: Bestehende Required-Deployments mit abgelaufener Deadline greifen nach der Aenderung sofort.
Fuer den gestaffelten Monats-Rollout Tools\Start-CMCURollout.ps1 verwenden.

.EXAMPLE
.\Set-CMCUDetection.ps1 -SiteCode P01 -ProviderMachineName cm01.contoso.local -Targets @{ 26100 = 7171; 26200 = 7171 }
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param
(
    [Parameter(Mandatory = $true)][string]$SiteCode,
    [Parameter(Mandatory = $true)][string]$ProviderMachineName,
    [string]$ApplicationName = 'Windows 11 Cumulative Update',
    [string]$DeploymentTypeName = 'PSADT',
    [Parameter(Mandatory = $true)][hashtable]$Targets
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CMCU.Common.ps1')

$script = Get-CUDetectionScriptText -Targets $Targets
$origLocation = Get-Location
Connect-CMCUSite -SiteCode $SiteCode -ProviderMachineName $ProviderMachineName
try
{
    if ($PSCmdlet.ShouldProcess("$ApplicationName / $DeploymentTypeName", 'Detection Script aktualisieren'))
    {
        Set-CMScriptDeploymentType -ApplicationName $ApplicationName -DeploymentTypeName $DeploymentTypeName `
            -ScriptLanguage PowerShell -ScriptText $script
        Write-Host "Detection aktualisiert: $(($Targets.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key).$($_.Value)" }) -join ', ')"
    }
}
finally
{
    Set-Location -Path $origLocation
}
