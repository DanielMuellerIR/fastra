# F07/F08: erstes natives Linux-Fenster

Stand: 2026-11-04. `crates/fastra-linux` bindet GTK4 0.11.5 und
GtkSourceView5 0.11.2 an den gemeinsamen Suchkern und den sicheren Linux-Dateiadapter.
Dies ist ein ausdrücklich begrenzter Arbeitsstand, keine vollständige F07-/F08-
oder Toolkit-Abnahme.

## Implementierter Ablauf

Das Fenster bietet ein erklärendes Startdokument, neue Dokumente, mehrere Tabs,
zwei Ansichten desselben GtkSource-Buffers, Syntaxfarben, Zeilenumbruch,
Rückgängig/Wiederholen, logische Rechteckauswahl über Alt-Ziehen und eine sichtbare Such-/Ersetzungsmaske. Ihre Gliederung
folgt dem Mac-Bestand: Eingaben, Suchart/Optionen, Trefferfreigaben, vollständige
Vorher-/Nachher-Ansicht und ausdrückliche Übernahme. DE/EN werden aus `LANGUAGE`
beziehungsweise `LANG` gewählt.

Dateien werden auf einem Hintergrundthread als `fastra_io::Snapshot` gelesen.
Die Dateiauswahl darf Symlinks auflösen; danach hält der Adapter die tatsächliche
Dateiidentität. Nicht-UTF-8-Dateinamen bleiben im Snapshot unverändert, die Tab-Beschriftung zeigt ungültige Bytes und Steuerzeichen als Escapes. Der aktuelle Dokumentpfad unterstützt verlustfreie UTF-8-/UTF-16-/UTF-32-
und drei Einbyte-Kodierungen bis 32 MiB. Große Dateien, lange Zeilen und
Binärdaten verwenden begrenzte schreibgeschützte Ansichten; siehe
[F07-DOCUMENTS](F07-DOCUMENTS.md).

Literal-/Wildcard-/Regex-Suche läuft außerhalb des UI-Threads. Neue Eingaben,
Editoränderungen und Tabwechsel brechen die alte Suche ab und invalidieren ihre
Generation. Eine verspätete Completion kann keinen anderen Tab ersetzen.
Die Trefferfreigaben erzeugen die vollständige sichtbare Zielansicht aus dem
bestehenden `Preview`; Apply prüft erneut Text, Revision und Generation und
ändert ausschließlich den Editor, als eine gemeinsame Undo-Aktion. Die Datei
wird dabei nicht geschrieben. Capture-Pillen lassen sich über den öffentlichen
GTK-Drag-and-drop-Pfad ins Ersetzungsfeld ziehen.

Bei geöffneten Dateien verwendet „Speichern“
`Transaction::save_document` und `finish_document_save`; es existiert kein
ungeprüfter Überschreibpfad. Neue Dokumente wählen über den nativen „Speichern unter“-Dialog ein neues Ziel.
`save_new_document` veröffentlicht es atomar mit `RENAME_NOREPLACE`; jeder
bereits belegte Dateiname wird abgewiesen, ohne ihn zu überschreiben.
Während des Speicherns bleiben neue Eingaben erlaubt; der erfolgreich
verifizierte Plattenstand wird zur neuen Basis, spätere Eingaben bleiben dirty.
Eine außerhalb von Fastra veränderte Datei wird abgewiesen. Schließen fragt vor
dem Verwerfen ungesicherter Texte nach; während eines laufenden Speichervorgangs
bleibt das Fenster offen.

Sichtbare Knöpfe haben entsprechende Tastaturwege: Ctrl+O/N/S/F, Ctrl+Return
für Vorschau und Ctrl+Q zum Schließen. Der native Editor verarbeitet Undo/Redo
und normale Texteingabe. Dateipfade als Startargument öffnen zusätzliche Tabs.

## Reproduzierbarer Build und Prüfung

Benötigt werden die festgelegte Rust-Toolchain, GTK ≥4.12, GtkSourceView ≥5.6,
ICU 78.3 sowie deren Entwicklungsdateien. `linux/build.sh` baut mit Cargo.lock;
`linux/run.sh` startet den Debug-Stand. Der Host-Probelauf verwendete GTK 4.24.1,
GtkSourceView 5.22.0 und Rust 1.99.1. GtkSourceView und Xvfb wurden ausschließlich
in einem temporären Verzeichnis entpackt, ohne Systeminstallation.

