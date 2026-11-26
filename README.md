# MECM Application: Windows 11 Cumulative Update (PSADT + PSWindowsUpdate)

MECM-Application, die per **PSAppDeployToolkit 4.1.x** und **PSWindowsUpdate** das aktuell angebotene kumulative Update (LCU) für Windows 11 installiert.

## Konzept

| Baustein | Aufgabe |
|---|---|
| `PSADT/Invoke-AppDeployToolkit.ps1` | Vorprüfungen, Benutzerdialog/Deferral, Scan + Installation über PSWindowsUpdate, Exit 3010 |
| `Detection/Detect-W11CU.ps1` | Script Detection: `CurrentBuildNumber` + `UBR` ≥ Ziel-UBR |
| `Tools/New-CUPackage.ps1` | Baut den Content (PSADT-Template + Skript + PSWindowsUpdate in `SupportFiles\Modules`) |
| `Tools/Set-CMCUDetection.ps1` | Monatlich: Ziel-UBR in der Detection des Deployment Types setzen |

**Evergreen-Prinzip:** Der Content bleibt gleich. Das Skript installiert immer das LCU, das der Client angeboten bekommt. Welcher Stand als „erfüllt“ gilt, steuert nur die Detection (Ziel-UBR). Monatlich wird nur die Detection angepasst, nicht der Content.

### Ablauf auf dem Client

1. Vorprüfungen: Windows 11, freier Speicher (Standard 15 GB), Netzbetrieb
2. Neustart ausstehend → Exit **3010** ohne Installation (z. B. LCU schon installiert, noch nicht aktiv)
3. Welcome-Dialog mit Deferral (Standard 3x). Wird bei `NonInteractive`/`Silent` übersprungen.
4. PSWindowsUpdate aus dem Content laden. Auf den Clients ist kein Zugriff auf die PowerShell Gallery nötig.
5. `Get-WindowsUpdate` → Filter auf den LCU-Titel (oder eine feste KB) → `-Install -AcceptAll -IgnoreReboot`
6. Exit **3010**. Den Neustart steuert MECM. Die Detection läuft nach dem Neustart erneut.

Log: `C:\Windows\Logs\Software\Windows11_CumulativeUpdate_*.log` (PSADT), dazu `AppEnforce.log` auf dem Client.

## Paket bauen

```powershell
.\Tools\New-CUPackage.ps1 -Destination '\\<server>\Sources$\Apps\Microsoft'
```

Vor der Produktivnahme auf einem Testclient (als SYSTEM, z. B. `psexec -s`) die angebotenen Titel prüfen und `TitleInclude`/`TitleExclude` im Skript (Bereich `CU-Konfiguration`) gegebenenfalls anpassen:

```powershell
Import-Module .\SupportFiles\Modules\PSWindowsUpdate\<version>\PSWindowsUpdate.psd1
Get-WindowsUpdate -MicrosoftUpdate | Select-Object KB, Title
```

## Update-Quelle (wichtig, bitte prüfen)

Parameter `UpdateSource` im Skript:

| Wert | Verhalten | Voraussetzung |
|---|---|---|
| `MicrosoftUpdate` (Standard) | Scan und Download direkt bei Microsoft Update, an SUP/WSUS vorbei | Internetzugriff für SYSTEM (WinHTTP-Proxy), GPO *„Keine Verbindungen mit Windows Update-Internetadressen herstellen“* **nicht** aktiv |
| `WindowsUpdate` | wie oben, nur Windows-Produkte | wie oben |
| `Default` | konfigurierte Quelle des Clients (bei MECM: SUP/WSUS) | Der Download funktioniert nur, wenn WSUS die Dateien vorhält oder der Client sie von MU laden darf. Beim Standard-SUP-Setup scheitert das in der Regel. |

Delivery Optimization reduziert bei `MicrosoftUpdate` die WAN-Last.

## MECM Application – Einstellungen

**Deployment Type: Script Installer**

| Einstellung | Wert |
|---|---|
| Installationsprogramm | `Invoke-AppDeployToolkit.exe -DeploymentType Install` |
| Reparaturprogramm | `Invoke-AppDeployToolkit.exe -DeploymentType Repair` |
| Deinstallationsprogramm | leer (ein LCU wird nicht per App deinstalliert) |
| Detection Method | Script → PowerShell → Inhalt von `Detection/Detect-W11CU.ps1` |
| Installationsverhalten | Für System installieren |
| Anmeldeanforderung | Unabhängig davon, ob ein Benutzer angemeldet ist |
| Sichtbarkeit | Normal |
| Benutzer dürfen Installation sehen und mit ihr interagieren | ✔ (PSADT 4.1 zeigt den Dialog in der Benutzersitzung, ServiceUI ist nicht nötig) |
| Max. Laufzeit / geschätzte Laufzeit | 120 / 45 Min. |
| Verhalten nach Installation | Verhalten anhand von Rückgabecodes bestimmen |
| Anforderungen | Betriebssystem: Windows 11 x64; freier Speicher auf dem Systemlaufwerk ≥ 15 GB |

