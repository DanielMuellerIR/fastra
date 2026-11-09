# Dokumentgliederung und gemeinsamer Sprungverlauf

Die Quell- und Rich-Ansicht verwenden dieselben drei Knöpfe: vorheriger Sprung,
nächster Sprung und Dokumentgliederung. Das native Popup misst innen 320 × 340
Pixel. Es zeigt eingerückte Markdown-Überschriften oder 4D-Klassenfunktionen mit
Typ und Zeile. Ohne 4D-Funktionen erscheint der Methodenname. Der aktuelle
Eintrag folgt dem Source-Cursor beziehungsweise der tatsächlichen Rich-Auswahl.
Die Liste aktualisiert sich nach Text-, Format- und Titeländerungen automatisch
mit 150 ms Verzögerung. Virtualisierte Zeilen ersetzen Filter und Seitenwechsel.

Markdown-Titel stammen aus dem Quellbaum: ATX und Setext, Entities, sichtbare
Inline-Formate und originale Unicode-/CRLF-Positionen bleiben erhalten.
Code-/HTML-Blöcke erzeugen keine falschen Überschriften. 4D verwendet die
vorhandene lexikalische Analyse; Kommentare, Strings und SQL werden ausgespart.
Die vollständige Analyse läuft begrenzt und abbrechbar im Hintergrund: höchstens
10 MiB, 200.000 Zeilen, 10.000 Einträge, 16 KiB je Titel und bei Markdown
500.000 Parserereignisse. Die engeren [Rich-Grenzen](F15-RICH-EDITOR.md) gelten
weiter. Bei unvollständig prüfbarer Quelle erscheint keine Teilliste.

Ein Klick schließt das Popup und springt in der aktuellen Bearbeitungsart.
Source verwendet die zuletzt aktive Teilansicht, entfaltet das Ziel und führt
eine sichtbare statische Vorschau mit. Rich prüft vor dem tatsächlichen Sprung
nochmals WebKit-Sitzung, Eingaberevision und Überschriftenstruktur; native und
DOM-Prüfung gehören zusammen. Eine alte Antwort nach Tabwechsel und Rückwechsel
wird verworfen. Navigation verändert weder Text noch Undo-Historie.

Der gemeinsame Verlauf hält höchstens 100 Positionen in noch offenen Dokumenten.
Neue Sprünge verwerfen einen späteren Zweig. Unveränderte Revisionen behalten
ihre Auswahl. Nach Änderungen werden Überschriften nur bei eindeutigem Titel,
Typ und Ebene wiedergefunden; sonstige Positionen verwenden begrenzte Zeilen-
und Nachbarkontexte. Geschlossene Dokumente, umbenannte oder mehrdeutige Ziele
werden ausdrücklich abgewiesen. Rich-Überschriften bleiben in Rich. Sonstige
Quellpositionen wechseln über die reguläre, geprüfte Synchronisation zurück in
die Quellansicht. Alt-Doppelklick und der sichtbare Kontextmenü-Eintrag für
4D-/Markdown-Ziele verwenden ebenfalls den Verlauf. Gewöhnliche Suche und
Zeilen-/Spaltennavigation erhalten wie auf dem Mac keinen zusätzlichen
Verlaufseintrag. Die Markdown-Verweisprüfung verwendet für ihre ausdrücklichen
Quellsprünge denselben Verlauf.

