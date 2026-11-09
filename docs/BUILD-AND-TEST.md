# Fastra bauen und testen

Diese Datei beschreibt den reproduzierbaren Build-, Paketierungs- und Testweg.
Projektfakten, Produktinvarianten und Konventionen stehen in
[AGENTS.md](../AGENTS.md).

Build, Installation und Unitlauf derselben Arbeitskopie nacheinander ausführen.
Sie verwenden dieselbe SwiftPM-Build-Datenbank; ein durch parallele Zugriffe
gestörter Lauf zählt nicht als Abschlussprüfung. Getrennte Arbeitskopien
benötigen getrennte Build-Verzeichnisse.


## Syntax-Folding prüfen

Patch 4z20 (`app/Patches/CodeEditSourceEditor/code-folding.py`) verbindet den
Snapshot-Provider mit `SourceEditor`, ersetzt den Fold-Cache und schützt jedes
Analyseergebnis mit einer Textrevision. Der Einrückungsfallback liest höchstens
50 Zeilen pro Main-Actor-Durchlauf und prüft vor dem nächsten Zugriff erneut.
Die Quelle bleibt vollständig im TextStorage; Platzhalter sind reine Layoutobjekte.

Der Patch prüft seine Integrationsanker vor dem Schreiben und danach jede
erzeugte Quelle. Attachment-Edits erhalten den alten ersetzten Bereich, entfernen
überlappende Platzhalter und invalidieren alle überlebenden verdeckten Zeilen.
Nach der Analyse werden erhaltene Platzhalter gegen die aktuellen vollständigen
Ranges abgeglichen. Verschachtelte Layoutbereiche verwenden das größte Ende,
statt vom letzten Start auf das Ende des Elternbereichs zu schließen.
Neue Platzhalter invalidieren auch die bereits gesetzten Fragmente der Kopfzeile,
damit sie sofort gezeichnet und angeklickt werden können.

Gezielte Prüfungen nach `./build.sh`:

```bash
cd app
./test.sh --fast-only --filter 'CodeFolding|SnapshotPresentation|CodeExplanation'
FASTRA_FOLDING_SCREENSHOT_DIR=/pfad/zur/aufnahme ./selftest.sh codefolding
```

Der Fenster-Selbsttest prüft echte Gutterklicks, Option-Klick, den Kindzustand nach
Öffnen des Elternbereichs, den Platzhalter-Doppelklick mit erhaltener Bereichsauswahl,
Klicks nach Scrollen sowie Copy des vollständigen
Quelltexts. Dazu kommen Editor-Tests für alte Analyseergebnisse, Kopf-/Tiefenänderungen
und überlappende Löschungen einschließlich der verbleibenden Zeilenhöhen.

## Textsuche im WYSIWYG-Modus

Nach `./build.sh` prüft `./test.sh --filter
'MarkdownVisualTests/visualFind'` WebKits echte Suche über Formatgrenzen,
Unicode, ausgeblendete Linkadressen und Markdown-Syntax, Groß-/Kleinschreibung,
Vorwärts/Rückwärts mit sichtbarem Scrollen sowie verspätete Antworten nach
Dokumentwechseln. Markdown-Originale und bestehende Bearbeitungsschritte bleiben erhalten.

`FASTRA_MD_VISUAL_FIND_DIR=/pfad/zur/aufnahme ./selftest.sh mdvisualfind`
öffnet die Leiste per echtem ⌘F, tippt in das native Textfeld, navigiert mit
⌘G/⇧⌘G und öffnet per ⌥⌘F die explizite Quelltextsuche. Der Lauf prüft
zusätzlich den sichtbaren Toolbar-Einstieg, Mausbedienung, einen schmalen
dunklen Zustand ohne Treffer und unveränderte Datei-/Dokumentinhalte.
Deutsch und Englisch getrennt laufen lassen und die Aufnahmen ansehen.
Der Fokusbeleg ist das `currentEditor()` des konkreten Suchfelds als First
Responder. Nach Schließen und Wiederöffnen prüft eine weitere echte Eingabe
die native Auswahlersetzung, danach Escape. Ein Fokusauftrag wird nach der
Montage erneut gesetzt und an Suchanfrage sowie Dokument gebunden.

`mdsearchnavigation` prüft zusätzlich den echten Trefferklick nach einer
verzögerten WebKit-Übernahme. Eine virtualisierte Ergebnisliste erzeugt nur
sichtbare Zeilen: zuerst die echte `NSScrollView` scrollen und den veränderten
Ausschnitt prüfen, erst danach den Zeilenmarker suchen und klicken.

Patch 4z26 (`Patches/CodeEditSourceEditor/highlight-style-bounds.py`) begrenzt
verspätete Syntax-Attributbereiche am tatsächlichen Textspeicher. Die Grenze
wird nach der Attributberechnung erneut geprüft, weil ein Theme-Provider
AppKit reentrant zur Textbearbeitung bringen kann. `HighlightStyleBoundsTests`
führt beide Kürzungen gegen den echten CodeEdit-Highlighter aus; Text und
gültige Farben bleiben erhalten. Nach Änderungen an diesem Patch den vollständigen
Build-/Unit-/Selbsttestpfad ausführen.

## Markdown-Tabellen

Nach `./build.sh` prüft `./test.sh --filter
'MarkdownVisualTests/table'`
die GFM-Strukturänderungen, Tab-Navigation, begrenztes TSV, geschützte
Kopfzeilen/HTML-Tabellen, native Undo-Schritte und Formel-/Kommentar-Roundtrips.

`FASTRA_MD_TABLE_DIR=/pfad/zur/aufnahme ./selftest.sh mdtable` prüft
Zellklicks und echte Tab-/Shift-Tab-Tasten, das native Zeilenmenü,
Undo/Redo ohne künstlichen Wechsel des nativen WebKit-Responders, den TSV-Dialog
mit breiter Tabelle, Moduswechsel sowie echtes Schließen und erneutes Öffnen.
Deutsch und Englisch getrennt laufen lassen; Hell/Dunkel jeweils bei Mindestbreite
und breit sowie TSV-Sheet und Quelltextansicht visuell prüfen. Auf dem Test-Mac das aktuelle notarisiert
installierte Bundle über `FASTRA_SELFTEST_APP_BUNDLE` und
`FASTRA_SELFTEST_APP_BIN` verwenden.

`./selftest.sh mdtableinteraction` prüft echte gezogene Textauswahlen bei
Mindestbreite und breitem Fenster sowie einzeiliges natives Clipboard-Einfügen
über den gesamten Zelltext mit Formatierung und Undo/Redo. Den fokussierten
Lauf ebenfalls in Deutsch und Englisch ausführen; er verändert die
Ausgangsauswahl des getrennten Strukturtests nicht.

## Textbausteine

`FASTRA_TEXT_WORKFLOW_DIR=/pfad/zur/aufnahme ./selftest.sh snippets` prüft den
sichtbaren Picker, native Namens- und Vorlageneingaben, wiederholte Unicode- und
Mehrzeilenwerte, Tab/Umschalt-Tab, vollständige Vorschau, Auswahlersetzung in
Quelle und WYSIWYG, natives Undo/Redo, Abbruch, erneutes Öffnen, Duplizieren,
Löschbestätigung und Exportabbruch. Die Aufnahmen umfassen beide Erscheinungsbilder
bei Mindestgröße und breitem Sheet; jeden Sprachlauf visuell prüfen.
Quelltext-Undo läuft über Command-Z in AppKits Event-Queue, Redo über die native
Bearbeiten-Menüaktion; ein synthetisch gepostetes Umschalt-Command-Z belegt diesen
Menüpfad nicht. Die Plattendatei bleibt bis zum normalen Speichern unverändert.
`TextSnippetTests` prüft zusätzlich Store-Revisionen aus mehreren Fenstern,
Importkonflikte und atomare Größen-/Validierungsgrenzen. Die WebKit-Regressionen
prüfen auch, dass unsicheres HTML nicht ausgeführt wird und Undo geschützte
Einfügeatome vollständig entfernt. Ein beliebiger Feldeditor belegt keinen
Fokus: vor der Eingabe muss `NSTextField.currentEditor()` zum konkreten Namensfeld
und zum First Responder des Sheets gehören.

`snippetfiles` ergänzt die positive JSON-Dateirundreise über echte macOS-Dateidialoge,
Konfliktumbenennung, eine vollständige 48-Namen-Importbestätigung und ungültige JSON.
Die Namenliste wird oben und unten in beiden Erscheinungsbildern aufgenommen.
Dieser gezielte Test benötigt einen externen, prozess- und fokusgebundenen
Tastentreiber: `FASTRA_TEXT_WORKFLOW_DIR/panel-key-*.json` enthält PID, Nonce und
keyCode 36 (Return), 124 (Rechtspfeil in die Dateispalte) oder 125 (Abwärtspfeil).
Return folgt erst, wenn `NSOpenPanel.urls` exakt die erwartete Fixture auswählt.
Optionale Fensteraufnahmen laufen vor der nächsten Taste. Antworten und Bilder bleiben im selben Aufnahmeverzeichnis.
Die Fixturepfade werden vor dem Panelstart gesetzt; der normale Appbetrieb erhält
keine Pfadvorgabe. Der Test gehört wie `diffexport` nicht zum Standardlauf.

## Gespeicherte Textabläufe

`./test.sh --filter 'TextWorkflow|ApplyTransaction|AtomicFileCommit|SearchUndo|HardWrap'`
prüft zusätzlich vollständige Mehrdokumentpläne, gemeinsame Speicher-Rücknahme,
Dateitypen/Ausschlüsse/Pakete, mehrere Fehler, Dirty-/Hex-Konflikte und Hardlinks
anderer Fenster, Pfadreservierung, verspätete Generationen und Reload über alle
Fenster. Die Tests mit appweiter Reservierung tragen `serialRunnerIntegration`
und laufen exklusiv in der seriellen Phase.

`FASTRA_TEXT_WORKFLOW_DIR=/pfad/zur/aufnahme ./selftest.sh textworkflowmulti`
bedient die echten Bereichs- und Vorschau-Picker, Eingabezeilen, Speicher-Apply
samt gemeinsamer Rücknahme/Wiederherstellung sowie Platten-Apply und geschützte
Rücknahme. Eine nach Vorschau veränderte, vorher wirkungslose Datei muss beide
Eingaben schützen. Fehler und sofortiger Abbruch dürfen keine Apply-Basis liefern.
Offene Dokumente, Ordner und Projekt werden jeweils bei 900/1200 pt sowie
Hell/Dunkel aufgenommen; zusätzliche Bilder zeigen Schrittvorschau, Fehler und
die beiden angewendeten Zustände. DE/EN gegen das frisch notarisiert installierte
Bundle ausführen und jede Aufnahme ansehen. Die Aufnahmevariable wird ausdrücklich
an LaunchServices weitergereicht; fehlende angeforderte PNGs sind ein Fehler.

Nach `./build.sh` prüft `./test.sh --fast-only --filter
'TextWorkflowTests|TextOp|LineFilter'` Engine, gemeinsame Texttransformationen,
Grenzen, Persistenzkonflikte sowie die Vorschau-/Apply-Bindung an das konkrete
Dokument. `MarkdownOutlineTests|MarkdownVisualTests/outline|MarkdownVisualTests/inlineCodeWhitespaceLine`
deckt zusätzlich Gliederungsverlauf, Tab-/Moduswechsel und verlustfreie
Markdown-Roundtrips ab.

`FASTRA_TEXT_WORKFLOW_DIR=/pfad/zur/aufnahme ./selftest.sh textworkflow`
öffnet das echte Textmenü, bearbeitet Name und Schritte, speichert die
Definition und prüft Schritt-/Endvorschau, Anwenden, natives Undo per Tastenkürzel
und Wiederholen über das echte Bearbeiten-Menü, Dateispeichern, echtes
Schließen/Wiederöffnen und erneutes Laden der Definition. Die synthetische
Shift-Command-Z-Zustellung an CodeEdit ist separat als Prüfgrenze dokumentiert;
der Menütest prüft den sichtbaren Eintrag und dessen tatsächliche Wirkung.
Schritt-/Endvorschau und exakte Auswahl werden über die sichtbaren Controls bedient.
DE/EN jeweils gegen das aktuelle notarisiert installierte Bundle ausführen. Hell/Dunkel
jeweils breit und bei der Mindestgröße des Sheets visuell prüfen; zusätzlich `filediff`
und `localization` aus dem gepackten Bundle ausführen.

## Blockübernahme im Dateivergleich

`./selftest.sh filedifftransfer` bedient den vorausgefüllten Vergleichsdialog,
beide Übernahmerichtungen und die genaue Bestätigung mit echten Mausklicks.
Er prüft Dirty-Zustand, unveränderte Plattendateien, native Undo/Redo über das
Bearbeiten-Menü und den beim Zurückwechseln aktualisierten Diff. EOF-Einfügungen
und -Löschungen, ignorierte Unterschiede, veraltete Speicher-/Dateiquellen,
schnelle Folgeaktionen und schreibgeschützte externe Quellen gehören zum Lauf.
`FASTRA_TEXT_WORKFLOW_DIR` sammelt echte Bildschirmaufnahmen des vorausgefüllten Dialogs, des Vergleichs,
der Vorschau, des identischen Ergebnisses, der veralteten Vorschau und der externen
Quelle in hell/dunkel bei Mindestbreite/breit. DE/EN gegen das frisch notarisiert
installierte Bundle ausführen und alle Bilder selbst prüfen. Fehlende echte
Aufnahmen ergeben einen Umgebungsfehler.

Nach `./build.sh` decken `FileDiffTransferTests`, `FileDiffTransferPreviewTests`
und `FileDiffTransferWorkspaceTests` die bytegenauen Blockgrenzen, Unicode-
Terminatoren, Limits, Snapshots, Fenster-/Dokumentidentität und Abbruch ab.
Der bestehende Datei-Diff und sein Renderer bleiben gemeinsame Regressionen.

## Schreibgeschützter Ordnervergleich

Nach `./build.sh` prüfen `FolderComparisonTests` und
`FolderComparisonWorkspaceTests` relative Pfade einschließlich `/var`-Alias,
Unicode, Binärbytes, Filter, Symlink-Schleifen, reale unlesbare Unterordner,
Datei-/Ordnerkonflikte, Grenzen, Abbruch und Veränderungen während der Prüfung.
Die Wachstumsprobe beobachtet die echte gelesene Deskriptorposition des
gemeinsamen Snapshot-Readers. Dateipaare benutzen den bestehenden Datei-Diff;
Tab-Schluss, Abbruch und neuere Aufträge müssen ältere Rückmeldungen entwerten.
Offene Dokumente und Plattendateien bleiben unverändert.

Die native Abnahme muss Ordnerauswahl, Ergebnisliste, Filter, Dateipaaröffnung,
erneute Prüfung und Abbruch über sichtbare Controls am frisch notarisiert
installierten Bundle bedienen. DE/EN, hell/dunkel, Mindestbreite/breit sowie
vollständige und unvollständige Ergebnisse als echte Bildschirmbilder prüfen.
Die Datei-Diff-/Blockübernahmeprüfungen und `localization` bleiben Regressionen.
`FASTRA_TEXT_WORKFLOW_DIR=/pfad/zur/aufnahme ./selftest.sh foldercompare`
bedient den echten Menübefehl und die sichtbaren Controls. Der Lauf erzeugt
Bildschirmaufnahmen von Auswahl, Ergebnissen, Dateipaar, erneuter Prüfung,
unvollständigem Ergebnis und Abbruch in beiden Darstellungen und Breiten.

## Markdown-Gliederung

Nach `./build.sh` prüft `./test.sh --filter
'MarkdownOutlineTests|MarkdownVisualTests/outline'` Parserstruktur, Unicode-
und Zeilenendpositionen, dokumentgebundenen Verlauf, echte WebKit-Selektion
und den sichtbaren Ausschnitt langer Dokumente. Inline-HTML-Überschriften
dürfen die Markdown-Sprungziele nicht verschieben.

`FASTRA_MD_OUTLINE_DIR=/pfad/zur/aufnahme ./selftest.sh mdoutline` öffnet die
native Gliederung per Maus, wählt einen späten Titel und bedient Zurück/Vorwärts.
Der Lauf prüft Quelltext und WYSIWYG sowie unveränderte Dokument- und Dateiinhalte.
Die Aufnahmen zeigen die schmale Quelltextansicht, den Gliederungs-Popover und
die breite dunkle Schreibansicht. Mit `FASTRA_SELFTEST_LANGUAGE=de` und `en`
wiederholen. Der Test wartet nach dem Popover-Aufbau auf dessen Layout, bevor
er einen über die echte Event-Queue zugestellten Klick misst.

## Geteilte Quelltextansicht

Patch 4z27 (`Patches/CodeEditTextView/shared-source.py`) hält schwache
Ansichtsreferenzen je gemeinsamem Textspeicher, verschiebt fremde Auswahlen
nach tatsächlichen Mutationen und bindet Undo an die bediente Ansicht. Er
prüft alle Anker sowie das geschriebene Ergebnis unmittelbar. Patch 4z28
(`Patches/CodeEditSourceEditor/shared-source-appearance.py`) setzt beim
Theme-Wechsel ausschließlich die sichtbaren Attribute dieses Ausschnitts
zurück. Ein Reset des gesamten gemeinsamen Speichers würde die bereits
berechneten Farben des anderen Ausschnitts löschen. Die Regression prüft
die tatsächlich gezeichneten CoreText-Farben beider Theme-Wechsel im echten
SwiftUI-Split. Beide Patches prüfen den Anker und Erfolg unmittelbar. Nach
Änderungen vollständigen Build-/Unit-/Selbsttestpfad ausführen.

`SplitEditorTests` prüft echte TextViews, gemeinsamen Storage, wechselseitige
Eingaben, Dokument-Undo und Workspace-Rückgaben. Der echte SwiftUI-Host
prüft außerdem die Minimap-Fragmentgrenzen beider Ausschnitte und die
Footerposition nach einem bereichsbasierten Sprung. `prepareCoordinator`
darf die Controller-View nicht laden: Der gemeinsame Speicher wird erst
danach angeschlossen. Die AppKit-Begrenzung wird in `controllerDidAppear`
gesetzt, damit die Minimap von Anfang an die richtige Textbasis erhält. `SearchUndoTests`, Cursor-/
Scroll-, Faltungs-, Suchsprung- und Markdown-Tests ergänzen die Regression.
`FASTRA_TEXT_WORKFLOW_DIR=/pfad/zur/aufnahme ./selftest.sh sourcesplit`
bedient den sichtbaren Split-Schalter, echte Tastatureingaben und Undo/Redo,
prüft getrennte Auswahlen/Ausschnitte, aktiven Sprung, UTF-16/BOM/gemischte Zeilenenden auf
Platte, native Trennlinienverschiebung, getrennte Faltung, Zoom/Wrap sowie echte Dateilade-Tabwechsel und Schließen. DE/EN sowie alle erzeugten
Hell-/Dunkel-/Mindestbreite-/Breit-Aufnahmen visuell prüfen. Gemischte
Zeilenenden sind zusätzlich über den allgemeinen Speicherpfad abzunehmen.

## 4D-Gliederung und gemeinsamer Sprungverlauf

Nach `./build.sh` prüft `./test.sh --fast-only --filter
'CodeOutlineTests|MarkdownOutlineTests|GoToTargetTests'` tokenbasierte
4D-Definitionen, Kommentare/Strings/SQL, Unicode, Grenzen, eindeutige Ziele
und dokumentgebundene Quellanker. Der Verlauf bleibt je Fenster getrennt;
geschlossene oder nach Änderungen mehrdeutige Ziele dürfen ihn nicht verschieben.

`FASTRA_MD_OUTLINE_DIR=/pfad/zur/aufnahme ./selftest.sh codeoutline`
bedient die native Gliederung, Zurück/Vorwärts, echten Alt-Doppelklick und
das Darstellungsmenü. Danach prüft er geschlossene Ziele und Rücksprünge nach
eingefügten Quellzeilen. DE/EN, hell/dunkel und 760/1100 pt ergeben sechs
Ansichtszustände je Variante. Menüeinträge erst nach Öffnen und Beginn des
echten Menü-Trackings suchen; SwiftUI baut sie beim ersten Öffnen auf.
`mdoutline`, `gototarget`, `gototargetwin`, `mdreferences`, `mdblocks`, `colsel`
und `localization` ergänzen die native Regression.

## Editoroptionen und Markdown-Listen

Nach `./build.sh` prüft `./test.sh --filter
'EditorDisplayOptionsTests|MarkdownVisualTests|SoftWrap|Indentation'` die
Dokumentisolation, echten Zeichen-Bitmaps, Auswahl- und Texttreue sowie die
Listen-Geometrie in Vorschau und WYSIWYG. WebKit rundet die tatsächlichen
Zeilenpositionen auf ganze CSS-Pixel; die Prüfung berücksichtigt das.

Patch 4z23 (`Patches/CodeEditSourceEditor/invisible-characters.py`) hält den
Zeichen-Coordinator bei Themen-, Schrift- und Einrückungswechseln aktuell und
zeichnet bestehende Fragmente bei Optionswechseln neu. Der Patch prüft seinen
Anker und das vollständige Ergebnis bei jedem Build. Der Renderer-Test
`liveAppearanceChanges` prüft die tatsächlichen Ersatzfarben, Schriftgrößen
und Einrückungsbetonungen; die Fensteraufnahmen ergänzen Hell-/Dunkel-Wechsel
und die Titelleiste bei minimaler Seitenleistenbreite.

`FASTRA_EDITOR_OPTIONS_DIR=/pfad/zur/aufnahme ./selftest.sh editoroptions`
bedient das Zahnrad, den Popover-Schalter und den echten Darstellungsmenüpfad.
Der Menüeintrag für unsichtbare Zeichen muss in Git-Verlauf und schreibgeschützter
Vorversion tatsächlich deaktiviert sein; beide Ansichten werden im Fenster geprüft.
Die Aufnahmen zeigen den Popover, Zeichenanzeige sowie lose Markdown-Listen und
Aufgabenlisten in beiden Ansichten bei 760 und 1100 pt. Für die Sichtprüfung
den Lauf mit `FASTRA_SELFTEST_LANGUAGE=de` und `en` wiederholen; zusätzlich
`softwrapmodes`, `softwrapindentcore`, `footerfit` und `sidebarheader` prüfen.

`sidebarheader` benennt außerdem eine geöffnete Datei und ihren Elternordner
extern um und speichert anschließend unter neuem Namen. Es prüft die sichtbaren
Dateibaumzeilen sowie die echten Pfad-Kopiermenüs von Kopf und Tab.
`FASTRA_FILE_LOCATIONS_DIR` speichert die Abschlussansicht. Die ergänzenden
`FileLocationTests` prüfen wiederverwendete Namen, atomare Dateiaustausche,
verspätete Prüfungen nach einem Save, Hardlinks und Papierkorbziele.
Die Wiederanlage des ursprünglichen Pfads während einer pausierten
Snapshot-Lektüre muss sowohl bei sauberen als auch bei ungespeicherten Tabs
am ursprünglichen Dokument bleiben; ein späteres Speichern lässt das Backup unverändert.

`FileSystemSafetyTests` prüft auf dem gewählten echten Dateisystem die
Mehrdatei-Vorschau vor und während des Preflights, wiederverwendete Namen,
wirkungslose Eingaben sowie einen Zielaustausch zwischen zwei Schreibschritten.
Apply/Undo müssen entweder sicher funktionieren oder alle betroffenen Originale
erhalten. Die Tests verwenden im Normalfall die Test-Sandbox. Für gesondert
eingehängte Testdatenträger setzt man `FASTRA_FILESYSTEM_TEST_ROOT` auf deren
Mountpunkt und `FASTRA_FILESYSTEM_EXPECTED` auf `hfs`, `exfat` oder `apfs`;
`./test.sh --fast-only --no-parallel --filter FileSystemSafetyTests` prüft vor
jeder Fixture den tatsächlichen Dateisystemtyp. Ein versehentlich nicht
eingehängter Datenträger kann damit keinen grünen Ersatzlauf auf APFS erzeugen.

## Rückgängig nach Suchen/Ersetzen

Patch 4z24 bindet einen dokumentgebundenen `CEUndoManager` erst nach der
Textinitialisierung an. `setText` löscht sonst dessen Verlauf. Modell-Ersetzungen
registrieren ihre Umkehrung auch für noch nicht montierte Tabs; ein neuer Editor
übernimmt denselben Verlauf. Native Edits melden ihren Text separat zurück,
damit sie nicht doppelt registriert werden.

Nach `./build.sh` prüft `./test.sh --fast-only --filter SearchUndoTests` Einzel-
und Alle-Ersetzen, frühere Eingaben, Undo/Redo, Tabwechsel, unsichtbare Dokumente
und verspätete Editor-Bindings. `./selftest.sh searchundo` prüft im gepackten
Bundle die Markdown-Splitansicht mit 700 Ersetzungen, 24 Tabwechseln und 48
Undo-/Redo-Aktionen: 24 Command-Z-Tastendrücke durch AppKits Event-Queue
und 24 Redo-Aktionen über die Responder-Kette. Dieser Test
benötigt exklusiven Fensterfokus.

## Markdown-Bilder und Undo

`./test.sh --filter 'MarkdownVisualTests/imageLogicalSize|MarkdownRichTextTests|MarkdownPreviewSchemeHandlerTests'`
prüft die tatsächlichen WebKit-Bildrechtecke bei 72, 144 und 216 dpi in Vorschau
und WYSIWYG sowie die Quelltexttreue. DPI-Metadaten verkleinern die natürliche
Darstellungsbreite auf die logische Mac-Größe; explizite HTML-Maße bleiben erhalten.
Der begrenzte Metadaten-Cache verwendet dieselbe Dateiidentität wie die Bild-URLs.

Entfernte Undo-Bilder liegen im gemeinsamen `MarkdownImageUndoBuffer`, ausschließlich
im RAM. Das Limit von 512 MiB zählt auch reservierte, noch nicht eingelesene Bytes.
Bei Platzmangel verfällt der älteste betroffene Dokumentverlauf vollständig;
eine einzelne zu große Aktion bekommt keinen Ersatz auf der Platte. Der Markdown-
Quelltextverlauf beginnt beim Speichern unter in einen anderen Ordner neu, weil
alte relative Bildpfade sonst das neue Dokument beschädigen könnten.
Die gespeicherten Herkunftsreferenzen folgen dem gebundenen Verzeichnisdeskriptor,
auch nach Finder-Umbenennungen.

Patch 4z25 (`Patches/CodeEditTextView/image-undo-memory.py`) verbindet den nativen
Undo-Verlauf mit asynchronen Bildaktionen. Der Editor bleibt während der Dateiaktion
gesperrt; Speichern, Ansichtswechsel und Beenden warten auf ihren Abschluss.
Dateiinhalte werden im Hintergrund geprüft. Unmittelbar vor dem Entfernen gleicht
der Main-Thread alle offenen Dokumentreferenzen erneut ab und führt nur noch die
kurze Metadatenoperation aus. Geänderte Referenzen lösen eine neue Prüfung aus.

