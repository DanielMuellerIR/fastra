# F07: native Quellfarben

Ab 1.186.1 bestimmen eingebundene Quellansichten ihr Adwaita-Farbschema aus
der tatsächlichen nativen Fensterfarbe. Eine dunkle Desktopvariante muss dafür
keine zusätzliche GTK-Dunkelpräferenz setzen. Änderungen von Theme oder
Dunkelpräferenz aktualisieren beide sichtbaren Quellansichten; eine verborgene
Ansicht übernimmt den aktuellen Zustand beim nächsten Einblenden.

Die Abfrage erfolgt am Fenster, weil die Quellansicht selbst bereits die Farbe
ihres gesetzten Syntaxschemas enthält. Vor dem Einbinden ist ihre Farbe noch
kein verlässlicher Themebeleg. Settings-Beobachter leben nur während des
Einblendens, enthalten schwache View-/Bufferreferenzen und werden beim
Ausblenden getrennt.

Zwei native Regressionen bestehen: `Adwaita-dark` ohne `GTK_THEME` und ohne
Dunkelpräferenz einschließlich Laufzeitwechseln, sowie `GTK_THEME=Adwaita:dark`.
Beide Ansichten behalten Text, gerichtete Auswahlen, Dirty, Revision und Undo.
Die alte Heuristik scheitert im identischen ersten Test am hellen Schema.
Dunkle und helle Syntaxansichten wurden angesehen. Das optimierte Paket
besteht zusätzlich auf einem physischen dunklen Cinnamon-/X11-Desktop Start,
Splitansicht, Speichern und exakte Undo-Rückkehr aus Source B.

Dies wählt die vorhandenen Syntaxschemata passend zum nativen Erscheinungsbild;
es führt keine neue Themeauswahl ein. Die allgemeine Desktop-/IME- und
Screenreader-Abnahme bleibt separat.


## Appweite Quellschrift ab 1.221.0

Die Editoroptionen bieten wie die Mac-Schriftwahl installierte Festbreitenschriften
mit ihren Schnitten an. Pango-Familien müssen als monospaced ausgewiesen sein;
reguläre, fette und kursive Schnitte behalten ihre jeweiligen Eigenschaften.
Eine gemeinsame Prozessinstanz versorgt die Quellansichten aller Fenster über
einen Display-Provider. Text, Kodierung, Zeilenenden und Source-Revision werden
nicht geändert; Pango-Kontextänderungen lösen die vorhandene Neuberechnung der
Umbruchgeometrie aus. Die vorgegebene Schriftgröße bleibt 13 px.

Die Wahl liegt getrennt in `fastra-editor/source-font.json` unter XDG-Config.
Der vorhandene abgesicherte Konfigurationsspeicher liest und schreibt im
Hintergrund, mit Eigentums-/Modus-/Linkprüfung, begrenzten Daten, exklusiver
Sperre und atomarer Ablage. Der Schriftrecord ist auf 4 KiB begrenzt;
Schriftnamen sind begrenzt und im Dialog mit vollständigem Hilfetext gekürzt. Defekte oder unbekannte Schemafassungen werden nicht
überschrieben. Eine nicht mehr installierte Schrift wird als eigener fehlender
Eintrag sichtbar; bis zur ausdrücklichen neuen Wahl gilt System-Monospace.
CSS wird ausschließlich aus tatsächlich gefundenen Schriftbeschreibungen
gebildet; fremde gespeicherte Namen werden nicht als CSS übernommen.

Laufende Speichervorgänge werden vor dem Beenden abgewartet. Ein Fehler der
Darstellungseinstellung bleibt sichtbar und erneut versuchbar, blockiert aber
nicht dauerhaft das Schließen unveränderter Dokumente. Es werden keine
Systemschriften installiert oder weiterverteilt. Die vollständige optische
Gesamtabnahme bleibt ein eigenes offenes Kriterium.


## Getrennte Größen ab 1.225.0

