# Gespeicherte Code-Erklärungen unter Linux

„Werkzeuge → Gespeicherte Codefrage öffnen …“ öffnet ein vorhandenes lokales
Snapshotpaket im eigenen schreibgeschützten Fenster. Das Format entspricht dem
vorhandenen Mac-Player: Schema 1, eine bis fünf UTF-8-Quellen und zwei bis fünf
Schritte. Jede Quelle ist an ihren ursprünglichen SHA-256 einschließlich eines
eventuellen UTF-8-BOM gebunden. Titel, Frage, Erklärung, Quellen- und Schrittwahl,
Zurück, Weiter, Pause und die ausdrückliche Rückkehr bleiben zugänglich.
Schriftgrößen und weicher Umbruch gelten nur für dieses Fenster.

Der Leser hält das Paketverzeichnis und öffnet relative Pfadkomponenten ohne
Symlinkverfolgung. Manifest, Quellen und Gesamtpaket sind auf 64 KiB, 256 KiB
beziehungsweise 1 MiB begrenzt. FIFOs, Verzeichnisverweise, ungültiges UTF-8,
falsche Hashes, unbekannte Schemas, doppelte IDs und ungültige Markierungen
werden erklärt zurückgewiesen. Es werden keine Dateien geschrieben oder
Erklärungsinhalte ausgeführt. Höchstens 16 Fenster einschließlich laufender
Ladevorgänge dürfen gleichzeitig bestehen; Schließen oder Abbrechen verwirft
späte Ladeergebnisse.

Geladene Quellen bleiben unveränderlich im Speicher, auch wenn sich die Datei
anschließend ändert. Jedes Fenster und jede Quelle erhält eine frische
Laufzeitidentität. Navigation bindet diese Identitäten, Quellenhash, Schritt und
Generation. UTF-16-Bereiche dürfen keine Graphemgrenzen durchschneiden. „Bereit“
setzt den tatsächlich dargestellten Quelltext, die vollständige Auswahl und die
sichtbare Zielposition voraus. Eingaben, Scrollen, andere Quellen, Schriftgröße
oder Umbruch pausieren ausstehende Navigation; eine alte Layoutantwort kann
danach keine Markierung erneut anwenden. Zurückkehren erfolgt ausdrücklich.

Die Fenster gehören nicht zum normalen Dokument-/Speicherpfad. Ctrl+W schließt
nur das Erklärungsfenster. Ungesicherte Arbeitsdokumente und ihre Einstellungen
bleiben erhalten. Es gibt keine eingebettete KI, Netzwerkverbindung oder neue
Schreibschnittstelle. Der externe Mac-Controller über AppleEvents ist damit
noch nicht portiert; eine Linux-Lokalsteuerung bleibt ein eigener Schritt.

Der Parser besitzt Referenzfälle aus tatsächlich ausgeführtem Mac-Foundation
für Datum, UUID und UTF-16-/Graphemgrenzen. Die native Prüfung verwendet die
wirkliche Werkzeuge-Schaltfläche und Dateiauswahl sowie Quellwechsel, Navigation,
Pause, Umbruch, Schriftgrößen, unveränderliche Quellen, Schreibschutz und
Fensterneustart auf Deutsch und Englisch bei 400 und 1100 Pixeln Fensterbreite.
Ein isolierter X11-Lauf ersetzt keine Desktop-/Wayland-/IME-Abnahme.


## Mac-Aufteilung ab 1.226.0

Snapshotfenster zeigen Dateiname und Status in einer gemeinsamen Kopfzeile.
Der Quellbereich reicht darunter bis zum Fensterrand; zusätzliche Zeilennummern
und der breite Schließen-Fuß entfallen wie auf dem Mac. Schließen bleibt über
die native Titelleiste und Ctrl+W erreichbar. Herkunftsangaben behalten ihre
gesonderte, begrenzte und scrollbar lesbare Fläche.

Der Player zeigt unter dem Quellbereich Schritttitel und Erklärung. Die untere
Bedienung besteht aus Schrittwahl, Fortschritt und Schriftsteuerung sowie einer
zweiten Zeile mit Zurück, Weiter, Pause, Rückkehr, Soft Wrap und Beenden.
Unter 580 logischen Breitenpunkten ersetzt ein Menü die Schriftknöpfe; unter
470 verkürzen eindeutig beschriftete Symbole mit Hilfetext die drei
Navigationsknöpfe. Vergrößerte Oberflächenschriften berücksichtigen diese
Grenzen. Bei sehr schmaler vergrößerter Bedienung wechseln Soft Wrap und Beenden in
eine weitere Zeile, damit ihre sichtbaren Beschriftungen erhalten bleiben. Ein nativer Viewport
verhindert, dass die kurz zuvor sichtbare breite Variante eine kleinere
Fensterbreite blockiert. Es entsteht kein zusätzlicher horizontaler Scrollbalken.
Die erste Teilung wird bei stabiler Zuweisung auf 44 Prozent gesetzt; spätere
Höhenänderungen vergrößern den Erklärungsteil und erhalten die Benutzerteilung.

Die zusätzliche Linux-Quellauswahl liegt am Dateinamen. Die zugehörige Frage
steht im selben Popover; Schritttitel und Dateiname bieten die vollständigen
Metadaten als Hilfetext. Auswahl einer anderen eingefrorenen Quelle pausiert
weiterhin die Navigation. Quellen, Dokumentidentitäten, SHA-256, UTF-16- und
Graphemprüfung sowie die sichtbare Bestätigung von Zielauswahlen bleiben
unverändert.

Paketgrößen bezeichnen logische Mac-Größen. Absolute Pango-Schriftgrößen
vermeiden die frühere zusätzliche Umrechnung von Punkten in 96-dpi-Pixel.
Der native Gegenversuch zeigte ein 10 Pixel breites Prüfzeichen bei Größe 12
gegenüber 8 Pixeln in der 13-Pixel-Quellrolle. Korrigiert sind es 7 Pixel;
Größe 13 entspricht der 13-Pixel-Rolle. Die nativen Bedienprüfungen verwenden
die echten schmalen Menüknöpfe und breiten Schriftknöpfe, prüfen ihre sichtbaren
Grenzen sowie Pause, Rückkehr, Quellwechsel und unveränderte Arbeitsdokumente.