`linux/test.sh` prüft Loader und Clippy. Für den echten Fensterlauf braucht es
`FASTRA_ISOLATED_DISPLAY=1`, ein eigenes Xvfb-`DISPLAY` und einen temporären
Testort auf Btrfs oder ext4 über `FASTRA_UI_TEST_ROOT`. tmpfs ist vom sicheren
Schreibadapter bewusst nicht freigegeben. Der Debug-Selbsttest verwendet
`FASTRA_UI_SELFTEST=1`; Release-Builds ignorieren diesen Testschalter.

Belegt sind drei Loader-Tests (Unicode/BOM/CRLF, Größen-/Binär-/Langzeilengrenzen,
FIFO ohne wartenden Schreiber) sowie grüne Clippy-Prüfung. Der echte GTK-Lauf
besteht in DE und EN: einzelne Freigabe abwählen, Apply, ein Undo, neue
Sucheingabe, Tabwechsel während laufender Suche, bytegenaues Speichern,
Eingaben während Save und Abweisung einer extern veränderten Datei.
Reale XTest-Eingaben über xdotool lösen die Suche mit Ctrl+Return aus und
ziehen `$1` tatsächlich in die Ersetzung. Die Rust-Rechteckerweiterung besteht
echte Alt-Mausgeste unter Soft Wrap, Ersetzung über lange/kurze logische Zeilen
mit Tabulator, kombinierendem Zeichen und Emoji sowie ein echtes Ctrl+Z für
die gesamte Aktion. Spaltenpaste füllt kurze Zeilen auf; ein Undo stellt
den ursprünglichen Text wieder her. Die Erweiterung begrenzt Rechtecke auf
2001 Zeilen und das Ergebnis auf 4 MiB. Nach einer Aktion wird die
Mehrfachauswahl aufgehoben; dauerhaftes Mehrcursor-Schreiben bleibt offen. Der native Save-As-Dialog wurde ebenfalls mit echter Tastatur/Maus bedient;
eine unabhängige Byteprüfung bestätigte den erzeugten Inhalt. Der aktuelle
Fenster-Selbsttest deckt zusätzlich neue Dokumente und bestehende Zielnamen ab.
Die Fensterläufe nutzen einen eigenen D-Bus ohne Desktop-Serviceaktivierung,
damit Dateidialoge keine Portale der Benutzersitzung erreichen. XDG-Konfiguration,
Cache und Daten liegen für den Test in einem eigenen temporären Verzeichnis;
GSettings bleibt im Speicher. Die hellen Ansichten wurden in beiden
Sprachen schmal und breit visuell geprüft; der Capture-Zustand ebenfalls.
Dark Mode wurde einschließlich des passenden GtkSource-Farbschemas geprüft.
Die vorläufige Mindestgröße beträgt 760 × 700 logische Pixel.

## Offene Grenzen des ersten Fensterstands

Projekt-/Alle-Tabs-Suche,
Speichern unter für bestehende Dokumente, externe Beobachtung/Reload, Sitzungswiederherstellung, vollständige
Editorfunktionen und nativer Desktop-/Installationspfad fehlen noch.
Ein Xvfb-Lauf ersetzt weder Wayland noch Cinnamon, physische deutsche
Tastatur/IME, Accessibility, fraktionale Skalierung oder Langzeitbetrieb.
Ordnersuche samt freigegebener Dateitransaktion ist als eigener Teilpfad in
[F06-FOLDER-SEARCH](F06-FOLDER-SEARCH.md) beschrieben. Konvertierung, Git und
weitere Produktfunktionen bleiben eigene Portierungsblöcke. Die Mac-Oberfläche wurde nicht geändert.

## Fortsetzung: Textwerkzeuge und Markdown

Der nächste zusammenhängende Teilstand ergänzt Textmenü, kleine Zeilenfaltung,
Ganzwortsuche, gebündelte Hilfe und eine lokale Markdown-Quellvorschau. Verhalten,
reale Renderprüfungen und die konkreten Dialektlücken stehen im
[F09/F12-Beleg](F12-MARKDOWN.md); die oben beschriebenen historischen Ergebnisse
bleiben davon getrennt.

## Fortsetzung: Mehrdokumente, Wiederaufnahme und weitere Ansichten