`linux/test.sh navigation`, `outline-fallback` und `rich-outline` prüfen native
Maus-/Tastatureingaben, wiederholte Änderungen, Rückwärts/Vorwärts, Dokument-
und Moduswechsel, unveränderte Dateien und natives Undo. Die DE-/EN-Matrix bei
760/1100 Pixeln und hell/dunkel enthält tatsächliche X11-Popup-Aufnahmen.
Der reine Ankervertrag besitzt ausgeführte Swift-Foundation-Referenzen; Details
und bekannte unbeabsichtigte Referenzfehler stehen unter
[Build und Test](../BUILD-AND-TEST.md#linux-native-quelltext-gliederung-und-verlauf).
Die unabhängige [Quell-/Vorschau-Klicknavigation](F12-SOURCE-CODE.md) bleibt ein
separater Vertrag.

Die direkte Zielauflösung folgt den beiden vorhandenen Mac-Providern. Normale
4D-Funktionen müssen eindeutig sein; Accessoren werden ausdrücklich über die
Gliederung gewählt. Danach folgen Methoden-/Klassendateien aus den bekannten
Quellwurzeln und die literale Mehrdateisuche. Unter Linux werden unterschiedlich
geschriebene 4D-Dateinamen begrenzt gesucht; mehrere gleichwertige Namen werden
abgewiesen. Markdown verarbeitet Inline-Links/Bilder, Autolinks, nackte HTTP(S)-
Adressen und die vorhandenen ATX-Ankerregeln. Der Fragmentteil hinter einer
Datei wird beim Öffnen ignoriert; prozentkodierte Dateinamen bleiben erhalten.
Externe Adressen werden nur nach dem ausdrücklichen Klick an den Systembrowser
übergeben. Der reine Kern bewahrt das Linkliteral, GLib prüft und kanonisiert
die tatsächliche URI an der nativen Grenze.

Die Suchfallbacks ändern Muster, Literalmodus und versprochenen Bereich. Die
übrigen Optionen und die Dateitypwahl bleiben erhalten. Die gemeinsame enge
Whitelist bekannter Textformate enthält derzeit keine `.4dm`-Dateien; dafür ist
„Alle Dateien“ nötig. Beide Filterzustände prüfen weiterhin Binärdaten.

## Lokale Markdown-Verweise

Der modale Dialog folgt dem Mac-Sheet: Titel, Erklärung, Dokument-/Projektwahl,
Prüfen/Abbrechen, datierter Status, Problemfilter, virtualisierte Befundliste
und Schließen/Zur Quelle. Mindestgröße 640 × 600, Standardgröße 900 × 700;
Deutsch und Englisch sowie beide Erscheinungsbilder sind geprüft. Dieselbe
CRLF-Testdatei liefert dieselben vier lokalen Befunde wie der Mac-Selbsttest.

Die Prüfung bindet offene Quellen an ihre ursprüngliche Dokumentidentität,
Fassung und Pfad. Im Projekt gelten Ausschlüsse; offene Markdown-Puffer ersetzen
die zugehörige Plattenfassung. Versteckte Dateien, Pakete und Symlinkquellen
bleiben ausgeschlossen. Quellsprünge prüfen die Berichtsbasis erneut, verlassen
Rich über den regulären Synchronisationsweg und halten den gemeinsamen Verlauf.
Ein unter demselben Pfad neu geöffneter Tab ersetzt die ursprüngliche Identität
nicht. Geänderte Plattenquellen durchlaufen zusätzlich die Ladeprüfung.

Lokale Mounts werden vor dem nächsten Zugriff geprüft, Symlinks komponentenweise
aufgelöst. Netzadressen werden nur gezählt; Netzwerk- und unbekannte Dateisysteme
bleiben ungeprüft. Grenzen: 200 Dateien, je 10 MiB und 200.000 CR/LF-Zeichen,
64 MiB insgesamt, je 10.000 Verweise und Anker. Der Projektlauf begrenzt außerdem
Dateiliste, Tiefe und Laufzeit. Nicht unterstütztes HTML, überschrittene Grenzen
und Lesefehler ergeben ausdrücklich unvollständige Befunde. Die bisherigen
Snapshot-Beschränkungen auf lesbare Schreibmetadaten und einfach verlinkte Dateien
gelten derzeit auch hier; ein davon unabhängiger Leseweg bleibt offen.

`linux/test.sh references`, `references-project`, `references-rich`,
`references-guards`, `references-disk-guards`, `references-unverified` und
`references-mac` prüfen echte Menü-/Tastatur-/Listenwege. Die Unit-Regressionen
übernehmen Mac-Fälle für Anker, HTML, Formeln, CRLF, Dateikodierung, Projektpuffer,
Limits und Abbruch. Zusätzliche tatsächlich ausgeführte Foundation-Vektoren
schützen die Schreibweise prozentcodierter Trenner und die `file:`-URL-Auflösung.