**Rückgabecodes** (zusätzlich zu den Standardcodes):

| Code | Typ | Bedeutung |
|---|---|---|
| 3010 | Soft Reboot | installiert, Neustart nötig |
| 1602 | Fehler (kein Neustart) | Benutzer hat verschoben (PSADT `UI.DeferExitCode`), Retry über Re-Enforcement |
| 1618 | Fast Retry | Dialog-Timeout (PSADT `UI.DefaultExitCode`) |
| 69001 | Fehler | kein passendes LCU angeboten |
| 69002 | Fehler | Vorprüfung fehlgeschlagen (OS/Speicher/Akku) |
| 69003 | Fehler | Installation fehlgeschlagen |
| 69004 | Fehler | PSWindowsUpdate fehlt im Content |
| 60001 | Fehler | unbehandelter Fehler (PSADT) |

> Hinweis zu 1602: Als *Fast Retry* zeigt MECM das Deployment ständig als „in Bearbeitung“, und der Client fragt alle 2 Stunden erneut nach. Als *Fehler* fragt der Client beim nächsten Deployment Evaluation Cycle erneut nach. Das ist eine Geschmacksfrage.

## Deployment-Vorschlag

### Zielsammlungen

Geräte-Sammlungen per Query auf den Build. Builds, die in der Detection nicht gepflegt sind, gelten absichtlich als „installiert“ (fail-safe).

```sql
select SMS_R_System.ResourceId from SMS_R_System
where SMS_R_System.Build01 in ('10.0.26100','10.0.26200')
```

### Ringe (Phased Deployment oder manuell)

| Ring | Sammlung | Verfügbar | Deadline | Benutzererlebnis |
|---|---|---|---|---|
| 0 – IT | IT-Geräte | Patchday +1 | Patchday +1 | interaktiv, Deferral 3x |
| 1 – Pilot | ca. 5–10 % repräsentative Geräte | +2 Tage | +4 Tage | interaktiv, Deferral 3x |
| 2 – Breit | alle Clients | +7 Tage | +10 Tage | interaktiv, Deferral 3x |
| 3 – Kritisch/Kiosk | Sondersysteme | +10 Tage | im Wartungsfenster | `-DeployMode NonInteractive` (eigener Deployment Type oder eigene App) |

Für Ring 0–2 bietet sich das MECM-Feature **Phased Deployment** für Applications an (Erfolgskriterium z. B. 95 %, dann automatisch nächste Phase).

### Deployment-Einstellungen

- Zweck: **Erforderlich**, Aktion: Installieren
- Benutzerbenachrichtigung: *Im Softwarecenter anzeigen und alle Benachrichtigungen anzeigen*
- Wartungsfenster: Softwareinstallation **und** Systemneustart außerhalb des Wartungsfensters erlauben, wenn die Deadline durchgesetzt werden soll. Sonst bleibt es beim Wartungsfenster.
- Neustart-Countdown über die **Client Settings** → *Computer Restart* (z. B. 8 h Countdown, 15 Min. finale Warnung)
- Optional: *Automatically upgrade/Re-Enforce* ist nicht nötig. Nach geänderter Detection wertet der Client beim nächsten Application Deployment Evaluation Cycle neu aus. Der Standard ist 7 Tage, für schnelleres Greifen den Zyklus verkürzen oder per Client Notification anstoßen.

### Monatlicher Betrieb

1. Patchday: neue UBR aus der *Windows 11 update history* entnehmen (24H2 und 25H2 teilen sich das LCU)
2. Auf Ring 0 testen (Skript-Log prüfen: angebotener Titel, Ergebnis `Installed`)
3. Detection aktualisieren:
   ```powershell
   .\Tools\Set-CMCUDetection.ps1 -SiteCode P01 -ProviderMachineName cm01.contoso.local `
       -ApplicationName 'Windows 11 Cumulative Update' -DeploymentTypeName 'PSADT' `
       -Targets @{ 26100 = <UBR>; 26200 = <UBR> }
   ```
4. Neue Deployments/Phasen gemäß Ringplan anlegen (oder bestehende Deadlines anpassen)

## Bekannte Einschränkungen

- **Neustart ausstehend:** Jeder ausstehende Neustart (auch durch andere Software) führt zu Exit 3010 ohne Installation. Nach dem Neustart läuft die Installation normal.
- **Titel-Filter:** Microsoft ändert gelegentlich die Benennung. Deshalb vor jedem Rollout auf Ring 0 prüfen. Alternativ in `KBArticleID` eine feste KB eintragen, dann ist allerdings eine Content-Aktualisierung nötig.
- **Parallelbetrieb mit SUP/ADR:** Werden LCUs zusätzlich über Software Updates verteilt, kann es zu doppelten Neustart-Aufforderungen kommen. Den Verteilweg pro Gerätegruppe eindeutig festlegen.
- **Uninstall:** wird nicht unterstützt (Exit 69010).
