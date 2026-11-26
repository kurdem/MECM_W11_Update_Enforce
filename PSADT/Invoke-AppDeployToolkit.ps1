<#

.SYNOPSIS
PSAppDeployToolkit (4.1.x) - Installiert das aktuelle kumulative Windows 11 Update (LCU) ueber das Modul PSWindowsUpdate.

.DESCRIPTION
"Evergreen"-Ansatz: Der Paketinhalt bleibt monatlich gleich. Das Skript sucht ueber die Windows Update Agent API
(PSWindowsUpdate) nach dem aktuell angebotenen kumulativen Update fuer Windows 11 und installiert es.
Welcher Patchstand als "installiert" gilt, steuert ausschliesslich die MECM Detection Method (Detection\Detect-W11CU.ps1).

Ablauf Install:
  1. Vorpruefungen (Windows 11, freier Speicher, Netzbetrieb)
  2. Ausstehender Neustart -> Exit 3010 (MECM fuehrt Neustart durch, Detection laeuft danach erneut)
  3. Optional: Hinweis/Deferral fuer den Benutzer
  4. PSWindowsUpdate aus SupportFiles laden
  5. Scan -> Filter auf LCU -> Download + Installation (ohne Neustart)
  6. Exit 3010, wenn Neustart erforderlich (Standardfall bei LCU)

Exit Codes (in MECM unter "Return Codes" pflegen):
  0      Erfolg, kein Neustart
  3010   Erfolg, Neustart erforderlich (Soft Reboot)
  1602   Benutzer hat verschoben (Retry)           -> config.psd1 UI.DeferExitCode
  1618   UI-Timeout (Retry)                        -> config.psd1 UI.DefaultExitCode
  69001  Kein passendes kumulatives Update gefunden (Failure)
  69002  Vorpruefung fehlgeschlagen (Failure)
  69003  Installation fehlgeschlagen (Failure)
  69004  PSWindowsUpdate konnte nicht geladen werden (Failure)
  69005  Scan/Download fehlgeschlagen, meist Proxy/Netzwerk (Failure)
  69010  Uninstall nicht unterstuetzt (Failure)
  60001  Unbehandelter Fehler (PSADT Standard)

.NOTES
Basis: Invoke-AppDeployToolkit.ps1 aus PSAppDeployToolkit 4.1.8.
Bei anderer PSADT-Version: Template mit New-ADTTemplate erzeugen und nur die Bereiche
"$adtSession", "CU-Konfiguration", "Hilfsfunktionen", "Install/Uninstall/Repair" sowie die Zeile
"Close-ADTSession -ExitCode $script:CUExitCode" in der Invocation uebernehmen.

#>

[CmdletBinding()]
param
(
    # Default is 'Install'.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType,

    # Default is 'Auto'. Don't hard-code this unless required.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Interactive', 'NonInteractive', 'Silent')]
    [System.String]$DeployMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$SuppressRebootPassThru,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$TerminalServerMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$DisableLogging
)


##================================================
## MARK: Variables
##================================================

$adtSession = @{
    # App variables.
    AppVendor = 'Microsoft'
    AppName = 'Windows 11 Cumulative Update'
    AppVersion = 'Evergreen'
    AppArch = 'x64'
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @()
    AppScriptVersion = '1.0.0'
    AppScriptDate = '2026-11-26'
    AppScriptAuthor = 'IT'
    RequireAdmin = $true

    # Install Titles (Only set here to override defaults set by the toolkit).
    InstallName = 'Windows11_CumulativeUpdate'
    InstallTitle = 'Windows 11 Sicherheitsupdate'

    # Script variables.
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.1.8'
}

##================================================
## MARK: CU-Konfiguration
##================================================

$script:CUConfig = @{
    # Quelle fuer den Scan:
    #   'WindowsUpdate'   = online gegen Windows Update, an SUP/WSUS vorbei (empfohlen bei SUP)
    #   'MicrosoftUpdate' = online gegen Microsoft Update (registriert ggf. den MU-Dienst auf dem Client)
    #   'Default'         = konfigurierte Quelle des Clients (bei MECM: SUP/WSUS -> Download scheitert i.d.R.)
    # Siehe README, Abschnitt "Update-Quelle".
    UpdateSource          = 'WindowsUpdate'

    # Optional: feste KB(s) erzwingen, z.B. @('KB5070000'). Leer = Titel-Filter (Evergreen).
    KBArticleID           = @()

    # Titel-Filter (Regex). Vor Produktivnahme auf einem Testclient (als SYSTEM) mit
    #   Get-WindowsUpdate -WindowsUpdate | Select-Object KB, Title
    # gegen die aktuell gelieferten Titel pruefen.
    TitleInclude          = 'Cumulative Update.*Windows 11|Windows 11.*Cumulative Update'
    TitleExclude          = '\.NET|Preview|Dynamic'

    # Vorpruefungen
    MinFreeSpaceGB        = 15
    RequireACPower        = $true

    # Benutzerinteraktion (nur wenn DeployMode interaktiv ist)
    ShowWelcome           = $true
    DeferTimes            = 3

    # Neustart: $false = MECM steuert den Neustart ueber Exit 3010 (empfohlen)
    #           $true  = PSADT-Restart-Prompt mit Countdown (dann in MECM "No specific action" waehlen)
    UsePSADTRestartPrompt = $false
    RestartCountdownSecs  = 14400
}

