<#
.SYNOPSIS
Legt die MECM-Application "Windows 11 Cumulative Update" inkl. Deployment Type, Return Codes,
Requirements, Content-Verteilung und Ring-Sammlungen an. Deployments werden NICHT angelegt
(dafuer monatlich Tools\Start-CMCURollout.ps1).

.DESCRIPTION
Voraussetzungen:
  - MECM-Konsole installiert, ConfigMgr 2107 oder neuer (Add-CMDeploymentTypeReturnCode)
  - Content bereits mit Tools\New-CUPackage.ps1 erzeugt (UNC-Pfad)
  - Konsolensprache Englisch (Namen der Global Conditions "Operating System" / "Disk space")

Idempotent: vorhandene Objekte (Application, Deployment Type, Sammlungen) werden uebersprungen.

Angelegte Sammlungen (Begrenzung: -LimitingCollectionName):
  <Prefix> | Basis           Query: Workstations mit Build 10.0.26100 / 10.0.26200
  <Prefix> | Ring 0 - IT      leer, Mitglieder manuell (Direct/Include), begrenzt auf Basis
  <Prefix> | Ring 1 - Pilot   leer, Mitglieder manuell, begrenzt auf Basis
  <Prefix> | Ring 3 - Kritisch leer, Mitglieder manuell, begrenzt auf Basis
  <Prefix> | Ring 2 - Breit   Include Basis, Exclude Ring 0/1/3

