JTL DHL Worker v1.13 All-in-One - Server + Print-Agent
======================================================

Zweck
-----
PowerShell-Loesung fuer JTL-Wawi + DHL Paket API Shipping V2 mit:
- CSV-Auftragsuebergabe aus JTL-Wawi
- direkter DHL-Sendungserstellung
- direktem Rueckschreiben der Tracking- und Versanddaten in die JTL-Datenbank
- optionalem separatem Print-Agent fuer automatischen Labeldruck

WICHTIG: KEIN JTL-VERSANDDATENIMPORT
------------------------------------
Diese Version schreibt Tracking und Versanddatum DIREKT in die JTL-Datenbank.
Deshalb in JTL fuer diese Versandarten:

- KEINEN Versanddaten-/Tracking-Import konfigurieren
- KEINE Importvorlage an der Versandart hinterlegen
- KEINEN automatischen Versanddatenimport aktivieren
- KEINen Auto-Import-Workflow fuer die erzeugten Daten einrichten

Der fruehere Importweg ist bei DirectJTL nicht erforderlich. Ein paralleler Import kann zu doppelten oder widerspruechlichen Verarbeitungsschritten fuehren.

Die CSV-Datei aus JTL ist hier nur die Uebergabe VON JTL AN DEN DHL-WORKER. Sie ist kein Rueckimport nach JTL.

Unterstuetzte JTL-Versandarten
------------------------------
- Versicherter Versand DHL       -> DHL Paket DE / V01PAK
- DHL Kleinpaket                 -> DHL Kleinpaket / V62KP
- Versicherter Versand DHL EU    -> DHL Paket International / V53WPAK, nur EU
- DHL Otto                       -> DHL Paket DE + DHL Retoure

Die Versandartnamen muessen exakt passen oder im Worker angepasst werden.

OTTO
----
Bei "DHL Otto" werden Hinweg-Tracking und Retouren-Tracking erzeugt und direkt in JTL geschrieben.

Hinweg:
- tVersand.cIdentCode

Retoure:
- tVersand.cEnclosedReturnIdentCode

Das OTTO-Retourenlabel wird NICHT mit der normalen Hinweg-PDF kombiniert und dadurch nicht automatisch ueber den normalen Print-Agent gedruckt.
Die Retouren-Sendungsnummer bleibt dennoch in JTL erhalten.

Direktes JTL-Update
-------------------
Der Worker schreibt nach erfolgreicher DHL-Buchung direkt in JTL:
- tVersand.cIdentCode
- bei OTTO zusaetzlich tVersand.cEnclosedReturnIdentCode
- tVersand.dVersendet
- tBestellung.dVersandt

Wenn tVersand.dVersendet noch NULL ist, wird der aktuelle SQL-Server-Zeitpunkt gesetzt.
Anschliessend wird derselbe Wert nach tBestellung.dVersandt uebernommen, sofern dort noch kein Versanddatum steht.

Die Zuordnung erfolgt ueber PaketRef -> tVersand -> tLieferschein -> tBestellung.
Vor einer echten DHL-Buchung wird geprueft, ob PaketRef, Lieferschein und Versandart eindeutig zusammenpassen und das Trackingfeld leer ist.

Voraussetzungen Server
----------------------
- Windows PowerShell 5.1
- JTL-Wawi / Microsoft SQL Server
- Windows-Benutzer des Workers benoetigt SQL-Zugriff auf die JTL-Datenbank
- DHL Paket API Shipping V2 Zugang
- passende DHL-Abrechnungsnummern
- fuer OTTO: freigeschaltete DHL Retoure + Retouren-Abrechnungsnummer

Server-Installation
-------------------
1. Ordner z.B. C:\JTL-DHL\Worker anlegen und Paket dort entpacken.
2. config.example.json nach config.json kopieren.
3. Pfade, SQL-Server, JTL-Datenbank, DHL-Daten und Abrechnungsnummern anpassen.
4. In JTL einen CSV-Export mit der Kopfzeile aus JTL-Export-Kopfzeile.txt anlegen.
5. Bei den verwendeten JTL-Versandarten KEINEN Import und KEINEN Auto-Import einrichten.
6. Zuerst Sandbox verwenden.
7. Fuer Production Production-Zugang-Einrichten.cmd unter genau dem Windows-Konto starten, unter dem spaeter der Worker laeuft.
8. Environment auf Production setzen und zuerst nur ProductionValidationEnabled=true verwenden.
9. Erst nach erfolgreicher Validierung ProductionEnabled=true setzen.
10. Fuer automatischen Worker-Betrieb zusaetzlich AutoProductionEnabled=true setzen und Start-Production-Automatik.cmd bzw. eine Windows-Aufgabe verwenden.

