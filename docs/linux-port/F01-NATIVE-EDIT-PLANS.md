# F01: native Delete-/Backspace-/Join-Pläne

Der optionale Laufzeitkandidat für 1.188.0 erweitert die finale
[Commit-Vorprüfung](F01-NATIVE-BOUNDARIES.md). Der normale Systempfad bleibt
unverändert. Die Anwendung verlangt vor dem Laden von Dokumenten sowohl den
GTK-Vertrag als auch die passende GtkSourceView-Plan-ABI; ein fehlender
Hostkanal, fehlende [korrigierte Zeilenmetadaten](F01-NATIVE-ITER-METADATA.md)
oder eine nur teilweise passende Bibliothek beendet den Start mit
Fehler 2. Ein gültiger Hostkanal allein aktiviert keine private Bufferklasse.

## Vertrag vor der Mutation

Das private GTK-Signal `fastra-preflight-edits-v1` trägt eine sortierte Liste
`a(iis)` aus ursprünglichen GTK-Zeichenpositionen und UTF-8-Ersatztexten. TRUE
bedeutet Ablehnung. `fastra-preflight-line-bytes-v1` übernimmt die zentrale
64-KiB-Zeilengrenze; die ausschließlich lesbare SourceView-Property
`fastra-edit-plan-abi-v1` bestätigt mit `0x46454431` den passenden Planer.
Die Ergänzungen sind keine zugesagte öffentliche GTK-ABI.

Delete, Backspace einschließlich NFD-Rückschritt, SmartBackspace und Join
berechnen ihren Ersatz vor `begin_user_action` und vor dem Entfernen einer
Auswahl. Die Anwendung bindet die aktive Quellansicht und prüft die gesamte
projizierte Bytezahl gegen 32 MiB sowie die berührten logischen Zeilen gegen
64 KiB. Der vorhandene Bytezähler vermeidet eine vollständige Dokumentkopie
pro Taste. Mutationsepochen erfassen auch Paintables und Childanchors;
zwischen Prüfung und Anwendung veränderte Pläne werden nicht ausgeführt.
Fremde Signalhandleränderungen werden dadurch nicht rückgängig gemacht.

Join führt nur seine geplanten Bereiche aus. Jede nicht abschließende
Joinaktion fügt genau ein dauerhaftes Leerzeichen ein, wodurch die Anzahl
notwendiger Planeinträge durch das Zeilenbytebudget plus zwei beschränkt ist.
Zusammenhängende leere Zeilen werden zusammengefasst; geprüfte Millionenfälle
brauchen null oder einen Eintrag. Readonly-Teilbereiche werden konservativ
abgewiesen. Fastras Quellansicht besitzt derzeit vollständig editierbaren Text.

Eine bereits vollständig vorgeprüfte Commit-Auswahl darf vorübergehend eine
längere Zwischenzeile erzeugen, wenn unmittelbar danach der geprüfte Ersatz
folgt. Ausschließlich die genau dafür gebundenen privaten Aufrufe umgehen die
zusätzliche innere Delete-Prüfung. Ein globales Bypassflag oder ein allgemeines
Abschalten von Guards wird nicht verwendet.

## Prüfung und verbleibende Grenzen

34 tatsächliche native Tastatur-/Joinfälle auf Source A und B prüfen gültige
Einzel-Undoaktionen und Ablehnungen ohne Änderung an Text, gerichteter Auswahl,
Dirty, Revision, Undo/Redo, Useraktionen oder Auswahlmarken. 914 Joinbereiche
werden mit dem ursprünglichen SourceView-Ergebnis verglichen. Weitere Proben
betreffen Millionen leerer/Whitespace-Zeilen, Reentranz durch Anchors/Paintables
und den abgewiesenen Start mit Stock-GtkSourceView. Die vorherigen zehn finalen
Commitfälle bleiben ein eigener Vertrag.

Der Vertrag für Delete/Backspace/Join gilt ohne aktive Komposition. Preedit,
zusammenhängendes Surrounding-Delete mit Commit oder Cancel, andere Return-/
Einrückungsfolgen, Tab-/Snippetfolgen, Cut/Paste und AT-SPI sind gesonderte Eingänge.
Ein C-String kann keinen eingebetteten NUL als Text transportieren. Diese
Grenzen bleiben ausdrücklich offen; die Planliste ersetzt keine allgemeine
IME-Transaktion und keine physische IME-Abnahme mit Kandidatenfenster.


## Gewöhnlicher Return mit eingebauter Einrückung

Der zusätzliche private SourceView-Vertrag `fastra-return-plan-abi-v1`
(`0x52544e31`, UInt/read-only, Owner GtkSourceView) schützt gewöhnlichen Return
bei aktivierter automatischer Einrückung. Die eigene View liefert die nur
lesbare BOOL-Policy `fastra-linear-return-v1`. Beide Properties werden vor dem
Laden von Dokumenten auf Owner, Typ und Flags geprüft; der native Marker auch
auf seinen tatsächlichen Wert. Ein legitimes FALSE bei Rechteckauswahl ist
keine fehlende Capability.

Die Planung greift ausschließlich beim eingebauten Indenter, unverbrauchtem
IM-Filterergebnis und unveränderter Mutationsepoche. Der vollständige Ersatz
enthält LF, gegebenenfalls entfernten Whitespace und den kopierten Präfix.
Bei einer Auswahl bleibt der ursprüngliche Trigger erhalten: keine zusätzliche
Einrückung oder Trim. Nach der Query werden Buffer, Indenter, Auswahl,
Editierbarkeit und Policy erneut geprüft. Ein gültiger linearer Return bildet
genau eine Useraktion; bei Ablehnung beginnt keine.

Neue Returnzeichen bleiben im Buffer LF; vorhandene CRLF-Bytes werden nicht
umgeschrieben. Es gibt keine erfundene LF-zu-CRLF-Interception. Bei aktiver
Rechteckauswahl bleibt der bisherige native Gridpfad unverändert; dessen zwei
Useraktionen werden nicht als neuer Ein-Undo-Vertrag ausgegeben.

18 echte A/B-Fälle prüfen Return, Trim, Einfügen innerhalb der Einrückung,
beide Auswahlrichtungen, 32-MiB-Präfixveto, Closeguard und CRLF bis genau zur
Gesamtgrenze. Zwei aktive Gridfälle stimmen hinsichtlich Text, Peertext,
Auswahl, Dirty, Revision, Undo/Redo und Useraktionen exakt mit dem alten
Bibliothekspaar überein. Der eingefrorene Vertrag und das frühe App-Startupgate
sind unabhängig ohne weitere Funde geprüft. Verbrauchte oder verändernde
IME-Pfade, Custom-Indenter und beliebige fremde Rich-/Readonly-Tags bleiben
außerhalb dieser begrenzten Zusage.