Nach `./build.sh` prüfen `./test.sh --filter
'MarkdownImageUndoBufferTests|MarkdownImageStoreTests|MarkdownVisualTests|SearchUndoTests|AtomicFileCommitTests'`
das Speicherlimit, Verwerfen während einer laufenden Aktion, gespeicherte und
geteilte Bildreferenzen, Dateikollisionen sowie echte WebKit-Undo-Vorgänge.
Die verzögerte Undo-Completion wird auch mit einer zwischenzeitlichen Modell-
Ersetzung geprüft: Danach darf kein alter Redo-Schritt wieder auftauchen.
Dateitests erhalten Finder-Tags, Modusbits, macOS-ACLs, Eigentümer, Gruppe und
Änderungsdatum trotz restriktiver umask; diese Metadaten zählen zum RAM-Budget.
Eine geerbte Schreibsperre prüft, dass nicht restaurierbare Metadaten das
Entfernen verhindern. Die Bereinigung wird gegen SVG, gefiltertes und ungequotetes
HTML einschließlich `object[data]`, nackte und codierte Prozentzeichen,
Referenzbilder und Downloadlinks geprüft.
Die Fenster-Selbsttests `mdassist`, `mdvisual`, `searchundo` und `cmdw` ergänzen
native Eingaben, Ansichtswechsel und Schließen im gepackten Bundle. `mdimagequit`
durchläuft den echten Beenden-Hook während einer angehaltenen Undo-Dateiphase
und eines anschließenden Save-As-Bildkopierauftrags. Er prüft dessen gezielt
blockierte Queue, die fertige neue Datei und die Bereinigung vor dem Prozessende.

## Build-Anleitung

```bash
cd app
./build.sh                 # debug
./build.sh release         # release (signiert ad-hoc)
./install.sh                           # notarisiert → /Applications/Fastra.app

# Gleiches bequem direkt aus dem Projekt-Root:
./install.sh
```

Beim ersten notarisierten Lauf prüft das Skript das Profil vor dem Build. Fehlt
die Clone-Einstellung, fragt es interaktiv nach dem Profilnamen; fehlt auch das
Profil im lokalen Schlüsselbund, bietet es die sichere interaktive Einrichtung
mit `notarytool store-credentials` an. Das App-spezifische Passwort wird dabei
nie als Argument übergeben. Optional kann der Profilname vorab gesetzt werden:

```bash
git config --local fastra.notaryProfile <profil>
```

`release.sh` und `install.sh` verwenden diese Einstellung, sofern
`NOTARY_PROFILE` nicht ausdrücklich gesetzt ist. Der Name liegt ausschließlich
in `.git/config`; Credentials bleiben im macOS-Schlüsselbund. Beides wird weder
committed noch zu einem Remote übertragen. Auf jedem weiteren Mac ist der
interaktive Bootstrap einmal nötig, weil iCloud notarytool-Profile nicht synct.

**Installations-Workflow (`app/install.sh`):** baut Release, signiert mit
Developer ID + Hardened Runtime, notarisiert bei Apple (`--wait`), stapelt das
Ticket und kopiert nach `/Applications`. Die Signatur-Identität wird zur Laufzeit
aus dem Schlüsselbund ermittelt (nichts Privates im Skript — public Repo). Der
Notary-Keychain-Profilname steht bewusst NICHT im Skript; er wird per
`NOTARY_PROFILE`, lokaler Git-Konfiguration oder Erstdialog ermittelt.
`./install.sh --no-notarize` signiert nur und legt das Test-Bundle im
Projekt-Root ab; es installiert ausdrücklich nichts nach `/Applications`.

**Release-Workflow (`./release.sh`):** notarisiert und stapelt zuerst die App,
danach das DMG. Der Mount-Test prüft auch das eigene Ticket der enthaltenen
App. Ein vorhandenes DMG unter `app/dist/` wird erst nach erfolgreicher
Signatur-, Ticket- und Gatekeeper-Prüfung atomar durch das neue ersetzt.

Der Root-Wrapper `./install.sh` reicht Optionen und Umgebungsvariablen
unverändert an `app/install.sh` weiter; dadurch funktioniert der komplette Lauf
auch ohne vorheriges `cd app`.

**Pflicht-Gate für Installationen (seit v1.12.2):** SwiftPMs generierte
`Bundle.module`-Accessor erwarten beim CLI-Build Ressourcen neben dem
Executable und enthalten zusätzlich einen absoluten Fallback in
`.build/<Konfiguration>`. Eine signierbare macOS-App braucht die Bundles aber
unter `Contents/Resources`. Fastras Locator und die `build.sh`-Patches für
CodeEditSymbols/CodeEditLanguages bevorzugen deshalb
`Bundle.main.resourceURL`; danach ruft der Build `verify-portable-app.sh` auf:
Alle lokalen `.build/*.bundle`-Fallbacks werden kurz ausgeblendet, dann müssen
aus der gepackten App sowohl der fensterlose Selbsttest `localization` als auch
eine echte Ordnersuche mit dem gebündelten ripgrep starten. Der zweite Lauf
schützt speziell gegen einzelne vergessene `Bundle.module`-Zugriffe, die beim
App-Start noch nicht ausgeführt werden.
`install.sh` wiederholt dieses Gate nach dem Kopieren mit der tatsächlich
installierten App. Signatur-, Stapler- und Gatekeeper-Prüfungen ersetzen
diesen echten Zielstart nicht.

Im Installationslauf setzt `install.sh` für den Build
`FASTRA_DEFER_PORTABILITY_CHECK=1`: Die App startet dort erstmals nach der
Developer-ID-Signierung und im notarisierten Lauf nach Ticket- und
Gatekeeper-Prüfung. Die aufgeschobene Portabilitätsprüfung läuft vor der
Installation am fertigen Bundle und danach erneut am installierten Ziel.
Ein direkter `build.sh`-Lauf behält seine unmittelbare Prüfung bei; wer die
Variable selbst setzt, muss die noch ausstehende Prüfung ausdrücklich nachholen.

**Agent-bindend (2026-07-21):** `/Applications` ist ausschließlich
notarisierten Bundles vorbehalten. `build.sh` legt Debug- und Release-Builds als
`Fastra.app` im Projekt-Root ab. Auch `install.sh --no-notarize` bleibt dort;
weder Ad-hoc- noch nur Developer-ID-signierte Builds dürfen nach
`/Applications` kopiert werden. Der vollständige notarierte Workflow via
`install.sh` ist der erforderliche Testpfad, sobald echtes
Installationsverhalten, Datei-Doppelklick über LaunchServices,
Finder-Zuordnungen oder macOS-Datei- bzw. Ordnerberechtigungen relevant sind.
Er darf ebenso für normale verifizierte Teststände verwendet werden; eine
abgeschlossene größere Etappe oder eine besondere Ansage sind dafür nicht
erforderlich.

Für schnelle rein interne Iterationen genügt `build.sh`; die frisch gebaute
Debug-App liegt danach im Projekt-Root. Für eine signierte, aber nicht
notarisierte Variante dient `install.sh --no-notarize`, ebenfalls ausschließlich
im Projekt-Root. Vor jeder Installation prüft `install.sh` Notary-Ticket,
Gatekeeper-Akzeptanz und Codesignatur des Quell-Bundles. Beim Version-Bump
`app/Info.plist` mitziehen (siehe AGENTS.md), sonst zeigt die App eine veraltete
Version.

`build.sh` kapselt Xcode-Toolchain-Switch + sechsunddreißig Checkout-Patches
(SwiftLint-Plugins aus, CodeEditSymbols Resources, CMD+F-Zombie-Kill,
toter cursorPositions-Reconcile, verworfene Auto-Vervollständigung schließen,
Gutter-Drag-Clamp, horizontaler Scrollbalken, Zeilenbreiten-Messung,
exotische Sprachen ausschneiden, Highlight-Query-Pfad layout-robust,
Text-Geist-Fix, zwei portable Ressourcenpfade, getrennte 4D-Theme-Slots
einschließlich eines optionalen Methoden-Slots, feste Soft-Wrap-Spalten und
Rechteckauswahl auf logischen Zeilen, vollständige Dateiende-Auswahl,
stabile Auswahl- und Layoutzustände großer Textoperationen, vollständige
Trefferflächen nach Texteingaben, klickdurchlässige verborgene Minimap,
zellenbasierte Doppelklick-Wortauswahl, Drag-Anker am Maus-Down,
Storage-/Layout-Konsistenz, aktuelle Zeile bei Auswahl, Fließtext-Einrückung
und den positionsgebundenen externen Bild-Drop).

Seit v1.19.0 verpackt `build.sh` zusätzlich das exakt gepinnte
`Sparkle.framework` unter `Contents/Frameworks`, entfernt die für die nicht
sandboxed App unnötigen XPC-Dienste und signiert Ressourcen, Autoupdate,
Updater-App, Framework und Fastra strikt von innen nach außen. `--deep` dient
nur noch der abschließenden Prüfung, nie der Signierung. Der Selbsttest
`updates` prüft im gepackten Bundle Menüpunkt, Feed, Signaturpflicht,
zustimmungspflichtige Installation und deaktiviertes Systemprofiling.
Details in `app/LESSONS-LEARNED.md` Sektion F (F.9 = CMD+F, F.10 = Reconcile).
Patch 4h (Highlight-Query-Pfad, 2026-07-10): `CodeLanguage.queryURL` baute
`resourceURL + "Resources/…"`, aber `Bundle.module.resourceURL` zeigt bei
unserem Bundle-Layout schon auf `…/Resources` → doppeltes
`Resources/Resources`, die highlights.scm wurde nie gefunden und der Editor
blieb monochrom (Sprache wurde trotzdem korrekt erkannt — betraf auch den
abgenommenen v1.0-Release). Regressions-Wächter: Selbsttest `highlight`
(zählt echte Vordergrundfarben im Editor-TextStorage).
Patch 4i (Text-Geist, 2026-07-12): CodeEditTextViews Break-Helfer liefert
einen absoluten Endindex im Content-Run, der Typesetter verwendete ihn aber
fälschlich als `NSRange.length`. Dadurch überlappten die gezeichneten
CoreText-Bereiche ab dem zweiten Umbruchfragment. Der Patch berechnet die
Länge als Endindex minus Startindex. Regressions-Wächter: Selbsttest
`ghosttext` (CoreText-Nutzlast, Fragmentbreite und doppelte Dokumentbereiche).
Gutter-Drag-Clamp (4d in build.sh): CESEs `mouseDragged` clampt die Drag-Position
auf `max(0, …)` → über der Gutter-Spalte liefert `textOffsetAtPoint` nil und die
Selektion friert ein; Patch clampt auf `max(layoutManager.edgeInsets.left, …)`.
Der zugehörige Gutter-Durchschuss-ins-Header-Fix ist App-seitig (`.clipped()` am
Editor in `EditorView`), KEIN Checkout-Patch.
Patch 4c1 (4D-Auto-Vervollständigung, 2026-07-19): CESE setzt vor einer
asynchronen Vorschlagsanfrage `activeTextView`. Liefert der 4D-Delegate für das
erste Zeichen absichtlich noch `nil`, blieb dieser Zustand ohne sichtbares
Fenster stehen; die Anfrage für das zweite Zeichen aktualisierte nur die
unsichtbare Liste. Der Patch ruft in diesem `nil`-Pfad `willClose()` auf. Der
Regressions-Wächter `./selftest.sh completion4d` lädt eine echte `.4dm`-Datei
und prüft Auto-Popup, ⌃Leertaste, ↓ sowie Klick/Doppelklick in der sichtbaren
CESE-Tabelle. Weil die letzten drei Schritte echten Fensterfokus brauchen,
startet der Runner die App über LaunchServices und beendet sie danach wieder.
Patch 4m (4D-Projektmethoden, 2026-07-19): Die 4D-Vorgaben unterscheiden
Methoden farblich und typografisch von Befehlen. `EditorTheme` besitzt upstream
keinen freien Methoden-Slot; der Checkout-Patch ergänzt daher am Ende des
Initializers ein optionales `methods`-Attribut mit Default `commands` und mappt
`.method` dorthin, während `.function` auf `commands` bleibt. Der Default ist
entscheidend: Alle bestehenden Themes und Sprachen behalten ihre Darstellung.
Der Patch prüft Marker und Mapping hart und verwirft anschließend die
CodeEditSourceEditor-Artefakte. Regressions-Wächter: Unit-Test gegen die
eingecheckten 4D-JSON-Farben sowie `./selftest.sh highlight4d`, der im echten
Editor Methode (Farbe + bold/italic), Befehl, Prozessvariable und String in
hellem und dunklem Theme beobachtet.
Patch 4m2 (4D-Komponentenmethoden, 2026-07-25): Completion kannte geteilte
Komponentenmethoden bereits, der Highlighter verlor diese Herkunft nach dem
Einfügen aber und ordnete den Namen wieder `.function`/`commands` zu. Der Patch
ergänzt deshalb `CaptureName.componentMethod` und einen optionalen
`EditorTheme.componentMethods`-Slot. Dessen rückwärtskompatibler Default ist
`commands`; bestehende Themes und Sprachen ändern sich dadurch nicht. Der neue
Capture-Case steht bewusst am Enum-Ende, damit die rohen Werte vorhandener
Cases stabil bleiben. Harte Marker prüfen Property, Initializer, Zuweisung,
Mapping sowie beide Capture-Konvertierungen; danach werden die
CodeEditSourceEditor-Artefakte verworfen. Unit-Tests prüfen Default, Mapping,
Kontrast und Projektmethoden-Priorität. `./selftest.sh highlight4d` beobachtet
Projektmethode, Komponentenmethode und Befehl im echten Editor in Hell und
Dunkel; `./selftest.sh completion4d` übernimmt zusätzlich eine Shared-
Component real aus der sichtbaren CESE-Liste und liest erst danach Farbe und
Font aus dem TextStorage.
Patch 4n (Soft-Wrap-Spalten und Seitenlinie, 2026-07-19): CodeEdit kann
upstream nur an der Viewportbreite umbrechen. Fastra ergänzt eine optionale
maximale Layoutbreite und `wrapAtColumn`; die effektive Breite bleibt das
Minimum aus Spaltenziel und nutzbarem Viewport. Umbruch und vorhandene
Reformatting-Linie verwenden dieselbe reale Schrift-, Kern- und Inset-Geometrie.
Der Patch korrigiert außerdem die bisher halbierte Guide-Koordinate und zeichnet
die versetzte Guide-View in lokalen Bounds. Bei extrem schmaler Breite erzwingt
der Typesetter mindestens ein vollständiges Graphem pro Fragment. Beim
Umschalten von Soft Wrap sichert der Patch die tatsächliche oberste logische
Textzeile statt des absoluten Y-Werts. Höchstens 24 Layoutschritte konvergieren
innerhalb desselben Runloops auf die neue Ankergeometrie; erst die stabile
Endposition wird sichtbar. So entstehen weder zeitversetzte Scrollkorrekturen
noch ein vollständiges Layout aller vorangehenden Zeilen.
Regressions-Wächter: `SoftWrapLayoutTests` treiben echte CodeEdit-Controller,
Layoutfragmente und Bitmap-Rendering; `./selftest.sh softwrapmodes` prüft im
laufenden Fenster alle drei Ziele, Guide-Koordinate, Resize, Zoom und
zustandsneutrales Reconcile. `./selftest.sh softwrapanchor` verankert in einem
realen Dokument mit 2.400 langen Zeilen die unabhängig beobachtete oberste
Zeile beim Aus- und Einschalten. Der Test tastet den sichtbaren Zustand alle
20 ms ab und akzeptiert keine abweichende Zwischenposition. `ghosttext`,
`hscroll`, `colsel` und `gutterdim` bleiben ergänzende Regressionen.

Patch 4z18 (Folgefragmentkern): Der gemeinsame Ursprung und reduzierte
Umbruchraum liegen in `app/Patches/CodeEditTextView/`. Der Patch läuft nach
allen älteren Typesetter-Patches und prüft sämtliche Ersetzungen hart.
`SoftWrapIndentationTests` deckt beide Umbruchstrategien, Tabs, Emoji,
Attachments, schmale Breiten, Profilmigration und die tatsächlich gezeichnete
Drag-Vorschau ab. Der Fenster-Selbsttest
`softwrapindentcore` prüft den Kern direkt; mit
`FASTRA_SOFTWRAPINDENT_DIR=<ordner>` entstehen sechs Aufnahmen für drei Modi
bei 300 und 700 pt über die vorhandene fensterbezogene Systemaufnahme.
Patch 4z19 verbindet das Formatprofil mit dem Controller und der Minimap;
siehe [Fragmentgeometrie](soft-wrap-fragment-geometry.md).
`SoftWrapIndentationIntegrationTests` prüfen Reconcile, Attachmentgrenzen,
Cache-Erhaltung, verborgene Minimap und die vertikale Hin-/Rückabbildung.
`softwrapindent` prüft den normalen Editor mit drei Modi, drei Wrap-Zielen,
760/1100 pt und zwei Zoomstufen, einschließlich Unicode, Kandidatenanker,
Rechteck-Paste, Undo/Redo und Drag/Auto-Scroll. Eine reale Eingabemethode
bleibt zusätzlich manuell abzunehmen. Mit `FASTRA_SOFTWRAPINDENT_DIR` werden
sechs Fensteraufnahmen angefordert; fehlende Aufnahmeberechtigung ist ENV.
`FASTRA_SOFTWRAPINDENT_REVIEW_DIR=<ordner>` hält danach die isolierte
Testinstanz höchstens 300 s für eine manuelle Menü-/IME-Prüfung offen; Runner
und In-App-Deckel erlauben dafür insgesamt 420 s. Normale Läufe behalten
ihre 180-s-Frist. Der
Marker `ready` zeigt die Bereitschaft; `continue` gibt den Abschluss frei.
Testeingaben müssen zuvor zurückgenommen sein. Die optionale Variable
`FASTRA_SOFTWRAPINDENT_REVIEW_WIDTH` wählt die Fensterbreite (Standard 760 pt).

`diffselection` prüft native Mauszüge vorwärts und rückwärts über mehrere
Zeilen einschließlich des Copy-Responderpfads. Datei-Diff, zweispaltiger
Git-Diff und einfacher Git-Diff werden bei zwei Breiten geprüft; die
zweispaltigen Ansichten zusätzlich mit und ohne Soft Wrap. Die Prüfung
benötigt exklusiven Vordergrundfokus und verändert die Test-Zwischenablage.
Mit `FASTRA_DIFFSELECTION_DIR=<ordner>` speichert sie zehn Fensteraufnahmen
mit der Auswahl und langen Zeilen für die visuelle Umbruchprüfung.
`diffselectionbackground` verwendet dieselben gerenderten Ansichten und native
Fensterereignisse für Drag und Shift-Klick in einem Fenster, das keinen Fokus
annehmen kann. Copy läuft über dessen eigenen First Responder; dieser Lauf
prüft die Diff-Bedienung neben einer aktiven Benutzeroberfläche, nicht den
globalen Menü-Responderpfad. Zusätzlich muss ein einfacher Git-Diff mit
20.000 kurzen Zusatzzeilen weniger als 200 Textansichten montieren.
`./test.sh --fast-only --filter DiffWrapLayoutTests` prüft Git- und Dateivergleiche
im vollständigen Dokumentfenster nach dem Laden, wiederholten Breitenwechseln,
Soft-Wrap-Umschaltungen und vergrößerter Schrift. Entscheidend sind die tatsächlich
gezeichneten Textbereiche innerhalb der umgebenden Zellen; allein eine ausreichend
hohe `NSTextView` erkennt abgeschnittene Zeilen nicht. `FASTRA_DIFF_WRAP_DIR=<ordner>`
sichert die umbrochenen Zustände als PNG. Der Lauf übernimmt keinen Vordergrundfokus.
Die Linux-Prüfung `linux/test.sh diff-interaction` kontrolliert zusätzlich die
nativen Umbruchfragmente, ihren Platz in der logischen Zeile, die nächste Zeile und
die gleiche vollständige Zeilenhöhe beider Seiten nach Ziehen und Verkleinern.

`FASTRA_GITHISTORY_REVIEW_DIR=<ordner>` hält die eigene Git-History-Fixture
nach den normalen Prüfungen bis zu 300 s für eine Menüabnahme offen
(Runner-Frist 420 s). `ready` meldet die Bereitschaft. Vor `continue` muss
„Datei öffnen“ aus dem Verlauf die aktuelle `alpha.txt` im normalen Editor
geöffnet haben; deren Inhalt wird beim Abschluss zusätzlich geprüft.

Patch 4o (Rechteckauswahl, 2026-07-19): Upstream baut die Spaltenauswahl aus
jedem sichtbaren `lineFragment` und macht umbrochene Fortsetzungen dadurch zu
zusätzlichen Rechteckzeilen. Fastra ersetzt
`TextView+ColumnSelection.swift` reproduzierbar aus
`app/Patches/CodeEditTextView/` und verdrahtet Copy/Paste, Delete sowie
Mehrfachbereich-Undo. Zeilen und Spalten werden aus logischen NSString-Zeilen,
vollständigen `Character`-Graphemen und tabstopp-bewussten visuellen Spalten
berechnet. CodeEditSourceEditor reicht die aktive Tabbreite und
Einrückungseinheit weiter. Alle Integrationsstellen besitzen harte Marker;
eine abweichende Upstream-Quelle bricht den Build ab. Regressions-Wächter:
`./selftest.sh colsel colselwrap colpaste` prüft Punkt-Drag, echte
Soft-Wrap-Fragmente, Vorwärts/Rückwärts, kurze und leere Zeilen, Tabs, CRLF,
Unicode, Copy/Paste/Cut/Delete/Tippen/Paste Column, Transformationen und genau
eine Undo-Gruppe pro Schreibaktion.

Patch 4p (Auswahl am Dateiende, 2026-07-20): Endet eine Datei mit LF, CRLF
oder CR, liegt der Dokumentend-Cursor bereits links in der nachfolgenden leeren
Zeile. CodeEditTextView verwendete diese X-Position als rechte Kante der
vorherigen ausgewählten Textzeile und erzeugte dort ein Rechteck mit Breite
null. Der Patch zeichnet eine ausgewählte abschließende Zeilenendung bis zum
rechten Textrand; Dateien ohne abschließenden Zeilenumbruch markieren weiterhin
nur bis zum letzten Zeichen. `SoftWrapLayoutTests` prüft die echte
CodeEdit-Auswahlrange und deren erzeugte Rechtecke für alle drei Zeilenenden.

Patch 4q (große Textoperationen mit Undo, 2026-07-20): CodeEditTextView setzt
nach einer großen Bereichsersetzung den Cursor ans Ende des Ersatztexts und
leitet die Undo-Auswahl allein aus der alten Mutationsrange ab. Bei „Zeilen
verbinden“ entstand dadurch eine extrem lange Soft-Wrap-Zeile mit instabilem
Scroll-/Layoutanker; Undo markierte anschließend das ganze alte Dokument und
konnte einen leeren Bildschirm oberhalb von Zeile 1 zeigen. Fastras
Textoperationspfad bildet Cursor oder Selektion nun bewusst auf das Ergebnis ab
und hinterlegt dafür opt-in Auswahlzustände im Undo-Element. Undo und Redo bauen
das Layout synchron am wiederhergestellten Anker auf. Normales Tippen und
Einfügen behalten CodeEdits Standardverhalten. `SoftWrapLayoutTests` prüft den
echten Controller einschließlich Text, sichtbarer Fragmente, Auswahl,
Undo und Redo. `./selftest.sh joinundo` treibt denselben Menüpfad im gepackten
Markdown-Editor und zählt echte sichtbare `LineFragmentView`s.

Patch 4r (Tastaturauswahl mitscrollen, 2026-07-21): CodeEditTextView versucht
nach `moveDownAndModifySelection` zwar, die Auswahl sichtbar zu halten, nutzt
dafür aber deren Bounding-Rect. Dessen Fill-Rects sind auf den sichtbaren
Textbereich begrenzt; die mit Shift+Pfeil bewegte Kante kann deshalb unter den
Viewport laufen, während das Scrollziel weiter auf den sichtbaren oberen
Ausschnitt zeigt. Fastra verwendet CodeEdits bereits vorhandene, zuvor an
dieser Stelle ungenutzte Nicht-Pivot-Kante als kleines eindeutiges Scrollziel.
Bei langen Soft-Wrap-Dokumenten beruht ihre erste Position jedoch noch auf
geschätzten Zeilenhöhen: Das faule Layout kann die Kante nach dem ersten
Scrollen erneut aus dem Viewport schieben. Deshalb folgt im nächsten
Main-Runloop ein zweiter Abgleich mit der dann ausgelegten Position; reine
Cursorbewegungen lösen ihn nicht aus.

Der direkte `SoftWrapLayoutTests`-Regressionstest treibt den echten
`moveDownAndModifySelection`-Befehl in einem bereits versetzten kurzen
Viewport. Der gepackte Editor wird zusätzlich mit `./selftest.sh
selectionscroll` geprüft. Dieser Selbsttest startet über den produktiven
SessionStateStore mit einem wiederhergestellten Markdown-Dokument aus 2.200
ungleich langen Soft-Wrap-Zeilen, wartet auf beide Hälften des Markdown-Splits,
fokussiert den linken Quelleditor und sendet sechs echte Shift+↓-Events über
mehrere Runloop-Durchläufe. Erst nach dem folgenden SwiftUI- und Layout-Abgleich
misst er die aktive Kante unabhängig vom gepatchten Scroll-Helfer.

Patch 4s (Trefferflächen nach Einfügungen, 2026-07-22):
`NSTextStorageDelegate.didProcessEditing` liefert den bearbeiteten Bereich im
neuen Text und separat die Längenänderung. CodeEditTextView leitete daraus
korrekt den vorher ersetzten Bereich ab, verwendete diesen alten Bereich aber
auch nach dem Umbau der Zeilenstruktur zur Layout-Invalidierung. Bei einer
reinen Einfügung ist er leer; an einer alten Fragmentgrenze konnten deshalb
die Umbruchfragmente des bisherigen Zeilenendes erhalten bleiben, obwohl die
logische Zeile bereits länger war. Der neue Text wurde sichtbar gezeichnet,
aber `rectForOffset` lieferte dahinter nur ein Nullbreiten-Fallback und der
Fenster-Hit-Test erreichte den Editor dort nicht. Fastra verwendet den alten
Bereich weiterhin ausschließlich zum Entfernen ersetzter Zeilen und
invalidiert anschließend den neuen `editedRange`.

