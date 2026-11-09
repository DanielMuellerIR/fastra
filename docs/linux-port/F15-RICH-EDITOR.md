# F15: synchronisierte Rich-Markdown-Bearbeitung unter Linux

Stand: 2026-11-09. Die ursprüngliche Integration erfolgte in 1.159.0/367;
Clipboard, Marker und Ausschnittbindung sind seitdem ergänzt. Die Ansicht verwendet
WebKitGTK innerhalb der nativen GTK-Anwendung. Die Mac-Ressourcen
`turndown-7.2.0.js`, `visual-tables.js` und `visual-editor.js` werden gemeinsam
wiederverwendet und in die Linux-Binärdatei eingebettet. Die Linux-Brücke liegt
in `crates/fastra-linux/src/rich_editor.rs` und dessen Untermodulen.

## Bedienung und Grenzen

„Rich-Markdown“ wechselt den aktuellen Dokumenttab zwischen Quelltext und
formatierter Bearbeitung. Die Werkzeugleiste bietet Fett/Kursiv, Inline-Code,
H1–H3/Absatz, Aufzählung, Nummerierung, Aufgabenliste, Zitat, harten Umbruch,
Links und Tabellen. Tabellen können angelegt, Zeilen/Spalten ergänzt oder
entfernt und Spalten ausgerichtet werden. Externe Links werden gespeichert,
aber nicht geöffnet. Das sichtbare Clipboardmenü und Ctrl+C/X/V übernehmen
privates Fastra-Markdown, erlaubtes HTML oder Klartext, in dieser Reihenfolge.
Ctrl+Shift+V fordert ausdrücklich Klartext an. Ein späteres Ergebnis darf nach
Quell-, Tab-, Clipboard- oder Cursorwechsel nichts einfügen. [Bild-/Datei-Drops und RTF-Import](rich-assets.md) ergänzen diesen Pfad
mit vollständiger Dateivorschau und gesonderter Bestätigung.

Normale Codeblöcke sind ab 1.228.0 mit Syntaxfarben direkt bearbeitbar. Mermaid
bleibt wie auf dem Mac geschützt und wird als Diagramm angezeigt, auch innerhalb
von Listen. Nicht unterstützte Bilder, Formeln und unbekanntes HTML behalten
ihre geschützte Darstellung. Ihre unveränderten Quellbytes bleiben
auch beim Bearbeiten anderer Blöcke erhalten. Änderungen daran erfolgen im
Quelltextmodus. Es gibt keinen behaupteten vollständigen Mac-Dialekt: unter
anderem fehlen direkte Formelbearbeitung, verlustfreie Inline-RTF-Übernahme und
Quellzeilensynchronisierung. Unterstützte lokale Rasterbilder werden tatsächlich
angezeigt, über das Bildmenü eingefügt und entfernt. Die gemeinsame native
Gliederung verbindet angenommene Quellüberschriften mit der tatsächlichen
Rich-Auswahl und prüft Sitzung sowie Eingaberevision.
`==Textmarker==` sind bearbeitbar und erscheinen auch in der Vorschau. Der
gemeinsame Markerhelfer berücksichtigt Unicode-Delimitergrenzen; mehrdeutig
kreuzende Formate bleiben geschützt. Der Moduswechsel bewahrt den visuellen
Ausschnitt und die vorherige Vorschau-/Splitwahl pro Dokument und Revision.

Die Eingabe ist auf 2 MiB, 10.000 Blöcke und 50.000 Parserereignisse begrenzt;
auch erzeugtes HTML und eingefügter Klartext sind begrenzt. Diese Grenzen sind
enger als die des normalen Texteditors. Abschnitts-, Hex- und Dateivorschauen
bleiben von Rich-Bearbeitung ausgeschlossen.

## Synchronisationsvertrag

Jede WebView erhält eine eigene zufällige Session und eine schwache Bindung an
die erzeugende Dokumentinstanz. Eine Änderung wird nur übernommen, wenn diese
Instanz noch im sichtbaren Fenster vorhanden ist, ihre Rust-Revision und ihr
Text der erwarteten Basis entsprechen und die JavaScript-Revision monoton
fortschreitet. Eine Nachricht wirkt niemals auf den zufällig aktiven Tab.

