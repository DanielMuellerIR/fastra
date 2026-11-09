# F14 – Nativer Linux-Druck

## Verhalten

Das Menü „Drucken“ und `Ctrl+P` öffnen den nativen Druckdialog für die aktuelle Ansicht. Quelltext und gerenderte Markdown-Vorschau sind zusätzlich ausdrücklich wählbar. PDF-Ausgabe erfolgt im Druckdialog; ein eigener PDF-Exportbefehl wurde nicht eingeführt. Ohne bestätigten Dialog schreibt der Produktionspfad keine Druckdatei und sendet keinen Druckauftrag.

Quelltext nutzt GTK PrintOperation, Pango und Cairo. Er wird vollständig mit Wortumbruch paginiert; der Fastra-Reiter schaltet Zeilennummern und Kopf-/Fußzeilen. Hex druckt den aktuell sichtbaren, beschrifteten Byteabschnitt ohne Zeilenumbruch. Auch große Textdateien drucken nur den geladenen Abschnitt, nicht unbemerkt die ganze Datei. Die Druckkopie vereinheitlicht CRLF/CR für die Seiteneinteilung; Editor, BOM und Originalbytes bleiben unverändert.

Bilder, SVG und PDF nutzen den bereits isolierten Viewer-Decoder. Jede Druckseite wird einzeln außerhalb von GtkMain berechnet; GTK wartet über `set_defer_drawing`/`draw_page_finish`. Quellidentität und Abbruch gelten vor und nach der Dekodierung. PDF druckt sämtliche gewählten Seiten ohne zusätzliche Fastra-Kopfzeile. Bilder erhalten Dateititel und Seitenzähler.

Markdown und Rich drucken die vorhandene native WebKit-Ansicht. Rich synchronisiert vor der Vorbereitung vollständig in den Quellpuffer und hält die JS-Eingabesperre. Die Dokumentbedienelemente sind während des Auftrags gesperrt, die Vorschau rendert nicht neu. Der Auftrag bindet Dokumentinstanz, Revision, Modusinstanz und bei der Vorschau den fertig dargestellten Render-Token. Ein veralteter oder noch ladender DOM wird nicht gedruckt. Vorbereitung und Aufräumen wirken auf die erzeugende Ansicht; eine verspätete Completion übernimmt keinen anderen Tab. Temporäre Druckstile und Sperren werden bei Erfolg, Abbruch und Fehler aufgehoben.

## Grenzen

- Quelltext/Abschnitte: höchstens 2 MiB, 64 KiB pro logischer Zeile, 25.000 dargestellte Zeilen und 1.000 Seiten. Die Paginierung bearbeitet maximal 64 logische Zeilen pro GTK-Aufruf. Fehlende Schriftglyphen brechen den Pango-Quelltextdruck sichtbar ab. Hex benötigt ausreichend breite Papierfläche; seine Zeilen werden nicht abgeschnitten oder umbrochen.
- Bild/PDF: begrenzte RGB-Rasterbilder bis 4.000 Pixel Kantenlänge und 16 Megapixeln, jeweils eine ausstehende Seite. Originale PDF-Vektoren, durchsuchbarer PDF-Text und individuelle Originalpapierformate bleiben nicht erhalten. Die gewählte Druckpapierfläche bestimmt die Einpassung. Diese Einschränkung steht im nativen Fastra-Druckreiter.
- WebKit: höchstens 2 MiB DOM-Text, 50.000 Elemente, 10.000 Text-/Tabellenblöcke, zwölf Spalten je Tabellenzeile und begrenzte Bildpixel. Breite Tabellen und komplexe Dokumente können abgewiesen werden. Im geprüften WebKit werden mehrseitige Tabellenköpfe trotz Print-CSS nicht zuverlässig wiederholt; alle geprüften Zeilen bleiben lesbar. Rich zeigt geschützte Blöcke entsprechend seiner Editoransicht, während die Markdown-Vorschau Formeln und Mermaid gerendert druckt.
- Systemschriften bleiben Voraussetzung. Die private Sichtprüfumgebung ergänzte Noto Color Emoji; das Produkt bündelt keine Schriften. Physische Drucker, Treiber, Papierzufuhr und Desktop-Portale wurden nicht abgenommen.

Die GTK-Seiteneinteilung und der WebKit-Druckpfad sind bewusst nativ. Dieser Stand beansprucht keine vollständige Parität mit dem macOS-PDFKit-Druck.