.EXAMPLE
.\New-CMCUApplication.ps1 -SiteCode P01 -ProviderMachineName cm01.contoso.local `
    -ContentLocation '\\cm01\Sources$\Apps\Microsoft\W11-CU' -DistributionPointGroupName 'Alle DPs' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param
(
    [Parameter(Mandatory = $true)][string]$SiteCode,
    [Parameter(Mandatory = $true)][string]$ProviderMachineName,
    [Parameter(Mandatory = $true)][string]$ContentLocation,

    [string]$ApplicationName = 'Windows 11 Cumulative Update',
    [string]$DeploymentTypeName = 'PSADT',
    [string]$Publisher = 'Microsoft',

    # Optional: Ziel-UBRs direkt setzen, sonst Platzhalter (= ueberall "installiert", kein Effekt)
    [hashtable]$Targets,

    # Requirement Betriebssystem (Anzeigename der Plattform in MECM)
    [string]$PlatformName = 'All Windows 11 (64-bit)',
    [int]$MinFreeDiskSpaceMB = 15360,

    # Verteilung: Gruppe und/oder einzelne DPs
    [string]$DistributionPointGroupName,
    [string[]]$DistributionPointName,

    # Sammlungen
    [switch]$SkipCollections,
    [string]$CollectionPrefix = 'W11-CU',
    [string]$LimitingCollectionName = 'All Desktop and Server Clients',
    [string[]]$Builds = @('10.0.26100', '10.0.26200')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CMCU.Common.ps1')

if (-not (Test-Path -LiteralPath (Join-Path $ContentLocation 'Invoke-AppDeployToolkit.exe')))
{
    throw "Invoke-AppDeployToolkit.exe nicht gefunden unter [$ContentLocation]. Erst Tools\New-CUPackage.ps1 ausfuehren."
}

$detectionScript = Get-CUDetectionScriptText -Targets $Targets
$origLocation = Get-Location
Connect-CMCUSite -SiteCode $SiteCode -ProviderMachineName $ProviderMachineName

try
{
    #region Application
    $app = Get-CMApplication -Name $ApplicationName -Fast
    if ($app)
    {
        Write-Host "Application existiert bereits: $ApplicationName"
    }
    elseif ($PSCmdlet.ShouldProcess($ApplicationName, 'Application anlegen'))
    {
        $app = New-CMApplication -Name $ApplicationName -Publisher $Publisher -SoftwareVersion 'Evergreen' `
            -Description 'Installiert das aktuelle kumulative Windows 11 Update ueber PSADT + PSWindowsUpdate (Quelle: Windows Update).' `
            -AutoInstall $true
        Write-Host "Application angelegt: $ApplicationName"
    }
    #endregion

    #region Requirements
    $requirements = @()

    $osGC = Get-CMGlobalCondition -Name 'Operating System' | Where-Object PlatformType -EQ 1
    $platform = Get-CMConfigurationPlatform -Fast | Where-Object LocalizedDisplayName -EQ $PlatformName
    if (-not $platform)
    {
        $hint = (Get-CMConfigurationPlatform -Fast | Where-Object LocalizedDisplayName -Like '*Windows 11*' |
                Select-Object -ExpandProperty LocalizedDisplayName) -join "`n  "
        throw "Plattform [$PlatformName] nicht gefunden. Verfuegbar:`n  $hint"
    }
    $requirements += $osGC | New-CMRequirementRuleOperatingSystemValue -RuleOperator OneOf -Platform $platform

    $diskGC = Get-CMGlobalCondition -Name 'Disk space'
    $requirements += $diskGC | New-CMRequirementRuleFreeDiskSpaceValue -PartitionOption System `
        -RuleOperator GreaterEquals -Value1 $MinFreeDiskSpaceMB
    #endregion

    #region Deployment Type
    $dt = Get-CMDeploymentType -ApplicationName $ApplicationName -DeploymentTypeName $DeploymentTypeName -ErrorAction SilentlyContinue
    if ($dt)
    {
        Write-Host "Deployment Type existiert bereits: $DeploymentTypeName (keine Aenderung)"
    }
    elseif ($PSCmdlet.ShouldProcess($DeploymentTypeName, 'Deployment Type anlegen'))
    {
        $dtParams = @{
            ApplicationName          = $ApplicationName
            DeploymentTypeName       = $DeploymentTypeName
            ContentLocation          = $ContentLocation
            InstallCommand           = 'Invoke-AppDeployToolkit.exe -DeploymentType Install'
            RepairCommand            = 'Invoke-AppDeployToolkit.exe -DeploymentType Repair'
            ScriptLanguage           = 'PowerShell'
            ScriptText               = $detectionScript
            InstallationBehaviorType = 'InstallForSystem'
            LogonRequirementType     = 'WhetherOrNotUserLoggedOn'
            UserInteractionMode      = 'Normal'
            RequireUserInteraction   = $true
            RebootBehavior           = 'BasedOnExitCode'
            MaximumRuntimeMins       = 120
            EstimatedRuntimeMins     = 45
            ContentFallback          = $true
            SlowNetworkDeploymentMode = 'Download'
            AddRequirement           = $requirements
            Comment                  = 'PSADT 4.1 + PSWindowsUpdate. Detection: CurrentBuildNumber/UBR.'
        }
        Add-CMScriptDeploymentType @dtParams | Out-Null
        Write-Host "Deployment Type angelegt: $DeploymentTypeName"

        # Return Codes (Standard 0/1707/3010/1641/1618 legt MECM selbst an)
        $codes = @(
            @{ Code = 1602;  Type = 'Failure'; Name = 'Benutzer hat verschoben' }
            @{ Code = 69001; Type = 'Failure'; Name = 'Kein passendes LCU angeboten' }
            @{ Code = 69002; Type = 'Failure'; Name = 'Vorpruefung fehlgeschlagen (OS/Speicher/Akku/GPO)' }
            @{ Code = 69003; Type = 'Failure'; Name = 'Installation fehlgeschlagen' }
            @{ Code = 69004; Type = 'Failure'; Name = 'PSWindowsUpdate fehlt im Content' }
            @{ Code = 69005; Type = 'Failure'; Name = 'Scan/Download fehlgeschlagen (Proxy/Netzwerk)' }
            @{ Code = 69010; Type = 'Failure'; Name = 'Uninstall nicht unterstuetzt' }
            @{ Code = 60001; Type = 'Failure'; Name = 'PSADT: unbehandelter Fehler' }
            @{ Code = 60008; Type = 'Failure'; Name = 'PSADT: Modul/Session-Initialisierung fehlgeschlagen' }
        )
        foreach ($c in $codes)
        {
            # Je Code frisch laden, damit kein veraltetes Objekt vorherige Codes ueberschreibt.
            $dt = Get-CMDeploymentType -ApplicationName $ApplicationName -DeploymentTypeName $DeploymentTypeName
            $dt | Add-CMDeploymentTypeReturnCode -ReturnCode $c.Code -CodeType $c.Type -Name $c.Name | Out-Null
            Write-Host "  Return Code $($c.Code) ($($c.Type)) - $($c.Name)"
        }
    }
    #endregion

    #region Content-Verteilung
    if ($DistributionPointGroupName -or $DistributionPointName)
    {
        if ($PSCmdlet.ShouldProcess($ApplicationName, 'Content verteilen'))
        {
            $distParams = @{ ApplicationName = $ApplicationName }
            if ($DistributionPointGroupName) { $distParams.DistributionPointGroupName = $DistributionPointGroupName }
            if ($DistributionPointName) { $distParams.DistributionPointName = $DistributionPointName }
            try
            {
                Start-CMContentDistribution @distParams
                Write-Host 'Content-Verteilung gestartet.'
            }
            catch
            {
                Write-Warning "Content-Verteilung: $($_.Exception.Message) (bereits verteilt?)"
            }
        }
    }
    else
    {
        Write-Warning 'Kein DP / keine DP-Gruppe angegeben. Content manuell verteilen.'
    }
    #endregion

    #region Sammlungen
    if (-not $SkipCollections)
    {
        $schedule = New-CMSchedule -RecurInterval Days -RecurCount 1
        $names = @{
            Base  = "$CollectionPrefix | Basis"
            Ring0 = "$CollectionPrefix | Ring 0 - IT"
            Ring1 = "$CollectionPrefix | Ring 1 - Pilot"
            Ring2 = "$CollectionPrefix | Ring 2 - Breit"
            Ring3 = "$CollectionPrefix | Ring 3 - Kritisch"
        }

        function New-CUCollection
        {
            param ([string]$Name, [string]$Limiting, [string]$Comment)
            if (Get-CMDeviceCollection -Name $Name)
            {
                Write-Host "Sammlung existiert bereits: $Name"
                return $false
            }
            if (-not $PSCmdlet.ShouldProcess($Name, 'Sammlung anlegen')) { return $false }
            New-CMDeviceCollection -Name $Name -LimitingCollectionName $Limiting -Comment $Comment `
                -RefreshType Both -RefreshSchedule $schedule | Out-Null
            Write-Host "Sammlung angelegt: $Name"
            return $true
        }

        if (New-CUCollection -Name $names.Base -Limiting $LimitingCollectionName -Comment 'Windows 11 Clients mit gepflegtem Build')
        {
            $buildList = ($Builds | ForEach-Object { "'$_'" }) -join ','
            $query = "select SMS_R_System.ResourceId from SMS_R_System where " +
            "SMS_R_System.OperatingSystemNameandVersion like '%Workstation%' and SMS_R_System.Build01 in ($buildList)"
            Add-CMDeviceCollectionQueryMembershipRule -CollectionName $names.Base -RuleName 'W11 Builds' -QueryExpression $query
        }

        New-CUCollection -Name $names.Ring0 -Limiting $names.Base -Comment 'Mitglieder manuell pflegen' | Out-Null
        New-CUCollection -Name $names.Ring1 -Limiting $names.Base -Comment 'Mitglieder manuell pflegen (5-10 %)' | Out-Null
        New-CUCollection -Name $names.Ring3 -Limiting $names.Base -Comment 'Kritische Systeme, nur im Wartungsfenster' | Out-Null

        if (New-CUCollection -Name $names.Ring2 -Limiting $names.Base -Comment 'Alle ausser Ring 0/1/3')
        {
            Add-CMDeviceCollectionIncludeMembershipRule -CollectionName $names.Ring2 -IncludeCollectionName $names.Base
            foreach ($ex in @($names.Ring0, $names.Ring1, $names.Ring3))
            {
                Add-CMDeviceCollectionExcludeMembershipRule -CollectionName $names.Ring2 -ExcludeCollectionName $ex
            }
        }
    }
    #endregion

    Write-Host ''
    Write-Host 'Fertig. Naechste Schritte:'
    Write-Host '  1. Ring-Sammlungen 0/1/3 befuellen'
    Write-Host '  2. Monatlich: Tools\Start-CMCURollout.ps1 -Targets @{ 26100 = <UBR>; 26200 = <UBR> }'
}
finally
{
    Set-Location -Path $origLocation
}