# Wird in der Invocation an Close-ADTSession uebergeben.
$script:CUExitCode = 0


##================================================
## MARK: Hilfsfunktionen
##================================================

function Test-CUPrerequisite
{
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$cv.CurrentBuildNumber
    Write-ADTLogEntry -Message "OS: $($cv.ProductName) $($cv.DisplayVersion) Build $build.$($cv.UBR)"

    if ($build -lt 22000)
    {
        Write-ADTLogEntry -Message 'Kein Windows 11 (Build < 22000).' -Severity 3
        return $false
    }

    $freeGB = [math]::Round((Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free / 1GB, 1)
    Write-ADTLogEntry -Message "Freier Speicher $($env:SystemDrive) $freeGB GB (min. $($script:CUConfig.MinFreeSpaceGB) GB)."
    if ($freeGB -lt $script:CUConfig.MinFreeSpaceGB)
    {
        Write-ADTLogEntry -Message 'Zu wenig freier Speicher.' -Severity 3
        return $false
    }

    if ($script:CUConfig.RequireACPower -and -not (Test-ADTBattery))
    {
        Write-ADTLogEntry -Message 'Geraet laeuft im Akkubetrieb.' -Severity 3
        return $false
    }

    if ($script:CUConfig.UpdateSource -ne 'Default')
    {
        # GPO "Keine Verbindungen mit Windows Update-Internetadressen herstellen" blockiert den Online-Scan.
        $wuPol = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
        if ($wuPol -and $wuPol.PSObject.Properties['DoNotConnectToWindowsUpdateInternetLocations'] -and $wuPol.DoNotConnectToWindowsUpdateInternetLocations -eq 1)
        {
            Write-ADTLogEntry -Message 'GPO DoNotConnectToWindowsUpdateInternetLocations=1 aktiv. Online-Scan nicht moeglich.' -Severity 3
            return $false
        }

        # WUA nutzt im SYSTEM-Kontext den WinHTTP-Proxy, nicht den Benutzer-Proxy (PAC/WinINET).
        $winhttp = (& "$env:SystemRoot\System32\netsh.exe" winhttp show proxy 2>&1 | Out-String).Trim()
        Write-ADTLogEntry -Message "WinHTTP-Proxy (SYSTEM):`n$winhttp"
    }

    return $true
}

function Import-CUModule
{
    $modRoot = Join-Path -Path $adtSession.DirSupportFiles -ChildPath 'Modules\PSWindowsUpdate'
    $psd1 = Get-ChildItem -LiteralPath $modRoot -Filter 'PSWindowsUpdate.psd1' -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object -Property FullName -Descending | Select-Object -First 1

    if (-not $psd1)
    {
        throw "PSWindowsUpdate nicht gefunden unter [$modRoot]."
    }

    Get-ChildItem -LiteralPath $psd1.Directory.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
    Import-Module -Name $psd1.FullName -Force -ErrorAction Stop
    Write-ADTLogEntry -Message "PSWindowsUpdate $((Get-Module -Name PSWindowsUpdate).Version) geladen aus [$($psd1.FullName)]."
}

function Get-CUSourceParams
{
    switch ($script:CUConfig.UpdateSource)
    {
        'MicrosoftUpdate' { return @{ MicrosoftUpdate = $true } }
        'WindowsUpdate'   { return @{ WindowsUpdate = $true } }
        default           { return @{} }
    }
}

function Find-CUUpdate
{
    $src = Get-CUSourceParams
    Write-ADTLogEntry -Message "Starte Update-Scan (Quelle: $($script:CUConfig.UpdateSource))."

    $all = @(Get-WindowsUpdate @src -UpdateType Software -ErrorAction Stop)
    foreach ($u in $all)
    {
        Write-ADTLogEntry -Message "Angeboten: [$($u.KB)] $($u.Title)"
    }

    if ($script:CUConfig.KBArticleID.Count -gt 0)
    {
        $kbs = $script:CUConfig.KBArticleID | ForEach-Object { $_ -replace '^KB', '' }
        return @($all | Where-Object { ($_.KB -replace '^KB', '') -in $kbs })
    }

    return @($all | Where-Object {
            $_.Title -match $script:CUConfig.TitleInclude -and
            $_.Title -notmatch $script:CUConfig.TitleExclude
        })
}

function Install-CUUpdate
{
    param ([Parameter(Mandatory = $true)][string[]]$KB)

    $src = Get-CUSourceParams
    Write-ADTLogEntry -Message "Installiere: $($KB -join ', ')"

    $result = @(Get-WindowsUpdate @src -KBArticleID $KB -Install -AcceptAll -IgnoreReboot -ErrorAction Stop)
    foreach ($r in $result)
    {
        Write-ADTLogEntry -Message "Ergebnis: [$($r.KB)] $($r.Title) -> $($r.Result)"
    }

    # Get-WindowsUpdate liefert je Phase eine Zeile (Accepted/Downloaded/Installed/Failed).
    $failed = @($result | Where-Object { $_.Result -match 'Failed|Aborted' })
    $installed = @($result | Where-Object { $_.Result -eq 'Installed' })
    return ($failed.Count -eq 0 -and $installed.Count -gt 0)
}


##================================================
## MARK: Install
##================================================

function Install-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Install
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    if (-not (Test-CUPrerequisite))
    {
        $script:CUExitCode = 69002
        return
    }

    # Bereits installiertes, aber noch nicht aktiviertes Update -> nur Neustart notwendig.
    if ((Get-ADTPendingReboot).IsSystemRebootPending)
    {
        Write-ADTLogEntry -Message 'Neustart ausstehend. Installation wird uebersprungen, Exit 3010.' -Severity 2
        $script:CUExitCode = 3010
        return
    }

    if ($script:CUConfig.ShowWelcome)
    {
        # Bei NonInteractive/Silent zeigt PSADT nichts an und faehrt direkt fort.
        # Timeout ohne Reaktion: config.psd1 UI.DefaultTimeout -> Exit UI.DefaultExitCode (1618).
        Show-ADTInstallationWelcome -AllowDefer -DeferTimes $script:CUConfig.DeferTimes -PersistPrompt
    }

    Show-ADTInstallationProgress -StatusMessage 'Das aktuelle Windows-Sicherheitsupdate wird heruntergeladen und installiert. Sie koennen weiterarbeiten. Dies kann 15-60 Minuten dauern.'

    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    try
    {
        Import-CUModule
    }
    catch
    {
        Write-ADTLogEntry -Message "Modulimport fehlgeschlagen: $(Resolve-ADTErrorRecord -ErrorRecord $_)" -Severity 3
        $script:CUExitCode = 69004
        return
    }

    try
    {
        $updates = Find-CUUpdate
    }
    catch
    {
        # Typisch: 0x80072EE2 (Timeout), 0x80072EFD (keine Verbindung), 0x80244022/0x80190197 (Proxy/407)
        Write-ADTLogEntry -Message "Update-Scan fehlgeschlagen: $(Resolve-ADTErrorRecord -ErrorRecord $_)" -Severity 3
        $script:CUExitCode = 69005
        return
    }

    if ($updates.Count -eq 0)
    {
        Write-ADTLogEntry -Message 'Kein passendes kumulatives Update angeboten.' -Severity 3
        $script:CUExitCode = 69001
        return
    }

    try
    {
        $ok = Install-CUUpdate -KB ([string[]]($updates.KB))
    }
    catch
    {
        Write-ADTLogEntry -Message "Download/Installation fehlgeschlagen: $(Resolve-ADTErrorRecord -ErrorRecord $_)" -Severity 3
        $script:CUExitCode = 69005
        return
    }
    if (-not $ok)
    {
        $script:CUExitCode = 69003
        return
    }

    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    Close-ADTInstallationProgress

    if (Get-WURebootStatus -Silent)
    {
        Write-ADTLogEntry -Message 'Installation erfolgreich, Neustart erforderlich.'
        if ($script:CUConfig.UsePSADTRestartPrompt)
        {
            Show-ADTInstallationRestartPrompt -CountdownSeconds $script:CUConfig.RestartCountdownSecs -CountdownNoHideSeconds 600
        }
        $script:CUExitCode = 3010
    }
    else
    {
        Write-ADTLogEntry -Message 'Installation erfolgreich, kein Neustart erforderlich.'
        $script:CUExitCode = 0
    }
}