„Einstellungen …“ und Ctrl+, öffnen die globale Schrift-/Größenwahl auch ohne
Dokument. Das Menü „Darstellung“ und native Knöpfe verwenden dieselben Aktionen.
Die Mac-Stufen bleiben erhalten: Oberfläche −3 bis +5 mit Faktor 1 + Stufe × 0,13,
Dokumenttext −4 bis +8 mit Faktor 1 + Stufe × 0,12. Die zentrale GTK-Stildatei
behält ihre Schriftrollen; nur ihre Pixel-Schrift-/Symbolgrößen werden skaliert.
Dokumentquellansichten haben eine gesonderte, von der Oberfläche unabhängige
Schriftgrößenrolle. Die Schriftfamilie bleibt weiterhin eine getrennte Wahl.

Ctrl +/−/0 verändert die Oberfläche; Ctrl Shift +/−/0 den Dokumenttext.
GTKs Accelerator-Abgleich verbraucht Shift beim Pluszeichen. Deshalb ordnet ein
Fenstercontroller die drei Größentasten anhand der nativen GDK-Tastaturbelegung
ohne Shift zu und aktiviert dieselben GActions wie die sichtbaren Knöpfe.
Andere Modifier bleiben unberührt; es gibt keine eigene Tastaturbelegung.
Die native deutsche Belegung ist gesondert geprüft.

Markdown-Vorschau und Rich-Markdown verwenden WebKits reine Textvergrößerung.
Die native DOM-Prüfung beobachtet in beiden Produktionsansichten höhere
Textrechtecke bei unverändertem Bildrechteck. Beide Quellausschnitte, weitere
Fenster und schreibgeschützte Quelltexte übernehmen ihre Größe gemeinsam.
Auswahl, Source-Revision, Inhalt, Undo und Quelldateien bleiben unverändert.
Vergleiche folgen der Oberflächengröße und richten ihre Zeilen nach Änderungen
der Pango-Schriftmetriken erneut aus. Vor der Höhenmessung wird das tatsächliche
GTK-Textlayout angefordert, damit außerhalb des sichtbaren Ausschnitts keine
vorläufige einzeilige Schätzhöhe als Umbruchhöhe verwendet wird.

`fastra-editor/zoom.json` unter XDG-Config enthält beide Stufen in einem auf
4 KiB begrenzten, strikt geprüften Record. Der bestehende sichere Speicher
schützt Verzeichnisse, Eigentümer, Symlinks, exklusive Sperren und atomare Ablage.
Schreiben läuft im Hintergrund; rasche Änderungen werden zur jüngsten Wahl
zusammengeführt. Eine Application-Haltefrist schützt noch ausstehende
Schreibarbeit auch nach dem Schließen des Einstellungsfensters. Fehler erhalten
die vorhandene Datei, sind sichtbar und erneut versuchbar, blockieren aber
nicht dauerhaft das Schließen von Dokumenten. Native Zwei-Prozess-Prüfungen
belegen Wiederherstellung, Schreibschutz sowie gesperrte und beschädigte
Einstellungen. Die Einstellungsansicht wird bei Mindest- und Höchststufe in
Deutsch/Englisch und hell/dunkel visuell geprüft.

Kontrollierte Snapshots und der Code-Erklärplayer verwenden ebenfalls das
zentrale Quellfarbschema. Die vorhandenen eigenen Größenregler des Players
bleiben erhalten. Die vollständige optische Gesamtabnahme bleibt offen.


## Appweites Erscheinungsbild ab 1.227.0

Das Zahnrad, Ctrl+, und „Einstellungen …“ öffnen auch auf der Startseite die
gemeinsamen Einstellungen. „Automatisch“, „Hell“ und „Dunkel“ entsprechen der
Mac-Auswahl. Die zentrale Palette gilt für Dokument- und Werkzeugfenster,
Popover und Quellfarbschemata. Die beiden manuellen Varianten übersteuern die
Desktopvorgabe innerhalb von Fastra. „Automatisch“ gibt die prozesslokale
GTK-Dunkelpräferenz frei und beobachtet Änderungen des GTK-Erscheinungsbilds.
Ein ausdrücklich gesetztes `GTK_THEME` bleibt Teil dieser automatischen
GTK-Vorgabe. Desktop-Einstellungen und Prozess-Umgebungsvariablen werden nicht
geändert. Externe Portal-Dateidialoge gehören weiterhin dem Desktop.

