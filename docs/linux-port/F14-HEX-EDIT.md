# Optionaler Linux-Hexentwurf

Die bestehende abschnittsweise Hex-/Textansicht bleibt der Einstieg. „Hex
bearbeiten …“ öffnet einen eigenen, ausdrücklich optionalen Entwurf für Dateien
bis 32 MiB. Größere Dateien bleiben abschnittsweise lesbar. Eine vollständige
Streaming-Bearbeitung ist damit nicht behauptet.

## Sicherheitsgrenze

Eine gehaltene Dateibasis enthält die Originalbytes und den bestehenden
`fastra-io::Snapshot`. Änderungen an 16-Byte-Zeilen bleiben ausschließlich im
Modell, höchstens 4096 geänderte Bytes und 4096 Undo-Schritte. Die Dateilänge
bleibt unverändert. Nicht vorgemerkte Feldeingaben sperren Navigation, Undo,
Vorschau, Speichern und Druck. Das Verbergen des Fensters erhält den Entwurf;
ein schmutziger Hexentwurf verhindert das Schließen des Hauptfensters.

Vorbereitung friert Revision und Änderungsliste ein. Ein Worker prüft die
vollständige Dateiidentität erneut und baut die Ausgabe sowie eine vollständige
Offset-/Alt-/Neu-Tabelle. Der Raw-Pfad wird eindeutig escaped angezeigt. Eine
frische ausdrückliche Zustimmung ist Voraussetzung für die Übernahme. Jede
Eingabe, Undo/Redo oder neue Dateibasis verwirft Plan und Zustimmung. Owner und
Host-Epoch verhindern auch eine alte Freigabe bei wiederholter Modellrevision
nach Rebase. Abgebrochene Jobs dürfen keine späten Ergebnisse veröffentlichen.

Speichern verwendet ausschließlich `Transaction::save_document` des vorhandenen
IO-Kerns. Andere schmutzige Text-/Hex-Tabs derselben Datei sperren den Vorgang.
Nach dem Schreiben prüft der Host Ausgabebytes und Abschnittsidentität, bevor
das Journal bereinigt wird. Jeder Fehler in dieser Phase bleibt als
`RecoveryRequired` mit Journalpfad sichtbar und im Wiederaufnahmeindex erhalten.
Erfolg ersetzt Snapshot, Abschnittsansicht und Entwurfsbasis; Undo beginnt neu.
Saubere andere Textansichten werden aus dem verifizierten Snapshot aktualisiert.

Die Elternansicht und ihr Druckpayload zeigen vorgemerkte Entwurfsbytes als
solche; die Datei bleibt bis zur Freigabe unverändert. Nicht vorgemerkte
Feldeingaben werden nicht als druckbarer Entwurf ausgegeben. Hexentwürfe werden
nicht durch die optionale Textsitzung persistiert.

## Referenz und Prüfung

Das reine Modell folgt `HexEditing.swift`. Acht Modelltests enthalten 117 mit
Swift erzeugte Parserfälle und fünf Edit-/Undo-/Redo-Verläufe. Der vollständige
Unicode-Skalar-Scan und 27.849 zusätzliche Differentialfälle prüfen die
Swift-Graphem-Whitespace-Semantik; unter anderem bleiben `+1`, `+F` und `-0`
kompatibel. Herkunft und reproduzierbare kleine Runner stehen unter
`crates/fastra-linux/tests/hex-reference/`.

Der native Test `linux/test.sh hex` läuft nur auf einem ausdrücklich isolierten
Display. Er prüft echte Zeileneingabe, Vormerken, Zustimmung und Speichern mit
XTest sowie Abbruch beim initialen Laden, ungültige Eingabe, Close-/Druckschutz,
seitenübergreifende Änderung, Undo/Redo, vollständige Vorschau, externe Änderung,
Verbergen/Wiederöffnen und neue Basis nach atomischem Speichern. Deutsch und
Englisch werden bei schmaler und breiter Ansicht geprüft. Dies ersetzt weder
einen Langzeittest noch die vollständige Desktop-/IME-Abnahme.

Der Reviewbefund zum Elternverzeichnis-ABA ist durch einen gemeinsamen
Dev/Inode-/Größenvergleich zwischen Snapshot, neuer Abschnittsansicht und
initialer Elternansicht geschlossen. Ein gezielter Hosttest belegt den
vorher möglichen Mischzustand selbst bei bytegleichen Dateien. Der echte
Behalten-/Verwerfen-Dialog besteht zusätzlich XTest in allen vier Varianten.

## Gespeicherte Textdateien und andere Dateimodi

„Werkzeuge → Dateibytes in neuem Hex-Tab …“ öffnet den Plattenstand auch
für normale Textdateien und Bild-/PDF-Vorschauen. Der bestehende Tab einschließlich
ungesichertem Text bleibt erhalten. Neue ungesicherte Texte werden sichtbar
abgewiesen; ein bereits existierender Hexentwurf wird wieder geöffnet. Ein
verspäteter Ladeauftrag erzeugt nach Tab-/Revisions-/Pfadwechsel keinen Tab.
Die gemeinsame Abschnittsansicht besitzt einen einzigen Aufbaupfad.

Der native Test `linux/test.sh hex-routes` prüft den sichtbaren Werkzeugeintrag,
die erhaltenen schmutzigen Quellbytes, einen fremden aktiven Tab, die Sperre
gegen einen schmutzigen anderen Tab und den späteren atomaren Save. Der
anschließende Rückabgleich eines sauberen Latin-1-Tabs behält dessen explizite
Zeichenkodierung statt erneut automatisch als UTF-8 zu interpretieren. Beide
Sprachen und schmale/breite Fenster bestehen den Lauf.
