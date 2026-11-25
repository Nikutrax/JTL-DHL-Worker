JTL DHL Print-Agent
===================

Zweck
-----
Ueberwacht den Label-Ordner des DHL-Workers und druckt neue PDF-Labels automatisch ueber PDF24 DocTool auf einen festgelegten Windows-Drucker.

Installation
------------
1. PDF24 Creator installieren.
2. print-config.example.json nach print-config.json kopieren.
3. LabelPath auf denselben Label-Ordner wie im Worker setzen.
4. PrinterName exakt auf den Windows-Druckernamen setzen.
5. Pdf24DocTool ggf. an den lokalen Installationspfad anpassen.
6. Zuerst PrintAgent-Test-Sichtbar.cmd starten und mit einem Testlabel pruefen.
7. Danach Start-PrintAgent.cmd verwenden oder diese CMD ueber Windows-Aufgabenplanung beim Benutzer-Login starten.

Druckverfahren
--------------
PDF24 DocTool wird mit -shellPrint und -printerName verwendet.
Nach erfolgreichem Aufruf wird das PDF nach ArchivePath verschoben. Dadurch wird es beim Neustart des Agents nicht erneut gedruckt.

OTTO
----
Der Worker kombiniert bei der Versandart "DHL Otto" das Retourenlabel nicht mit der normalen Hinweg-PDF. Dadurch wird nur das Hinweg-Label im normalen Drucklauf verarbeitet.
Als zusaetzliche Sicherheit ueberspringt der Print-Agent Dateinamen, die standardmaessig "retoure", "return" oder "ruecksendung" enthalten.

Hinweis
-------
Vor dem Dauerbetrieb immer einen Testdruck durchfuehren. Der konfigurierte Druckername muss exakt dem Windows-Druckernamen entsprechen.