Der Selbsttest `./selftest.sh wordclick` kürzt eine lange Markdown-Zeile
zunächst auf den bereits ausgelegten Wortanfang, fügt den Rest durch den echten
`TextView` wieder ein und prüft Fenster-Hit-Test sowie Koordinatenabbildung an
Anfang und Ende des Worts. Die echte `TextView`-Doppelklickfolge am Wortanfang
und die produktive Wortauswahl am abgebildeten Wortende müssen dieselbe
vollständige Auswahl erzeugen. Für die Erstdiagnose kann
`FASTRA_WORDCLICK_FIXTURE` eine lokale Realdatei laden; der normale Lauf bleibt
mit einem datenschutzneutralen Größenabbild der 132 Vorzeilen portabel.

Patch 4t (verborgene Minimap schluckt Klicks, 2026-07-24): AppKits
Default-`hitTest` sortiert verborgene Views selbst aus; `MinimapView`
überschreibt die Methode aber ohne `isHidden`-Prüfung und frisst Mausereignisse
mit leeren `mouseDown`-Überschreibungen. Bei ausgeblendeter Minimap (Fastras
Default) lag deshalb eine unsichtbare, rund 90 pt breite Fläche über der
rechten Editorkante: Klicks und Doppelklicks auf Text in diesem Band kamen nie
im Editor an — am auffälligsten im Markdown-Split mit seinen bis an den
Scrollbalken umbrochenen Zeilen. Der Patch beendet `hitTest` bei
`isHiddenOrHasHiddenAncestor` sofort mit `nil`.

Patch 4u (Doppelklick-Wortauswahl zellenbasiert, 2026-07-24):
`textOffsetAtPoint` rundet als Einfüge-Position auf — ein Klick auf die rechte
Hälfte des letzten Wortzeichens landet auf dem Folgezeichen, und der
Doppelklick markierte dessen Leerraum statt des Worts. NSTextView und BBEdit
wählen das Wort über die getroffene Zeichenzelle; der Patch rückt die
Auswahlbasis vor `selectWord` entsprechend zurück.

Patch 4v (Drag-Anker am Maus-Down, 2026-07-24): Upstream verankert eine
Maus-Selektion erst im ersten `mouseDragged`. Schnelle Bewegungen liefern grob
gerasterte Events; das erste Drag-Ereignis kann weit vom Klickpunkt entfernt
liegen und wird unterhalb des Fensters aufs Dokumentende geklemmt — die
Auswahl begann dann dort statt am angeklickten Zeichen. Der Patch setzt den
Anker bereits im `mouseDown`.

Die Selbsttests dazu: `./selftest.sh rightedge` stellt die gemeldete
Nutzergeometrie her (1100×800, Seitenleiste, integrierte Markdown-Vorschau,
Zeilen bis 646 Zeichen) und prüft ein Raster von Klickpunkten bis einen Punkt
vor dem vertikalen Scrollbalken per Fenster-Hit-Test und Koordinatenabbildung,
anschließend einen echten Doppelklick auf das letzte Zeichen eines Worts an
der Umbruchkante. `./selftest.sh dragscroll` zieht eine echte Maus-Selektion
40 Punkte unter das Fenster und verlangt Autoscroll plus einen am Klickpunkt
verankerten Auswahlbeginn. `./selftest.sh selshort` wiederholt den
Tastatur-Scrolltest in der kleinen, stark umbrochenen Datei des
Fehlerberichts. `./selftest.sh dirtyundo` sichert den Änderungspunkt im Tab:
Einfügen → Punkt, exakte Rücknahme per Undo oder manuellem Löschen → Punkt
weg, Redo → Punkt wieder da.
`./selftest.sh emojisplit` schiebt die Umbruchgrenze über 121 Vorschau-
Breiten durch eine Emoji-Zeile und verlangt, dass kein Surrogatpaar in
Attributläufen, Umbruchfragmenten oder Glyphen zerfällt. `./selftest.sh
comment4d` editiert in einem langen 4D-Kommentarblock und verlangt
Kommentarfarbe bis zum Blockende (siehe F.22). `./selftest.sh sighelp4d`
prüft die 4D-Parameterhilfe End-to-End: Panel mit Signatur und
Kommentarkopf innerhalb der Klammern, in verschachtelten Aufrufen erst die
innere und hinter deren schließender Klammer wieder die äußere Methode,
ausgeblendet außerhalb.

Patch 4z2 (Fließtext-Einrückung, 2026-08-11): TextFormations allgemeine
Klammermuster behandelten auch reinen Text und Markdown wie Quellcode. Eine
Zeile, die mit `(` begann, erhöhte die Einrückung; der Rückwärtsscan übersprang
danach eine bewusst geleerte Zeile und holte die Einrückung immer wieder
zurück. Für `.plainText` und `.markdown` verwendet Fastra keine Code-Muster und
die unmittelbare Vorzeile als einzige Referenz. `./selftest.sh mdindent` treibt
die echte TextView mit einem datenschutzneutralen Abbild der gemeldeten
`.txt`-Datei durch beide Return-Schritte.

Patch 4z3 (externer Bild-Drop, 2026-08-11): SwiftUIs `onDrop` übermittelt dem
Markdown-Assistenten keine Textposition. CodeEditTextView übernimmt externe
Bild-Drops deshalb vor seinem normalen Text-Drag, zeichnet eine Einfügemarke an
der Mausposition und scrollt per Timer weiter, solange die Maus am oberen oder
unteren Rand steht. Nicht akzeptierte Pasteboards laufen unverändert durch den
Upstream-Pfad. Die versionierte Ergänzung liegt unter
`app/Patches/CodeEditTextView/`; Marker, kopierte Quelle und Routing werden nach
jedem Anwenden geprüft. `./selftest.sh mddropcursor` beobachtet Cursor, echten
Rand-Autoscroll und den Link exakt an der beim Loslassen bestimmten Textposition.

Patches 4z4–4z12 (Megazeilen, 2026-08-12–14): Sichtbare Textbereiche und
Syntaxattribute bleiben auf den Viewport begrenzt, CoreText arbeitet in
handlichen Portionen, Soft Wrap hält nur sichtbare Fragment-Views und der
Wortumbruch langer ASCII-Tokens vermeidet Substrings sowie wiederholte
Foundation-Zeichensatzobjekte. Unicode nutzt weiterhin den exakten allgemeinen
Umbruchpfad. Patch 4z8 entfernt zusätzlich drei dokumentweite
`NSAttributedString`-Kopien aus dem ersten Layout. Patch 4z9 überspringt das
vorzeitige Voll-Layout beim Einhängen in ein Fenster und nimmt einen bereits
geplanten AppKit-Durchlauf nicht synchron aus einer Viewport-Benachrichtigung
vorweg. Patch 4z10 wartet vor dem ersten Umbruch kurz auf die dicht
aufeinanderfolgenden SwiftUI-Aktualisierungen von Text, Attributen und Insets
und bündelt ihre Invalidierungen zu einem fenstergebundenen Layoutlauf.
Normales Scrollen und spätere Layouts bleiben unmittelbar. Patch 4z11 erzeugt
Fragmentkennungen aus einer erst beim tatsächlichen Typeset erzeugten UUID pro
logischer Zeile und einem fortlaufenden Index, statt für jedes der rund 50.000
Umbruchfragmente einer Megazeile eine eigene UUID anzufordern. Die Generation
trennt unabhängige Typesetter; der Index bleibt darin eindeutig.
Patch 4z12 erzeugt Fastras internen Klartextspeicher mit bereits vollständigen
Schrift- und Farbattributen und meldet sie als sofort gültig. Damit entfällt
AppKits dokumentweite, erst beim ersten CoreText-Layout ausgelöste
Attributkorrektur. Die Backing-Methoden liegen in Objective-C, damit derselbe
Pfad auch in unoptimierten Debug- und Test-Builds schnell bleibt. Fremde,
explizit übergebene `NSTextStorage`-Instanzen werden weiterhin wie bisher
behandelt.
Jeder Teil besitzt eigene Marker und eine harte Prüfung direkt nach dem
Anwenden. Wächter sind `DifficultDocumentCorpusTests`,
`LongLineEditorPerformanceTests` und `./selftest.sh loadperf`.

### Bundle-Größe — Apple-Silicon-only, ~57 MB (Stand 2026-07-15)

Das Bundle war einmal 489 MB. Drei Ursachen, alle in `build.sh` adressiert:
1. **Kein Intel.** Fastra wird nur für arm64 gebaut (Produktentscheidung 2026-07-08).
   `swift build` baut ohnehin nur die Host-Arch; die einzige x86_64-Quelle war das
   Grammatik-XCFramework (s. u.), das jetzt nicht mehr mitwandert.
2. **Grammatik-XCFramework NICHT mehr ins Bundle kopiert** (Bundle-Schritt in build.sh).
   `CodeLanguagesContainer` (CodeEditLanguages, `.binaryTarget`) ist ein STATISCHES
   ar-Archiv (~375 MB, universal): zur Build-Zeit ins Binary gelinkt, zur Laufzeit nie
   geladen (dyld kann kein ar-Archiv laden; nicht in `otool -L`). War reines totes Gewicht.
   Nur echte dynamische Frameworks (.dylib-Binary) dürften wieder kopiert werden.
3. **Exotische Grammatiken ausgeschnitten (Patch 4g).** Jeder `case .X: return tree_sitter_X()`
   in `CodeLanguage.swift` erzwingt die statische Linkage der Grammatik-.o (teils zweistellige
   MB). Patch 4g ersetzt den Rückgabewert der Exoten durch `return nil` → Linker lässt die .o
   draußen. Ausgeschnitten: Verilog, OCaml(+Interface), Julia, Haskell, Scala, Agda, Elixir,
   Zig (~50 MB). Dart + alle Mainstream-Sprachen bleiben. Cut-Sprache = kein Highlighting
   (Plaintext), sonst unberührt. Neue Sprache streichen: Case-Zeile in die 4g-Schleife.
4. **Release strippt + signiert ad-hoc neu.** `strip -x` (nur ~wenige MB, Grammatiken
   dominieren) invalidiert auf Apple Silicon die Signatur → `codesign --force --sign -`
   direkt danach, sonst startet die App nicht. Nur im Release-Build; Debug behält Symbole.

---

## QA-Strategie — Automatisierte Tests

