# JTL DHL Worker – Community

**Entwicklungsstand: v1.15-beta.1 (CSV-Architektur, noch nicht veröffentlicht)**

Kostenlose Open-Source-Versandanbindung zwischen JTL-Wawi und DHL Paket API Shipping V2 (Windows PowerShell 5.1). Kein offizielles Produkt von JTL oder DHL.

## Was ist neu?

JTL-Wawi exportiert ein Paket als CSV. Der Worker validiert die Sendung, bucht einmalig das DHL-Label und speichert das PDF sowie den Buchungsstatus. Er stellt anschließend eine Tracking-CSV bereit. JTL importiert die Trackingnummer über seine eigene Versanddatenschnittstelle und setzt das Versanddatum. **Kein direkter SQL-Zugriff durch den neuen Versandworker.**

Die private Pilotversion v1.12e wurde am 27.11.2026 mit JTL-Wawi 2.1.2 im DHL-Inlandsversand erfolgreich im Automatikbetrieb getestet. Der öffentliche Entwicklungsstand wurde davon abgeleitet; installationsbezogene Abrechnungs- und Absenderdaten wurden entfernt. Die öffentliche Variante benötigt eigene erneute Tests.

**Amazon-Praxistest (27.11.2026):** Für die private SQL-freie Pilotversion v1.12e unter JTL-Wawi 2.1.2 wurde die erfolgreiche Amazon-Versandbestätigung vom Betreiber gemeldet. Die Marktplatzmeldung erfolgt über JTL, nicht durch einen direkten Amazon-Aufruf des Workers. Dies ist kein separater Praxistest der öffentlichen v1.15-beta.1.

## Einstieg

1. [CSV-Installations- und Migrationsanleitung](docs/CSV-Setup.md) lesen.
2. `config.example.json` nach `config.json` kopieren und lokal konfigurieren.
3. JTL-Export und JTL-Import einrichten und den Import mit einem internen Testauftrag prüfen.
4. In der Sandbox oder Production zunächst ausschließlich eine Einzeldatei validieren. Keine echten Sendungen buchen.
5. Erst nach erfolgreicher Prüfung einer tatsächlich zu versendenden Inlandssendung und Kontrolle in JTL die Automatik ausdrücklich freigeben.

Die Beispielkonfiguration erlaubt keine Production-Buchungen und keine Automatik. Nicht mit dem SQL-Legacy-Worker oder einem anderen Labelerzeuger parallel betreiben.

## Aktuell unterstützter Pilotumfang

- Automatik: genau ein Paket je Exportdatei, Versandart `Versicherter Versand DHL`, Deutschland (V01PAK).
- Andere Versandarten, internationale Sendungen, Kleinpaket, Premium und Mehrpaketverarbeitung sind nicht für den unbeaufsichtigten Betrieb freigegeben.
- Die kombinierte OTTO-Retourenbuchung ist gesperrt. Die Retourenrückmeldung und weitere Marktplatzprozesse sind nicht abschließend geprüft; siehe Amazon-Praxistest oben.
- Das vorhandene PrintAgent-Zubehör bleibt erhalten; dessen Integration mit der neuen Version ist separat zu testen.
- Der Worker hat keine technische Importquittung von JTL. Das Verschwinden einer CSV allein ist kein Erfolgsnachweis; Trackingnummer, Versanddatum und gegebenenfalls Marktplatzstatus kontrollieren.

## Bisherige SQL-Version

Die öffentliche v1.14-beta.2 bleibt im [Legacy-Branch](../../tree/legacy/sql-v1.14-beta.2) einschließlich ihrer Konfiguration und Startskripte erhalten. Sie ist eine getrennte Rückfalloption, keine parallel auszuführende Komponente. Bestehende Buchungsstatusdateien dürfen bei einem Wechsel nicht gelöscht werden.

## Sicherheit

Keine Zugangsdaten, echte Abrechnungsnummern, privaten Konfigurationen, Kunden-CSV, PDF-Labels oder Versandlogs veröffentlichen. Unklare Buchungen niemals einfach wiederholen. Die dateibasierte Sperre erkennt keine Buchungen, die außerhalb des Workers ohne lokale Nachweise vorgenommen wurden. Details und Wiederherstellung siehe [CSV-Setup](docs/CSV-Setup.md).

## Lizenz und Mitarbeit

[GNU GPL v3.0 (GPL-3.0-only)](LICENSE). Rechte an externen Produkten und Marken bleiben unberührt.

Beiträge sind willkommen: [Anleitung zur Mitarbeit](CONTRIBUTING.md), [Issues](../../issues) und Pull Requests gegen `develop`.