JTL-CSV-Export
--------------
Pflichtspalten:
PaketRef;Lieferschein;Versandart;Vorname;Nachname;Firma;Adresszusatz;Strasse;Hausnummer;PLZ;Ort;LandISO;Email;Telefon;Mobil;Gewicht

PaketRef muss auf den JTL-Versanddatensatz zeigen, typischerweise z.B. P1234 fuer kVersand=1234.
Gewicht wird in kg erwartet.

Noch einmal wichtig:
Die Export-CSV wird vom Worker eingelesen. Es wird KEINE Tracking-CSV fuer einen JTL-Rueckimport benoetigt.

Print-Agent / Client
--------------------
Der Unterordner PrintAgent enthaelt einen separaten Druck-Client.
Er kann auf demselben Rechner oder auf einem anderen Windows-Rechner laufen, sofern dieser auf den konfigurierten Label-Ordner zugreifen kann.

Voraussetzungen Client:
- Windows PowerShell 5.1
- PDF24 Creator
- installierter Windows-Labeldrucker
- Zugriff auf den Label-Ordner

Einrichtung:
1. Ordner PrintAgent auf den Druck-PC kopieren.
2. print-config.example.json nach print-config.json kopieren.
3. LabelPath, ArchivePath, ErrorPath und PrinterName anpassen.
4. Pdf24DocTool kontrollieren.
5. PrintAgent-Test-Sichtbar.cmd starten.
6. Test-PDF in den Label-Ordner legen und Druck pruefen.
7. Danach Start-PrintAgent.cmd oder Windows-Aufgabenplanung verwenden.

Der Print-Agent verwendet PDF24 DocTool mit -shellPrint und -printerName.
Nach erfolgreichem Druck wird das Label archiviert, damit es bei einem Neustart nicht doppelt gedruckt wird.

OTTO und Print-Agent:
Das OTTO-Retourenlabel wird vom Worker nicht in die normale Hinweg-PDF kombiniert. Der Client druckt somit nur das normale Versandlabel. Zusaetzlich sind Dateinamen mit "retoure", "return" und "ruecksendung" standardmaessig vom automatischen Druck ausgeschlossen.

Sicherheitsmechanismen
----------------------
- Production standardmaessig gesperrt
- manueller Production-Versand nur mit -ApproveProductionShipment und -SpecificFile
- automatischer Production-Betrieb nur bei AutoProductionEnabled=true
- Doppelstart-Sperre fuer AutoProduction
- Vorpruefung der JTL-Zuordnung vor DHL-Erstellung
- State-Datei verhindert DHL-Doppelbuchungen
- Falls DHL erfolgreich war, aber JTL-Update fehlschlaegt, wird beim Folgelauf nur das JTL-Update nachgeholt
- SQL-Tracking- und Versanddatum-Updates laufen in einer Transaktion
- Print-Agent archiviert erfolgreich verarbeitete PDFs

Wichtiger Hinweis
-----------------
Direkte Schreibzugriffe auf die JTL-Datenbank erfolgen auf eigenes Risiko und sind vor dem Einsatz in einer produktiven Umgebung mit Backup/Testsystem zu pruefen. Bei JTL-Updates koennen sich Tabellen, Spalten oder interne Ablaeufe aendern.

Das Paket ist keine offizielle Erweiterung von JTL, DHL oder OTTO.

Dateien
-------
JTL-DHL-Worker.ps1                 Hauptworker
config.example.json                neutrale Server-Beispielkonfiguration
Production-Zugang-Einrichten.*     verschluesselte Production-Credentials
Start-*.cmd                        Startbeispiele
JTL-Export-Kopfzeile.txt           benoetigte Exportspalten
JTL-Export-Beispiel.csv            Minimalbeispiel
PrintAgent\                        separater Druck-Client