## Prüfung am 2026-11-05

Privater Ubuntu-24.04-Container, Rust 1.99.1, GTK/WebKitGTK aus den vorhandenen Paketimages, ICU 78.3 mit Basis-x86-64-Runtime. Xvfb und private D-Bus-Konfiguration; kein Benutzerdesktop, kein Host-CUPS, kein Netzwerk und kein Abschalten der inneren WebKit-Sandbox. Die Laufzeit erhielt nur Programm, ICU, Test-D-Bus-Konfiguration und synthetische Dateien; kein Quellbaum und keine Build-Ressourcen.

Der echte GUI-Selbsttest öffnete Quelltext, Hex, SVG und ein dreiseitiges PDF über die Anwendung, aktivierte Markdown- und Rich-Modus und erzeugte zwölf native PDFs in Deutsch/Englisch: Quelltext je drei Seiten, Hex je zwei, SVG je eine, PDF je drei, Markdown je drei und Rich je eine. Insgesamt 26 Seiten wurden gerastert und visuell geprüft. Alle 70 Tabellenwerte und 128 Hex-Offsets erscheinen je Sprachfassung genau einmal; Endmarkierungen von Quelltext, Markdown und Rich bleiben erhalten. Unicode, Akzente, griechische Zeichen und echte Emoji-Fallbackglyphen sind sichtbar. Die PDFs enthalten kein JavaScript. Quelldateien und Rich-Quellpuffer blieben byte-/textgleich.

Zusätzlich wurden der tatsächliche `Ctrl+P`-Dialog und der Fastra-Reiter geöffnet und abgebrochen. Veralteter Owner, identische Bytes unter neuer Inode, überschrittenes Textbudget und veralteter WebKit-Owner brechen sichtbar ab, ohne den alten Quellstand als neuen zu übernehmen. Die Wiederherstellung der gesperrten Dokumentbedienelemente wird geprüft. Debug-PDF-Zielpfade und synthetische Fixtures sind ausschließlich mit `debug_assertions` kompiliert; Release hat nur den Dialogpfad.

`cargo check --release --offline --locked -p fastra-linux` und `cargo clippy --offline --locked -p fastra-linux --all-targets -- -D warnings` wurden im isolierten Builder ausgeführt. Quellidentität und letzte Ergebnisse stehen beim Handoff; das ist kein Beleg für später zusammengeführte Änderungen oder ein bereits gebautes Releasepaket.

## Schnittstellen und Quellen

`print_view.rs` enthält Auftrag, Paginierung und GUI-Selbsttest. Die Viewer-Brücke liefert einen gebundenen `Source`-Klon, Seitenzahl und begrenztes `render_print_page`; `DocumentView::print_text` liefert ausschließlich den bereitstehenden aktuellen Abschnitt. Die neue direkte Rust-Abhängigkeit `pangocairo = "=0.22.9"` verwendet die vorhandenen Pango/Cairo-Versionen; ihre beiden Crates enthalten vollständige Lizenztexte und werden vom vorhandenen Rust-Lizenzinventar erfasst.