function Uninstall-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    $adtSession.InstallPhase = $adtSession.DeploymentType
    Write-ADTLogEntry -Message 'Deinstallation kumulativer Updates wird nicht unterstuetzt.' -Severity 2
    $script:CUExitCode = 69010
}

function Repair-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    Install-ADTDeployment
}


##================================================
## MARK: Initialization
##================================================

# Set strict error handling across entire operation.
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

# Import the module and instantiate a new session.
try
{
    # Import the module locally if available, otherwise try to find it from PSModulePath.
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf)
    {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{ ModuleName = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }
    else
    {
        Import-Module -FullyQualifiedName @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }

    # Open a new deployment session, replacing $adtSession with a DeploymentSession.
    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
}
catch
{
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int32]::MaxValue)))
    exit 60008
}


##================================================
## MARK: Invocation
##================================================

# Commence the actual deployment operation.
try
{
    # Import any found extensions before proceeding with the deployment.
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory | & {
        process
        {
            if ($_.Name -match 'PSAppDeployToolkit\..+$')
            {
                Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
                Import-Module -Name $_.FullName -Force
            }
        }
    }

    # Invoke the deployment and close out the session.
    & "$($adtSession.DeploymentType)-ADTDeployment"
    Write-ADTLogEntry -Message "Beende mit Exit Code $($script:CUExitCode)."
    Close-ADTSession -ExitCode $script:CUExitCode
}
catch
{
    # An unhandled error has been caught.
    $mainErrorMessage = "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity 3
    Close-ADTSession -ExitCode 60001
}
