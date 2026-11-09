# Nativer lesender Ordnervergleich

Stand: 2026-11-05. „Werkzeuge → Ordner vergleichen …“ bindet den bereits
vorhandenen begrenzten `fastra-diff::folder`-Kern an GTK. Zwei native Ordnerwahlen
bewahren die Rohpfade. Die Pfadanzeigen sind nicht editierbar; ungültige UTF-8-
Bytes und Steuerzeichen werden dargestellt, ohne daraus später Pfade abzuleiten.

Die Liste zeigt bytegleiche, unterschiedliche, nur links/rechts vorhandene und
nicht prüfbare Einträge. Versteckte Einträge bleiben ausgeschlossen. Symlinks
und Sonderdateien werden angezeigt und nicht verfolgt. Verzeichnisse werden
mitgeführt; eine unvollständige Struktur wird nicht als sichere Abwesenheit der
Gegenseite behandelt. Vergleich und abschließende Dateistandsprüfung laufen auf
Workern, Abbruch und neue Wurzeln verwerfen alte Antworten.

Status- und Textfilter ändern ausschließlich die sichtbaren Ergebnisse. Der
Textfilter verwendet die kleingeschriebene dargestellte Pfadfolge; er ist kein
Glob- oder Suchkernfilter. Die Berechnung erfolgt abbrechbar im Hintergrund.
Seiten mit höchstens 100 nativen Zeilen halten auch große Ergebnislisten
bedienbar. Grenzen des Vergleichs bleiben insgesamt 20.000 Einträge, 256 MiB
je Datei und 2 GiB gelesene Dateibytes sowie die vorhandenen Tiefen-/Speicherbudgets.
Grenzfehler liefern kein scheinbar vollständiges Ergebnis.

„Links öffnen“ und „Rechts öffnen“ verwenden den normalen Dokumentloader.
„Textpaar vergleichen …“ liest beide ausgewählten Dateien neu. Die Liste ist
eine erklärte Momentaufnahme und keine Schreibfreigabe. Nicht reguläre oder
inzwischen aus den gewählten Wurzeln führende Quellen werden abgewiesen.
Binär-/Abschnittsdateien und Textpaare über 4 MiB erhalten eine klare Ablehnung.
Die linke Quelle wird als neuer, sauberer Tab mit ihrem tatsächlichen Snapshot,
Encoding und BOM geöffnet; rechts verwendet der bestehende Dateivergleich den
Rohpfad und eine erneute Quellenprüfung. Eine Blockübernahme braucht dessen
eigene vollständige Vorschau und wirkt zunächst nur auf den neuen Editor.
Die ursprünglichen Dateien bleiben unverändert. Änderungen an Auswahl,
Wurzeln, Besitzer oder Zielzustand verhindern verspätetes Öffnen eines Paars.

## Beleg und Grenzen

Vier native Läufe auf Deutsch/Englisch bei 640/1100 px bestehen mit Rohpfaden,
Byte- und Statusunterschieden, Sonderdateien, ausgeschlossenen versteckten
Dateien, Seitennavigation über mehr als 100 Einträge, Filtern und Auswahl.
Ein nach der Ordneraufnahme geändertes rechtes Dokument erscheint frisch im
Dateivergleich. Text, Dirty-Flag, Undo und beide Plattenquellen werden geprüft;
Rootwechsel und Abbruch lassen keine alte Antwort wieder auftauchen. Die
Ordner- und Textpaaransichten wurden in beiden Sprachen visuell geprüft.

Vorab-Ausschlussmuster, Beschränkung der gescannten Dateitypen, detaillierter
Scanfortschritt und ein externer Diff-Helfervertrag bleiben offen. Ein Filter
auf der Ergebnisliste ersetzt diese Scanoptionen nicht. Es gibt keine
Ordnersynchronisation und keinen Kopier-/Löschbefehl zwischen den Bäumen.
