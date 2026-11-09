# Native 4D-Quellnavigation unter Linux

## Bedienung

`*.4dm` und `*.4qs` erhalten automatisch die gebündelte Sprache `4D`.
Sie ist auch unter „Editoroptionen → Format“ wählbar. Die vorhandene Wahl wird
weiter über den Formatstore gespeichert; Einrückung bleibt bei den bestehenden
Editoroptionen. Es werden keine 4D-Quelldateien umgeschrieben.

„Werkzeuge → 4D-Methoden und Parameter“ bindet ein natives Fenster an den
aktuellen editierbaren Quelltab. „Definitionen neu lesen“ zeigt Funktionen,
Getter, Setter, Query-/OrderBy-Funktionen und Klassenkonstruktoren. Treffer
markieren die originale Kopfzeile ohne öffnende Klammer. Kommentare, Strings
und `Begin SQL`/`End SQL`-Blöcke sind keine Definitionen. Gefaltete Quellen
müssen vor einem Sprung entfaltet werden.

„Projektmethoden lesen“ verwendet den bereits gewählten Projektbaum. Gelesen
werden ausschließlich die vier bekannten direkten Ordner
`Project/Sources/Methods`, `Sources/Methods`, `Project/Sources/Classes` und
`Sources/Classes`. Es gibt keinen rekursiven Projektvollscan und keinen
Dateiscan je Tastendruck. Eine Listenzeile zeigt die gecachte Signatur und den
Kommentarkopf. „Gewählte Methode öffnen“ prüft die gelesenen Bytes und die
Dateiidentität erneut auf einem Worker und öffnet über den bestehenden,
unmittelbar vor Veröffentlichung geprüften Owner-Pfad. Dessen bestehender
`load_path_validated`-Hook verlangt zusätzlich den tatsächlich geladenen
Text-Snapshot mit identischen Rawbytes, Pfad und Dev/Inode sowie gültiger
RootWorkBinding. Eine Prüfung nur vor dem asynchronen Load genügt nicht.

„Parameter am Cursor“ berechnet den innersten offenen Aufruf im Hintergrund.
Der aktuelle Parameter ist mit `▶` markiert. Die Signatur kommt nur aus einer
eindeutigen Projektdatei, nie aus einer vermeintlichen Compilerantwort.
Unterstützt sind `#DECLARE`, dessen Rückgabe, klassische `C_*`-Deklarationen
mit optionalem `:Cnnn`, nummerierte Parameter einschließlich Lücken und
`${N}`-Variadics. Die klassische höchste Parameternummer ist 1024. Benannte
Prozessvariablen werden nicht als klassische Parameter ausgegeben.
Objektmember, lokale Variablen und Kontrollwörter liefern keinen
Projektmethodenaufruf. Methodenvergleiche verwenden Kleinschreibung und NFC,
Dateipfade behalten ihre originalen Unix-Bytes.

Der Index ist ein ausdrücklich neu einzulesender Snapshot. Externe Änderungen
werden nicht als live eingelesene Signaturen ausgegeben. Projektauswahlwechsel
verwerfen den Snapshot und brechen aktive Arbeit ab; reine Baumfilter ändern
seine Projektgeneration nicht. Vor einer Aktion müssen Dokumentobjekt, aktiver
Tab, Revision, Rich-/Readonly-Sperre und Ergebnisgeneration passen. Cursorhilfe
prüft zusätzlich die bei Auftragserteilung gelesene Cursorposition. Schließen
oder Verbergen des Hauptfensters beendet das Werkzeug und seine Arbeit. Ein
Abbruch zeigt keine Teilergebnisse und startet keine neue Arbeit automatisch.

## Grenzen und bewusste Teilmenge

- Quelltab: 4 MiB UTF-8, 10.000 Definitionen, 1024 Bytes je Definitions-/Aufrufname.
- Projekt: 4000 Verzeichniseinträge, 2000 Dateien, 1 MiB je Datei, 16 MiB gesamt.
- Höchstens 1024 Parameter und 1024 offene Aufrufklammern.
- Höchstens 200 sichtbare Listeneinträge; Namensfilter grenzt die Anzeige ein.
  Details zeigen höchstens 16.000 Unicode-Skalare mit sichtbarem Kürzungshinweis.
- Verzeichnis-/Datei-Symlinks und Spezialdateien werden sichtbar verweigert.
  Gehaltene Eltern-Deskriptoren und `openat(O_NOFOLLOW)` verhindern das Verfolgen
  ausgetauschter Elternlinks. Dateien werden vor/nach dem begrenzten Lesen
  geprüft. Ungültiges UTF-8 ist ein Fehler; nicht darstellbare Methodennamen
  und Steuerzeichen im Namen erscheinen als ausdrücklich ausgelassene Pfade.
- Cancellation wird in Quellscan, Offsetaufbau, Deklarations-/Argumentläufen
  sowie zwischen Verzeichniseinträgen und Dateiblöcken geprüft. Ein im Kernel
  blockierter Dateisystemaufruf besitzt keinen erzwungenen Abbruch.