Akzeptierte Eingaben werden zeitnah als Unicode-sicherer minimaler Textdiff in
den Rust-Quellpuffer gespiegelt. So bleiben Dirty-Status, Revision und
Quelltext-Undo erhalten, ohne pro Tastenanschlag das gesamte Dokument in die
Undo-Historie einzufügen. Im Rich-Modus verwendet Rückgängig/Wiederholen die
native WebKit-Historie. Ein Neuaufbau des Rich-Modus beginnt eine neue
WebKit-Historie; die Quelltext-Historie bleibt über den Moduswechsel erhalten.

Speichern, Schließen und der Rückwechsel führen zusätzlich `prepareAction`
aus: JavaScript sperrt Eingaben, liefert den vollständigen letzten Stand und
der Host prüft erneut Dokument, Session und Revision. Eine späte Completion
nach Moduswechsel oder Timeout kann keine neue Ansicht überschreiben. Fehler,
Komposition und ausstehende Synchronisation halten die Aktion an. Die Ansicht
bleibt erhalten. Nur „Rich-Ansicht verwerfen …“ darf nach ausdrücklicher
Bestätigung noch nicht synchronisierte Eingaben aufgeben.

Die Session-Anbindung verwendet
`flush_all_owned(ui, hold, completion)`: alle Rich-Ansichten bleiben bis zur
synchronen Completion gesperrt. Erst nach `completion(true)` darf der Host den
Rust-Stand auf dem GTK-Thread als unveränderliche Session-Capture übernehmen.
Bei `hold=true` gibt der Aufrufer anschließend mit `release_all(ui)` frei;
bei `hold=false` erfolgt die Freigabe nach Rückkehr der Completion. Fehler
verbieten Capture und Close. Die Session-Integration und ihr dauerhafter
Schreibabschluss werden im Session-Modul gesondert geprüft.

`Document::is_read_only()` behält die Bedeutung tatsächlicher
Datei-/Ansichtsschreibschutz. `is_rich_active()` und `source_edits_locked()`
stellen die zusätzliche Grenze für Quelltextwerkzeuge, Suche und Batch dar;
Rich-Dokumente dürfen nicht von der Session-Sicherung ausgeschlossen werden.

## Isolation und Paketressourcen

Die WebView verwendet eine flüchtige Netzwerksitzung. Eine geschlossene
URI-Liste liefert die eingebetteten Ressourcen und ausschließlich geprüfte
Bildtokens aus `fastra-rich:`. Navigation, Berechtigungsanfragen und Kontextmenü sind gesperrt.
Die Content Security Policy verbietet Netzwerkverbindungen, fremde Bildadressen, Frames,
Objekte, Worker, Formaktionen und fremde Skripte. Rohes Markdown-HTML wird nicht
als aktives HTML ausgeführt; nur eine kleine attributfreie Inline-Positivliste
ist erlaubt. Die Hostbrücke enthält keine beliebigen Datei-, Prozess- oder Systembefehle.
Bildtransaktionen verwenden ausschließlich den gesonderten Vorschau-/Apply-Pfad.

Turndowns vollständige MIT-Lizenz steht bereits in `THIRD-PARTY-NOTICES.md`.
Das JS-Inventar des Paketbaus muss die nun aktiv verwendete Turndown-Datei
zusätzlich abdecken. Ein erneuter Release-Paketlauf erfolgt gegen den späteren
integrierten Commit; diese Prüfung ist kein solcher Release-Nachweis.

## Frühe Prüfung (1.159.0)

Drei reine Regressionstests bestanden: bytegenaue Blockzuordnung und geschützte
Syntax, kleine HTML-/URL-Positivliste und minimale Unicode-Differenzen. Build
unter Ubuntu 24.04 mit Rust 1.99.1 und Clippy mit `-D warnings` bestanden.

Die echte WebKitGTK-Ansicht lief offline, als unprivilegierter Benutzer und mit
aktivem WebKit-Sandboxpfad in privaten Xvfb-/D-Bus-Sitzungen. Deutsch bei 760
Pixel Breite/hell und Englisch bei 1600 Pixel Breite/dunkel wurden visuell
geprüft. Die Rich-Werkzeugleiste bricht um; der Dokumentinhalt scrollt.

