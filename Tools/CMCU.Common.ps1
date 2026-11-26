<#
.SYNOPSIS
Gemeinsame Funktionen fuer die MECM-Skripte (per Dot-Sourcing eingebunden).
#>

function Connect-CMCUSite
{
    param
    (
        [Parameter(Mandatory = $true)][string]$SiteCode,
        [Parameter(Mandatory = $true)][string]$ProviderMachineName
    )

    if (-not (Get-Module -Name ConfigurationManager))
    {
        if (-not $env:SMS_ADMIN_UI_PATH) { throw 'MECM-Konsole nicht installiert (SMS_ADMIN_UI_PATH fehlt).' }
        Import-Module -Name (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1') -ErrorAction Stop
    }
    if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue))
    {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName -ErrorAction Stop | Out-Null
    }
    Set-Location -Path "$($SiteCode):\"
}

function Get-CUDetectionScriptText
{
    # Liefert Detection\Detect-W11CU.ps1, optional mit ersetzten Ziel-UBRs.
    param ([hashtable]$Targets)

    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $text = Get-Content -LiteralPath (Join-Path $repoRoot 'Detection\Detect-W11CU.ps1') -Raw -ErrorAction Stop
    if (-not $Targets) { return $text }

    $lines = foreach ($k in ($Targets.Keys | Sort-Object)) { "    $k = $([int]$Targets[$k])" }
    $block = "### TARGETS-BEGIN ###`r`n`$Targets = @{`r`n$($lines -join "`r`n")`r`n}`r`n# ### TARGETS-END ###"
    return [regex]::Replace($text, '### TARGETS-BEGIN ###[\s\S]*?# ### TARGETS-END ###', $block.Replace('$', '$$'))
}

function Get-PatchTuesday
{
    # Zweiter Dienstag des Monats.
    param ([datetime]$Date = (Get-Date))

    $first = Get-Date -Year $Date.Year -Month $Date.Month -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0
    $offset = ([int][DayOfWeek]::Tuesday - [int]$first.DayOfWeek + 7) % 7
    return $first.AddDays($offset + 7)
}