Dies ist keine vollständige 4D-Grammatik oder Compilerprüfung. Die statische
Definitions-/Signaturteilmenge folgt `FourDDefinitions.swift` und
`FourDSignatureHelp.swift`. Der Linux-Scan ist bewusst strenger bei Symlinks
und UTF-8. Komponentenarchive, Komponenten-/Klassenauflösung,
Projektmethoden-Autovervollständigung, vollständiges SQL-Highlighting,
Makroausführung und Compilerdiagnosen bleiben offen. Die Syntaxfarben sind
GtkSourceView-Styles; die exakten Mac-4D-Themenfarben werden nicht behauptet.

## Ressourcen und Herkunft

Die eigene GtkSourceView-Grammatik enthält 1270 Befehls- und 2306 Konstantennamen
als Fakten aus dem vorhandenen `FourDSymbols.swift`. Herkunft/Lizenz:
[4D-Dokumentation, CC BY 4.0](../../THIRD-PARTY-NOTICES.md#4d-dokumentation-abgeleitete-fakten).
Es werden keine Beschreibungen oder fremden Grammatiken übernommen.
`crates/fastra-linux/resources/generate-four-d.py` erzeugt Grammatik und
Testkorpus reproduzierbar. Feste Präfixkontexte halten die einzelnen und
zusammengefassten GtkSourceView-Transitionen unter dem Regex-Compilerlimit;
Längsttreffer gelten vor Kategorien, danach Befehle/Konstanten/Keywords wie
im vorhandenen Swift-Tokenizer.

`build.rs` verlangt `glib-compile-resources` und verfolgt XML und `.lang` mit
`rerun-if-changed`. Das GResource ist im Binary eingebettet. Im GTK-Startup
wird `resource:///org/fastra/language-specs` vor dem ersten Sprachladen zum
DefaultManager hinzugefügt; alle Standardsuchpfade bleiben erhalten.
[GtkSourceView unterstützt diese Ressourcenpfade seit 5.4](https://gnome.pages.gitlab.gnome.org/gtksourceview/gtksourceview5/method.LanguageManager.set_search_path.html),
die Buildbasis verlangt mindestens 5.6. Es gibt weder absolute Buildpfade noch
Quellbaum-Fallback, Cacheextraktion oder nachzuliefernde Sprachdatei.

## tool4d/LSP: enger Verfügbarkeitsbefund

Die [offizielle CLI-Dokumentation](https://developer.4d.com/docs/Admin/cli)
nennt Windows/macOS. Der [offizielle Analyzer-Downloader](https://github.com/4d/4D-Analyzer-VSCode/blob/main/editor/src/tool4D/toolPreparator.ts)
enthält jedoch explizit Linux, `/opt/tool4d/tool4d` und einen Debian-Paketpfad.
Ein pauschaler Linux-Ausschluss wäre deshalb falsch. Beim lokalen Versuch
waren weder PATH-Binary noch dieses Artefakt oder ein lokaler Analyzer vorhanden.
Es wurde nichts heruntergeladen, systemweit installiert oder gestartet.
Runtime-/LSP-Funktion ist in diesem statischen Paket ausdrücklich ungeprüft.
Die Mac-Implementierung und ihre Produktgates bleiben unverändert.

## Prüfbeleg

Acht neue Coretests enthalten 15 tatsächlich ausgeführte synthetische
Swift-Referenzfälle für Definitionen, UTF-16-Bereiche, Signaturen und
Aufrufkontexte. Für Linux Foundation wurde nur die temporäre Kopie von
`FourDDefinitions` um die dort nötige `@escaping`-Annotation des
Regex-Callbacks ergänzt; Tokenizer, Tabellen und Auswertelogik blieben gleich.
Weitere Vektoren prüfen Unicode/NFC, CRLF, Kommentare/SQL, Größen-/Parameter-/
Namens-/Klammergrenzen und Cancel. Ein 700.012-Byte-Header mit 100.000 Modifiern
wurde in etwa 395 ms im Debugtest verarbeitet; keine allgemeine Laufzeitgarantie.
Vier Indexfälle prüfen temporäre Rohpfade, unlesbare Namen, FIFO/Symlinks,
Dateigrenze, veraltete Quellen und den echten geladenen Snapshot nach
Byteänderung beziehungsweise Inodeersatz.

Native DE/EN-Läufe bei 640 und 1080 Pixeln prüfen echte Tools-Menüs, originale
Quellbereiche, fremde Tabs, alte Treffer, Projektfilter/-wechsel,
Parameterhilfe, veraltete Datei, frisches Reopen über den Codec-Pfad,
Cancellation, Rich-Sperre und Verbergen des Elternfensters. Der vollständige
Korpus von 3576 Symbolnamen erhält jeweils am letzten Zeichen einen echten
GtkTextTag-Vordergrund. Die Läufe verwenden ausschließlich private Xvfb-/DBus-
Sitzungen und temporäre XDG-Verzeichnisse; nur das verschobene Binary und ICU
sind eingebunden, kein Quellbaum oder Build-Ressourcenpfad.