Der Test führte Formatierung, natives Undo/Redo, Tabellenbearbeitung und
Speichern mit UTF-8-BOM aus. Geschützte Code-/Scriptquellen blieben bytegleich;
NBSP und Unicode wurden nach echtem Close in einem frischen Prozess wieder
übernommen. Ein Moduswechsel während des Save-Flush wurde angehalten. Eine
verspätete echte JavaScript-Änderung nach einer externen Quellrevision wurde
abgewiesen; weder anderer Tab noch Datei wurden überschrieben. Die Prüfung
lief allein mit Binärdatei und ICU-Laufzeit, ohne gemounteten Quellbaum oder
Build-Ressourcen. Die minimalen Containerfonts decken nicht jedes getestete
Unicodezeichen visuell ab; die Zeichenfolge wurde zusätzlich in DOM und
Dateibytes geprüft.

Die späteren gemeinsamen WYSIWYG-Korrekturen und Mac-Referenztests stehen
unter [F15-WYSIWYG-REGRESSIONS](F15-WYSIWYG-REGRESSIONS.md). Die zusätzlichen
nativen Clipboard- und Markerprüfungen beschreibt [Build und Test](../BUILD-AND-TEST.md).

## Gliederung im Rich-Modus

Rich verwendet dasselbe kompakte Popup, dieselben drei Knöpfe und denselben
Verlauf wie die Quellansicht. Die Liste aktualisiert sich automatisch; die
Auswahl folgt den DOM-Meldungen. Vor einem Sprung wird der Rich-Inhalt sicher
synchronisiert. WebKit prüft unmittelbar vor Auswahl und Scrollen nochmals
Sitzung, Eingaberevision und Überschriftenstruktur. Eine veraltete Antwort nach
Tabwechsel und Rückwechsel wird verworfen. HTML-/Code-Blöcke erzeugen keine
falschen Einträge. Grenzen bleiben 10.000 Überschriften, 16 KiB je Titel und
2 MiB Titeltext insgesamt.

Überschriften im Verlauf bleiben in Rich. Ein gespeicherter Quelltext-Cursor
wechselt über den normalen synchronisierten Moduswechsel in die Quellansicht.
Navigation verändert weder die Quellbytes noch die Undo-Historie. Der
[gemeinsame Gliederungsvertrag](F12-NAVIGATION.md) und `linux/test.sh rich-outline`
beschreiben die native Prüfung einschließlich echter Tastatureingabe,
207 DOM-Überschriften und unveränderter Datei.

## Sichtbare Leerzeilen und Clipboard

[Sichtbare ASCII-Leerzeilen](F12-BLANK-LINES.md) bleiben auch in Listen und
Zitaten erhalten. Eingabe, Rücknahme, globale Referenzdefinitionen und echte
Clipboard-Rundläufe sind Teil dieser Ergänzung. Sie erweitert weder den
Formeldialekt noch die Quelltext-/Vorschau-Klicknavigation.

## Textbausteine

