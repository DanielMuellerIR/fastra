# F10: Zuletzt benutzte Projekte unter Linux

Die Projektansicht bietet eine sichtbare Liste von höchstens zwölf zuletzt
bewusst gewählten Ordnern. Vorbild ist `ProjectStore.swift`: neue Einträge stehen
oben, ein vorhandener Eintrag rückt nach oben. Linux speichert absolute rohe
Unix-Pfade als Bytefolgen; Anzeige-Escapes werden nie in einen Pfad zurückgewandelt.
Die nach erfolgreichem Scan aufgelöste Projektwurzel ist die gespeicherte Basis.
Anders als die Mac-Defaults verwendet die Linux-Datei keine Tilde-Kürzung.

Ordnerauswahl, „Öffnen“ eines Listeneintrags und Enter im Pfadfeld zählen als
bewusste Wahl. Erst eine akzeptierte erfolgreiche Scan-Completion merkt den
Ordner. Bloßes Tippen, Filteränderungen, Polling, fehlgeschlagene oder abgebrochene
Scans legen keinen Eintrag an. Root-Bindung, Generation und Filterverhalten
bleiben im bestehenden Projektbaum. Es gibt keinen automatischen Projekt- oder
Dateistart. Das Entfernen einzelner oder aller Einträge ändert nur die Liste;
geöffnete Projekte, ungesicherte Texte und Dateien bleiben erhalten.

`fastra-workflow::recent_projects` verwendet den vorhandenen internen
`store_file::PrivateStore`. Es gibt keine weitere Sicherheits-IO-Implementierung.
Die private Datei liegt unter `$XDG_CONFIG_HOME/fastra-recent-projects/library.json`
beziehungsweise `$HOME/.config/fastra-recent-projects/library.json`; das
Unterverzeichnis hat Modus 0700, Daten und Sperre Modus 0600. Die vorhandenen
Regular-File-, NoFollow-, Eigentümer-, Hardlink-, Sperr- und atomaren Schreibregeln
gelten weiter. Gespeichert werden nur Pfade, keine Dokumentinhalte.

Jede Mutation liest frisch. Ein konkurrierender CAS-Konflikt führt zu höchstens
sechs erneuten Merge-Versuchen. Fehler, eine belegte Sperre und ungültige
bestehende Daten werden sichtbar gemeldet und nicht mit einer leeren Liste
überschrieben. Das Menü lädt beim Öffnen frisch; bestehende Fenster müssen
keinen veralteten Gesamtstand zurückschreiben. IO läuft ausschließlich auf
Workern. Während eines Auftrags sind Listenaktionen gesperrt; gleichzeitig
abgeschlossene bewusste Projektwahlen werden begrenzt nachgeführt.

Grenzen: zwölf eindeutige absolute Pfade, jeweils höchstens 4096 Bytes ohne NUL,
256 KiB Storedatei. Nicht mehr vorhandene Projekte bleiben sichtbar und können
entfernt werden; „Öffnen“ zeigt den bestehenden Scanfehler. Es werden keine
Projekt-Suchkonfigurationen, Sammlungen oder Wiederherstellungsinhalte portiert.

Prüfung am 2026-11-05 mit Rust 1.99.1: fünf neue Backendtests und insgesamt
22 Workflow-Tests bestanden; Clippy für Workflow und GTK-Host mit allen Targets
und `-D warnings` bestanden. Die nativen Xvfb-Läufe auf Deutsch/Englisch bei
640/1100 Pixeln bedienen Menü, Öffnen, Entfernen, Leeren und Enter per XTest.
Geprüft wurden ein Nicht-UTF-8-Pfad, kein Autostart oder zusätzlicher Dateitab,
unbestätigtes Tippen und Scanfehler ohne Historieneintrag sowie erhaltene
Projektdateien. Menü und Projektansicht wurden schmal/breit visuell geprüft.
Private Testdaten und Bildbelege bleiben außerhalb der Produktquellen.