Die verwendeten Protokolle folgen [GTK PrintOperation](https://docs.gtk.org/gtk4/class.PrintOperation.html), insbesondere verzögertem Zeichnen und inkrementeller Paginierung, sowie [WebKit PrintOperation](https://webkitgtk.org/reference/webkit2gtk/2.36.6/WebKitPrintOperation.html) mit getrenntem Fehler-/Fertigsignal. Die tatsächlichen GTK4/WebKit6-Rustsignaturen wurden gegen die gepinnten Crates geprüft.

## Gemeinsame Druckvorgaben ab 1.235.0

**Einstellungen → Drucken** folgt den vier Mac-Feldern: Zeilennummern,
Kopf-/Fußzeilen und Syntaxfarben sind standardmäßig an; die Druckschrift hat
10 pt und erlaubt 6 bis 18 pt. Die Vorgaben werden in `printing.json` im
privaten Konfigurationsstore gesichert. Feldänderungen lesen unter dem
vorhandenen atomaren Schreiblock neu ein und erhalten andere Felder.
Beschädigte, unbekannte, verknüpfte, zu große oder gesperrte Daten werden nicht
überschrieben. Fehler zeigen einen erneuten Versuch. Nicht geladene oder noch
laufende Vorgaben geben keinen Druck mit stillen Ersatzwerten frei.

Die Checkboxen des nativen Fastra-Druckreiters ändern dieselben Vorgaben,
auch wenn der Druck anschließend abgebrochen wird. Der laufende Auftrag hält
dagegen seine eigenen Dialogwerte und die beim Öffnen gebundene Schriftgröße;
Änderungen in einem anderen Fenster schreiben sie nicht nachträglich um.
Hex hat keine Zeilennummern, Bild/PDF keine Syntaxfarben und PDF keine eigene
Dekoration. Bildausdrucke bieten Kopf-/Fußzeilen. Papiergröße und Ausrichtung
bleiben im nativen GTK-Druckdialog.

Quelltext übernimmt die gewählte installierte Festbreitenschrift. Die
Syntaxfarben entstehen aus einer eigenen GtkSourceView-Textkopie mit dem
hellen Fastra-Farbsatz und der gewählten Sprache. UTF-8-Bytebereiche werden in
Pango-Attribute übertragen; die vorhandene Umbruch- und Seiteneinteilung bleibt
erhalten. Markierungen und dunkle Editor-Tags werden nicht verändert.
Die zusätzlichen Grenzen sind 100.000 Syntaxbereiche und weiterhin höchstens
64 logische Zeilen je Paginierungsschritt. Ein Überschreiten bricht sichtbar ab;
Syntaxfarben lassen sich ausdrücklich abschalten. Nach der Aufteilung kann
die zusätzliche Syntaxkopie freigegeben werden.

Die Zeilennummern verwenden dieselbe Schriftgröße und eine rechtsbündige graue
Spalte. Hex misst seine breiteste Zeile vor der ersten Seite und verkleinert
gegebenenfalls einheitlich bis 6 pt; was dann noch nicht passt, wird weiterhin
abgewiesen. Markdown und Rich setzen die gemeinsame Größe nur für den Auftrag
in ihrem temporären Druckstil. Quellbytes, Editorzustand und normale Leseschrift
bleiben erhalten.

Die nativen Prüfwege heißen `linux/test.sh print` für tatsächliche PDFs sowie
`printing`, `printing-busy` und `printing-corrupt` für Mausbedienung, Speichern,
Neustart, Fehlerrücknahme und Wiederholung. Mindestbreite und breite Fenster,
Deutsch/Englisch und die äußeren Oberflächenskalierungen werden zusätzlich
visuell geprüft. Das ist keine physische Druckerabnahme.

### Offene PDF-Textzuordnung in WebKit/Skia

Das geprüfte WebKitGTK 2.52.6 erzeugt Markdown-/Rich-PDFs mit Skia/PDF.
Optionale Inter-Alternativglyphen führten dazu, dass ASCII-Bindestriche im
extrahierten Text als privates Unicode-Zeichen erschienen. Ausgeschaltete
Ligaturen und kontextabhängige Alternativen im Druckstil beseitigen diesen
konkreten Fall. Die sichtbare Vorschau und ihre normalen Schriftfunktionen
bleiben unverändert.

Eine allgemeine Unicode-Garantie besteht damit nicht: Beim griechischen
`Ελληνικά` lieferte derselbe PDF-Textweg trotz passender sichtbarer Glyphen
für das akzentuierte Iota einen anderen Unicode-Wert. Der native
Pango-Quelltextdruck erhält die geprüften Originalzeichen. Für weiterzugebende
PDFs mit zuverlässig kopierbarem Text ist dieser Weg derzeit die geprüfte
Alternative; er ist kein Nachweis formatierter Markdown-Parität.

Im gepinnten [Skia-Schriftpfad von WebKit](https://github.com/WebKit/WebKit/blob/webkitgtk-2.52.6/Source/WebCore/platform/graphics/skia/FontSkia.cpp)
werden Text-Blobs aus Glyphen und Positionen aufgebaut, ohne die ursprünglichen
UTF-8-Zeichenfolgen samt Clusterzuordnung zu übergeben. Das passt zum
beobachteten Zuordnungsfehler; eine allgemeine Korrektur im Backend ist noch
offen. Ebenfalls offen bleiben die vollständige Mac-Kopf-/Fußzeilendekoration,
ein eigener Papierformat-Menübefehl und die Vektor-/Texttreue gedruckter PDFs
anstelle der vorhandenen Rasterausgabe. Diese Punkte sind keine vollständige
Druckabnahme oder still akzeptierte allgemeine Plattformausnahme.
