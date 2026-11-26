<#
.SYNOPSIS
Setzt die Ziel-UBRs in der Detection Method des MECM Deployment Types (monatliche Pflege).

.DESCRIPTION
Liest Detection\Detect-W11CU.ps1, ersetzt den Block zwischen TARGETS-BEGIN/END und schreibt das
Ergebnis per Set-CMScriptDeploymentType in den Deployment Type. Content muss nicht neu verteilt werden.
Auf einem System mit installierter MECM-Konsole ausfuehren.

.EXAMPLE
.\Set-CMCUDetection.ps1 -SiteCode P01 -ProviderMachineName cm01.contoso.local `
    -ApplicationName 'Windows 11 Cumulative Update' -DeploymentTypeName 'PSADT' `
    -Targets @{ 26100 = 7171; 26200 = 7171 }
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param
(
    [Parameter(Mandatory = $true)][string]$SiteCode,
    [Parameter(Mandatory = $true)][string]$ProviderMachineName,
    [Parameter(Mandatory = $true)][string]$ApplicationName,
    [Parameter(Mandatory = $true)][string]$DeploymentTypeName,
    [Parameter(Mandatory = $true)][hashtable]$Targets
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$template = Get-Content -LiteralPath (Join-Path $repoRoot 'Detection\Detect-W11CU.ps1') -Raw

$lines = foreach ($k in ($Targets.Keys | Sort-Object)) { "    $k = $([int]$Targets[$k])" }
$block = "### TARGETS-BEGIN ###`r`n`$Targets = @{`r`n$($lines -join "`r`n")`r`n}`r`n# ### TARGETS-END ###"
$script = [regex]::Replace($template, '### TARGETS-BEGIN ###[\s\S]*?# ### TARGETS-END ###', $block.Replace('$', '$$'))

if (-not (Get-Module -Name ConfigurationManager))
{
    Import-Module -Name (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1')
}
if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue))
{
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName | Out-Null
}

Push-Location -Path "$($SiteCode):\"
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
    Pop-Location
}