Der kompakte Bausteinknopf steht zwischen Gliederung und Suche. Der
[Bausteinvertrag](F09-WORKFLOWS.md#textbausteine-in-quelltext-und-rich) beschreibt
das festgehaltene WebKit-Lesezeichen, die vollständige Einfügevorschau,
Dokument-/Sitzungsprüfungen, lokale Bildverweise und den nativen Undo-Schritt.

## Codeblöcke und Diagramme ab 1.228.0

Die Renderer beider Parserwege führen normale Codeblöcke durch den gemeinsamen
Mac-Serializer. Nicht bearbeitete Blöcke behalten ihre ursprünglichen Fence-,
Zeilenende- und Unicode-Bytes. Bei Änderungen an einem Codeblock schreibt der
Serializer einen passenden Backtick-Fence; andere Blöcke bleiben unverändert.
Mermaid erhält eigene geschützte Quellschlüssel. Bei verschachtelten Diagrammen
verwaltet der gemeinsame Serializer die Einrückung des äußeren Listen-/Zitatblocks,
wie in `MarkdownVisualDocument` auf dem Mac.

Die bereits gebündelten Versionen von highlight.js und Mermaid werden über die
bestehende feste Ressourcenliste ausgeliefert. Externe Verbindungen, Frames,
Worker und Roh-HTML-Ausführung bleiben gesperrt. Mermaid verwendet `strict`,
keine HTML-Beschriftungen, höchstens 100.000 Zeichen und 500 Kanten pro Diagramm.
Ein temporärer Rendercontainer liegt außerhalb des editierbaren Dokuments und
wird auch bei Fehlern entfernt. Ungültige Quellen bleiben als Code mit einer
lokalisierten Meldung erhalten. Die sequenzielle Renderkette verwirft überholte
Farbergebnisse. Nach nativem Undo/Redo werden wiederhergestellte SVGs an die
aktuelle Palette angepasst; die ursprünglichen Diagrammquellen bleiben davon
unberührt.

Die nativen Fälle verwenden echte Eingaben in syntaxhervorgehobenem Code,
Rückgängig/Wiederholen und Ctrl+S sowie einen frischen Prozess. Sie prüfen beide
Parserwege, CRLF, unveränderte Diagrammquellen und unbekanntes HTML. Die appweite
Erscheinungsbildprüfung beobachtet die tatsächlichen SVG-Farben in Vorschau und
Rich-Ansicht, ohne Text, Auswahl oder Undo zurückzusetzen. Diese Prüfungen ersetzen
keine vollständige Markdown- oder Desktopabnahme.

## Gemeinsame Leseschrift ab 1.230.0

Die gruppierten Markdown-Einstellungen wählen eine appweite proportionale
Leseschrift samt Schnitt für Vorschau und Rich-Editor. Die Grundgröße beträgt
wie auf dem Mac 14 px; Dokument-Zoom bleibt unabhängig, Bilder skalieren nicht
mit. Inter und Sora werden auch dem abgeschotteten WebKit-Unterprozess über die
feste Ressourcenliste bereitgestellt. Ein Live-Wechsel ersetzt ausschließlich
ein Stylesheet im Dokumentkopf, ohne Inhalt, Auswahl oder Undo neu aufzubauen.
Fehlende gespeicherte Schriften bleiben benannt; die Systemschrift dient nur als
vorläufiger Ersatz. Der getrennte, atomare Leseschriftspeicher schützt bestehende
und fremde Einstellungen. Native Schrift-, Fehler- und Neustartprüfungen sind in
[Build und Test](../BUILD-AND-TEST.md#linux-gemeinsame-markdown-leseschrift) beschrieben.

## Appweite Seitenvorschau ab 1.231.0

Die standardmäßig eingeschaltete Markdown-Seitenvorschau folgt wie auf dem Mac
einer gemeinsamen Vorgabe. Einstellungen und Vorschauknopf ändern denselben
atomaren Speicher; vorhandene und neue Markdown-Quellansichten übernehmen die
Wahl. Inaktive Tabs erstellen ihre WebView erst beim Anzeigen. Ein Formatwechsel
schließt die Vorschau lokal, ohne die globale Vorgabe zu überschreiben.
Rich-Markdown deaktiviert die Seitenvorschau nur intern. Der bestehende gehaltene
Synchronisations- und Bildprüfpfad bleibt Voraussetzung des Quelltextwechsels;
danach gilt die aktuelle globale Vorgabe, nicht das vor dem Rich-Einstieg
gespeicherte Anzeigeflag. Die globale WYSIWYG-Standardwahl ist davon getrennt.

## Standard und Dokument-Override ab 1.232.0

Die globale WYSIWYG-Wahl entspricht `markdown.visualEditing` auf dem Mac. Eine
optionale ausdrückliche Dokumentwahl hat Vorrang; erfolgreiche manuelle
Moduswechsel setzen sie, globale und formatbedingte Wechsel erhalten sie.
Inaktive Dokumente erzeugen ihre formatierte Ansicht erst beim Anzeigen. Eine
fehlende gespeicherte Wahl löst den ersten Modusdialog aus; gespeichertes `false`
ist eine bestätigte Quelltextwahl. Beide Werte werden im getrennten atomaren
Modusspeicher streng geprüft. Ctrl+Shift+Alt+M verwendet denselben geschützten
Dokumentwechsel wie der sichtbare Knopf.

Vor einer globalen Änderung werden Rich-Ansichten mit Eingabesperre synchronisiert.
Eigentümer und Operationsnummer gehören zu jeder gehaltenen Sperre; das Ende einer
alten Vorbereitung darf keine neuere Aktion entsperren. Für den Quelltextwechsel
folgt die bestehende Wiederherstellung der Bild-Undo-Receipts. Erst nach Prüfung
aller vorbereiteten Ziele wechseln die Ansichten synchron. Ein inzwischen
geschlossenes Dokument verwirft die gesamte Vorbereitung. Der gemeinsame
Ansichtsabschluss bewahrt die aktuelle appweite Vorschauwahl. Schreibgeschützte
Texte sowie die bestehenden Größen-, Zeilen- und Ressourcengrenzen bleiben wirksam.