Der nächste zusammenhängende Stand ergänzt die
[Mehrtab-Vorschau](F06-TABS.md), fortgesetztes Rechteckschreiben,
[Projektbaum und externe Dateiänderungen](F10-PROJECT-WATCH.md),
[ausdrücklich aktivierte lokale Textsicherungen](F10-SESSION.md),
[Bild-/SVG-/PDF-Ansichten](F14-VIEWER.md),
[formatierte Markdown-Bearbeitung](F15-RICH-EDITOR.md) und
[Markdown-Gliederung](F12-NAVIGATION.md) sowie
[gespeicherte Textabläufe und Bausteine](F09-WORKFLOWS.md),
[Suchvorlagen](F09-PATTERNS.md) und [native Druckpfade](F14-PRINTING.md). Die sichtbare Wiederaufnahme von
Dateitransaktionen ist unter [F03/F08](F03-TRANSACTIONS.md#sichtbare-wiederaufnahme)
beschrieben. Eine verlustfreie alternative Escape-Ansicht macht Unicode-
Normalisierung und Steuerzeichen in Datei-/Mehrtab-/Ordnerfreigaben eindeutig prüfbar.

Die weiter oben genannten ersten Fensterbefunde bleiben historische Belege.
Die verlinkten Folgebelege nennen jeweils implementierte Funktionen und
verbleibende Grenzen. Vollständige Parität, über Neustarts persistente Projekte, sämtliche Git-Aktionen, 4D-Anbindungen, vollständige XPath-Parität, verbleibende
Editorfunktionen und native Desktop-/IME-Abnahme sind damit nicht abgeschlossen.
Die folgende [XPath-Quellnavigation](F14-XPATH.md) ergänzt die dokumentierte
Teilmenge mit expliziten Parsergrenzen.


### Gemeinsamer Prüfstand 1.159.0

Die zusammengeführte Backend-Suite besteht mit 189 Tests. Der GTK-Build besteht
Clippy mit `-D warnings`, 30 ausgeführten Hosttests sowie 16 Tests für Abläufe
und Vorlagen; der zusätzliche native Decoder-Test wurde getrennt erfolgreich
mit den echten lokalen Hilfsprogrammen ausgeführt. Reale isolierte GTK-Läufe
bestehen für Textabläufe, Suchvorlagen, Projekt-Suche, Sitzungsrettung,
Mehrtab-/Ordnerfreigaben, Transaktionswiederaufnahme, Rechteckschreiben,
Markdown-Navigation und die bisherigen Editorpfade. Die maßgeblichen neuen
Dialoge wurden auf Deutsch und Englisch bei schmaler und breiter Ansicht
geprüft. Zwölf vollständige Druckausgaben über die sechs Dokumentpfade wurden
als PDF erzeugt; Abbruch und veraltete Quellen bleiben gesperrt.

Das belegt den isolierten X11-Lauf. Ein physischer Drucker, reale Eingabemethoden,
Cinnamon und der normale KDE-Arbeitsdesktop sowie die native Mac-Anwendung
wurden für dieses Folgepaket nicht erneut abgenommen. Die Paketprüfung des
benannten Commits folgt getrennt und wird nicht aus dem Entwicklungsbuild
abgeleitet.

Die folgende [native Syntaxwahl und Editoroptionen](F07-EDITOR-OPTIONS.md) ergänzt
die dateibezogene Formatwahl und gemeinsame Ansichtseinstellungen.


### Kurzer realer Wayland-Lauf

Am 2026-11-05 lief der Entwicklungsstand 1.160.0 für 3,07 Sekunden am echten
Wayland-Display mit Skalierungsfaktor 2. Backend und Fenstergröße wurden in der
App erfasst; zwei ausschließliche App-Fensteraufnahmen zeigen den ausgeklappten
und eingeklappten Suchbereich. Die App blendete sich danach selbst aus und
beendete sich; der eigene Testcontainer blieb nicht laufen. Die geänderte
Teilungslogik besteht zusätzlich isolierte native X11-Geometrieprüfungen.

Dieser kurze Lauf belegt den wirklichen Wayland-Start und das Layout mit der
Ubuntu-Laufzeit im Container. Er ersetzt weder eine installierte Host-Paketabnahme
noch echte IME-, Drag-and-drop-, Clipboard- oder Cinnamon-Prüfungen.


### Gemeinsamer Prüfstand 1.160.0

Die vollständige Backend-Suite besteht mit 219 ausgeführten Tests. Die
GTK-Hosttests bestehen mit 33 Tests; der separate native Decoder-Test bleibt
als eigener Umgebungsweg gekennzeichnet. Der zusammengeführte Stand besteht
Clippy mit `-D warnings` und jeweils vier native Läufe für Auswahlbereich,
Editoroptionen, Ordnervergleich, XPath und Git-Indexfreigabe in beiden Sprachen
und schmaler/breiter Ansicht. Das Git-Paket enthält die zwei gezielt gegen den
vorigen Code reproduzierten Elternaustauschfälle sowie die echte Prüfung der
66.000-Zeichen-Diffgrenze. Die oben dokumentierte kurze Wayland-Aufnahme prüft
die neue Suchflächenaufteilung separat. Belege und konkrete Grenzen stehen in
den jeweiligen Funktionsdokumenten; physische Eingabemethoden und allgemeine
Desktopabnahme bleiben offen.


### Gemeinsamer Prüfstand 1.161.0

Die integrierte Backend-Suite besteht mit 232 Tests. Der GTK-Host besteht
50 Tests einschließlich Hexmodell, Dateibasisbindung und Save-Receipt-Recovery;
ein nativer Viewer-Test bleibt als separater Umgebungsweg ausgewiesen.
Clippy aller GTK-Targets mit `-D warnings` ist grün. Je vier native Läufe
in Deutsch/Englisch bei schmaler/breiter Ansicht prüfen den
[Hexentwurf](F14-HEX-EDIT.md), die [statische 4D-Navigation](F04-FOUR-D.md) und
[weitere Textoperationen](F09-EXTENDED-TEXT.md). Die Dialogansichten wurden
gezielt visuell geprüft; die oben genannten Desktop-/IME-Grenzen bleiben.


### Gemeinsamer Prüfstand 1.162.0

Die vollständige Backend-Suite besteht mit 237 Tests; GTK besteht 50 Hosttests
und Clippy aller Targets mit `-D warnings`. Die [Projektliste](F10-RECENT-PROJECTS.md)
und der [Hex-Einstieg für gespeicherte Texte](F14-HEX-EDIT.md#gespeicherte-textdateien-und-andere-dateimodi)
bestehen jeweils vier echte native Läufe in beiden Sprachen bei schmaler und
breiter Ansicht. Der Hex-Menüeintrag wird dabei per XTest angeklickt. Die
bestehenden vollständigen Editor- und Dokumenttests bestehen zusätzlich
jeweils auf Deutsch und Englisch; die Dokumentfixture liegt ausdrücklich auf
Btrfs. Der separate native Viewer-Test bleibt als eigener Prüfweg ausgewiesen.
Die [1.161.0-Paketabnahme](F16-1.161.0-EVIDENCE.md) ist an ihren eigenen Commit
gebunden und wird nicht als Paketbeleg für 1.162.0 ausgegeben.

## Eingeklappte Suche und Größenänderung

Die eingeklappte Suche verwendet GTKs tatsächliche Maximalposition und führt sie
nach einer geänderten Allokation nach. Die Mindesthöhe des Endbereichs bleibt
erhalten. Der native breite Splitter verhindert außerdem, dass die unsichtbare
Hitzone des dünnen Griffs den kompakten Suchkopf überlagert. Ein echter Mausklick
muss die Suche wieder ausklappen; bloße Geometrieprüfung genügt nicht. Der frühere Wert `i32::MAX` konnte bei
gleichzeitiger Fenstervergrößerung die Dokumentfläche verschwinden lassen.
GTK rechnet die gesetzte Position mit der Allokationsdifferenz weiter und begrenzt
erst danach; siehe den [GTK-Quelltext](https://raw.githubusercontent.com/GNOME/gtk/4.14.5/gtk/gtkpaned.c).

Die getrennte Ereignisprüfung belegt den zweiten Fehler: Der dünne Paned-Griff
beanspruchte den real am Suchpfeil eintreffenden Press/Release-Zyklus bereits in
der Capture-Phase; der Titel erhielt keine Klicksequenz. Mit ausschließlich
`set_wide_handle(true)` verweigerte Paned die Sequenz, der native Titel erhielt
Press/Release und öffnete die Suche. Es gibt keinen zusätzlichen Toggle-Handler.

Der gezielte native Test klappt vor der ersten Allokation ein, öffnet erneut,
klappt wieder ein und vergrößert unmittelbar um 80 Pixel. Gegen das unveränderte
Produktverhalten von 1.163.0 blieb dabei eine Höhe von 657 Pixeln für die
vermeintlich eingeklappte Suche stehen. Dieselben Geometriebedingungen werden im
korrigierten Stand geprüft. Ergänzend hält der getrennte
[A/B-Paketlauf](F16-PANE-AB.md) 16 frische SVG-/PDF-Starts je Binary fest; der
historische [1.163-Paketbefund](F16-1.163.0-EVIDENCE.md) bleibt erhalten.

## Fortsetzung: Speichern unter und Beenden

Bestehende editierbare Textdokumente besitzen nun [Speichern unter mit
vollständiger Vorschau](F07-SAVE-AS.md). Der [gemeinsame Anwendungsabschluss](F07-QUIT.md)
koordiniert sämtliche Hauptfenster und ihre ausstehenden Dateiarbeiten.
