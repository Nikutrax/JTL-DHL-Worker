# JTL DHL Worker – Community

Importstand: v1.14 (PowerShell 5.1), ergänzt um die Server- und Print-Agent-Dateien aus v1.13. Kein offizielles Produkt von JTL oder DHL.

## Funktionen

- CSV-Übergabe aus JTL-Wawi an DHL Paket API Shipping V2
- Labelerstellung und optionaler separater PDF24-Print-Agent
- Direktes SQL-Update von Tracking und Versanddatum; kein paralleler JTL-Versanddatenimport
- Sandbox- und Production-Modus mit expliziten Freigaben
- Experimentelle SQL-Versandstatusintegration (standardmäßig deaktiviert)

## Einrichtung

1. `config.example.json` nach `config.json` kopieren und lokal konfigurieren.
2. CSV-Export entsprechend `JTL-Export-Kopfzeile.txt` einrichten.
3. Zuerst Sandbox-Validierung ausführen.
4. Für Production den Zugang unter dem Windows-Konto des Workers einrichten; zunächst nur validieren.
5. Echtversand erst nach erfolgreichen Tests und Datenbank-Backup freigeben.

Die ergänzenden Startskripte und Print-Agent-Dateien stammen unverändert aus v1.13. Sie wurden nicht mit v1.14 ausgeführt oder auf Kompatibilität getestet. Historische Anleitung: [v1.13](docs/legacy/README-v1.13.txt).

## Sicherheit

Keine echten Zugangsdaten oder Kundendaten einchecken. SQL-Direktzugriffe vor produktivem Einsatz auf einem Testmandanten prüfen. `EnableExperimentalShippingStatusSql` bleibt `false`; `AmazonPlatformId` bleibt `0`, bis die installationsabhängige Zuordnung geprüft wurde.

## Status

Importbasis, noch nicht als vollständiges Release getestet. Keine Lizenz festgelegt; zunächst privates Repository empfohlen.
