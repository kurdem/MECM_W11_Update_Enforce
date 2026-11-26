<#
.SYNOPSIS
Baut das MECM-Content-Verzeichnis (PSADT 4.1.x Template + Skript + PSWindowsUpdate).

.DESCRIPTION
Auf einer Admin-Workstation mit Internetzugang ausfuehren (PowerShell 5.1, Administrator nicht erforderlich).
  1. PSAppDeployToolkit aus der PowerShell Gallery installieren (CurrentUser)
  2. Template per New-ADTTemplate erzeugen
  3. Invoke-AppDeployToolkit.ps1 aus diesem Repo ueberschreiben
  4. PSWindowsUpdate nach SupportFiles\Modules speichern (kein Gallery-Zugriff auf den Clients noetig)

.EXAMPLE
.\New-CUPackage.ps1 -Destination \\cm01\Sources$\Apps\Microsoft\W11-CU
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [string]$Name = 'W11-CU',

    [version]$PSADTVersion = '4.1.8',

    # Leer = aktuelle Version aus der Gallery
    [string]$PSWindowsUpdateVersion
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Path $PSScriptRoot -Parent

if (-not (Get-Module -ListAvailable -Name PSAppDeployToolkit | Where-Object Version -EQ $PSADTVersion))
{
    Install-Module -Name PSAppDeployToolkit -RequiredVersion $PSADTVersion -Scope CurrentUser -Force
}
Import-Module -Name PSAppDeployToolkit -RequiredVersion $PSADTVersion -Force

New-ADTTemplate -Destination $Destination -Name $Name -Force
$pkg = Join-Path -Path $Destination -ChildPath $Name

Copy-Item -LiteralPath (Join-Path $repoRoot 'PSADT\Invoke-AppDeployToolkit.ps1') -Destination $pkg -Force

$modPath = Join-Path -Path $pkg -ChildPath 'SupportFiles\Modules'
New-Item -Path $modPath -ItemType Directory -Force | Out-Null
$saveParams = @{ Name = 'PSWindowsUpdate'; Path = $modPath; Force = $true }
if ($PSWindowsUpdateVersion) { $saveParams.RequiredVersion = $PSWindowsUpdateVersion }
Save-Module @saveParams

Write-Host "Paket erstellt: $pkg"
Get-ChildItem -LiteralPath $modPath -Recurse -Filter *.psd1 | ForEach-Object { Write-Host "  Modul: $($_.FullName)" }
