# CSV-Installation und Migration (v1.15-beta.1)

## 1. Voraussetzungen und sichere Migration

Windows PowerShell 5.1, DHL-API-Zugang, JTL-Wawi mit Versanddatenexport/-import. Pilot erfolgreich unter JTL-Wawi 2.1.2 in einer Installation getestet; ob die automatische Verarbeitung Packtisch+ oder WMS voraussetzt, ist pro Installation zu prüfen.

Alten SQL-Worker und alle anderen Labelerzeuger stoppen (auch Aufgabenplanung). Konfiguration, Skripte, Export-/Importordner, Statusdateien, Labels und Sicherungen sichern. Keine echten Zugangsdaten, Kundenadressen oder Versanddateien in GitHub ablegen. Bereits gebuchte oder ungeklärte Pakete im DHL-Portal und JTL abgleichen; alte Exportdateien außerhalb des überwachten Ordners sichern. Statusordner nicht leeren, dieselben Paket-IDs dürfen nicht erneut gebucht werden. Bei mehreren JTL-Mandanten separate Verzeichnisse und Statusordner benutzen.

## 2. JTL-Vorlagen

Versanddatenexport: Semikolon, eine Kopfzeile, genau ein Paket je CSV. PaketRef ist die interne Paketnummer mit Präfix P, z. B. `P{{Paket.InternePaketnummer}}`. Spalten gemäß `JTL-Export-Kopfzeile.txt`:

```csv
PaketRef;Lieferschein;Versandart;Vorname;Nachname;Firma;Adresszusatz;Strasse;Hausnummer;PLZ;Ort;LandISO;Email;Telefon;Mobil;Gewicht
```

Beim Ausliefern Versanddaten exportieren, das Versanddatum nicht vorab setzen. Nur offene, noch nicht gebuchte Pakete exportieren. Versanddatenimport: Semikolon, eine Kopfzeile, Spalte 1 ID-Nummer, Spalte 2 Tracking-Nr. Importordner aus der Konfiguration verwenden. Beispiel (nur fiktive Daten):

```csv
PaketRef;Tracking
P1234;TEST123456789
```

Automatischen Abgleich aktivieren und mit einem getrennten internen Testlieferschein prüfen (keine Kundenbenachrichtigung, kein echter Labelkauf). Vor dem Test alle Labelerzeuger stoppen. Test-Exportdatei anschließend aus dem Exportordner archivieren. In JTL sowohl Trackingnummer als auch Versanddatum kontrollieren. Bei ausbleibendem Import JTL-Konfiguration und gegebenenfalls Packtisch+/WMS prüfen.

## 3. Konfiguration und Zugangsdaten

`config.example.json` nach `config.json` kopieren. ExportPath, ImportPath, LabelPath, ProcessedPath, ErrorPath, StatePath und LogPath auf getrennte, für das Worker-Konto erreichbare Ordner setzen; bei Netzwerkpfaden UNC bevorzugen. Für Production die eigene Absenderreferenz und Abrechnungsnummer hinterlegen. `Production-Zugang-Einrichten.ps1` unter demselben Windows-Konto ausführen wie den Worker; standardmäßig wird `production-credentials.json` erzeugt (DPAPI). Keine Produktionszugangsdaten in die Beispieldatei schreiben.

Sandbox nur zur Validierung, niemals Sandbox-Tracking in den produktiven JTL-Import. ProductionEnabled, AutoProductionEnabled und CsvAutomationEnabled bleiben bis zur bewussten Freigabe false. ProductionValidationEnabled erlaubt allein die Validierung. Die Automatik nutzt zusätzlich CsvAutomationNotBefore (ISO-8601 Rundreiseformat mit Offset, z. B. `[DateTimeOffset]::Now.ToString('o')`).

## 4. Einzeldatei testen

Im Worker-Verzeichnis, bei weiterhin gestoppter Automatik:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\JTL-DHL-Worker.ps1 -ConfigPath .\config.json -ValidateOnly -SpecificFile 'TESTDATEI.csv'
```

Erst nach erfolgreicher Validierung, Abgleich mit JTL und DHL-Portal und ausdrücklicher Freigabe ProductionEnabled=true setzen und einen tatsächlich zu versendenden Auftrag buchen (kostenpflichtig):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\JTL-DHL-Worker.ps1 -ConfigPath .\config.json -ApproveProductionShipment -SpecificFile 'ECHTE_DATEI.csv'
```

PDF, Status-JSON, CSV-Sicherung, Archivierung, Trackingnummer und Versanddatum in JTL kontrollieren. Bei Fehler nach einer möglichen DHL-Buchung nicht wiederholen. Der Modus `-CheckDuplicateOnly -SpecificFile P1234` (Paket-ID, nicht Dateiname) ist ein reiner lokaler Nachweistest ohne API-Aufruf.

## 5. Automatik erst nach erfolgreichem Einzeltest

Exportordner prüfen und alte Dateien archivieren. Die drei Schalter ProductionEnabled, AutoProductionEnabled, CsvAutomationEnabled ausdrücklich auf true setzen und CsvAutomationNotBefore auf die aktuelle Zeit setzen. Freigabe ausschließlich für genau ein Paket je Datei, Versandart `Versicherter Versand DHL`, Deutschland. Start:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\JTL-DHL-Worker.ps1 -ConfigPath .\config.json -AutoProduction
```

Ersten automatischen Auftrag überwachen. Für Aufgabenplanung das Konto der DPAPI-Datei verwenden; keine parallelen Instanzen. PrintAgent und Druck separat prüfen. Mehrpaketsendungen, OTTO-Retouren und andere Versandarten nicht automatisch buchen. Die Marktplatzmeldung separat kontrollieren.

## 6. Fehlerbehandlung und Rückfall

`DHL_BOOKING_RESERVED` bedeutet unklarer Buchungsstatus. DHL-Portal prüfen, vorhandenes Label und Tracking wiederherstellen. `DHL_CREATED_PENDING_CSV` / `CSV_PUBLISH_PENDING` zeigen einen unterbrochenen Rückmeldeablauf; keine neue DHL-Buchung durchführen. `CSV_PUBLISHED_UNCONFIRMED` bedeutet nur, dass der Worker die CSV bereitgestellt hat; JTL manuell prüfen. Importdateien, die länger als fünf Minuten liegen, lösen Warnungen aus. Das Verschwinden einer Datei ist keine technische Importquittung.

Bei Migration und Rückfall immer zuerst beide Worker stoppen. Die bisherige Version ist im Branch `legacy/sql-v1.14-beta.2` gesichert. Vor einem SQL-Rückfall automatische CSV-Importe und offene Dateien abgleichen, damit nicht beide Verfahren denselben Lieferschein bearbeiten. Originalkonfiguration und vorhandene Nachweise erhalten. Keine ungeklärten Sendungen erneut in den Export legen. Änderungen am bisherigen öffentlichen SQL-Stand sind nicht Teil dieses Entwicklungsbranches.

## 7. Testumfang

Die private v1.12e wurde am 27.11.2026 mit echtem DHL-Inlandsversand, NAS-Statusspeicherung und automatischem JTL-Import erfolgreich getestet. Die öffentliche Ableitung enthält bereinigte Vorgaben und strengere Sandbox-Sperren. Sie muss erneut getestet werden. Keine Freigabe für andere Versandarten, Retouren oder ungeprüfte Marktplatzprozesse.