`fastra-editor/appearance.json` unter XDG-Config verwendet denselben sicheren
Store wie die übrigen Editorpräferenzen: strikt geprüftes Schema 1 und Mode,
maximal 4 KiB, Eigentums-/Modus-/Linkprüfung, atomare Ablage und exklusive Sperre.
Die IO läuft im Hintergrund und führt rasche Änderungen zur jüngsten Wahl
zusammen. Eine Haltefrist schützt noch ausstehende Schreibarbeit; permanente
Fehler bleiben erneut versuchbar und blockieren Dokumente nicht dauerhaft.

Native Quellansichten ändern ausschließlich ihr Schema. Vorschau und Rich-Editor
aktualisieren CSS und Hintergrund im bestehenden Web-Dokument. Text und Bilder
werden nicht neu importiert; Schrift- und Dokumentzoom bleiben unabhängig.
Die Vorschau serialisiert Themewechsel ihrer vorhandenen Mermaid-Diagramme;
überholte Renderergebnisse können die letzte Wahl nicht überschreiben.
Ungültige Diagramme behalten ihren ursprünglichen Quellblock und Fehlerhinweis.
Die erste Diagrammdarstellung verwirft keinen bereits wartenden Quellsprung.

Die nativen Prüfungen wechseln Licht/Dunkel gegen die jeweilige Desktopvorgabe,
beobachten tatsächliche Quell- und DOM-Farben sowie bestehende Diagramme und
prüfen einen hellen nativen Popup auf dunklem Desktop. Eine echte Rich-Eingabe
behält über beide Farbwechsel ihren Quelltext, ihre Revision, Dirty, Auswahl
und Undo-Fähigkeit; anschließendes Undo stellt den vorherigen Inhalt wieder her.
Ein frischer Prozess stellt die Wahl wieder her. Startseitenzahnrad, beschädigte
Einstellungen und ein fehlgeschlagener Speicherversuch mit sichtbarem Retry
werden getrennt ausgeführt.

## Gruppierte Einstellungen ab 1.229.0

Erscheinungsbild, Schrift/Größe und Editor folgen der gruppierten Mac-Form mit
13 px großen normalen Beschriftungen, getrennten Zeilen und Sektionen. Die
bevorzugte Fenstergröße ist 680 × 720, die Mindestgröße 480 × 380; beide folgen
der Oberflächenskalierung. Der Inhalt scrollt vertikal. Ein zusätzliches
Schließen-Feld unten entfällt; Titelleiste und Ctrl+W/Escape bleiben verfügbar.
Weitere Mac-Einstellungsbereiche sind damit noch nicht als portiert erklärt.

Die vertikalen GTK-Regler zeigen ihren Wert in der Zeilenbeschriftung. Maus,
Pfeiltasten und natives Gedrückthalten verstellen denselben Wert. Die internen
Textdelegationen bleiben für GTK im Layout; freie Texteingaben werden abgefangen.
Schriftwahlen kürzen lange Namen mit vollständigem Tooltip. Meldungen erscheinen
bei Laden, Speicherung oder Fehlern und verdrängen keine dauerhaft benötigten Felder.

Die appweite Seitenlinie ist zusätzlich hier erreichbar. Änderungen publizieren
an alle vorhandenen Quellansichten und verwenden die bestehende geordnete
Profilwarteschlange; ein Dokument als Auftragseigentümer ist nicht erforderlich.
Die atomare Änderung lädt den aktuellen Speicher erneut und erhält andere
Formatfelder. Fehler behalten den Auftrag und zeigen einen erneuten Versuch.
Vor Schließen werden die vorhandenen Regler übernommen; aktive Schreibvorgänge
halten weiterhin die Anwendung. Ein beschädigter Speicher wird nicht ersetzt.
Quelltext, Auswahl, Änderungszustand und Undo/Redo werden nicht angefasst.

Die native Prüfung beobachtet zusätzlich die tatsächlich zugestellte Mausposition
an den kleinen Pfeilen. GTK 4.14.5 lieferte bei dekorierten Fenstern einen
Surface-Versatz von 4 px; die frühere doppelte Subtraktion im gemeinsamen
Prüfhelfer verfehlte das Ziel um 8 px. Der inverse Weg addiert den Versatz.
Das ist eine Korrektur der Eingabesimulation, keine Änderung der Produkteingabe.
