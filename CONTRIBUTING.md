# Mitarbeit am JTL-DHL-Worker

Willkommen! Fehlerberichte, Tests, Dokumentation und Codebeiträge sind willkommen. Das Projekt ist unabhängig von JTL und DHL.

## Einstieg
1. Offene [Issues](../../issues) ansehen oder eine neue Aufgabe anlegen.
2. Änderungen bei größeren Vorhaben zuerst im Issue abstimmen.
3. Repository forken, vom Branch `develop` einen eigenen Branch erstellen.
4. Kleine, nachvollziehbare Commits erstellen und lokal testen.
5. Pull Request gegen `develop` öffnen, zugehöriges Issue verlinken und Tests beschreiben. `main` enthält gesicherte Versionsstände.

## Entwicklung und Tests
- Windows PowerShell 5.1 kompatibel halten; keine unnötigen Abhängigkeiten einführen.
- Konfiguration aus den Beispieldateien erzeugen; niemals lokale Konfiguration oder Zugangsdaten committen.
- Zuerst Sandbox und Testmandant verwenden. Vor SQL-Tests Datenbank sichern.
- Keine echten Sendungen erzeugen, sofern nicht ausdrücklich in einer kontrollierten Testplanung freigegeben.
- Experimentelle SQL-Versandstatusintegration standardmäßig deaktiviert lassen.
- Änderungen an SQL, API und Druckpfaden dokumentieren, Fehlerfälle und Wiederholungen berücksichtigen.
- GitHub Actions prüft die Syntax; funktionale Tests separat dokumentieren.

## Datenschutz und Sicherheit
Keine Kundendaten, API-Schlüssel, Passwörter, Trackingnummern, echten Labels, unveränderten Logdateien oder Datenbankauszüge in Issues oder Pull Requests einstellen. Fehler mit synthetischen Daten reproduzieren. Sicherheitslücken vertraulich gemäß [SECURITY.md](SECURITY.md) melden.

## Lizenz
Beiträge werden unter GPL-3.0-only gemäß [LICENSE](LICENSE) bereitgestellt. Mit einem Beitrag bestätigst du, dass du berechtigt bist, ihn unter diesen Bedingungen beizutragen. Keine fremden proprietären Quelltexte oder geschützten Inhalte übernehmen.

Vielen Dank für deine Unterstützung!
