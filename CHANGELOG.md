# Änderungsverlauf

## v1.15-beta.1 – in Vorbereitung
- CSV-basierte Trackingrückmeldung statt direkter SQL-Updates; JTL setzt das Versanddatum.
- Aus der privaten, mit JTL-Wawi 2.1.2 am 27.11.2026 erfolgreich getesteten v1.12e abgeleitet; private Abrechnungs- und Absenderdaten entfernt.
- Explizite Automatikfreigabe und Zeitstichtag, Statusreservierung vor Buchung, NAS-Dateisperre, Schreibprobe, Erhalt von Recovery-Dateien und CSV-Sicherungen.
- Automatik zunächst nur für reguläres DHL Paket Deutschland, ein Paket je CSV.
- Importüberwachung warnt bei ausstehenden Dateien; keine technische JTL-Importbestätigung.
- SQL-Legacy-Stand separat gesichert. Keine parallele Ausführung.
- Amazon-Praxistest am 27.11.2026: erfolgreiche Versandbestätigung bei Amazon vom Betreiber für die private SQL-freie v1.12e mit JTL-Wawi 2.1.2 gemeldet. Die Marktplatzmeldung liegt bei JTL.
- Öffentliche Variante erneut testen; Retouren, weitere Versandarten, Mehrpaket- und ungeprüfte Marktplatzabläufe nicht freigegeben. Der Amazon-Pilotbefund ist keine Freigabe der öffentlichen Beta.

## v1.14-beta.2
- Vereinfachte Einrichtung der Production-Zugangsdaten via Zwischenablage oder verdeckte Eingabe (PR #11, #12).
- Windows-PowerShell-5.1- und DPAPI-Tests erfolgreich; manuelle Zwischenablageprüfung offen.

## v1.14 – Importstand
- Originales Hauptskript aus v1.14 übernommen.
- Zubehör und Startskripte aus v1.13 übernommen.
- Beispielkonfiguration um deaktivierte experimentelle Versandstatusintegration und AmazonPlatformId=0 ergänzt.
- Historische Dokumentation erhalten.
- Keine Laufzeitprüfung durchgeführt.