- **Logik** automatisiert via [Swift Testing](https://developer.apple.com/xcode/swift-testing/) (Apple, ab Xcode 16). **UI und Visuelles** manuell — XCUITest ist aus Wartungssicht nicht vertretbar.
- **Verbindlicher Einstieg:** `cd app && ./test.sh` führt immer beide
  Unit-Test-Phasen in derselben isolierten Sandbox aus. Die schnelle Phase läuft
  parallel. Tests mit echten Git-Prozessen, temporären Repositories oder lokalen
  Remotes tragen im Swift-Bezeichner das stabile Kennzeichen
  `gitIntegration`/`GitIntegration`; derselbe reguläre Ausdruck schließt sie in
  Phase 1 aus und wählt sie in Phase 2 vollständig für einen seriellen Lauf aus.
  Prozessnahe Runner-Regressionen tragen getrennt davon das Kennzeichen
  `serialRunnerIntegration`/`SerialRunnerIntegration`, weil sie selbst
  Prozessgruppen, Pipe-Grenzfälle oder Cleanup-Läufe starten und den parallelen
  Kern sonst künstlich belasten. Dazu gehören auch die Smart-Paste-Fixtures
  mit echten Shell-Prozessen, geerbten Deskriptoren und Ausgabebudgets. Ihre
  Zeitgrenzen bleiben unverändert. Dasselbe gilt für die ripgrep-Prozessfixtures:
  Ausgabegrenzen, Timeout und Abbruch werden mit unveränderten Produktfristen
  geprüft, ohne mit hunderten gleichzeitig gestarteten Testaufgaben um
  Prozess- und Threadressourcen zu konkurrieren.
  Auch die asynchrone JSON-Responsivitätsmessung
  trägt diesen Marker: Ihre Wanduhrgrenzen dürfen nicht die Arbeit fremder
  MainActor-Tests während der Parser-Wartezeit mitmessen. `.serialized` an
  ihrer Suite allein verhindert diese Überlagerung nicht.
  Dasselbe gilt für `ExternalDiffServiceSerialRunnerIntegrationTests`: Die
  echten Annahme-/Zustellfristen dürfen nicht durch schwere Editor-Tests auf
  demselben MainActor ablaufen. Die Fristen selbst bleiben unverändert.
  `MarkdownVisualTests` läuft ebenfalls im frischen seriellen Prozess. Die
  echten WebViews sollen keine verbliebenen Layout- und Hintergrundaufgaben
  des großen Editor-Belastungskorpus übernehmen; alle Formatierungs-, Speicher-
  und Wiederöffnungsprüfungen bleiben unverändert aktiv.
  Die Renderer-Fixtures übernehmen keinen Desktop. Der gehostete Runner meldet
  auch nach `orderFrontRegardless` keinen sichtbaren Fensterzustand; dieser ist
  deshalb keine Voraussetzung der Renderer-Prüfung. Sichtbare Bedienung wird
  separat mit den nativen Fenster-Selbsttests abgenommen. Das Fixture-Fenster
  hält seinen Workspace bis zum Schließen.
  Die sichtbaren, lokalisierten Testtitel sind ausdrücklich kein Teil der
  Gruppierung. Für gezielte Runner-Diagnosen stehen `./test.sh --fast-only` und
  `./test.sh --serial-integration-only` bereit; ohne diese Optionen bleibt der
  Lauf vollständig. Weitergereichte `--filter`-Ausdrücke werden mit dem
  jeweiligen Phasenmarker geschnitten. Swift 6.3 vereinigt mehrere Filter
  ansonsten und würde schnelle Zieltests in der seriellen Phase erneut starten.
- Asynchrone Workspace-Prüfungen verwenden den gemeinsamen `waitUntil` aus
  `TestWaiting.swift`, auch die Git-Diff- und Sync-Helfer. Nach einer verzögerten
  Main-Queue-Zustellung muss der bereits erreichte Zustand noch geprüft werden;
  eine vorher abgelaufene Wanduhrfrist allein ist kein Zustandsfehler.
  Abbruchtests prüfen die synchrone Abbruchanforderung getrennt vom späteren
  Taskabschluss und warten auf dem MainActor niemals blockierend darauf.
- CLI-Fixtures verwenden `Tests/FastraTests/Support/TestProcess.swift`.
  Der gemeinsame Helfer begrenzt Prozessende und Ausgabe auf standardmäßig
  120 Sekunden. Nach Überschreitung wirft er einen Fehler samt bisheriger
  Ausgabe, sendet TERM an verifizierte Mitglieder seiner eigenen Prozessgruppe
  und nach 0,5 Sekunden KILL. Die Prüfung wartet auch auf geerbte Ausgabepipes;
  ein früh beendeter Elternprozess kann den Test dadurch nicht hängen lassen.
  Absichtlich in neue Sitzungen abgesetzte Kinder bleiben Aufgabe der jeweiligen
  Fixture und ihrer eigenen Aufräumlogik.
- **Maschinenlesbarer Abschluss:** Jede Phase meldet eine
  `FASTRA_TEST_PHASE`-Zeile, der Gesamtlauf eine `FASTRA_TEST_SUMMARY`-Zeile.
  Funktionsfehler ergeben Exit 1 und behalten Vorrang, falls danach zusätzlich
  ein Start-, Sandbox- oder Prozess-Cleanup-Problem auftritt. Exit 2 ist
  ausschließlich solchen Umgebungsproblemen ohne Funktionsfehler vorbehalten.
- **Workflow:** Tests werden parallel zur Implementierung geschrieben. Eine Phase gilt erst als abgeschlossen, wenn alle Tests grün sind.
- **Coverage:** über 700 Tests; Schwerpunkte sind RegEx-/Platzhalter-Parsing,
  Capture Groups, Find/Replace, Datei-/Projekt-/Git-Logik, Encoding,
  Zeilenenden, Hex-/Großdatei-Routing und Textoperationen.
- **Veröffentlichungs-Hygiene:** `cd app && ./public-history-audit.sh` prüft den
  ausgehenden Stand gegenüber dem öffentlichen Remote auf interne Angaben —
  private IP-Bereiche, absolute Home-Pfade, E-Mail-Adressen und ssh-Remotes in
  Commit-Nachrichten, dazu die eigenen Rechner-/Hostnamen aus der
  gitignorierten `app/public-history-patterns.local` (auch gegen hinzugefügte
  Zeilen). Im Release-Lauf bleibt jeder ungeprüfte Fund ein harter Fehler.
  Semantisch bestätigte historische Fehlalarme können in
  `app/public-history-reviewed.sha256` exakt dokumentiert werden: Eine Zeile
  enthält nur den vom Audit als `sha256=…` ausgegebenen Hash. Dieser bindet
  Fundart, volle Commit-ID und vollständige Fundzeile; derselbe Text in einem
  neuen Commit oder mit anderem Inhalt bleibt gesperrt. Neue Einträge erfordern
  eine bewusste Prüfung, keine automatische Übernahme der Audit-Ausgabe.
  Ungültige IDs und Scannerfehler brechen weiterhin hart ab. Ohne die lokale
  Musterdatei greifen nur die eingebauten Muster; das Skript weist darauf hin.
  Exit 2 bedeutet nur „kein öffentliches Remote bekannt" — dann erst
  `git fetch <remote>`.
- **Lokalisierung:** `cd app && ./localization-audit.sh` vergleicht statische
  SwiftUI-Schlüssel mit der englischen Tabelle und prüft Format-Platzhalter.
  `./selftest.sh localization` prüft danach die Tabellen im fertig gepackten
  Haupt-App- und SwiftPM-Ressourcenbundle sowie die lokalen KaTeX-, Mermaid-
  highlight.js- und Turndown-/WYSIWYG-Dateien.
  Das Skript braucht `rg`; fehlt ripgrep im PATH (nicht jeder Mac hat es
  installiert), nimmt es das im Repo mitgelieferte Binary unter
  `app/Sources/Fastra/Resources/ripgrep` (seit 2026-09-02).
- **Suchmasken-Layout:** `./selftest.sh searchlayout` vermisst die Suchmaske
  in jedem Bereich (Datei, Geöffnet, Ordner, Projekt) bei Mindestbreite und 1000 pt:
  Tab-Beschriftungen einzeilig, kein Bedienelement außerhalb des Fensters,
  Trefferliste mindestens 25 % der Höhe. Mit
  `FASTRA_SEARCHLAYOUT_DIR=<ordner>` legt er je Kombination ein PNG des
  Fensterinhalts ab (`search-<Bereich>-<Breite>.png`) — nach jeder Änderung
  an der Suchmaske alle Bereichs-, Breiten- und Mustervarianten ansehen (Befund 2026-09-15).
- **Trefferfreigabe:** `./selftest.sh searchapproval` bedient Treffer- und Datei-Checkboxen, Alle/Keine, die vollständige Vorschau und Apply per echten AppKit-Ereignissen. Er prüft Speicher-/Plattenänderungen, natives Undo/Redo, gemeinsame Rücknahme, Read-only und Ticketentwertung. `FASTRA_SEARCHLAYOUT_DIR` sammelt die befüllten vier Bereiche in hell/dunkel bei Mindestbreite/breit sowie die Vorschau- und Fehlerzustände. Alle Sprachfassungen visuell prüfen.
  `./selftest.sh searchapprovalclose` verzögert den getrennten Webprozess kurz und schließt das Sheet per Maus während einer realen Synchronisierung. Die Rückmeldung darf danach keine Speicheränderung mehr ausführen. Die Probe kontrolliert die unveränderte Quelle vor Apply und protokolliert Vorher/Nachher und den Rücknahmestand. Die Undo-Probe schließt die Suchmaske über ihren nativen Fensterknopf und fokussiert den Dokumenteditor per Mausklick; vor ⌘Z müssen das Hauptfenster und dessen Editor tatsächlich den Tastaturfokus besitzen. Eine gesetzte First-Responder-Referenz allein belegt das aktive Fenster nicht. Sie benötigt wie `searchapproval` eine kontrollierte Fokus-Sitzung.
- **Übrige Dialoge:** `./selftest.sh dialoglayout` öffnet Einstellungen,
  Dateivergleich und die vier Blätter der Suchmaske (Extraktion, Vorlagen,
  Beispiel-Ableitung, Datei-Set) und prüft, dass kein Bedienelement über den
  Inhalt hinausragt oder auf null Breite gedrückt ist. Mit
  `FASTRA_DIALOGLAYOUT_DIR=<ordner>` entsteht je Dialog `dialog-<name>.png`.
  Die Blätter öffnet der Test über die Notification
  `fastraSelfTestSearchSheet` (reiner Testhaken in `FloatingSearchDialog`).
- **Fokus der Suchmaske:** `./selftest.sh searchfocus` schließt und öffnet die
  Maske per ⌘F, ⇧⌘F und Menüpunkt in Datei- und Projekt-Bereich und verlangt
  jedes Mal das Suchfeld als First Responder, auch nach einem Klick in
  „Ausschlüsse" (Befund 2026-09-15).
- **README-Aufnahmen:** `./screenshot-run.sh [all|de|en] [all|search]` verwendet
  den gemeinsamen Selbsttest-Runner mit GUI-Sperre, Test-Sandbox und begrenztem
  Prozess-Cleanup. `search` erzeugt nur die beiden Suchmasken. Die Sprachwahl
  setzt auch die Beispieldaten; Light Mode gilt ausschließlich im Testprozess.
  `FASTRA_SELFTEST_SCREENSHOT_DIR` wählt bei Bedarf ein anderes Zielverzeichnis,
  sonst entstehen die Dateien unter `screenshots/` im Projekt-Root. Die normale
  Binary-Auswahl über `FASTRA_SELFTEST_APP_BIN` gilt auch für diese Aufnahmen;
  für eine installierte App auf deren `Contents/MacOS/Fastra` zeigen. Ein gesperrter
  Bildschirm oder fehlende Aufnahmeberechtigung ergibt Exit 2; das Werkzeug
  fordert keine neue Berechtigung an. Die Fensteraufnahme verwendet
  `screencapture -x` ohne Kameraton und ersetzt ein vorhandenes Bild erst nach
  erfolgreicher Aufnahme. Danach beide Sprachfassungen visuell prüfen.
- **Markdown-Umwandlung:** `./selftest.sh markdownimport` läuft fensterlos gegen
  das echte `poormans-text`: Formatkatalog (RTF als Datei, RTFD als Paket),
  Zwischenspeicher, Öffnen/Abbruch aller gemeldeten Endungs-/Containerkombinationen,
  echter DOCX-Direktimport, RTF-Öffnen mit Umwandeln/Quelltext/Abbrechen, eine Umwandlung
  ohne Bilder, eine mit eingebettetem PNG und
  der Kollisionsschutz — jeweils an echten temporären Dateien. Der RTFD-Paketweg
  prüft außerdem zusammenhängende Aufzählungen mit wörtlichem „• “ und erhält
  gewöhnliche Absatzgrenzen. Fehlt das
  Werkzeug oder kennt es `--formats` noch nicht, meldet der Test ein
  Umgebungsproblem (Exit 2) statt eines Funktionsfehlers. Gegen einen frisch
  gebauten, noch nicht installierten Stand testen:
  `FASTRA_POORMANS_TEXT=<pfad>/.build/debug/poormans-text ./selftest.sh markdownimport`.
  `markdownimportui` bedient die echten RTF-/DOCX-Dialoge mit und ohne Pandoc
  sowie Fortschritt, Abbruch, Warnungen und Fehler. `FASTRA_MARKDOWN_IMPORT_UI_DIR`
  speichert Fensteraufnahmen. Für eine isolierte native Abnahme hält
  `FASTRA_MARKDOWN_IMPORT_REVIEW_DIR=<ordner>` die Testinstanz nach den Prüfungen
  höchstens 300 Sekunden offen: `ready` meldet Bereitschaft, `continue` beendet
  die Abnahme. Der Runner erlaubt dafür 420 Sekunden; normale Läufe behalten
  ihre bisherige Frist. Nutzer-Einstellungen und Sitzungsdaten bleiben isoliert.
- **Markdown-Vorschau:** `./selftest.sh markdown` lädt ein echtes temporäres PNG,
  eine TeX-Formel, einen Swift-Code-Block und ein Mermaid-Diagramm. Der Test liest
  unabhängig das fertige WebKit-DOM: Bildbreite, MathML, SVG und Highlight-Spans
  müssen tatsächlich vorhanden sein.
- **Klick-Sprung aus der Vorschau:** `./selftest.sh markdownjump` klickt im echten
  WebKit-DOM mitten in einen dreizeiligen Absatz und erwartet den Cursor auf der
  passenden Dateizeile. Genau dieser Fall lässt sich nicht als String-Test
  abbilden: Der Block kennt nur seine erste Zeile, die restlichen löst erst das
  Vorschau-JS über die Zeilenumbrüche vor der Klickstelle auf. Steht der Cursor
  am Absatzanfang statt in der geklickten Zeile, ist diese Auflösung defekt.
- **XPath-Sprung:** `./selftest.sh xpath` tippt die Query bewusst SOFORT nach
  dem Öffnen der Leiste, also bevor der asynchrone Index fertig ist — genau der
  Fall, in dem der Sprung verloren ging. Die Fixture ist deshalb absichtlich
  groß (rund 4000 Elemente): Bei einer winzigen Datei ist der Index manchmal
  schon fertig, und der Test wäre je nach Systemlast mal grün, mal rot. Die
  Erfolgsmeldung weist aus, welcher Fall geprüft wurde; steht dort „Index war
  bereits fertig", lief der Lauf am eigentlichen Risiko vorbei.
- **tool4d-LSP:** `./selftest.sh tool4dlsp` braucht zwei Dinge, sonst meldet er
  ein Umgebungsproblem (Exit 2): ein installiertes tool4d und eine ausdrücklich
  übergebene **sichere Kopie eines echten 4D-Projekts**:
  `FASTRA_TOOL4D_TEST_PROJECT=<kopie> ./selftest.sh tool4dlsp`. Der Ordner muss
  in sich oder in seinem `Project`-Unterordner eine `.4DProject`-Datei haben;
  die geprüfte Methode wählt der Test als erste `.4dm` aus
  `Project/Sources/Methods` (alphabetisch, damit die Auswahl reproduzierbar
  bleibt) oder nimmt `FASTRA_TOOL4D_TEST_DOCUMENT` innerhalb des Projekts.
  Niemals das echte Arbeitsprojekt übergeben — der Test startet einen echten
  tool4d-Sprachserver darauf.

  Ein selbst zusammengesetztes Minimalprojekt genügt NICHT: Mit einer bloßen
  `.4DProject`-Datei plus einer `.4dm`-Methode liefert tool4d innerhalb der
  Wartezeit keine Diagnosen, und der Test schlägt als Funktionsfehler fehl,
  obwohl am Produkt nichts defekt ist (geprüft 2026-07-28). Welche
  Projektbestandteile tool4d wirklich braucht, ist offen und gehört am echten
  Bundle erhoben — nicht geraten.
- **Hell-/Dunkel-Wechsel der Vorschau:** `./selftest.sh markdownappearance`
  startet bewusst dunkel und schaltet erst im laufenden Betrieb auf hell. Nur
  dieser Ablauf deckt den Fall auf, dass `underPageBackgroundColor` einmalig
  gesetzt wurde und WebKits eigene Ableitung einfriert — ein Start direkt im
  Zielmodus bliebe grün. Gegengeprüft: Mit der Farbe nur in `makeNSView`
  schlägt der Test fehl, mit dem Setzen bei jedem Update besteht er.
- **Drucken:** `./selftest.sh print` druckt alle sechs Fassungen (Quelltext,
  Markdown-Vorschau, Markdown-Quelltext, Hex-Abzug, Bild, PDF) ohne Drucker in
  PDF-Dateien und prüft am ERGEBNIS: Seitenzahl, enthaltener Text, gerenderter
  Diagramm- und Formelinhalt statt rohem Markdown, keine umgebrochene
  Hex-Rasterzeile. Zum Schluss prüft er die ⌘P-/⌥⌘P-/⇧⌘P-Menüpunkte
  strukturell (exaktes Kürzel samt Modifiern), löst den Druckbefehl aus und
  belegt, dass das System-Druckfenster am Dokumentfenster öffnet und darin
  die Fastra-Optionen (Kopf-/Fußzeile, Zeilennummern) stehen. Ein
  synthetisches ⌘P-Event kann die SwiftUI-Menü-Bindung nicht auslösen
  (nachgemessen 2026-08-18: SwiftUI-Menüpunkte tragen kein Target/Action, und
  die Shortcut-Zustellung springt für `NSApp.postEvent`-Events nicht an; ein
  echter Tastendruck öffnet das Blatt — per System-Events-Probe belegt).
  Möglich macht das
  `jobDisposition = .save` mit einer im Programm gesetzten Ziel-URL — derselbe
  Druckweg wie beim Nutzer, nur ohne Dialog.

  Für eine Sichtprüfung des Umbruchs bleiben die erzeugten PDFs liegen:
  `FASTRA_PRINT_TEST_OUTPUT_DIR=<ordner> ./selftest.sh print`. Der Test legt
  darunter je Lauf einen frischen `fastra-print-<UUID>`-Unterordner an und
  schreibt nie direkt in den angegebenen Ordner — seine festen Dateinamen
  (`quelltext.txt`, `bild.png`, …) würden dort sonst gleichnamige vorhandene
  Dateien überschreiben. Ohne die Variable räumt der Test seinen Ordner wieder
  auf.
- **Nicht getestet:** visuelles Rendering von Diff/Tokens/Pillen und
  OSS-Framework-Interna von CodeEditSourceEditor. Kritische
  App-weite Bridges werden dagegen über In-App-Selbsttests abgesichert.
- **Zwei-Tab-Vergleich:** `./selftest.sh tabcompare` lädt zwei echte
  Dokumente, sendet einen Shift-Klick durch die Fenster-Eventpipeline und
  beobachtet unabhängig die stärkere Primär- und schwächere
  Vergleichsmarkierung. Anschließend müssen beide Tab-IDs als linkes/rechtes
  Feld im echten Vergleichs-Sheet erscheinen; ein normaler Klick muss die
  Paar-Auswahl wieder aufheben.

### Regressions-Schutz — Lehre aus dem „Zombie-Find-Bar" (2026-05-27)

Die Find-Leiste tauchte bei CMD+F mehrfach wieder auf. Der korrekte Befund nach gründlicher Analyse:

1. **Echter Root Cause:** Der „Zombie" ist NICHT die macOS-NSTextView-Find-Bar, sondern **CodeEditSourceEditors eigenes Find-Panel**. Der Editor installiert beim Laden einen EIGENEN lokalen `keyDown`-Monitor (`TextViewController.handleCommand`), der bei fokussiertem Editor CMD+F abfängt und `showFindPanel()` aufruft. Deshalb halfen `disableFindBars`/Menü-Purge nie — die zielen auf den FALSCHEN Mechanismus (Standard-NSTextView-Find), nicht aufs Editor-eigene Panel.
   **Was NICHT funktioniert:** Versuchen, den Konflikt über die Reihenfolge konkurrierender `NSEvent`-Local-Monitore zu gewinnen (LIFO/„neuester zuerst"). Diese Reihenfolge ist in der Praxis **nicht zuverlässig steuerbar** — Reinstall-auf-Notification und Launch-Timer waren beide flaky (per Selbsttest reproduziert).
   **Zwischenschritt (Write-back-Reconcile, reicht NICHT ganz):** CodeEditSourceEditors Coordinator schreibt `findPanelVisible` in den `SourceEditorState`-Binding ZURÜCK, wenn sein Panel öffnet (`SourceEditor+Coordinator`). Wir beobachten `editorState.findPanelVisible` in `EditorView`: wird es `true`, setzen wir es sofort `false` (der Editor reconciled → Panel schließt) und öffnen STATTDESSEN unsere Suchmaske (`.fastraShowSearchFile`). Problem: `showFindPanel()` animiert das Panel 0,15 s EIN, bevor unser `false` es wieder schließt — es **blitzt kurz auf** (reproduzierbar bei rapidem CMD+F + Klick ins Hauptfenster).
   **Finaler Fix (deterministisch, 2026-06-03):** `build.sh` patcht den resolved CESE-Checkout — der CMD+F-Zweig in `TextViewController.handleCommand` ruft nicht mehr `showFindPanel()`, sondern `return event` (CMD+F wird durchgereicht). Damit zeigt der Editor sein Panel NIE, egal wer das Monitor-Rennen gewinnt; CMD+F fängt ausschließlich unser App-Monitor ab. Der Patch fügt sich in das bestehende `build.sh`-Patch-Muster (nicht-invasiv, idempotent, verifiziert dass er greift, invalidiert die CESE-Build-Artefakte — SPM trackt Checkout-Änderungen sonst NICHT). Write-back-Reconcile + Reinstall-Hack (`installKeyMonitor`/`installFlagsMonitor` auf `didBecomeKey`/flagsChanged) bleiben als Sicherheitsnetz. Unser App-Monitor deckt zusätzlich CMD+F bei NICHT fokussiertem Editor sowie CMD+SHIFT+F/ESC ab.

2. **VERBOTENER Irrweg (kostete eine Session):** `NSApplication` zu subclassen, um CMD+F in `sendEvent` abzufangen — egal ob via `NSPrincipalClass` (wird unter SwiftUI ignoriert) oder via eigenem `main.swift`, der `CustomApp.shared` vor `App.main()` verankert. Letzteres ERSETZT SwiftUIs interne `SwiftUI.AppKitApplication`, deren eigenes Event-Routing dann fehlt → **die gesamte App wird maus-tot** (keine Klicks, kein Fenster-Schließen, CMD+Tab bringt nicht nach vorn). **Niemals NSApplication unter SwiftUI-Lifecycle subclassen.** Zur Laufzeit ist `NSApp.className == "SwiftUI.AppKitApplication"` — das ist korrekt und soll so bleiben.

3. **In-App-Selbsttests** (`SelfTest.swift`, kein Accessibility nötig — Events werden intern gepostet). **Aufruf: bevorzugt über den Runner `./selftest.sh` (alle Tests oder `./selftest.sh findbar jump`), direkt via `Fastra -selftest findbar -ApplePersistenceIgnoreState YES` oder Umgebungsvariable `FASTRA_SELFTEST=findbar`.** `-selftest findbar` postet ein echtes CMD+F bei fokussiertem Editor und **pollt ~1,2 s engmaschig**, ob das Editor-Find-Panel AUCH NUR KURZ auftaucht (eine Einzel-Messung am Ende würde das Aufblitzen verpassen). `-selftest newwindow` löst den echten ⌘N-Menübefehl aus und prüft im Hintergrund ein zweites, passend großes Dokumentfenster mit unabhängigem Workspace und gültigem Editor-Einfügepunkt. Den echten Fokuswechsel, ⌘T zwischen zwei Workspaces und ⌘W am letzten Tab prüft anschließend der fokuspflichtige Sammeltest `cmdw`; er schließt zuvor bereits Suchmaske und Hilfe jeweils per echtem ⌘W. `-selftest fields` prüft, ob Suchen- UND Ersetzen-Feld echte, editierbare, betippbare Texteingaben sind (fing den toten Find-Feld-Bug). `-selftest tabswitch` prüft, ob der Editor beim Tab-Wechsel neu erzeugt wird (CESE schiebt Binding-Text nicht zurück → ohne `.id(activeTab.id)` bliebe der Inhalt stehen; via Objekt-Identität vorher≠nachher belegt). `-selftest jump` lädt Text mit unterschiedlich langen Vorzeilen (inkl. Emoji als UTF-16-Surrogatpaar) in einen Tab, postet exakt wie die GUI einen Treffer-Sprung (Zeile/Spalte-Pfad über `postMatchJump`) und liest die ECHTE Editor-Selektion zurück (`CodeEditTextView.TextView.selectedRange()`): der selektierte Text muss exakt der Treffer sein. Fing den toten Treffer-Sprung — CESE 0.15.x reconcilet `cursorPositions` von außen NIE (Bedingung `!= state.cursorPositions` vergleicht mit sich selbst, immer false; in `build.sh` gepatcht auf `!= controller.cursorPositions` + `scrollToVisible`). `-selftest replaceall` lädt den Demo-Inhalt („Nachname, Vorname"), setzt `(\w+), (\w+)` → `$2 $1`, ruft `applyAllInActiveBuffer()` und liest den ECHTEN Editor-`.string` zurück: er muss nach dem Replace den ersetzten Text zeigen (== Modell-Inhalt). Fing die Regression, dass „Alle ersetzen" im Editor folgenlos blieb (CESE übernimmt Binding-Änderungen nicht → in `EditorView` über `editorReloadNonce` an der `.id` eine Neuerzeugung erzwungen). `-selftest pilldrop` fokussiert das Ersetzen-Feld und treibt dessen Drag-Destination-Methoden mit einem `NSDraggingInfo`-Mock („$1"): Annahme (`draggingEntered == .copy`) + Einfügung müssen AUCH bei Fokus klappen. Fing den Bug, dass ein Gruppen-Pillen-Drop aufs fokussierte Ersetzen-Feld verpuffte (NSTextView lehnt Drops bei First-Responder ab → in `RegexFieldTextView` die Destination-Methoden überschrieben). `-selftest windows` ist ein reines Diagnose-Flag (Fenster-Dump über 10 s). Jeder Test schreibt atomar `SELFTEST-RESULT v=1 test=<name> status=PASS|SKIP|ENV|FAIL` und danach die lesbare `SELFTEST <name>: …`-Zeile. Der Runner wertet ausschließlich den strukturierten Status aus; unbekannte Versionen oder Werte sind echte Protokollfehler. Nur bei alten Bundles ohne Maschinenzeile greift noch die fest positionierte Textauswertung. Nach der Auswertung gibt der Runner je Test genau eine kanonische Maschinenzeile aus, auch für ein altes Bundle. Mehrere Befunde werden in der Reihenfolge `FAIL > ENV > SKIP > PASS` zusammengeführt. Fenster-Tests pollen bis 15 s auf ihr Fenster statt nach fixer Frist zu guarden. **Genau die Bug-Klasse (App-weites Event-/Eingabe-Verhalten), die reine Unit-Tests NICHT fangen.** Nach jeder Änderung an Lifecycle/Fenster/Monitoren mehrfach laufen lassen (Flakiness zeigt Race-Conditions).
   Seit v1.19.2 setzt `-selftest newwindow` zusätzlich eine markante
   Ausgangsgröße und vergleicht nach ⌘N den tatsächlichen `NSWindow`-Rahmen,
   damit SwiftUIs spätes Zurücksetzen auf die fitting size nicht unbemerkt bleibt.
   `-selftest multisearch` öffnet zwei Dokumentfenster mit je eigener
   Suchmaske und belegt, dass ein Treffer-Sprung ausschließlich Selektion,
   Fokus und Scrollziel des adressierten Workspace verändert.
   `-selftest sessionrestore` legt vor dem ersten Workspace eine isolierte
   gespeicherte Sitzung an und prüft den echten Kaltstart mit zwei Fenstern,
   drei dateibasierten Tabs, Projekt, aktivem Tab und ohne unbenannten Tab.
   `-selftest windowchrome` öffnet zwei gespeicherte Textdateien gemeinsam über
   den externen Öffnen-Delegate. Es prüft Haupt-, Zusatz- und Restorefenster,
   wiederholtes Öffnen, Tabwechsel und Resize auf ausgeblendeten nativen Titel
   und tatsächlich unsichtbares AppKit-Titelfeld. `FASTRA_WINDOWCHROME_DIR`
   speichert ergänzende Fensteraufnahmen. Der Test läuft ohne App-Aktivierung.
   `-selftest coldopen` startet das Debug-Bundle dagegen über LaunchServices
   mit einer ausdrücklich geöffneten Datei und einer abweichenden gespeicherten
   Sitzung aus zwei Projektfenstern. Es prüft, dass beide Projektfenster
   wiederhergestellt werden und die externe Datei zusätzlich in einem dritten
   Fenster erscheint. `-selftest coldopenoff` verwendet dasselbe Fixture bei
   abgeschalteter Sitzungswiederherstellung und erwartet ausschließlich die
   externe Datei in genau einem Fenster. Für den vorgeschriebenen notarisierten
   Zieltest kann der Runner über
   `FASTRA_SELFTEST_APP_BIN` und `FASTRA_SELFTEST_APP_BUNDLE` auf das bereits
   geprüfte Bundle unter `/Applications` gerichtet werden. Auf einem Test-Mac
   ist das der Standardweg für die ganze Suite: macOS merkt sich
   TCC-Berechtigungen (lokales Netzwerk, Festplattenvollzugriff, Automation …)
   dauerhaft nur für eine stabile notarisierte Code-Identität. Ein
   ad-hoc-signierter Debug-Build erhält mit jedem Build eine neue Identität —
   die Berechtigungsdialoge erscheinen dann bei jedem Lauf erneut (beobachtet
   2026-08-18 auf dem Test-Mac: Abfrage „nach Geräten im lokalen Netzwerk
   suchen" mitten im Suite-Lauf), und Testfehler sind nicht von
   Berechtigungsproblemen unterscheidbar. Einrichtung je Test-Mac: notarisiert
   installieren, Berechtigungen einmal setzen, dann ein Kontrolllauf ohne
   neue Dialoge.
   Auch `soak-test.sh` übernimmt diese beiden Variablen. Ist nur das Bundle
   gesetzt, verwendet es dessen `Contents/MacOS/Fastra`; ein ausdrücklich
   gesetztes Binary hat Vorrang. Für Direktstart, Messung und Aufräumen wird
   dessen tatsächlicher Bundle-Pfad verwendet. Ohne Vorgabe bleibt der lokale
   Debug-Build der Standard. Die Pfadauswahl ersetzt keine Notarisierungsprüfung.
   `-selftest projectinput` öffnet die echte Projekt-Suchmaske, betippt das
   native Ausschlussfeld und verlangt noch im selben Main-Thread-Umlauf eine
   leere Treffer-, Navigations- und Apply-Basis. Der Test misst zusätzlich die
   synchrone Eingabedauer und setzt den First Responder direkt im
   Hintergrundfenster; globalen Vordergrundfokus braucht er nicht.
   Die nicht zur Standardsuite gehörenden Diagnosemodi `projectperf` und
   `projectopenperf` benötigen ausdrücklich
   `FASTRA_PROJECT_PERF_ROOT=/pfad/zum/nur-gelesenen-projekt`:
   `projectperf` führt ein Warm-up und drei `util_*`-Läufe aus und meldet
   Kandidaten, Treffer, Wall-/CPU-Zeit und Max-RSS; `projectopenperf` misst
   davon getrennt `Project/Sources/folders.json` bis zum tatsächlich
   montierten Editor. Beide verändern den Realbestand nicht.
   `-selftest loadperf` gehört dagegen zur Standardsuite und erzeugt selbst
   eine rein synthetische 4.357.697-Byte-`.txt`-Megazeile. Der Test misst den
   Main-Thread-Herzschlag im 10-ms-Takt durch Datei-I/O,
   `Workspace.loadFile`, Soft Wrap, automatisch sichtbare Fragment-Views,
   Statistik und eine weitere Sekunde Nachlauf. Erst nach der Sichtprüfung
   darf der Test ein Kontrolllayout anfordern; die unveränderte Grenze für die
   größte Main-Thread-Lücke beträgt 250 ms. Für eine
   gezielte Diagnose kann `FASTRA_LOADPERF_FILE` eine andere, nur gelesene
   Datei vorgeben; deren Inhalt wird vom Test weder ausgegeben noch dekodiert.
   `-selftest textop` bedient eine Texttransformation und beide
   Sortierrichtungen über den echten Notification-/Editorpfad und liest den
   tatsächlich sichtbaren Editorinhalt zurück.
   `-selftest markdown` prüft die echte WKWebView-Ausgabe eines lokalen Bildes,
   einer KaTeX-Formel, eines Mermaid-Diagramms und eines hervorgehobenen
   Code-Blocks; ein bloß vorhandenes HTML-Zielelement genügt nicht.
   `-selftest ghosttext` lädt mehrere lange Zeilen und prüft nach Laden und
   Resize die echten CoreText-Fragmente: gezeichnete Nutzlast entspricht dem
   Dokumentbereich, kein Fragment überschreitet die Umbruch-Breite und kein
   Dokumentbereich ist doppelt sichtbar. Er sichert den Fehler ab, bei dem
   Wörter nach Paste/Laden mehrfach erschienen und rechts aus dem Editor liefen.
   **Umgebungs-Fallen beim Selbsttest-Aufruf (2026-06-11, alle in `selftest.sh` gekapselt):**
   - **NIEMALS positionale `--selftest-…`-Argumente verwenden (Root Cause des „kein Hauptfenster"-Bugs).** AppKit interpretiert unbekannte positionale Argumente als „zu öffnende Datei" — die App durchläuft dann den Open-File-Launchpfad statt `applicationOpenUntitledFile`, und SwiftUI erzeugt das WindowGroup-Hauptfenster NIE (`NSApp.windows` bleibt leer, Main-Thread idle; empirisch: JEDES `--flag` löst das aus). `-Key Value`-Argumente (NSArgumentDomain) sind unschädlich → daher `-selftest <name>`. Dass die Fenster-Tests früher trotz `--selftest-…` grün waren, lag mutmaßlich an der Fenster-Restauration aus dem Saved State — die seit 2026-06-11 mitgegebene `-ApplePersistenceIgnoreState YES` schaltete genau diese Krücke ab und machte den Bug sichtbar. Alte Aufrufform wird erkannt und FAILt sofort mit Hinweis.
   - **Immer `-ApplePersistenceIgnoreState YES` mitgeben** (`Fastra -selftest findbar -ApplePersistenceIgnoreState YES`). Nach einem abgebrochenen Lauf (z.B. `pkill` in build.sh) zeigt macOS sonst beim nächsten Start den modalen „Fenster wiederherstellen?"-Dialog (`NSPersistentUIManager`) — die App hängt dann VOR dem Selbsttest endlos (per `sample` diagnostiziert: Main-Thread in `promptToIgnorePersistentStateWithCrashHistory`).
   - **Gesperrter Bildschirm = keine Fenster-Selbsttests.** Bei gesperrter Konsole (`ioreg -n Root -d1 | grep IOConsoleLocked` → Yes) schlagen alle fensterbasierten Tests fehl — das ist Umgebung, nicht Code. Nur die im Runner ausdrücklich als fensterlos markierten Tests sind dann aussagekräftig. `selftest.sh` prüft das vorab.
   - **Nur `cmdw` und `completion4d` brauchen die externe Aktivierung über LaunchServices und System Events.** macOS 26 verweigert einem im Hintergrund gestarteten Prozess die Selbst-Aktivierung komplett (`NSApp.activate` wirkungslos, `isActive` bleibt false — kooperative Aktivierung). `selftest.sh` hält diese Namen in `FOCUS_REQUIRED_TESTS`, startet nur sie via `open`, setzt `FASTRA_SELFTEST_ALLOW_ACTIVATION=1` und holt die App per System Events nach vorn. Für die ausdrücklich hintergrundfähigen Tests setzt der Runner dagegen `FASTRA_SELFTEST_ALLOW_ACTIVATION=0`; auch produktive Fenster-Helfer können die aktive Nutzer-App dann nicht verdrängen. `newwindow`, `projectinput`, `help` und `welcomenew` prüfen weiterhin echte Fenster und brauchen deshalb eine entsperrte WindowServer-Sitzung, laufen dort aber ohne globale Aktivierung. Andere direkt gestartete Tests behalten ihr bisheriges Aktivierungsverhalten und können Fastra selbst aktivieren, solange ihre Fokusabhängigkeit nicht eigens entfernt wurde. Soll so ein Test trotzdem im Hintergrund laufen (jemand arbeitet gerade am Mac, oder ein Agent hat keine Zustimmung zum Fokuswechsel), nimmt `FASTRA_SELFTEST_NO_ACTIVATION="tabflood sessionrestore" ./selftest.sh tabflood` die genannten Namen für diesen Lauf in die Hintergrundliste auf; `tabflood` besteht so (belegt 2026-09-02, Fenster-Menü mit 41 Einträgen). Ein Test, der ohne Aktivierung nicht auskommt, meldet dann einen Umgebungsfehler, keinen Erfolg. Bereits fertige Fokustests brechen die Aktivierungsschleife vor dem nächsten Ein-Sekunden-Warten ab. Arbeitet gleichzeitig jemand aktiv am Mac, kann dessen App den Fokus dennoch zurückholen → der Test meldet einen ausgewiesenen Umgebungsfehler (`selftest.sh`-Exit-Code 2), keinen Funktionsfehler. Für die beiden extern aktivierten Tests den Desktop unbeaufsichtigt lassen oder manuell bewerten.
   - **Ohne Automation-Freigabe antwortet System Events nie (2026-07-26).** In einer ssh-Sitzung oder einem launchd-Job fehlt die Freigabe „darf System Events steuern". Der Apple-Event wartet dann UNBEGRENZT auf den TCC-Dialog, den dort niemand wegklickt — der Runner hing dadurch minutenlang statt einen Umgebungs-FAIL zu melden. `selftest.sh` begrenzt den Aufruf deshalb doppelt (`with timeout of 3 seconds` plus harter Kill nach `ACTIVATE_TIMEOUT_SECS`) und gibt nach der ersten Zeitüberschreitung auf, statt achtmal aufzulaufen. Die Aktivierung übernimmt dann allein LaunchServices (`open` ohne `-g`) — auf einem unbenutzten Mac genügt das für echten Fokus.
   - **Keine Bildschirmaufnahme-Freigabe während eines Testlaufs anfordern.** `typescroll` vergleicht nach Möglichkeit zwei echte Fensteraufnahmen. Neu gebaute, nicht notarierte Debug-Bundles verlieren diese TCC-Freigabe jedoch regelmäßig; ein ungeprüfter `screencapture`-Start öffnet dann einen modalen Systemdialog im Namen von Fastra und entzieht späteren Fenstertests den Fokus. Der Test fragt deshalb nur den bestehenden Freigabestatus ab und nutzt ohne Freigabe sofort seinen AppKit-Ersatz. Er öffnet niemals selbst den Berechtigungsdialog.

   **Fenster-Selbsttests auf einem entfernten Mac (verifiziert 2026-07-26 auf einem unbenutzten Mac):**
   Erst prüfen, ob der Mac wirklich frei ist: `ioreg -n Root -d1 | grep IOConsoleLocked` muss
   `No` liefern, und `ioreg -c IOHIDSystem` → `HIDIdleTime` zeigt, wie lange niemand am Gerät
   war. Dann reicht ein gewöhnlicher `ssh`-Aufruf von `./selftest.sh` — der Runner läuft nicht
   mehr fest, und LaunchServices aktiviert die App. Nur der fokusempfindlichste Test
   (`completion4d`) meldete so einen Umgebungs-FAIL. Wer auch den grün sehen will, startet den
   Runner als kurzlebigen launchd-Job in der Aqua-Session — `launchctl bootstrap gui/<uid> <plist>`
   plus `kickstart`, Ausgabe über `StandardOutPath`, danach `bootout`; dieser Weg überlebt
   sogar einen ssh-Abbruch. `launchctl asuser` braucht root und geht über ssh nicht. Den Stand
   dorthin bringt ein eigener Worktree; `.build/artifacts` vorher aus einem gebauten Checkout
   klonen (`cp -Rc`), sonst scheitert SwiftPM am gesperrten Login-Keychain.

Der gezielte Selbsttest `markdownimportui` prüft die echten RTF-Rückfragen mit
und ohne verfügbares Pandoc, einschließlich aller Dialogknöpfe. Er nutzt eine kontrollierte CLI mit
angehaltener Ausgabe. Er prüft echte Fortschrittsmeldungen vor Prozessende,
den sichtbaren Abbruchknopf, unveränderte Quellen und aufgeräumte Arbeitsordner
sowie Erfolg mit vollständigen Verlustwarnungen und einen Fehler. Mit
`FASTRA_MARKDOWN_IMPORT_UI_DIR` entstehen Aufnahmen der vier Zustände bei
650 und 1100 pt; die deutsche und englische Fassung getrennt starten und
alle Aufnahmen ansehen. `markdownimport` bleibt daneben der echte Importpfad
mit dem installierten Poor Man's Text. Die Unit-Prüfung
`MarkdownImportProgressTests` belegt zusätzlich den Gruppenabbruch samt
Kindprozess und die Kompatibilität älterer CLI-Stände ohne `--progress`.

### MBOX- und ENEX-Sammlungen prüfen

`markdowncollections` ist ein gezielter Integrationstest außerhalb des
Standardlaufs. `tools/linux-probes/make-collections.py` erzeugt in einem neuen
Ordner zwei Nachrichten, zwei Notizen, ein PNG und belegte Zielnamen.
`FASTRA_COLLECTION_REVIEW_DIR` zeigt auf diese Fixtures, `FASTRA_POORMANS_TEXT`
auf die nachweislich zugeordnete echte CLI. Gegen das notarisiert installierte
Bundle ausführen. Der Test übernimmt `index.md`, öffnet sämtliche Unterdokumente
und kehrt zur Übersicht zurück. Anschließend die Datei `reopen` im Fixtureordner
anlegen und denselben Test in einem **neuen App-Prozess** ausführen.

`tools/linux-probes/native-collections.py` ergänzt die echte PMT-Oberfläche und
vergleicht beide vollständigen Bäume mit `verify-collections.py`: Quellbytes,
Anlagen, relative Verweise, Kollisionsschutz und Persistenz. PMT- und Fastra-Builds
vorher über `build-identity.py` zuordnen; eine Versionsnummer allein genügt nicht.
Der externe native Beobachter braucht im **ausführenden Kontext** bestehende
Bedienungshilfenrechte. Ein berechtigter SSH-Prozess belegt keine Rechte eines
autonomen Testdienstes. `--fastra-only` setzt einen bereits gesicherten echten
PMT-Referenzbaum voraus und wiederholt dessen Konvertierung nicht.
Der äußere Testlauf besitzt den eigenen Prozess und stellt gesicherte PMT-
Einstellungen wieder her; die Fastra-Runner verwenden ihre reguläre Sandbox.

### Lokale Laufzeit-Baselines je Mac

Gezielte Engine- und Ordnersuchmessungen einschließlich des optionalen Modus
`searchperf` sind in [SEARCH-PERFORMANCE.md](SEARCH-PERFORMANCE.md) dokumentiert.
Sie ersetzen keine vollständige Laufzeit-Baseline.

Die Vergleichsmessung umfasst nicht nur die Zeit im Testkörper, sondern trennt
Aufräumen, App-Start bis Ergebnis, die von der App gemeldete Laufzeit und den
gesamten Test. Sie bleibt bewusst lokal unter
`$HOME/Library/Application Support/Fastra/SelfTests/<Maschinen-Hash>/` und wird
auf 20 vollständige Läufe je Konfiguration begrenzt. Die rohe Gerätekennung,
der Rechnername und Fixture-Pfade werden weder gespeichert noch ausgegeben.

```bash
cd app
./performance-baseline.sh standard
./performance-baseline.sh status

# Seltener Langlauf; 60 Runden je Phase qualifizieren die Frische-Anzeige.
./performance-baseline.sh long 60

# Optional zusätzlich gegen ein nur gelesenes reales Projekt messen.
FASTRA_PROJECT_PERF_ROOT=/pfad/zur/fixture ./performance-baseline.sh long 60
```

`standard` baut zuerst, führt `./test.sh`, den Lokalisierungs-Audit und die
vollständige Selbsttestsuite aus. Nur ein vollständig grüner Lauf von einem
sauberen, währenddessen unveränderten Git-Stand und App-Binary wird als
Baseline gespeichert. Nur der Wrapper darf die kanonische Historie ergänzen,
weil er das geprüfte Bundle unmittelbar vorher aus demselben Git-Stand baut.
Direkte `selftest.sh`- und `soak-test.sh`-Läufe geben weiterhin Zeiten aus,
verändern Baseline und Frische aber nicht. Einzeltests, Timeouts, Fehler und
Umgebungs-Skips werden diagnostisch gemessen, verändern die Baseline ebenfalls
nicht. Debug/Release,
direkter Start/LaunchServices und verschiedene macOS-Hauptversionen werden nie
miteinander vermischt. Eine nicht blockierende Warnung erscheint erst, wenn ein
Test sowohl mehr als 30 Prozent als auch mehr als eine Sekunde langsamer als
der Median der letzten fünf vergleichbaren Läufe ist.

`long` ergänzt den Standardlauf um den dreiphasigen Dauertest. `projectperf`
wird nur mit gesetztem `FASTRA_PROJECT_PERF_ROOT` hinzugefügt, weil es eine
bewusst ausgewählte, nur gelesene Projektkopie braucht. Der Runner erinnert
nach einem vollständigen Standardlauf an den Langlauf, wenn auf diesem Mac noch
keiner gespeichert wurde, der letzte älter als sieben Tage ist oder seitdem
mindestens 20 relevante App-Commits hinzugekommen sind. Unterschiedliche
Rundenzahlen und Fixture-Profile werden getrennt gespeichert; Rohzeiten solcher
Konfigurationen sind nicht direkt vergleichbar.
Jede Dauertest-Phase muss mindestens eine Arbeitsrunde ausführen und prüfen.
Reine Zustandsprüfungen nach einem Neustart erfüllen diese Bedingung nicht.
`SOAK-ZUSAMMENFASSUNG` nennt die abgeschlossenen Runden im Feld `runden`;
das historische Feld `aktionen` umfasst zusätzlich solche Zustandsprüfungen.
Fokusprobleme stehen als `SOAK-UMGEBUNG` im Protokoll; ein ausschließlich
dadurch unvollständiger Lauf endet mit Exit 2 und speichert keine erfolgreiche
Performance-Baseline. Echte Invarianten-Verstöße behalten auch bei späterem
Fokusverlust Exit 1. Die Zusammenfassung zählt Umgebungsprobleme im Feld
`umgebung` getrennt von `befunde`.

Alle In-App-Selbsttests und der Dauertest verwenden einen gemeinsamen, pro
Nutzer maschinenweiten Lock. Damit können zwei Worktrees ihre App-Prozesse und
den Fensterfokus nicht mehr gegenseitig verfälschen. Ein zweiter Runner endet
als Umgebungsfehler (Exit 2); reine `./test.sh`-Läufe bleiben davon unabhängig.
Ein nachweislich verwaister Lock wird beim nächsten Start übernommen.
Die Besitzerprüfung, Übernahme und Freigabe laufen unter einer kurzen
`flock`-Sperre des Betriebssystems. Dafür bleibt eine leere Datei mit dem
Suffix `.guard` neben dem Lock-Verzeichnis bestehen. Sie darf während möglicher
Runner-Starts nicht gelöscht werden: Sonst könnten zwei Prozesse verschiedene
Dateien sperren. Nach einem Prozessabbruch gibt macOS die Sperre selbst frei;
der Inhalt dieser Datei ist kein Hinweis auf einen laufenden Test.

`./test.sh`, `selftest.sh`, `soak-test.sh` und die beiden vom Build gestarteten
Portabilitäts-Selbsttests geben jedem Lauf außerdem ein eigenes `TMPDIR` und ein
eigenes Core-Foundation-Preferences-Verzeichnis. Die schnelle und die serielle
Git-Phase von `./test.sh` teilen sich genau diese eine Sandbox; zwischen ihnen
wird der Prozessbaum der abgeschlossenen Phase vollständig beendet. Am Ende
wird die Sandbox entfernt, auch bei einem roten Lauf oder Signal.
Foundation beachtet `TMPDIR` dabei nicht: `FileManager.default.temporaryDirectory`
und `NSTemporaryDirectory()` liefern auf macOS immer den Benutzer-Temp-Ordner
(`getconf DARWIN_USER_TEMP_DIR`; belegt 2026-09-17, rund 250 Fixture-Reste
lagen dort). Fixtures der Unit-Tests holen ihre Wurzel deshalb über
`testTemporaryDirectory()` (`Tests/FastraTests/Support/`), die Selbsttests
über `selfTestTemporaryDirectory()`; beide lesen `TMPDIR` selbst. Der Wächter
`TestTemporaryDirectoryTests` lehnt jeden direkten Zugriff in Tests und
`SelfTest.swift` ab.
Benannte `UserDefaults`-Suiten können diese Umleitung auf macOS umgehen und
lassen über `cfprefsd` nach dem Prozessende nochmals eine leere Plist entstehen.
Der Testcode meldet seine exakten UUID-Domains deshalb zusätzlich an den
äußeren Runner; nur dieser kann die letzte leere Plist nach dem Prozessende
sicher entfernen. Ein per SIGKILL oder Rechnerausfall unterbrochener
Sandbox-Rest wird beim nächsten Lauf nach 24 Stunden übernommen, sofern PID
UND Startzeit nicht mehr zum damaligen Besitzer gehören.

AppKit und Sparkle beachten diese Umleitung nicht in jedem Pfad. Die beiden
GUI-Runner sichern deshalb zusätzlich die echte Fastra-Preferences-Domain und
den von AppKit im Nutzer-Temp-Verzeichnis angelegten gespeicherten
Fensterzustand und stellen beide nach dem letzten Testprozess semantisch bzw.
dateigetreu wieder her. Der Lauf beginnt nur, wenn keine andere Fastra-Instanz
läuft und der Snapshot vollständig belegt ist; ein Lese- oder Kopierfehler
bricht ab, ohne den Originalzustand anzufassen. Die maschinenweite GUI-Sperre
wird vor diesen Snapshots erworben.

Die Runner-Fixtures der Unit-Tests (`SelfTestPerformanceTests`) fahren das
echte `selftest.sh` gegen ein Ersatz-Binary. Sie dürfen dabei die echten
Einstellungen nie erreichen: Jede Fixture lenkt Domain und Saved-State-Ordner
über `FASTRA_SELFTEST_PRODUCT_DEFAULTS_DOMAIN` (Testpräfix plus UUID, wie alle
Test-Domains) und `FASTRA_SELFTEST_PRODUCT_SAVED_STATE_DIR` (direkt unter dem
Sandbox-Elternordner der Fixture) auf Wegwerfziele. Ein Lauf mit umgelenktem
`FASTRA_TEST_SANDBOX_PARENT`, dem eine der beiden Variablen fehlt oder deren
Ziel unsicher ist, endet mit Exit 2, bevor er etwas sichert oder startet
(`configure_product_state_overrides`; Review-Fund 2026-09-17: Unit-Tests
schrieben bis dahin Nutzereinstellungen zurück).

`cfprefsd` kann eine bereits geleerte Test-Domain erst nach dem Ende des
Testprozesses nochmals als leere Plist schreiben. Der äußere Runner beobachtet
die exakt registrierten UUID-Domains deshalb weitere 1,5 Sekunden und entfernt
nur diese. Das ist ein fester Abschluss pro Suite, nicht pro Einzeltest.

Die Runner verfolgen auch Kindprozesse und eigene Prozessgruppen. Bei Timeout
oder Signal folgen auf `TERM` und `CONT` nach kurzer Frist ein begrenztes
`KILL` und eine echte Ende-Prüfung; Git-, Import- oder Capture-Prozesse dürfen
nicht im Hintergrund weiterlaufen. Ein zugestelltes `KILL` bestätigt dabei
noch kein Prozessende. Bleibt ein Kind lebendig, kehrt der Cleanup begrenzt mit
einem Fehler zurück und behält Prozessmarken sowie die private Sandbox für die
Wiederherstellung. Er wartet dann weder synchron auf das Kind noch startet er
weitere Hilfsprozesse. In-App-Tests mit Copy/Paste sichern die
allgemeine Zwischenablage itemgetreu innerhalb der Sandbox. Der normale
Abschluss gibt sie selbst zurück, nach Crash oder Timeout übernimmt ein
frischer Hilfsprozess. Hat der Nutzer inzwischen kopiert, bleibt der neuere
Inhalt unangetastet. Sparkle wird im Selbsttest gar nicht gestartet.

Fehlerausgaben der kurzen Selbsttests und Beweise des Dauertests werden mit
Zugriffsrechten nur für den aktuellen Nutzer aufbewahrt; jeweils höchstens die
fünf jüngsten Läufe. Ein per LaunchServices gestartetes Debug-Bundle wird nach
dem Lauf am exakten Pfad wieder abgemeldet. Dasselbe gilt für direkte
App-Starts der Portabilitäts-, Selbst- und Dauertests, weil schon AppKit deren
Debug-Bundle bei LaunchServices registrieren kann. SwiftPM-, Build-,
Dependency- und die begrenzte lokale Performancehistorie liegen bewusst
außerhalb der Wegwerf-Sandbox und bleiben für spätere Läufe erhalten.

**Daraus abgeleitete Test-Leitlinien (verbindlich):**
- **Logik aus AppKit-Glue in pure Funktionen ziehen.** Entscheidungen (Event→Aktion, Footer-Kante, find-bezogener Menüpunkt) leben in `KeyRouting`, `CursorFooter`, `DocumentStats`, `AppDelegate.isFindRelated`. Abgedeckt durch `KeyRoutingTests`, `FooterLogicTests`, `FindBarSuppressionTests`, `RegexElementsTests`.
- **ABER: Pure Unit-Tests fangen die gefährlichste Bug-Klasse NICHT** — App-weite Event-/Lifecycle-/Monitor-Ordering-Fehler. Die `KeyRouting`-Tests waren grün, während die App komplett unbenutzbar war. Lehre: Logik-Tests sind nötig, aber NICHT hinreichend. Jede Änderung an App-Lifecycle/Fenster/Monitoren MUSS zusätzlich real verifiziert werden (manuell oder per UI-Automation).
- **Single Source of Truth.** CMD+F/ESC-Routing existiert genau einmal (`KeyRouting.route`).

## Speicher-Diagnose: `leakscenario` + `leaks`

Das Diagnose-Szenario `-selftest leakscenario` übt Bildvorschau, PDF-Vorschau,
Hex-Ansicht und XPath-Leiste je einmal aus, schließt alles wieder, meldet
`LEAKSCENARIO READY <pid>` auf stderr und bleibt dann ~60 s am Leben — genau
für einen `leaks <pid>`-Durchlauf gegen die laufende App:

```bash
APP=".build/debug/Fastra.app/Contents/MacOS/Fastra"
ERR=$(mktemp); "$APP" -selftest leakscenario -ApplePersistenceIgnoreState YES 2>"$ERR" &
until grep -q READY "$ERR"; do sleep 1; done
leaks "$(awk '/READY/{print $3}' "$ERR")"
```

**Ergebnis 2026-07-17 (v1.25.0, Wunschpaket-Abschluss):** 288 Leaks /
14,4 KB — ausnahmslos bekannte Apple-XPC-Zyklen (`NSXPCConnection`/
`LNDaemonApplicationInterface`, AppIntents-Daemon-Anbindung); keine einzige
Fastra-Klasse in den Leak-Bäumen. Bundle-Wachstum des Wunschpakets
(Leitplanke ≤ ~1 MB): Debug-Binary v1.22.0 → v1.25.0 gemessen +536 KB
(überwiegend die generierten 4D-Symbollisten); Etappen 1–3 waren reiner
Code ohne neue Ressourcen. Gesamt klar unter der Leitplanke.

**Pflicht-Smoke-Test nach JEDER Änderung an App-Lifecycle, Fenster-Setup, Menüleiste oder Event-Monitoren — die Klasse von Bugs, die Unit-Tests nicht fangen:**
0. **Maus funktioniert überhaupt:** Klick in Editor setzt Cursor, Buttons reagieren, roter Schließen-Knopf schließt, CMD+Tab holt App nach vorn. (Diese Stufe zuerst — ist sie rot, ist alles andere irrelevant.)
1. CMD+F (Editor fokussiert) → Suchmaske öffnet, **kein** Editor-Find-Panel.
2. CMD+SHIFT+F → Ordner-Modus, Fenster wächst, kein Find-Panel.
3. ESC bei vorderer Suchmaske → blendet aus. ESC sonst → stört nichts.
4. CMD+F mehrfach hintereinander → kein Zombie, kein Doppel-Öffnen.
5. App-Wechsel raus und zurück, dann CMD+F → Suchmaske kommt wieder nach vorn.

Nach größeren Funktionspaketen ergänzt der gelegentliche, reale
[Menüvolltest](MANUAL-MENU-FULL-TEST.md) diese kurze Pflichtprüfung. Seine
wegwerfbare Test-App besitzt eine eigene Bundle-ID und bleibt im Projekt-Root;
er wird nur nach ausdrücklicher Freigabe des Nutzer-Desktops ausgeführt.

## Externer Dateivergleich

Der reguläre Build erzeugt zusätzlich `Contents/Helpers/fastra-diff` und
signiert den Helfer vor dem äußeren Bundle. Die Portabilitätsprüfung prüft
Ausführbarkeit und Fähigkeitserkennung. Der Vertrag und die beiden gezielten
Integrationstests stehen in [EXTERNAL-DIFF.md](EXTERNAL-DIFF.md).
`./selftest.sh externaldiff` läuft im Hintergrund gegen die laufende Test-App;
`./external-diff-test.sh` prüft echte LaunchServices-Kaltstarts mit isolierten
Bundle-Kopien unter `.build` und öffnet dafür kurz eigene Testfenster.

## Lokale Snapshot-Steuerung

Der Build liefert `Contents/Helpers/fastra-control` und
`Contents/Resources/Fastra.sdef`. Der Helfer wird vor dem äußeren Bundle
signiert. Die Portabilitätsprüfung verlangt beide Bestandteile und ausführbare
Offline-Capabilities. Der Vertrag steht in [LOCAL-CONTROL.md](LOCAL-CONTROL.md).

```bash
./build.sh
./test.sh --filter LocalControl
FASTRA_CONTROL_HEARTBEAT=1 ./test.sh --filter LocalControlResponsivenessTests
./local-control-test.sh
```

Der letzte Aufruf erzeugt eine eigene Bundle-ID, Sandbox und zwei reale
Arbeitsfenster mit ungespeicherten Inhalten. Der CLI-Helfer und externes
`osascript` müssen denselben Controller, Hash, IDs und Job erreichen.
Die AppleScript-Fassung kompiliert Begriffe aus dem tatsächlich gebündelten
Dictionary. Native Objektbezüge und schreibgeschützte Properties werden
ebenfalls extern geprüft. Direkt aufgerufene Handler zählen nicht als Abnahme.
Ohne Automation-Freigabe ist der AppleEvent-Test offen; ein Timeout ist kein PASS.
`FASTRA_CONTROL_CLI_ONLY=1` erlaubt einen ausdrücklich getrennten CLI-Teillauf.

Für passive Aufnahmen aus dem laufenden Testfenster dienen
`FASTRA_CONTROL_TEST_LANGUAGE=de` beziehungsweise `en` und
`FASTRA_CONTROL_SCREENSHOTS=<Belegverzeichnis außerhalb des Repos>`.
Der Host nimmt den nativen Fensterrahmen bei 400 und 900 pt auf, einschließlich
Titel, Auswahl und einer Hash-Fehlerlage. Beide Sprachfassungen selbst ansehen.
Transparente View-Caches werden mit der tatsächlichen Fensterfarbe unterlegt;
eine schwarze oder fehlende Caption ist kein gültiger Sichtbeleg.

Die Heartbeat-Probe läuft separat ohne konkurrierende MainActor-Tests.
Sie misst bei 10 ms Solltakt die größte Tick-Lücke vom Laden bis `ready`,
jeweils nahe 256 KiB mit vielen kurzen Zeilen und einer langen umgebrochenen
Zeile, beide mit EOF-Ziel. Das Abnahmekriterium der Fixture ist unter 250 ms;
der konkrete Messwert und die Datenform gehören zum Ergebnisbericht.

### Prüfung der installierten App

Zuerst vollständig notarisiert über `./install.sh` installieren. Die normale
App darf beim Start der Prüfung nicht laufen. Ein unverändert installiertes
Bundle direkt mit improvisierten Preferences zu starten schützt den
Produktzustand nicht ausreichend; stattdessen besitzt `selftest.sh` den Host
und seine bestehende Preferences-/Saved-State-/Clipboard-Sicherung.

1. Eigenes Verzeichnis mit `mktemp -d "$PWD/.build/control-installed.XXXXXX"`
   anlegen. `FASTRA_CONTROL_HOST_DIR` auf dieses Verzeichnis setzen.
2. `FASTRA_SELFTEST_APP_BIN=/Applications/Fastra.app/Contents/MacOS/Fastra`
   und `FASTRA_SELFTEST_APP_BUNDLE=/Applications/Fastra.app` setzen und
   `./selftest.sh controlhost` im Hintergrund starten; die Runner-PID speichern.
   Begrenzt auf neue `host-ready`- und `host-binding`-Dateien warten.
3. Mit `FASTRA_CONTROL_TEST_APP=/Applications/Fastra.app` und
   `FASTRA_CONTROL_TEST_HOST_DIR=<Hostverzeichnis>` direkt
   `python3 tools/local-control-test.py` ausführen. Den äußeren
   `local-control-test.sh` hier nicht benutzen: Der Selftest-Runner hält
   bereits dieselbe maschinenweite GUI-Sperre.
4. Der Treiber schreibt nach seinen Senderaufrufen auch bei Fehler
   `host-finish`. Im äußeren Aufräumpfad denselben Marker zusätzlich schreiben,
   falls der Treiber vorzeitig abgebrochen wurde, und den Runner abwarten. Externen und Runner-Exit getrennt sichern.
   Nur beide erfolgreichen Ergebnisse sind eine vollständige Abnahme.

Der installierte Treiber startet keine App: CLI benutzt `--no-launch` plus
die gebundene `runtimeID`, AppleEvents benutzen JXA `Application(PID)` aus
der Hostbindung. Das verhindert einen normalen Neustart bei verlorenem Host.
JXA prüft den nativen Dictionary-/AppleEvent-Weg. Mit
`FASTRA_CONTROL_APPLESCRIPT=1` führt der installierte Treiber dieselben Proben
als echtes AppleScript aus. Er prüft vorher die gebundene Host-PID und eine
bereits laufende App; Capabilities und Inventar bestätigen die erwartete Runtime.
AppleScript adressiert die Bundle-ID, JXA die PID. Ein readonly-Setter liefert
bei AppleScript -10006, bei JXA -10003; beide Property-Inhalte müssen unverändert
bleiben. Der Host prüft reale
Inhalte, Dirty-Flags, Auswahl, Projekt, Fensterrahmen und Einstellungen seiner
beiden normalen Fenster. Ohne geprüften PASS beendet `host-finish` ihn als FAIL.
Der Host hat 120 s, der Runner 130 s als äußere Frist. Bei TCC-Timeout keine
identischen Wiederholungen; Host beenden und Produktzustand restaurieren lassen.

Bei einem installierten AppleEvent-Aufruf, der nach 1,5 s noch aussteht,
sichert der Treiber einmal gleichzeitig Sender- und Empfänger-Stack sowie
eine unabhängige readonly CLI-Capability-Abfrage. Die Belege liegen unter
`ae-diagnostic-<UUID>` im eigenen Hostverzeichnis. Dabei bleibt genau derselbe
Sender am Leben; es gibt keinen erneuten AppleEvent. AppleScript behält seine
native Frist von 3 s, der äußere Senderpfad ist einschließlich Diagnose auf
höchstens 6 s begrenzt. Sample-Fehler werden getrennt protokolliert und sind
kein Ursachenbeweis. Ein erfolgreiches CLI-Ergebnis bei gleichzeitig hängendem
AppleEvent grenzt den Engpass ein, bestätigt allein aber keine TCC-Ursache.
Auch ein später doch erfolgreicher Sender hinterlässt seinen Diagnosebeleg.

Dieser Diagnosepfad wurde mit sofortigem, verzögertem und dauerhaft wartendem
isoliertem Sender geprüft: keine Wiederholung und kein zurückbleibender Prozess.
Der anschließende echte AppleScript-/CLI-Lauf gegen den geschützten installierten
Host bestand mit zwei unveränderten dirty Fenstern. Ein neuer realer
AppleEvent-Hänger wurde damit nicht reproduziert.

Neue Aufnahmen sind kleine Ergebnisbelege; entbehrliche Testkopien werden vom
Treiber entfernt. Aufbewahrung und spätere Bereinigung der Belege folgen der
Testdatenregel, ohne ungefragte Bereinigung fremder Bestände.

### Gezielte Negativproben für Fokus-Timeouts

Diese Aufrufe prüfen die Einstufung realer AppKit-Zustände und erwarten
ausdrücklich Exit 2 mit `ENV`, keinen grünen Produkttest:

```bash
FASTRA_SELFTEST_NO_ACTIVATION="multisearch bgscroll" ./selftest.sh multisearch bgscroll
FASTRA_SELFTEST_DEACTIVATE_BEFORE_BGSCROLL_SWITCH=1 ./selftest.sh bgscroll
```

Der erste Aufruf sperrt die Aktivierung bereits beim Start. Der zweite
braucht eine freigegebene GUI-Sitzung: Nach der normalen aktiven Vorbereitung
blendet die Test-App sich vor dem Fensterwechsel aus. Erst wenn AppKit den
verlorenen Fokus bestätigt, läuft der unveränderte Fenster-Timeout. Eine
fehlgeschlagene Vorbereitung der Probe bleibt `FAIL`. Ohne die Variable
bleibt der normale bgscroll-Test unverändert.

### Zustandsfolgen zwischen Tabs prüfen

`./selftest.sh tabsearchmemory` öffnet zwei XML-Dokumente mit je 1200 Zeilen,
findet denselben Suchtext an unterschiedlichen Positionen und springt über den
normalen Trefferpfad dorthin. Danach wechselt der Test 48-mal per Maus zwischen
den vorhandenen Tabs, zunächst mit längerer, dann mit kürzerer Pause. Nach jedem
Wechsel prüft er die tatsächliche TextView-Auswahl und den sichtbaren Ausschnitt;
er setzt beides während der Wechsel nicht erneut. Der Test läuft ohne globale
App-Aktivierung und gehört zur regulären Selbsttestsuite.

Bei Fehlern in gemerktem UI-Zustand muss die Regression die auslösende Folge
zusammensetzen: Zustand durch den betroffenen Bedienpfad herstellen, verlassen,
wiederkehren und wiederholen. Unterschiedliche gültige Darstellungen desselben
Zustands mitprüfen — hier absolute Zeichenbereiche gegenüber Zeile/Spalte eines
Suchsprungs. Die Gegenprobe muss am alten Produktcode fehlschlagen.

Die früheren Tests `tabswitch` (neuer Tab) und `tabscroll` (ein Rückwechsel mit
absolut gesetztem Cursor) deckten diese Kombination nicht ab. Auch der Dauertest
prüft unveränderte Auswahl und Ausschnitt anderer Fenster, aber keine vollständige
Historie der Auswahl jedes zuvor verlassenen Tabs. Mehr Laufzeit allein ersetzt
diese fehlende Erwartung nicht.

Patch 4c-3 korrigiert zusätzlich `resolveCursorPosition` der Editor-Bibliothek:
1-basierte Spalten werden in UTF-16-Offsets umgerechnet, die Länge ergibt sich
aus Ende minus Anfang. Der bestehende Reconcile-Vergleich aus Patch 4c-2 darf
weder eine andere Range als die tatsächlich gesetzte Auswahl noch `nil` für
einen gültigen späten Treffer liefern. `cursorResolutionMatchesAppliedSelection`
prüft frühe, späte, mehrzeilige und leere Auswahlen am echten Controller gegen
unabhängig berechnete Textpositionen. Der Build prüft den Patch unmittelbar.

Die Ausschnitt-Wiederherstellung darf ihren eigenen Scroll-Aufruf nicht sofort
als Erfolg werten: Ein späterer Layoutdurchlauf kann ihn zurücksetzen. Der
Fenstertest wartet deshalb auf den Zielzustand und beobachtet ihn zusätzlich
über weitere Durchläufe, ohne die Ansicht selbst zu korrigieren. Bei einem
Fehler gibt er die letzten Wiederherstellungsschritte aus einem begrenzten
Speicherpuffer aus; laufende Terminalausgabe würde das Timing beeinflussen.

### Gespeicherter Codefrage-Player

Gezielte Paket-/Controller-/FileLoader-Prüfung nach `build.sh`:

```sh
./test.sh --filter 'CodeExplanation|LocalControl|FileLoader'
```

Für die installierte Integration den geschützten `controlhost` wie oben starten.
Zusätzlich beim externen Treiber `FASTRA_CONTROL_EXPLANATION_TEST=1` setzen.
`FASTRA_CONTROL_EXPLANATION_PACKAGE` bezeichnet ein eigenes Fixture-Verzeichnis
außerhalb versionierter Dateien. Zwei nacheinander beendete Hostprozesse mit
identischem Paket belegen Wiederöffnung nach einem echten App-Neustart und
ungültige alte Laufzeit-Jobs. Die ersten Paketdateien werden nur angelegt, wenn
das Manifest fehlt; vorhandene Quellen werden nicht zur Wiederöffnung verändert.

Der Host betätigt reale native Player-Knöpfe in seiner eigenen Sitzung und
beobachtet Auswahl, Dokument-ID, Schriftgrößen, readonly-Zustand und Playerstatus.
Die separate Markerdatei ist ausschließlich eine Testhost-Funktion, keine neue
Wire-Operation. Die vorhandene Prüfung der beiden dirty Arbeitsfenster und
Test-Preferences läuft anschließend unverändert. Außerdem unbekanntes Schema,
Pause während Navigation, bewusstes Zurückkehren und Beenden prüfen. Capture
`explanation-ready`, `explanation-paused` und `explanation-error` erzeugt native
Aufnahmen bei 400/900 pt; jede Sprachfassung selbst ansehen. Ein Testknopfaufruf
belegt dessen Aktion, keine vollständige reale Maus-/Tastaturabnahme.

### Screenshot-Bestätigung des Erklärungsplayers

`python3 app/tools/test-code-explanation-capture.py` prüft die Capture-Grenze
ohne Appstart: alte FAIL-Marker und eine fehlende zweite Fensterbreite dürfen
keinen Erfolg liefern. Installierte Playerläufe verbinden Auftrag, PASS-Marker
und beide PNG-Dateinamen über ein einmaliges Token. Bereit-, Pause- und
Fehlerzustände verwenden dieselbe Bestätigung.

### Remote-Auswahl für Fetch und Pull

`GitIntegrationRemoteActionTests` verwendet zwei temporäre lokale Remotes und
prüft expliziten Pull bei anderem/fehlendem Upstream, ungültige Ref-Spezifikationen
sowie vollständigen Fetch trotz `skipFetchAll`, gleichnamiger Remote-Gruppen
und ausgefallener Einzelquellen. Ein Abbruch startet keine weitere Quelle. `./selftest.sh gitremotedialogs`
prüft native Auswahl-/Branchzustände und betätigt den tatsächlichen
Bestätigungsknopf über AppKits `NSButton.performClick`. Der Dialogtest startet
wie andere Fokusprüfungen über LaunchServices; sein Timer wird auch in der
modalen RunLoop-Schleife bedient. Mit
`FASTRA_REMOTE_DIALOG_DIR` werden fünf Dialogzustände als PNG gesichert; beide
UI-Sprachen visuell prüfen.

### Blockweise Vorschau-Aktualisierung

`./test.sh --fast-only --filter MarkdownPreviewBlocksTests` prüft echte WebKit-
Blockobjekte nach Einfügen, Löschen, Verschieben und Bearbeiten, verschachtelte
Quellpositionen, Referenzdefinitionen, Bildwechsel, Auswahl, Scrollanker,
Codeknopffokus und verspätete Diagrammantworten. WYSIWYG verwendet weiterhin
seinen getrennten Quellerhalt; `MarkdownVisualTests` bleibt dessen Regression.

`FASTRA_MD_COMFORT_DIR=<Belegverzeichnis> ./selftest.sh mdblocks` misst für
64 und 4096 Absätze je einen Aufwärmdurchlauf und fünf Werte. Derselbe native
Eingabepfad wird einmal mit vollständigem Body-Tausch und einmal mit dem
Blockabgleich gefahren. Der Quellsprung beginnt ausdrücklich außerhalb seiner
Zielzeile; Undo läuft als Tastendruck, Redo über den echten Bearbeiten-Menüeintrag.
`block-performance.json` trennt cmark-/Bild-Rendering,
DOM-Arbeit, Zeit vom geposteten AppKit-Eingabeereignis bis zum nächsten
Animationsframe der Vorschau und die tatsächliche WYSIWYG-Serialisierung. Diese Zeit umfasst
keine Hardware-/System-Eingabelatenz. Der Lauf prüft außerdem erhaltene Code-
und Diagrammobjekte, aktualisierte Quellsprünge, bytegleiche Dokument-/Dateibasen
sowie natives Undo/Redo. DE und EN gegen das frisch notarisiert installierte
Bundle ausführen; `mdcomfort` ergänzt alle Darstellungs- und Größenvarianten.

Der Tabellenlauf `mdtable` wartet nach dem nativen Paste auf die neu gerenderte
aktive Bestätigung. Der sichtbare NSTextView-Inhalt kann der SwiftUI-Bindung
vorauslaufen; eine feste Pause oder ein Screenshot ersetzt diesen Zustand nicht.
`mdtableinput` ist eine gezielte Diagnose mit externem nativen Tastentreiber
und dem vorhandenen Aufnahmeverzeichnis als Request-/Receipt-Ablage.

### Bestehende Dateien in allen Editormodi speichern

`./selftest.sh saveexisting` gehört zum Standardlauf. Der Runner legt vor dem
App-Start drei Bestandsdateien mit älterem Änderungsdatum und definierten
Zugriffsrechten an. Die installierte App öffnet sie im normalen Texteditor,
als Markdown mit Vorschau und in WYSIWYG. Je Modus bearbeitet der Test den
sichtbaren Editor, speichert über ⌘S, schließt den Tab und öffnet ihn neu;
anschließend wiederholt er den Ablauf. Die fünf Ordnerzustände sind: ohne
Temp-Rest, unveränderte alte Temp-Datei, beschädigte Binärdaten, Ordner unter
einem Temp-Namen und Symlink unter einem Temp-Namen. Diese Pfade müssen
unverändert bleiben. Vor den Änderungen prüft der Test in allen drei Modi außerdem ⌘⇧←/→ bis zur sichtbaren Zeilengrenze und die unveränderte wortweise Auswahl mit ⌥⇧→. Die Auswahl darf das Dokument nicht verändern. Insgesamt entstehen 30 Speichervorgänge. Sichtbarer Inhalt und tatsächliche
Plattenbytes müssen nach jedem Speichern und Wiederöffnen übereinstimmen. Der vollständige sichtbare
WYSIWYG-Text wird zusätzlich vor und nach dem Öffnen exakt verglichen.
Nach dem App-Prozess vergleicht zusätzlich der Runner alle drei Dateien mit
unabhängig erzeugten Sollbytes. Ein grüner App-Status allein genügt nicht.

Die native Abnahme läuft auch mit `FASTRA_SAVEEXISTING_PARENT` unter einem
vorbereiteten Desktop-Testverzeichnis gegen die notarisierte installierte App.
Der Runner entfernt nur sein markiertes Fixture-Unterverzeichnis.
Damit bleiben Testdateien außerhalb ihres Test-Homes und betreffen den realen
Desktop-Zugriff. Fehlende Systemfreigaben gelten als offene Prüfung. Nach
Speicher-, Editor- oder Berechtigungsänderungen ist dieser Ablauf in beiden
Sprachen erforderlich; reine In-Memory- oder frisch appintern angelegte
Fixtures ersetzen ihn nicht.

### Visuelle Markdown-Bearbeitung

Bei Änderungen an WYSIWYG-Formatierung, Serialisierung oder Rendering ist
`./test.sh --filter Markdown` nach dem Build erforderlich.
`MarkdownVisualTests/formatOptionsSaveReopen` bedient alle 15 Formatierungsbefehle
mit echten WebKit-Auswahlen in Hell und Dunkel, speichert über den Workspace,
schließt den Tab und erzeugt aus der Plattendatei einen frischen Editor.
Erwartete Elemente sowie tatsächliche Schrift, Farben und Glyphenpositionen
werden vor und nach dem Öffnen verglichen. Link- und Tabellenrückfragen erhalten
feste Testwerte; ihre Dialogbedienung bleibt Aufgabe der Fenstertests.
Range-Rechtecke tolerieren wegen Textknoten-Grenzen und Kerning 1 pt;
Zeichen, Schriftattribute und Farben müssen exakt übereinstimmen.
`repeatedEditsKeepBlockSeparators` prüft drei echte Speicherrundreisen mit
fehlendem, einfachem und doppeltem Dateizeilenabschluss in LF und CRLF.
`plainParagraphKeepsAdjacentBlockBoundary` schützt die nötige Trennung nach
dem Umwandeln einer direkt benachbarten Überschrift in Fließtext.
`highlightSaveReopen` ergänzt Wort-/Dokumentauswahlen bis zum Absatzende in Absätzen,
Überschriften, Listen, Zitaten und Tabellen; `punctuationFormatSaveReopen`
prüft Satzzeichen zwischen Buchstaben. `tableFormatsSaveReopen` prüft die
speicherbaren Zellformate, `tableRejectsBlockFormats` die erklärte, unverändernde
Abweisung von Blockformaten. Eine Prüfung des vorhandenen DOM allein reicht
für diese Fälle nicht. Der Fensterlauf `mdvisual` setzt zusätzlich neue
Inline-Formate bis zum Absatzende über echte Toolbar-Klicks und prüft ihre Speicherrundreise.
`blockFormatKeepsSelection` tippt nach Listen-/Zitatformatierung weiter und
prüft Cursor sowie Teilauswahl. `protectedHTMLRejectsFormatting` verhindert
vorübergehende Auszeichnungen in unveränderlich erhaltenen HTML-Bereichen.

`MarkdownVisualTests/copyPasteSelectionStyles` prüft Textteilauswahlen innerhalb
von Auszeichnungen, Links, Überschriften, Zitaten, Listen und Codeblöcken über
das echte WebKit und ein isoliertes natives Clipboard (Markdown, HTML und RTF).
`copyPasteDocumentStyles` ergänzt gemischte Dokumente, Ausschneiden, Undo/Redo
und erneutes Rendern über Markdown- und HTML-Clipboard; Inline-HTML-Auszeichnungen,
Tabellen und die Codesprache bleiben erhalten.

`mdcomfort` prüft Lesespalte und breite Tabellen in den echten Vorschau- und
WYSIWYG-Ansichten bei Mindestbreite und breit, hell und dunkel. Er scrollt die
Tabelle tatsächlich bis zum Ende, bedient den Code-Kopierknopf mit echter Maus
und Leertaste und prüft Klartext, unveränderte Quelle/Platte sowie natives Undo.
`FASTRA_MD_COMFORT_DIR` speichert die Ansichten und das jeweils erreichte
Tabellenende. Beide Sprachfassungen visuell prüfen. Die Knöpfe liegen außerhalb
des bearbeitbaren DOM und werden im Ausdruck nicht erzeugt.
`MarkdownPresentationTests` ergänzt verdeckte WebKit-Fenster, den Austausch des
Vorschauinhalts, mehrere Codeblöcke und die unabhängigen Layoutrechtecke.
Verdeckte Referenzdefinitionen bleiben beim Bearbeiten und Löschen eines
Nachbarblocks sowie nach WebKit-Undo mit LF, CRLF und CR erhalten.

`mdsearchnavigation` prüft einen weit unten liegenden Suchtreffer aus dem
WYSIWYG-Modus sowie Geöffnet-Navigation und echte Trefferklicks. Eine bewusst
offengehaltene WebKit-Promise belegt, dass Tabwechsel und Trefferindex erst nach
der Synchronisierung bestätigt werden. Der Test liest die echte TextView-Auswahl
und prüft beim späten Treffer zusätzlich, dass der Editor gescrollt hat.
`MarkdownVisualTests` prüft außerdem abgewiesene Dateiöffnungen mit erneutem
Versuch und den verzögerten Nachrück-Sprung nach Einzel-Ersetzen.

`mdvisual` bedient den echten Erstwahl-Dialog und die Format-Toolbar, prüft eine
native Copy-/Paste-Rundreise einer fett formatierten Teilauswahl samt Undo,
Shift-Return und den Umbruch-Button als Zeilenumbruch im selben Absatz sowie
Return als neuen Absatz. Ein gespeicherter Umbruch muss nach Undo wieder
verschwinden. Der Fenstertest prüft außerdem
Listenverschachtelung mit der echten Tab-Taste, Aufgabenlisten und Häkchen,
letzte Eingaben vor dem Speichern, den Moduswechsel sowie die Bildkopien von
„Speichern unter“. Fettung und Textmarker mit geschützten Leerzeichen müssen
mehrere Moduswechsel überstehen; eine externe Datei- und Ordnerumbenennung darf
den WYSIWYG-Undo-Verlauf nicht verlieren.
`FASTRA_MD_VISUAL_DIR` speichert den Erstwahl-Dialog, Ansichten
bei 650 und 1100 pt, den Dunkelmodus, bearbeitete Listen und den Quelltext nach dem Zurückwechseln;
jeweils Deutsch und Englisch ansehen.

`MarkdownVisualTests` misst Zeilenhöhe und Absatzabstand in Vorschau und WYSIWYG
und prüft Umbruch, Undo/Redo und erneutes Öffnen bei unveränderter Listen-Geometrie.

`MarkdownClipboardImageReviewTests` hält den nativen Export gezielt auf und
prüft die Veröffentlichung nach Invalidierung und Freigabe des Quell-Coordinators
sowie den Schutz neuer Zwischenablageinhalte. Ein Dateiaustausch nach dem ersten
Bildsnapshot darf HTML und Attachments nicht verändern; ein fehlender Snapshot
darf keine neue Dateilesung auslösen. `MarkdownVisualTests` prüft im echten WebKit
beide Abschlussreihenfolgen von Clipboard und Dokumentaktion: Die Aktionssperre
bleibt erhalten, und ein abgebrochener Cut verändert den Snapshot nicht nachträglich.
`MarkdownVisualTests/relocatedParentImageClipboard` verschiebt einen Dokumentbaum
zweimal mit einer `../`-Bildquelle. Die echte WebKit-Kopie muss jeweils dieselben
Bildbytes in HTML und RTFD liefern; DOM-Bildobjekt und natives Undo bleiben erhalten.
`relocatedImageSourceAliasesClipboard` ergänzt unterschiedliche relative Verweise
auf dieselbe Datei, auch innerhalb eines Absatzes. Nach dem Umzug in einen anders
benannten Ordner müssen einzeln kopierte gültige Bilder ihre HTML-/RTFD-Daten behalten.
`pasteboardCaptureSerialRunnerIntegration` führt die privaten Clipboard-Nachkontrollen
und den wirklichen Prozessabschluss mit einer Zwischenablage-Attrappe aus. Fremde
lesbare oder nicht lesbare Daten während der Nachkontrolle ergeben `ENV` ohne
veraltetes Rettungsjournal; eigene unbestätigte Schreibfehler bleiben `FAIL` mit Journal.

`MarkdownVisualTests` prüft Einfügen am Listenanfang mit sofortigem Cursorwechsel,
sichtbare Leerzeilen nach erneutem Rendern und die tatsächlichen WebKit-Rechtecke
nach dem Einfügen verschachtelter Listen. Die Bildtests prüfen auch Dateiinhalte
nach Undo/Redo, weitere Eingaben nach dem Löschen und unabhängige Bildkopien
zwischen zwei Dokumenten im selben Ordner. `tabcommitfocus` wechselt zwölfmal
per echtem Mausklick die Dateitabs nach einer Eingabe im Commit-Feld; währenddessen
bleibt ein zweites Fenster mit einem visuellen Markdown-Dokument geöffnet.

Turndown 7.2.0 liegt unverändert als `dist/turndown.js` im lokalen Ressourcenordner
`MarkdownVendor/turndown-7.2.0.js`, zusammen mit seiner MIT-Lizenz. Quelle ist das
npm-Paket `https://registry.npmjs.org/turndown/-/turndown-7.2.0.tgz`.
Fastras Dialekt- und Erhaltungsregeln stehen separat in `visual-editor.js`.
Beide Skripte werden aus `AppResources.bundle` in die lokale WebKit-Seite geladen;
es gibt keinen Download zur Laufzeit.

## Große Dateivergleiche mit Zeilenankern

Nach `./build.sh` prüft `./test.sh --fast-only --filter 'FileDiff|Myers'`
die bisherigen Zuordnungen und den Ankerpfad. `FileDiffPatienceTests` enthält
100.000 Zeilen je Seite mit verteilten Änderungen, kreuzende und wiederholte
Zeilen, normalisierte Anker mit ignorierten Leerzeilen, reine Einfügungen und
Löschungen sowie Abbrüche an jedem tatsächlich erreichten Prüfpunkt. Beide
Eingaben müssen aus den Ergebniszeilen vollständig rekonstruierbar bleiben.

Unterhalb des 30.000-Zeilen-Budgets bleibt die bisherige Myers-Zuordnung
unverändert. Größere Eingaben nutzen die längste geordnete Folge von Zeilen,
die auf beiden Seiten eindeutig sind. Jeder verbleibende Myers-Bereich und
die Summe ihrer quadratischen Arbeitsgrenzen werden vor der ersten
Teilberechnung geprüft. Eine fehlende oder unzureichende Ankerfolge liefert
die vorhandene erklärte Grenze. Die Tests protokollieren außerdem die
Laufzeiten beider Kerne auf derselben deterministischen Eingabe; die Messung
ersetzt keine Zuordnungsprüfung.

### Datei vom Dokument-Tab ziehen

Der gezielte Fenster-Selbsttest `tabfiledrag` erwartet `FASTRA_TABDRAG_DIR`.
Er erzeugt eine isolierte Datei mit Leerzeichen, Raute und Emoji im Namen und
eine abweichende ungespeicherte Editorfassung. `ready.json` enthält PID sowie
Quell-/Zielkoordinaten in globalen Bildschirmkoordinaten für einen externen
Maus-Treiber. Ein echtes AppKit-Drop-Ziel liest den Datei-Pasteboard und kopiert
die gespeicherte Fassung. Der Test endet nach erfolgreichem Drop oder 30 Sekunden.
Er gehört zum gezielten Abnahmelauf; der Standardlauf benötigt keinen Maus-Treiber.
Klick-/Schließen-/Shift-Auswahl prüfen zusätzlich `tabswitch`, `tabclosehit`
und `tabcompare`. Der Aufnahmestand `tab.png` zeigt den unveränderten dirty Tab.

### Diff-Bericht und Herkunftsübernahme

`diffexport` bedient den sichtbaren Exportknopf und die echten Speichern-/Abbruch-
Sheets in einem eigenen Datei- und Git-Vergleichsfenster. Der UTF-8-Bericht wird
gegen die fertige Vergleichsbasis geprüft; Originaldateien bleiben unverändert.
`FASTRA_DIFFEXPORT_DIR` nimmt die Ansichten bei 760/1100 pt und die Dialoge auf.
Der Testpfad wird vor dem Öffnen am Panel konfiguriert; nachträgliche Setter
ändern den macOS-Open/Save-Service nicht zuverlässig. Ein externer Tastentreiber
liest `FASTRA_DIFFEXPORT_INPUT_DIR/key-0.json` bis `key-3.json` (PID, keyCode 53
für Abbruch beziehungsweise 36 für Speichern) und sendet echte Tasten nur bei
bestätigtem Fokus der Test-App. Ohne Treiber gehört der Test nicht zum Standardlauf.

`sourceprovenance` übernimmt ein Mitglied eines geschachtelten ZIP als eigene
schreibgeschützte Sitzungskopie. Der Senderpfad wird nach `ready` entfernt,
der sichtbare Inhalt und die eigene Bytekopie werden erneut geprüft; Schließen
muss die Sitzungskopie entfernen. Starker Archivhash und ausdrücklich schwächere
Generation-Bindung werden bei 400/760/1100 pt aufgenommen; Zielverzeichnis:
`FASTRA_SOURCEPROVENANCE_DIR`. Bei 400 pt wird die Herkunft zusätzlich bis
zum Ende gescrollt. Ein TAR-Fixture enthält gleiche Anzeigenamen mit verschiedenen
ungültigen UTF-8-Namenbytes: Beide Sitzungen müssen unterscheidbar bleiben.
Falscher Blatthash und ausgetauschte Archivgeneration dürfen keine Übernahme
bestätigen; ihre wirklichen Fehleransichten werden ebenfalls aufgenommen.
Beide Tests gehören zum gezielten Abnahmelauf.

Der Soak wartet nach einem Tabwechsel bis zu zwei Sekunden auf übereinstimmende
Editor-/Modellbytes, bevor die bleibenden Invarianten geprüft werden. Ein
beobachteter Aufbauunterschied wird mit seiner Auflösungszeit protokolliert;
eine nicht aufgelöste Abweichung bleibt ein Fehler. Dieser Testaufbau ist kein
Beleg für die Ursache früherer sporadischer Editorbefunde.

Der gezielte Selbsttest `textworkflowonesided` prüft die Darstellung eingefügter
Unicode-/CRLF-Zeilen im Ablaufdialog. Mit `FASTRA_TEXT_WORKFLOW_DIR` entstehen
Aufnahmen in hell/dunkel bei Mindestbreite und breiter Ansicht.

### Lokale Markdown-Verweise

`FASTRA_TEXT_WORKFLOW_DIR=/pfad/zur/aufnahme ./selftest.sh mdreferences` prüft den
echten Markdown-Menüweg, Dokument-/Projektbereich, Befundfilter, Quellsprung und
veraltete Quellen. Eine befristet belegte Renderqueue bildet Konkurrenz zur
Vorschau ab und erlaubt deterministischen nativen Abbruch; Cleanup gibt sie vor
Erfolg oder Fehler frei. Aufnahmen zeigen alle Zustände hell/dunkel, bei
Mindestbreite und breit. Unit-Regressionen prüfen cmark-Referenzlinks, HTML/Anker,
Encoding/BOM, codierte Pfade, Symlinks, Projekt-Ausschlüsse, Ressourcenlimits und
Dokumentidentitäten. Es werden ausschließlich temporäre Fixtures verwendet.

Linux verwendet `linux/test.sh references`, `references-project`, `references-rich`
sowie `references-guards`, `references-disk-guards` und `references-unverified`.
`references-mac` verwendet dieselbe CRLF-Datei wie der Mac-Test `mdreferences`.
Die echten GTK-Menü-/Listen-/Filter-/Sprungpfade werden
mit X11-Eingaben geprüft; `FASTRA_REFERENCE_WIDTH=640` prüft die Mindestbreite.
Projektbefunde springen erst nach erneuter Snapshot- und Ladeprüfung in neue
Quell-Tabs. Der Abbruchtest hält nur seinen eigenen Debug-Worker kurz zurück;
Generation, Dokumentidentität und identische neu publizierte Quellbytes bleiben
getrennt geprüft. Die Unit-Suite enthält zusätzlich Linux-Mountgrenzen,
Symlink-Elternpfade, Unicode-Anker und begrenzte schreibgeschützte Berichte.

## WYSIWYG: Clipboard, Leerraum und Ausschnitt

`MarkdownVisualTests/reportBoldReturnDelete` prüft Einfügen von HTML-Fettdruck
und Markdown mit NBSP, Return, mehrere echte Render-Rundreisen, vollständiges
Löschen und Undo. `reportHighlightClipboardMetadata` verwendet zwei unabhängige
Editoren mit isoliertem nativem Clipboard, kontrolliert exportierte Farbe und
fehlende interne Blockkennungen und prüft eine echte Speichern-/Öffnen-Rundreise.
`reportViewportOwnership` prüft tatsächliches Scrollen, den synchronisierten
Ausschnitt, Wiederaufbau sowie abgewiesene alte Revisionen und fremde Fenster.
Nach Build die drei Gruppen zusätzlich zu den bestehenden Format-, Clipboard-,
Leerzeilen- und Blockerhaltungstests ausführen; die nativen Fenstertests bleiben
für den sichtbaren Moduswechsel erforderlich.

Unter Linux führt `python3 tools/linux-probes/wysiwyg-report/run.py <repo>` die
gemeinsamen Originalskripte mit GTK4/WebKit6 in einer isolierten Anzeige aus.
Die Probe benötigt PyGObject und die installierten GI-Bindungen. Jede Eingabe
lädt ein frisches Webdokument; Text, Metadaten und Quellen sind synthetisch.
`FASTRA_WYSIWYG_VENDOR` kann für den Gegenbeweis auf einen privaten Ordner mit
den drei unveränderten Ausgangsskripten zeigen. Der vorhandene native Rich-
Fenstertest ergänzt Formatierung, Undo/Redo, Tabellen, Unicode, BOM, sichere
Speichersynchronisierung und veraltete Modusantworten. DE/EN bei Mindestbreite
und breit sowie hell/dunkel prüfen und die tatsächlichen Aufnahmen ansehen.

## Linux: Build, lokale Pakete, Signatur und Installation

Die Linux-Oberflächenschrift Inter 4.1 liegt unverändert unter `crates/fastra-linux/resources/fonts/inter-4.1`. `SOURCE.json` enthält Archiv- und Dateiprüfsummen. Die Paketierung prüft alle Datei-Hashes und kopiert Lizenz und Herkunftsnachweis. Die Registrierung gilt nur im laufenden Prozess; GTKs Fontmap wird nach der Ergänzung neu eingelesen. WebKit erhält eigene normale/kursive WOFF2-Dateien über exakt erlaubte lokale Dokumentadressen und `font-src` derselben privaten Route. Es gibt keinen Webfont-Dienst. `linux/test.sh fonts` liest die tatsächlich verwendeten Pango-Textläufe sichtbarer Tabs und halbfetter Suchtitel sowie die geladenen WebKit-Fonts in Vorschau und Rich. Die alte unsichtbare Notebook-Beschriftung ist keine Fontreferenz. Die nativen Prüfungen verwenden minimale/breite Ansichten in beiden Sprachen und Farbschemata; Quelltextschrift und Textbytes müssen erhalten bleiben.

Die Rootskripte wählen unter macOS weiterhin `app/`, unter Linux `linux/`.
Die Linuxversion und die native Buildnummer werden aus Cargo und `Info.plist`
ermittelt und auf Konsistenz geprüft; kein Skript erhöht selbst die Version.

```bash
./build.sh                    # nativer Debugbuild, drei ELF
./build.sh --release          # nativer optimierter Build
./linux/run.sh                # verwendet dieselbe private ICU
./linux/run.sh --release
./release.sh --unsigned       # lokale DEB-, tar.gz- und ZIP-Pakete
./release.sh --key FULL_SIGNING_FINGERPRINT --output dist/local-release
./install.sh --package dist/local-release/packages/fastra-VERSION-linux-x86_64.tar.gz
```

`build.sh` braucht Rust gemäß `rust-toolchain.toml`, C/C++, Make, pkg-config und
GTK4 >=4.12, GtkSourceView >=5.6 sowie WebKitGTK 6 >=2.40 einschließlich ihrer
Entwicklungspakete. Fehlende Voraussetzungen werden benannt; die Skripte
installieren keine Systempakete. Zusätzliche Cargoargumente folgen nach `--`,
etwa `./build.sh -- --offline`. `--release` wird an Cargo korrekt als Option
weitergereicht. Der nativen App stehen die externen Vorschauwerkzeuge weiterhin
nur zur Verfügung, wenn die Distribution sie installiert hat; siehe F16.

Fehlt `--icu-prefix` beziehungsweise `FASTRA_ICU_PREFIX`, lädt der Build
`https://github.com/unicode-org/icu/releases/download/release-78.3/icu4c-78.3-sources.tgz`,
prüft SHA256 `3a2e7a47604ba702f345878308e6fefeca612ee895cf4a5f222e7955fabfe0c0`
und baut ICU78.3 ohne Rootpräfix. Der geprüfte Präfix enthält `ICU-LICENSE`
und `ICU-SOURCE-SHA256`. Native ICU-Builds landen unter
`${FASTRA_LINUX_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/fastra-linux}`.

`release.sh` beziehungsweise `linux/package.sh` braucht zusätzlich Docker.
Der vorhandene Ubuntu-24.04-Builder ist per Basisimage-Digest gepinnt. Beim
Standardweg baut er ICU innerhalb dieser glibc-2.39-Untergrenze; ein manuell
übergebener ICU-Präfix muss dieselbe ELF-Prüfung bestehen. Der Builder läuft
mit der aufrufenden UID/GID, damit Ergebnisse anschließend signierbar sind.
`FASTRA_PACKAGE_CACHE` bestimmt den separaten Cargo-/Target-/ICU-Cache.
`--skip-image-build` verwendet das bestehende `FASTRA_PACKAGE_BUILDER`-Image.
Das Image muss aus dem mitgelieferten Dockerfile stammen. Der tatsächliche
Imagehash, Rustversion und die Distributionspakete werden am Ergebnis gesichert.
Aus Quellarchiven ohne Gitmetadaten muss `SOURCE_DATE_EPOCH` vorgegeben werden.

Paketierung baut `fastra-linux`, `fastra-control` und `fastra-diff` gemeinsam. Alle drei ELF
werden auf x86_64, GLIBC-Symbole oberhalb 2.39 und RPATH/RUNPATH geprüft.
Die GTK-freien Helfer liegen unter `libexec/` neben der GUI; ihre festen
`bin/`-Launcher setzen ausschließlich für den Kindprozess die private ICU.
Alle Formate enthalten Lizenzen und `manifest.json` mit Quellidentität,
Buildnummer, Runtime-Dateihashes und relativen Symlinkzielen. TAR/DEB/ZIP
verwenden feste Metadaten aus `SOURCE_DATE_EPOCH`. `SHA256SUMS` enthält nur
relative Paketnamen. Ein vorhandener Ergebnisordner wird nie ersetzt; erst
der vollständige Erfolg macht den neuen Ordner sichtbar. Bitgleichheit über
später neu gebaute Dockerimages hinweg ist dadurch nicht behauptet.

`release.sh` verlangt entweder `--key FINGERPRINT`/`FASTRA_SIGNING_KEY` oder
bewusst `--unsigned`. Der Fingerprint muss vollständig sein und einen
vorhandenen Signierschlüssel bezeichnen. Signierung erfolgt ausschließlich
lokal außerhalb Docker; `gpg --verify` prüft die erzeugte detached Signatur
`SHA256SUMS.asc` tatsächlich. Bestehende Signaturen werden nie überschrieben.
Es gibt keine automatische Schlüsselauswahl oder -erzeugung, keinen Pass-Store,
keinen Gitpush, Tag oder Upload. Bereits erzeugte Pakete signiert
`./linux/sign.sh --key FINGERPRINT PAKETVERZEICHNIS`.

Der Benutzerinstaller akzeptiert tar.gz oder ZIP samt benachbarten
`SHA256SUMS`. `--key FINGERPRINT` verlangt zusätzlich eine gültige Signatur
von diesem Fingerprint. Er entpackt ohne ausführbaren Paketcode, prüft sämtliche
Manifestdateien/Links und installiert unter `~/.local/share/fastra/versions/`.
Ein atomarer `current`-Link wählt die Fassung; `~/.local/bin/fastra`,
`fastra-control`, `fastra-diff` und der Desktopeintrag verweisen darauf. `--prefix` unterstützt
auch Pfade mit Leerzeichen. Fehler/Signale beim Austausch stellen den alten
Link und den bisherigen Desktopeintrag wieder her. Altversionen bleiben für
eine Rücknahme erhalten. Fremde Launcher, Desktopeinträge, aktuelle Links oder
nichtleere unmarkierte Runtimeverzeichnisse werden nicht überschrieben.
Ohne `--package` wird das zuletzt erzeugte tar.gz unter `dist/*/packages/`
verwendet. `--system-deb PAKET` ist eine ausdrückliche Alternative: sie prüft
Paket und Runtimemanifest und ruft nur bei bereits als Root gestarteter
Aufruf `dpkg --install` auf. Sie startet niemals selbst sudo.


### Linux-Updates aus GitHub

Aktive Benutzerinstallationen bieten „Updates …“ und eine abschaltbare tägliche
Prüfung des stabilen Releases aus `DanielMuellerIR/fastra`. Quellbuilds starten
keine automatische Netzwerkprüfung. Systeminstallationen und der optionale
Toolkitkanal werden weiter über ihren ursprünglichen Installationsweg gepflegt.
Nur ein neueres `fastra-VERSION-linux-x86_64.tar.gz` mit vollständigem
GitHub-SHA256-Digest, erwarteter Adresse und begrenzter Größe wird angeboten.
Die Vertrauensquelle ist GitHubs HTTPS-Release-API; das ist keine zusätzliche
unabhängige OpenPGP-Signatur. Der manuelle Installer behält `--key` bei.

Die Installation bindet sich erneut an freigegebene Version und SHA256, prüft
Download, Manifest und Paketversion, führt keinen Paketcode aus und verwendet
den vorhandenen atomaren Installer. Dessen Sperre prüft den erwarteten aktuellen
Versionspfad nochmals unmittelbar vor dem Wechsel. Ein paralleles Update kann
so keinen inzwischen neueren Stand zurücksetzen. Frühere Versionen bleiben
liegen; die laufende Sitzung wird nicht neu gestartet. Der Helfer nutzt `-B`,
damit Python keine zusätzlichen Dateien im streng verifizierten Paket erzeugt.
Updater, Installer und Verifier sind Teil des gebundenen Quellsnapshots und des
Laufzeitmanifests. Einstellungen liegen unter `XDG_CONFIG_HOME/fastra/updates.json`.

Gezielt prüfen: `python3 -B -m unittest discover -s tools/linux-package/tests -v`.
Die Tests prüfen unter anderem beschädigte Downloads, Paket-/Releaseabweichung,
HTTPS-Downgrade, echte Installation mit alten Versionen und abgewiesenen
Versionswechsel nach einer parallelen Installation. Die Oberfläche in DE/EN
und Hell/Dunkel am gepackten Stand prüfen. Ein echtes GitHub-Update setzt ein
entsprechend veröffentlichtes neueres Linux-Paket voraus.

### Linux-cmark und optionale Umbruchprofile

Der Linux-Build verwendet für GFM-Autolinks den offline vendorten Mac-Pin unter
`crates/fastra-linux/native/`. `build/native_cmark.rs` prüft vollständigen
Dateisatz und SHA-256 vor dem statischen C-Build; eine System-cmark-Bibliothek
oder ein Netzdownload ist kein Ersatz. Die vier Quellpatches und ihre
Vorher-/Nachhermanifeste gehören zur reproduzierbaren Eingabe. Lizenztexte
müssen auch im fertigen Paket enthalten sein. Native Gegenfälle prüfen echte
DOM-Links, Originalbereiche, LF/CRLF/CR, Rich-Bearbeitung, Undo/Redo und Save;
reine Parserprüfungen ersetzen diese Wege nicht. Details: [F12-AUTOLINKS](linux-port/F12-AUTOLINKS.md).

Die erweiterten Umbruchprofile prüfen eine eigene Pango-Capability statt einer
Versionsnummer. Der System-Gegenlauf muss null Umbruch-Tags behalten. Der
positive Lauf muss beide Teilansichten, Größenwechsel, native Controlbedienung,
Tabs/Unicode sowie Quelle, gerichtete Auswahl und Historie prüfen. Ein neuer
Toolkit-, Font- oder Namespacepfad verlangt einen gezielten Kombinationslauf;
ein unveränderter früherer Prototyp reicht nicht. Details: [F07-WRAP-PROFILES](linux-port/F07-WRAP-PROFILES.md).

### Linux-Rich: native Clipboard- und Markergrenzen

`FASTRA_ISOLATED_DISPLAY=1 FASTRA_RICH_SELFTEST=1
FASTRA_RICH_CLIPBOARD_SELFTEST=1` aktiviert den zusätzlichen nativen Ablauf
(jeweils als Umgebungsvariablen setzen). Nur auf einer eigenen X11-Testanzeige
mit `FASTRA_RICH_TEST_ROOT` und `FASTRA_RICH_SCREENSHOTS` ausführen. Er nutzt
zwei eigene Fenster und synthetische Dateien: echter Highlight-/Undo-Button,
MIME-Union mit bytegenau nachgewiesenem Vorrang des Fastra-Markdownformats,
Copy/Paste zwischen Dokumenten, geschützte HTML-Originale, NBSP, Return,
vollständiges Delete/Undo, Plain-Paste/Cut per Tastatur, Speichern, Schließen
und erneutes Dateiöffnen. Er kontrolliert tatsächliches Scrollen und die
vorherige Vorschauwahl beim Moduswechsel. Unsicheres HTML, fremde interne
Metadaten, Tab-ABA, Clipboardwechsel und eine absichtlich langsame Leseanfrage
prüfen die Ablehnung ohne Ausgabe. DE/EN, Mindestbreite/breit und hell/dunkel
mit Sichtprüfung der Aufnahmen abnehmen.

Der Clipboard-Reader liest höchstens 2 MiB UTF-8 in 64-KiB-Stücken und besitzt
eine 5-Sekunden-Frist. Der HTML-Import akzeptiert höchstens 20.000 Elemente,
keine Bilder oder Dateipakete und keine relativen oder ausführbaren URLs.
Der gemeinsame Markerhelfer bleibt begrenzt. Die statische Vorschau prüft rohes HTML
gegen die enge Mac-Positivliste; fremde interne Positions-/Kopierattribute gelangen
nicht in die vertrauenswürdigen Register. Abgewiesene Fragmente bleiben escaped.
Überschriftsprünge behalten die Offsets der unveränderten Quelle.
`FASTRA_CODE_COPY_SELFTEST=1 FASTRA_HTML_WHITELIST_SELFTEST=1` prüft lokal
Bild/Details, abgewiesene Skripte, unveränderte Quelle und die Codekopiergrenze.
`FASTRA_PREVIEW_LINKS_SELFTEST=1` benötigt zusätzlich einen privaten URI-Testhandler
(`FASTRA_LINK_TEST_RECEIPT`): echte Tastaturaktivierung muss HTTP(S)/Mailto
übergeben, automatische Klicks und Dateiprotokolle müssen ohne Ausgabe bleiben.
Beide Debugprüfungen ausschließlich auf privaten Displays ausführen.

### Linux: Hauptfenster und Suchlayout

Die visuelle Referenz ist die aktuelle native Mac-Version mit denselben
synthetischen Dateien. `./linux/test.sh chrome` prüft echte Maus-/Tastaturaktionen
für Tabs, Ctrl+T, Ctrl+Shift+O, Ctrl+F, Suchfelder, Groß-/Kleinschreibung, Moduswahl, einzelne
Trefferfreigaben, Wiederöffnen, Übernahme, Ctrl+Z, Seitenleiste sowie
Datei-/Ordner-/Projektwechsel. Ordner und Projekt werden bei 520 und 720
logischen Pixeln aufgenommen; beide vollständigen Textvorschauen müssen
sichtbare, lesbare Flächen behalten. Ein verborgenes Suchfenster darf den
Prozess nach dem Schließen des letzten Editors nicht weiter offen halten.

Die Suchprüfungen lesen die tatsächlich dargestellte Vergleichsansicht. Die
abgetrennten früheren Textpuffer und Checkboxen bleiben leer. Native Eingaben
warten auf den abgeschlossenen Zustandswechsel und die Fenstergeometrie;
Mauspunkte beziehen sich auf das Zielfenster, nicht den Bildschirmursprung.
Mit Fenstermanager erfolgt die Aktivierung über dessen regulären Weg. Für
Alt-Mausgesten muss das private Testdisplay die Geste dem Editor überlassen.

`FASTRA_POORMANS_TEXT=/pfad/zur/echten/poormans-text ./linux/test.sh rich-rtf-import`
prüft den RTF-Verbraucher unabhängig vom Bild- und Dateidrop: echten
RTF-Clipboardinhalt im Rich-Editor einfügen, sichtbaren Verlusthinweis prüfen,
über die echte lokale PMT-CLI konvertieren, vollständige Vorschau und native
Übernahme prüfen, anschließend Fettung, Textmarker und Unicode im gerenderten
Rich-Tab nachweisen. Ausgangspuffer, Ausgangsdatei und materialisierte RTF-Bytes
müssen unverändert bleiben. Die separate Bild-/Dateidrop-Prüfung bleibt erforderlich.
Der eigene Dateidrop besitzt die Ablage ausschließlich: Interne Drop-Controller
der WebView werden entfernt. Leere Formate und eine deaktivierte Ereignisphase
reichen beim getesteten WebKitGTK 2.52.6 nicht aus; sein eigener
[Accept-Handler](https://github.com/WebKit/WebKit/blob/webkitgtk-2.52.6/Source/WebKit/UIProcess/API/gtk/DropTargetGtk4.cpp)
kann dennoch einen späteren Status auf dem bereits abgeschlossenen Drop setzen.
Die native Bild-/Dateiprüfung läuft daher mit `G_DEBUG=fatal-criticals`, echten
GDK-Dateilisten und einem angebotenen widersprüchlichen String. Abbrechen darf
keine Dateien erzeugen; Übernehmen erhält die Quelldatei und meldet COPY genau
einmal. Normale Dateien und Ordner behalten den regulären Öffnungsweg.


`FASTRA_TOOL_SCREENSHOTS` wählt den Belegordner. Den Ablauf mit `LANGUAGE=de`
und `en` sowie `GTK_THEME=Adwaita` und `Adwaita:dark` wiederholen. Für das
Hauptfenster 760 und 1100 logische Pixel prüfen, einschließlich leerem Tab,
Projekt, Quelltext und Markdown. Dateisuche zusätzlich bei 520 Pixeln prüfen.
Die native Dateizugprüfung bleibt `./linux/test.sh tab-file-drag`; sie muss den
sichtbaren Griff der kompakten Tab-Leiste und echte externe Empfänger verwenden.
Dateigriffe dürfen keinen `GtkWindowHandle` als Vorfahren besitzen: Dessen
Fensterziehgeste konkurriert mit dem nativen Dateidrag. Nur freie Titelleistenflächen
sind Fenstergriffe. Verborgene Suchfenster werden aus der `GtkApplication`
entfernt und beim Anzeigen wieder angemeldet. Die Vorschauprüfung bestimmt das
tatsächlich aktive App-Fenster; `active_window()` allein kann noch das zuletzt
fokussierte, bereits inaktive Fenster liefern.

Die Statuszählung verwendet den vorhandenen ICU-Graphemiterator. Die Beispiele
in `text_statistics` sind mit der Mac-Zeicheniteration gegengeprüft; CRLF,
zusammengesetzte Emoji und kombinierte Zeichen dürfen nicht als mehrere
Zeichen erscheinen. GTK-Puffer werden abschnittsweise kopiert, die Zählung
läuft mit Abbruch und Generationsprüfung im Worker. Markierungen sowie der
Wechsel zwischen den unabhängigen Quellansichten aktualisieren den Bezug.

`./linux/test.sh search-live` prüft echtes Tippen in Datei-, Tab- und Ordnersuche,
sofortige Entwertung, Bereichserhalt, kurze Muster per Return, Vertauschen sowie
Capture-Klick und tatsächlichen Drag. Danach folgt im selben Prozess eine Suche
mit kürzerer Ersetzung und einem langen Detailtreffer; `G_DEBUG=fatal-criticals`
muss dabei aktiv bleiben. GTK 4.14 beendet den Text-Drop ohne `leave` und kann
sonst einen alten Drop-Caret zeichnen. Die Suchfelder räumen ihn bei
`notify::current-drop` auf. Grundlage sind der beobachtete Snapshot-Stack und
[GtkText](https://github.com/GNOME/gtk/blob/4.14.5/gtk/gtktext.c) sowie
[GtkDropTarget](https://github.com/GNOME/gtk/blob/4.14.5/gtk/gtkdroptarget.c).
`./linux/test.sh search-detail` prüft denselben 28-Pixel-Detailkasten separat:
600 Zeichen bleiben vollständig vorhanden, echtes Ctrl+End scrollt horizontal,
Quelle und Undo bleiben unverändert. `FASTRA_SEARCH_LAYOUT_WIDTH=520` beziehungsweise
`900` setzt für die Sichtprüfung schmale und breite Suchfenster. Screenshots erst
nach einem tatsächlich gezeichneten Frame aufnehmen.

`./linux/test.sh search-groups`, `search-groups-open`, `search-groups-folder`
und `search-groups-project` prüfen native Detailauswahl, Gruppenbildung mit
Referenzverschiebung, Capture-Klick, Auflösen und sichtbare Verweigerung,
Gruppen ohne Treffer, Element-Picker, Verlauf und den Fokus des sichtbaren
Suchfelds. Die echte horizontale Liste scrollt anschließend zu Gruppe 31 und
zieht deren `$31` ins Ersetzungsfeld. `FASTRA_CAPTURE_STRESS=1000` erweitert
denselben Ablauf auf 1.000 Gruppen und prüft, dass weniger als 500 Knöpfe
aufgebaut sind. Aktueller Referenzlauf: drei gleichzeitig gemappte Knöpfe.
Die drei Darstellungs-Tags folgen einem im Worker berechneten Plan nicht
überlappender Farbabschnitte; UTF-16, Emoji und die Rangfolge verschachtelter
Gruppen besitzen eigene reine Tests. Alle geänderten Ansichten in Datei,
Geöffnet, Ordner und Projekt bei 520 und 900 Pixeln selbst ansehen.

Die Regex-Syntaxquellen unter `crates/fastra-core/native/regex-syntax` sind
unveränderte Auszüge der Mac-Pins. `SOURCES.json` bindet Revisionen und
Dateihashes. Paketierung und Updateprüfung verlangen Runtime-, Grammatik-
und Unicode-Lizenzen. Der kleine C-Adapter begrenzt Parserzeit, Knoten und
Baumtiefe und übergibt ausschließlich geprüfte Bytepositionen an Rust.

`./linux/test.sh single-replace` und `single-replace-secondary` prüfen echte
Einzelersetzungen ohne Sammelfreigabe in beiden Quellansichten: Unicode/CRLF,
Auswahlbereich, Folgetreffer, native getrennte Rückgängig-Schritte und wirkungslose
Ersetzungen. `single-replace-open` prüft Dokumentidentitäten bei gleichen Namen und
unabhängiges Undo. `single-replace-guards` und `single-replace-guards-open` verzögern
die Antwort, ändern die Suchanfrage beziehungsweise wechseln tatsächlich zu einem
fremden Fenster und zurück. Die verspätete Ersetzung muss ausbleiben; eine neue
Anfrage muss anschließend wieder funktionieren. `search-footer` und
`search-footer-open` verwenden echte Return-/Strg+G-/Umschalt+Strg+G-/Strg+Return-
Tasten und die sichtbaren Voriger/Nächster-/Beispielknöpfe. Alle diese Läufe
verwenden `G_DEBUG=fatal-criticals`.

`./linux/test.sh search-parity` prüft die native Extraktion in einen neuen dirty
Tab, Abbrechen, die Zwischenablage als Ziel, veraltete Eingaben ohne Ausgabe, All/None, das getrennte Freigabefenster, die Ablehnung nach Fremdfensterwechsel
und frisches Apply/Undo. `./linux/test.sh home` prüft spätes Abbrechen ohne
Teilabschluss, Verwerfen, leeren fokussierten Start und die Entwertung alter
Projektbindungen. `./linux/test.sh rich-find` prüft Ctrl+F, echte Tastatureingaben,
Return/Escape/Wiederöffnen, Groß-/Kleinschreibung, Treffer über Formatgrenzen,
Ctrl+G mit tatsächlichem Scrollen und den Wechsel zur Quelltextsuche. Die
Rich-Zahlen gelten dem vollständigen synchronisierten Quelltext. Rich-Aufnahmen
müssen das echte X11-Fenster einschließlich WebKit erfassen; GTK-Widget-Snapshots
allein können eine noch nicht gezeichnete WebKit-Fläche auslassen. Ein zusätzlicher
Lauf mit `G_DEBUG=fatal-criticals` prüft das Aufräumen verschachtelter GTK-Fenster.

Die weiterhin offenen Layoutangleichungen stehen in der [Roadmap](../ROADMAP.md).

### Linux: Dateivergleich und dokumentgebundene Übernahme

`./linux/test.sh diff` prüft den nativen Quelldialog, Ergebnis-Tab, Kopieren
ohne Nummern oder Ausrichtungszeilen, vollständige Vorschau, Übernahme und
ein natives Undo. Derselbe Lauf prüft lange Unicode-Zeilen, schmale und breite
Spalten, Soft Wrap sowie tatsächliches Auf- und Zuklappen mit sichtbarer Kopierausgabe.
`diff-interaction` prüft den echten neun Pixel breiten Trennleistengriff,
proportionalen Größenwechsel, gemeinsame Vorschau- und Tabteilung, Doppelklick,
F8/Pfeiltasten/Pos1 sowie Alt-Navigation bis zu einem vorher unsichtbaren
Unterschied und dessen tatsächlich sichtbaren virtuellen Listeneintrag.
Ein langer nativer Quelltext bleibt ohne Umbruch innerhalb der Spalte und
ohne zusätzliche horizontale Leiste. Das eigene Vergleichsprofil darf das
normale Textprofil nicht ändern. Eine zusätzliche Wiederaufnahmeprobe startet
einen frischen Prozess mit derselben privaten Konfiguration und prüft Teilung
und Umbruch erneut; Geometrie verborgener Tabs wird erst nach deren echter
Aktivierung bewertet.

`diff-states` bedient Optionen und Dateiquellen einschließlich fehlender, binärer
und BOM-kodierter Dateien; dateibasierte Quellen bleiben auch bei offenem
Dokument schreibgeschützt. `diff-guards` prüft echte Übernahmeversuche nach
Dokumentänderung und externem Austausch mit gleicher Größe und restaurierter
mtime, Abbrechen der Vorbereitung, Quellschließen und Wiederöffnung desselben Pfads.

`diff-rich` prüft exakte Übernahme im unveränderten Rich-Modus mit
nativem Undo/Redo/Undo. `FASTRA_DIFF_RICH_VARIANT` wählt zusätzlich `empty`,
`definitions`, `math` oder `image`; gerenderte Formeln und Bilder müssen
vor und nach Undo tatsächlich vorhanden sein. `diff-export` bedient
den nativen Speicherdialog, Abbrechen und die echte Überschreibbestätigung
für eine geschützte Vergleichsquelle. Der Bericht muss vollständig und
sprachrichtig sein; beide Quellen bleiben bytegleich.

`diff-drop` baut einen unabhängigen GTK-Prozess als Dragquelle und bietet
mehrere Dateien samt widersprüchlichem String an. Der native Drop muss COPY
melden und den ersten Dateipfad einschließlich Leerzeichen, Raute und ZWJ-Emoji
erhalten. `diff-large` verwendet standardmäßig 40.000 Zeilen;
`FASTRA_DIFF_LARGE_ROWS=200000` prüft die nominelle Zeilengrenze. Der Lauf
bricht zunächst einen pausierten Worker nativ ab und berechnet danach ohne
Pause neu. Während vollständigem Aufbau und echter Navigation zum letzten
Unterschied misst ein Main-Loop-Heartbeat die längste Bedienpause. Die Prüfung
liest unabhängig die wirklich sichtbare Quellzeile; eine geänderte Auswahl
allein belegt keinen erfolgreichen Sprung. Große Leistungsläufe ohne parallelen
Build ausführen. `diff-budget` prüft zusätzlich die erklärte Rechengrenze
bei langen 200.000-Zeilen-Quellen, ohne Teilergebnis oder Schreibzugriff.
Diese Tests benötigen ein isoliertes Display und ersetzen
keine physische IME- oder Screenreader-Abnahme.

### Linux: Speichern unter und gemeinsames Beenden

`./linux/test.sh save-as` prüft den nativen Dateidialog, beide Seiten der
vollständigen Zielvorschau, tatsächliche Bildkopien, Herkunft/Rücknahme,
Überschreibfreigabe und spätere Speicherung ausschließlich am übernommenen Ziel.
`./linux/test.sh git-force-push` prüft den eigenen Force-Modus einschließlich
Abbruch der Zusatzbestätigung, Serverdrift und veraltetem Fensterbesitz gegen
temporäre lokale Repositories. Der normale `git-push`-Fall bleibt getrennt.

`./linux/test.sh application-quit` verwendet den bestehenden Prozess-/
Steuerungsprobe für Mehrfensterentscheidungen, native Speicherauswahl,
veraltete Freigaben und den tatsächlichen Service-/Socketabschluss.
`./linux/test.sh application-quit-asset-io` hält echte Bildrücknahme und deren
letzten Main-Rückruf gezielt an: Beenden muss bis zum vollständigen Abschluss
blockiert bleiben und danach bei erneutem Versuch funktionieren.

Diese Tests verwenden ausschließlich ihre privaten Homes, Dateisystem-Fixtures
und Xvfb-Anzeigen. Dateitransaktionen brauchen das vom normalen Runner vorbereitete
unterstützte Dateisystem; ein gewöhnliches Container-Overlay oder TMPFS ist kein
Ersatz. Nach einer im Test absichtlich geänderten Projektwahl wartet der nächste
unabhängige Speicherfall auf deren frischen gebundenen Baum. Eine korrekt
abgewiesene veraltete Vorschau darf nicht als fehlgeschlagene Speicherung mit
unverändert gültiger Basis ausgegeben werden.

`./linux/test.sh application-quit-folder` prüft denselben Schließschutz bei echter
Ordner-Dateiübernahme und Rücknahme bis zur abschließenden Journalbestätigung.

### Linux: sichtbare Markdown-Leerzeilen und Zwischenablage

`./linux/test.sh rich-blank-lines` prüft die generierten sichtbaren Zeilen mit
echter Eingabe, Undo, Formatierung, Save, Tab-Close und Wiederöffnung.
`./linux/test.sh rich-blank-clipboard` führt fünf tatsächliche native
Copy-/Paste-Rundläufe aus: sichtbare Leerzeilen, verschachtelte und lose Listen,
Literalcode sowie NBSP und harte Umbrüche. Zusätzlich liest es das HTML aus der
statischen Vorschau über GDK. `rich-blank-typed-copy` prüft echte Eingabe in einen
solchen Platzhalter, Copy, Paste, Cut und die beiden Rücknahmen bis zu den exakten
Originalbytes. Ein DOM-Stringtest allein ersetzt diese Zwischenablagebelege nicht.

Sprachen und schmale/breite Ansichten gezielt ausführen und die Aufnahmen ansehen.
Ein unlesbares Erstbild gilt nicht als Sichtbeleg; das Testfenster muss sichtbar
positioniert sein. Der Runner setzt ein privates HOME und XDG-Verzeichnisse und
entfernt fremde Prüfflags vor dem ausdrücklich gewählten Fall.


Der [externe Linux-Vergleichshelfer](EXTERNAL-DIFF.md#linux) besitzt einen eigenen
isolierten Prüfeinstieg `linux/external-diff-test.sh BINARY_DIRECTORY NEW_OUTPUT`.
Ältere Laufzeitmanifeste mit zwei Executables bleiben zulässig. Neue Pakete ab
1.182.0 müssen auch den Diff-Helfer enthalten; ein Rückwechsel entfernt nur dessen
eigenen Launcher und stellt ihn bei einem Fehler wieder her.


### Linux: unabhängige Split-Auswahlen

`FASTRA_SPLIT_GATE_SELFTEST=1` aktiviert ausschließlich im Debugbuild den
nativen Komponenten-/Befehlszieltest. Dazu private X11-Anzeige, privaten D-Bus,
frische XDG-Verzeichnisse, `FASTRA_ISOLATED_DISPLAY=1` und
`FASTRA_TOOL_SCREENSHOTS` verwenden. `FASTRA_SPLIT_TARGET_CASE` prüft gebundene
Operationen; `FASTRA_SPLIT_PASTE_CASE` begrenzte tatsächliche B-Paste.
Die Auswahlprüfung mit `FASTRA_SPLIT_REVIEW_SCOPE0=1` schützt Ganzdateivorschauen.
PRIMARY-, Auswahl- und Historyfälle zusätzlich unter `G_DEBUG=fatal-criticals`
ausführen; Focus-only, tatsächliches Collapse und fremde Anbieter getrennt prüfen.
Die [Komponentenbeschreibung](linux-port/F07-SELECTION.md) hält Ressourcen- und
allgemeine Eingabegrenzen ausdrücklich fest.

### Linux: eingefrorener Suchbereich und kompakte Freigabevorschau

`linux/test.sh search-navigation`, `selection`, `single-replace`,
`single-replace-secondary` und `single-replace-longer` prüfen echte Trefferwahl,
Quellscrollen, unveränderte Vorschauidentität, Unicode/CRLF, mitwandernde Grenzen
und eigenständige Undo-Schritte. `single-replace-guards` und
`single-replace-guards-open` behalten die verspäteten Antworten nach Such- und
Fensterwechseln als separate Wächter.

`inline-preview` und `inline-preview-open` prüfen mit nativen Freigabeklicks
Einzel-/Sammelfreigaben, drei Zeilen mit ehrlichem Restzähler, aktive Dokumente
mit identischen Namen, sofortige Invalidierung und wirkungslose Ersetzungen.
Die Ansichten in beiden Sprachen, hell/dunkel und bei 520/900 Pixeln ansehen.
Der reine Zeilenvertrag wird mit Unicode, CRLF, mehrzeiligen Treffern,
Nulltreffern, ungültigen Freigaben, Abbruch und 200.000-Zeilen-Grenze geprüft.
Die kompakte Ansicht ersetzt niemals die vollständige Freigabeansicht.

### Linux: Ordnerquellen und Projekt-Datei-Sets

`linux/test.sh search-sources` und `search-sources-project` prüfen native
Auswahlhäkchen, Entfernen, die Dateitypwahl sowie Anlegen, Validierung und Löschen
von Datei-Sets. Reale Trefferzahlen belegen die Auswahl; Quelldateien bleiben
unverändert. Projekt-Ausschlüsse werden vor dem Schließen gespeichert und nach
Wiederöffnen frisch gelesen. `selection-entry` prüft echtes Strg+F, automatische
mehrzeilige Auswahlbindung, den Geöffnet/Datei-Rundweg und das Zurücksetzen der
wörtlichen Sternsuche.

Ordner-/Projektmasken mit langen Setnamen und mindestens acht Ordnern bei
520/900 Pixeln, in beiden Sprachen und hell/dunkel ansehen. Tatsächliche
X11-Fensteraufnahmen über den gemeinsamen Debug-Helfer verwenden; ein
`GtkWidgetPaintable` kann nach dynamischen Layoutwechseln Teile alter Frames
liefern. Mausklicks nach dem Einblenden der kompakten Vorschau erst nach deren
Montage und Größenvergabe ausführen.

Die Ablageprüfungen erfassen rohe Unix-Pfade, unabhängige Schreiber, Wiederöffnen,
ungültige Datei-Sets, beschädigte Daten und Symlinks. Der echte Datenträgertest
belegt ausgewählte Dateien/Unterordner, Ausschlüsse, unveränderte übrige Dateien
sowie Apply/Undo. Die relative Auswahl ist auf eine Projektwurzel gebunden und
wird vor dem Öffnen der Dateien geprüft. Die Release-Konfiguration zusätzlich
mit `cargo check --release --locked -p fastra-linux` prüfen: Debug-Prüfeinstiege
müssen vollständig aus diesem Build verschwinden.

`linux/test.sh template-menu` prüft die echte Popup-Auswahl per Maus und
Tastatur, frisch gelesene eigene Vorlagen, optionalen Ersetzungstext, erhaltene
Flags und Bereich, Namenskürzung nach sichtbaren Zeichen, „Keine“, eine
zwischenzeitliche Formularänderung und Wiederöffnen. Die eigentliche Quelle
bleibt unverändert. Leere Trefferlisten und das Dateitypmenü gehören zur
Sichtprüfung der Suchmasken in beiden Sprachen bei 520 Pixeln und breit.

### Linux: Bedienen und Schließen während lesender Ordnersuche

`linux/test.sh folder-readonly` hält eine bereits berechnete Worker-Antwort
gezielt zurück. Ein echter Mausklick öffnet währenddessen das Dateitypmenü;
dieses bleibt sichtbar und bedienbar. Die Auswahl „Alle Dateien“ beendet den
alten Lauf und liefert drei statt zwei Treffer. Tatsächliche Find-Eingabe und
Schließen während eines weiteren Laufs dürfen keine alten Ergebnisse in das
wieder geöffnete Fenster übertragen. Quellen und Editor bleiben unverändert.
`linux/test.sh folder` prüft weiterhin selektives Anwenden, Codec/BOM, schmutzige
Editoren und Rücknahme; während der schreibenden Phase sind Quellen und beide
Schließwege gesperrt. Die Antwortverzögerung existiert ausschließlich im
Debug-Selbsttest.

### Linux: native Quelltext-Gliederung und Verlauf

`linux/test.sh navigation` bedient das echte Gliederungspopup mit der Maus,
prüft Markdown und 4D, Rück-/Vorwärtssprünge nach wiederholten Änderungen,
Dokumentwechsel, geschlossene Ziele und mehrdeutige Überschriften. Die beiden
Textänderungen müssen über natives Undo vollständig zurückgehen; Navigation
legt keine eigenen Textschritte an. `outline-fallback` prüft einen 4D-Methodeneintrag
ohne Funktionen, einen Sprung auf dieselbe Position und die verborgenen
Verlaufsknöpfe im anschließenden Klartextdokument. `source-sync` bleibt ein
separater Wächter für gekoppelte Quellansichten.

Beide Sprachen, hell/dunkel und 760/1100 Pixel breit ansehen, einschließlich des
nativen Popup-Fensters. Unter Openbox müssen verwaltete Hauptfenster über die
Fenstermanager-Aktivierung fokussiert werden; direkte X11-Fokuszuweisung allein
kann danach reale Mausklicks verlieren. Unverwaltete Popups behalten ihren
eigenen nativen Fokusweg.

Der reine Ankervertrag wird gegen 1.130 tatsächlich ausgeführte Swift-Foundation-
Referenzfälle geprüft. Der Generator bewahrt zusätzlich das unveränderte
Swift-Ergebnis: Dessen doppelte Prüfung einer letzten Zeile ohne Abschluss
verweigert 80 sonst eindeutige Ziele. Linux wiederholt diese unbeabsichtigte
Doppelzählung nicht. Unicode, verschiedene Zeilentrenner, Mehrdeutigkeit, lange
Zeilen, Abbruch sowie Quell-/Zeilen-/Treffergrenzen werden getrennt geprüft.

### Linux: gemeinsame Rich-/Quelltext-Gliederung

`linux/test.sh rich-outline` prüft das native Popup mit 207 tatsächlichen
DOM-Überschriften, ausgeblendeten HTML-/Code-Überschriften, echtem Klick,
Rich-Auswahl und Scrollen. Rückwärts/Vorwärts muss in Rich bleiben. Echte
Tastatureingabe aktualisiert die Liste ohne manuelles Neuladen. Eine Antwort
vor einem Tabwechsel und Rückwechsel wird verworfen. Ein gespeicherter
Quelltext-Cursor wird über den normalen synchronisierten Moduswechsel
wiederhergestellt; natives Undo erreicht anschließend die Originalbytes und
die Datei bleibt unverändert. Die 760/1100-Pixel-Matrix in beiden Sprachen
und hell/dunkel verwendet tatsächliche X11-Popup-Aufnahmen.

Bei virtualisierten Listen reicht `is_mapped` nicht für einen Mausklick: Die
Zeile braucht eine tatsächliche Größenvergabe und einen fertigen Frame. Nach
asynchronem Moduswechsel ebenfalls vor der Aufnahme auf einen fertigen Frame
warten. Ein fehlendes `GtkWidgetPaintable`-Bild ersetzt keinen Sichtbeleg.

### Linux: direkte Zielsprünge, geteilte Ansichten und verspätete Antworten

`linux/test.sh target` bedient tatsächlichen Alt-Doppelklick und den nativen
Kontextmenü-Eintrag, lokale 4D-Funktionen, Dateiöffnen und den gemeinsamen
Verlauf ohne doppelte Tabs. Beide Suchfallbacks behalten Ersetzung und übrige
Optionen, wählen den richtigen Ordner-/Projektbereich und wechseln nur das
Muster in den Literalmodus. Die Prüfung bildet die vorhandene enge Whitelist
ab: zunächst kein `.4dm`-Treffer, dann ein tatsächlicher Treffer mit „Alle Dateien“.

`target-markdown` prüft Unicode/CRLF, die vollständige Ankerauswahl, eine lokale
Datei mit `%23` im Namen, Rück-/Vorwärts und die tatsächliche sichtbare Meldung
für einen fehlenden Anker. Ein privater XDG-Standardhandler empfängt die von
`GtkUriLauncher` gestartete kanonische Adresse. Das ist ein echter Desktop-
Dispatch im isolierten Lauf; der Test öffnet keinen Netzbrowser und verwendet
keine globale MIME-Konfiguration. Die URI-Schreibweise wird zusätzlich gegen
die unveränderte Foundation-Referenz geprüft.

`target-guards` hält bereits berechnete Antworten gezielt zurück. Ein Tabwechsel
mit Rückkehr, Textänderung mit Undo auf dieselben Bytes und das Schließen des
Ausgangstabs dürfen keine alte Auswahl oder Dateiöffnung übernehmen. Ein neuer
Sprung gewinnt. Die zweite Quellansicht behält die erste Auswahl unangetastet;
Gliederungsmarkierung und Rücksprung folgen der aktiven Teilansicht. Tatsächliches
Alt-Einzelziehen bleibt eine Rechteckauswahl und erhält vorhandenes Redo.
Verzögerung und Zähler existieren ausschließlich im Debugbuild.

Für diesen Gestentest darf der private Fenstermanager keine eigene Alt-Maus-
Belegung besitzen. Es werden keine Hosteinstellungen verändert. Im normalen
Desktop bleibt der Kontextmenü-Eintrag verfügbar, wenn dessen Fenstermanager
Alt-Mausgesten abfängt. Der Test wartet auf das Ende seines XTest-Prozesses,
einschließlich Modifier-Freigabe, bevor eine folgende Texteingabe beginnt.
Native GTK-Kindgesten setzen ihre Klickzähler zurück; die Anwendung liest den
Doppelklick deshalb vor ihnen am tatsächlich geklickten Fenster mit den
GTK-Zeit-/Abstandsgrenzen.

`crates/fastra-core/tests/fixtures/go-to-target-reference.py` führt die originalen
Foundation-Provider mit originalem 4D-Tokenizer und Symbolbestand aus. Der
620-Fälle-Beleg enthält auch kanonische URI und Linkliteral sowie vollständige
Ablehnungsgründe. Der Kern prüft das Literal, die native Grenze die URI. Einfache
Kleinschreibung reicht für `caseInsensitiveCompare` nicht: ß/SS, finales Sigma,
Ligaturen und die ausdrücklich verschiedenen I-Varianten bleiben geprüft.

### Linux-Textbausteine in Quelle und Rich

`linux/test.sh snippet-source` prüft die tatsächlich sichtbare Bausteinmaske,
beim Öffnen festgehaltene Auswahl, mehrzeilige und wiederholte Werte, direkte
Einfügevorschau, Werterhalt beim Speichern, native Einfügung/Undo, Filter,
Verweigerung veralteter Auswahl und Revision, Speichern/Verwerfen/Zurück sowie
JSON-Export/-Import mit neuen IDs und Namenszusätzen. Eine U+0000-Definition wird
vor der Einfügung abgewiesen; native GTK-Textpuffer bekommen keine Nullzeichen.

`linux/test.sh snippet-rich` betätigt den wirklichen Rich-Bausteinknopf, hält eine
DOM-Auswahl fest und prüft formatierten Markdown, tatsächlichen DOM- und GTK-Fokus,
natives Strg+Z/Strg+Umschalt+Z, unveränderte Quellbytes nach Undo und Verweigerung
nach Tabwechsel. Ein lokales Bild wird relativ zum gespeicherten Ziel geladen;
Bild und Dokument bleiben auf Platte unverändert. Eine Rücknahme entfernt Bild
und Text gemeinsam. WebKit kann beim Bearbeiten sichtbare Abstände als NBSP
serialisieren; die Darstellung prüft deshalb NBSP als Abstand und die Rücknahme
zusätzlich gegen die ursprünglichen Bytes.

`linux/test.sh snippet-big` verwendet 600.000 zusätzliche kurze Zeilen mit mehr als 4 MiB,
prüft die eingefrorene Auswahl, vollständige Ausgabeprüfung auf einem Worker,
native Einfügung, ein Undo und die unveränderte Datei. Es prüft den tatsächlich
vollständig geladenen Editor, nicht die schreibgeschützte Abschnittsansicht.
Textabläufe behalten ihren eigenen 4-MiB-Vertrag.

Die Sichtprüfung verwendet Source/Rich jeweils bei 760 × 650 und 960 × 740,
in Deutsch und Englisch sowie hell/dunkel. `FASTRA_TOOL_WIDTH` stellt die Breite
ein; `FASTRA_TOOL_SCREENSHOTS` sammelt native X11-Aufnahmen. Ein privater
Fenstermanager ist nötig, damit Dialogfokus und Rückgabe realistisch bleiben.
Bei nativen Undo-Prüfungen wird ein noch offenes nicht modales Ablaufwerkzeug
vorübergehend ausgeblendet, damit es den Quelleditor nicht verdeckt. Rückfragen
werden vollständig geschlossen, bevor der Test die Folgeaktion startet.

`linux/test.sh snippet-secondary` wiederholt den Bausteinlauf in der zweiten
Quellansicht. Die Teilung und Fokuswahl erfolgen über echte Klicks. Einfügung und
native Rücknahme erhalten die unabhängige Emoji-Auswahl der ersten Ansicht;
spätere Auswahl- und Revisionsprüfungen bleiben an die zweite Ansicht gebunden.


### Linux: schreibgeschützte Sitzungsreferenzen

`linux/test.sh session-readonly`, `session-readonly-only`,
`session-readonly-missing` und `session-readonly-optout` prüfen jeweils zwei echte App-Prozesse auf einem
privaten Xvfb-Display mit getrennten XDG-Pfaden. Der erste Prozess wird erst nach
bestätigter lokaler Sicherung per SIGKILL beendet. Vor dem Neustart entfällt der
Hardlink und der UTF-16-Dateiinhalt ändert sich. Native Freigabe und
Wiederherstellung müssen den aktuellen schreibgeschützten Text, die gemischte
Tab-Reihenfolge, den aktiven Tab und den ungesicherten Entwurf erhalten.
Der Fehlpfad entfernt eine Quelle und prüft die weiter vorhandene ursprüngliche
Sicherung. Der Nur-Lese-Fall schützt Archive ohne bearbeitbare Dokumente vor
versehentlichem Verwerfen. `FASTRA_TOOL_SCREENSHOTS` erfasst Freigabedialog,
Teilfehlermeldung und wiederhergestelltes Fenster. Der Opt-out-Fall stellt ausdrücklich wieder her, ohne eine neue Sicherung
anzulegen oder die ursprünglichen Archive zu verbrauchen. Die Sicherung bleibt ohne
Opt-in aus; V1-, Zeilenenden-, Eigentümer- und Journalregressionen gehören zum
bestehenden gezielten Sitzungsblock.


### Linux: appweite Quellschrift

`linux/test.sh source-font` und `source-font-readonly` prüfen die tatsächliche
native Wahl eines fett-kursiven Festbreitenschnitts, beide Quellausschnitte und
ein zweites Fenster. Ein frischer Prozess liest dieselbe Wahl und weist die
wirklich verwendeten Pango-Glyphenschriften nach. Text, gerichtete Auswahl,
Revision, Dirty, Undo und Quelldatei bleiben unverändert. Unter der gewählten
Schrift folgen echte Ctrl-Umschalt-Abwärts-/Copy-Eingaben in Ansicht B und die
exakte Prüfung der kopierten zwei Rechteckzeilen. `source-font-missing`
bietet einen unbekannten gespeicherten Namen als fehlend an und wählt erst
über native Eingabe auf System-Monospace zurück. `source-font-busy` hält die echte Konfigurationssperre: Der Fehler erhält die
vorige Plattenwahl, lässt die Darstellung und unveränderte Dokumente benutzbar
und wird nach Freigabe über einen nativen Retry-Klick behoben. Die privaten XDG-Pfade bleiben
vom Benutzerprofil getrennt. `FASTRA_TOOL_SCREENSHOTS` erfasst Optionen,
fehlende Schrift und Quellansichten; die Fenster werden bei Mindestbreite und
breit in beiden Sprachen geprüft. Die regulären Options-/Umbruch-, Quell- und
Rechtecktests sichern die angrenzende Geometrie ab.

### Linux: gemeinsame Markdown-Leseschrift

`linux/test.sh reading-font` wählt über die echte Schriftliste proportionale
Normalschrift, die gebündelten Inter- und Sora-Schriften sowie einen fett-kursiven
Schnitt. Vorschau und Rich-Editor müssen dieselbe Schrift mit 14 px Grundgröße
verwenden; WebKit muss die gebündelten Schriften tatsächlich laden. Abweichende
Glyphenbreiten sichern die Verwendung installierter Schriften ab. Ein echter
Rich-Tippeingriff mit Auswahl und Undo bleibt über alle Schriftwechsel erhalten,
ebenso Quellbytes, Revision, Dirty, Vorschau-Token und die 120 px breite Bilddatei.
Ein frischer Prozess prüft die gespeicherte Wahl in einer neu erzeugten Vorschau.

`reading-font-busy` hält die echte Konfigurationssperre und prüft den sichtbaren
Speicherfehler samt nativem Wiederholungsversuch. `reading-font-corrupt` und
`reading-font-missing` erhalten die vorhandene Datei und zeigen Fehler bzw.
fehlende Schrift ausdrücklich an. Die Store-Tests schützen zusätzlich fremde
Versionen und Felder, überlange Daten, Symlinks und die getrennte Quellschriftwahl.
Alle Varianten benötigen das vorhandene isolierte Display und private XDG-Pfade;
`FASTRA_TOOL_SCREENSHOTS` erfasst Einstellungen und beide Markdown-Ansichten.

### Linux: appweite Markdown-Vorschau

`linux/test.sh markdown-preview` prüft die standardmäßig eingeschaltete Vorgabe,
vorhandene und neue Tabs in zwei Fenstern, verzögertes Laden inaktiver Tabs und
Formatwechsel. Der native Schalter in den Einstellungen und der Vorschauknopf
verwenden denselben atomaren Speicher. Ein echter Rich-Tippeingriff mit markiertem
Text behält Auswahl und Undo über die globale Änderung. Nach nativem Undo wechselt
der bestehende Synchronisationspfad zum Quelltext; dort muss die aktuelle Vorgabe
gelten, obwohl vor dem Rich-Wechsel die gegenteilige Einstellung aktiv war.
Ein frischer Prozess prüft die ausgeschaltete Vorgabe ohne versteckte WebView.

`markdown-preview-busy` hält die Konfigurationssperre und prüft sichtbaren Fehler
und nativen Retry. `markdown-preview-corrupt` schützt die ursprünglichen Bytes
auch vor dem Vorschauknopf. Erst die Fixture repariert die Datei ausdrücklich;
der anschließende Retry muss die neue Vorgabe laden. Die Store-Tests schützen
zusätzlich unbekannte Versionen/Felder, ungültige Typen, Übergröße und Symlinks.
Die Fälle verwenden die reguläre isolierte Display-/XDG-Sandbox;
`FASTRA_TOOL_SCREENSHOTS` erfasst Schalter, Fehler und Vorschauzustände.

### Linux: Markdown-Standard und Dokumentwahl

`linux/test.sh markdown-mode` prüft echte Moduswechsel in drei Fenstern, bereits
geöffnete, neue und inaktive Dokumente sowie ausdrücklich gewählte Quelltext-
und Rich-Ausnahmen. Rich-Eingabe, Auswahl, Undo und Quellen müssen erhalten bleiben.
Eine echte Tab-Schließung nach der Vorbereitung blockiert den gesamten Wechsel;
kein früherer Eintrag darf bereits verschwinden. Eine neuere Synchronisation
behält ihre Eingabesperre, wenn eine ältere Vorbereitung endet. Eine tatsächlich
laufende WebKit-Synchronisation hält den nativen globalen Schalter an; der
Wiederholungsversuch muss die ursprüngliche Nutzerwahl übernehmen. Native
Quelltext-Undo-Schritte stellen anschließend die ursprünglichen Bytes wieder her.
Zwischenstände des gemeinsamen Serializers können sichtbare Leerzeichen als
`&nbsp;` bewahren; der Test prüft deren Textbedeutung und die exakte Endfassung.

`markdown-mode-busy` hält zusätzlich die echte Konfigurationssperre und prüft den
Speicher-Retry. `markdown-mode-corrupt` erhält die vorhandene Datei auch beim
fehlgeschlagenen Laden. Erst die Fixture repariert sie ausdrücklich und prüft
den anschließenden nativen Lade-Retry. Ein frischer Prozess belegt die
wiederhergestellte Vorgabe ohne Dokument-Override. Die Store-Tests unterscheiden
„noch nicht gewählt“ von der gespeicherten Quelltextwahl und schützen fremde
Versionen/Felder, ungültige Typen, Übergröße und Symlinks.

`markdown-mode-choice-source` und `markdown-mode-choice-visual` prüfen den ersten
Modusdialog, genau einen Besitzer für mehrere Fenster, Escape-Schutz und echte
Alt+Return-/Return-Eingaben. Die neue Dokumentwahl per Ctrl+Shift+Alt+M darf weder
den Standard noch andere Dokumente ändern. Dialog und Glyphen müssen bei
normaler, maximaler und minimaler Oberflächengröße innerhalb ihrer Grenzen bleiben.
`markdown-mode-choice-quit` belegt reguläres Beenden per Ctrl+Shift+Q aus dem
Dialog, ohne eine Moduswahl zu speichern. Andere isolierte Debug-Selbsttests überspringen diesen Erstkontakt wie der
Mac-Runner; Release-Builds durchlaufen immer den normalen Produktpfad.
Alle Fälle verwenden private XDG-Pfade und das vorhandene isolierte Display;
`FASTRA_TOOL_SCREENSHOTS` erfasst Dialog, Einstellungen, Fehler und Quellansicht.


### Linux: Diff-Übernahme und Farbwechsel

`linux/test.sh diff-palette` schaltet über die echten Einstellungen Hell/Dunkel/Hell,
auch mit `GTK_THEME=Adwaita:dark`. Ein bereits geöffneter Vergleich und seine
Übernahmevorschau müssen alle vier bestehenden TextTag-Gruppen einfärben, ohne
TextTag-Objekte, Bereiche, Auswahl, Rendergeneration oder Datenbasis zu ersetzen.
Die native Prüfung kontrolliert außerdem das SourceView-Farbschema, die vollständigen
Höhen langer umbrochener Zeilen und unveränderte Dateien. `diff-guards` schützt weiterhin Revision, geschlossene Tabs, Dateiaustausch,
ctime bei wiederhergestelltem mtime (auch nach abgeschlossener Worker-Prüfung),
weiterlaufenden GTK-Callbacks während eines gehaltenen Workers und Abbruch.
Vollständige Byteprüfungen besitzen
zusätzlich eine Debug-Assertion gegen den GTK-Mainloop; vor dem Speichercommit
bleibt die begrenzte Metadaten-/Pfadprüfung erhalten.

`diff-rich-image` prüft echte Übernahme mit Bilddarstellung und Undo/Redo/Undo sowie
die unveränderte Cache-Anzahl. Unit-Regressionen prüfen gemeinsame Anzahl-/Byte-/
Pixelgrenzen einschließlich alter Undo-Versionen, 300 wiederholte identische
Bildversionen und getrennt erhaltene geänderte Bytes. Quell- und Leseschrift
verwenden denselben internen Speicherzustand; beide nativen Schriftmatrizen
(normal/busy/missing und die jeweils unterstützten readonly/corrupt-Zustände)
prüfen Filter, angewendete Glyphen, Wiederholungsversuch und frischen Prozess.
