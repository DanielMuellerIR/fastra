# Sicherer Git-Ausbau

Stand: 2026-07-16. Dieses Dokument beschreibt Ausgangspunkt, umgesetzte
Architektur, Sicherheitsgrenzen und Abnahme des Git-Ausbaus in Fastra 1.18.0.
Die fünf Implementierungspakete wurden jeweils nach gezielten Tests durch zwei
getrennte Reviews geprüft und ihre bestätigten Findings korrigiert. Die
abgeschlossene visuelle Produktabnahme ist unten getrennt aufgeführt.

## Verifizierter Ist-Stand

Fastra erkennt lokale Repositories und zeigt Branch, Ahead/Behind, Dateiänderungen,
Branches und einen Commit-Graphen. Staging, Commit, Fetch, Pull, Push und einige
Zusatzaktionen sind dünne asynchrone Frontends zum installierten `git`-CLI. Vor
Beginn bestanden 783 Swift-Tests und der Lokalisierungs-Audit jeweils mit Exit 0.

Vor Paket 1 nutzte die Statusabfrage Porcelain v1 als Text und konnte Pfade mit
Zeilenumbrüchen sowie Rename-Quellpfade nicht verlustfrei modellieren. Status,
Branches und Graph wurden getrennt aktualisiert. Der Prozesswrapper unterschied
einen Startfehler nicht von fehlendem Git und begrenzte seine Ausgabe nicht. Eine
zentrale Operationskoordination, Fetch-Historie und typisierte Git-Präferenzen
existierten noch nicht.

## Architekturentscheidungen

- Git bleibt die einzige Quelle für Repositorysemantik. Fastra baut keine eigene
  Git-Engine und ändert keine Repository- oder globale Git-Konfiguration ohne eine
  ausdrückliche Nutzeraktion.
- Jeder Aufruf verwendet Executable und Argumentarray ohne Shell, `--no-pager`
  und `GIT_TERMINAL_PROMPT=0`. stdout und stderr werden parallel, begrenzt und als
  rohe Bytes gelesen; Start-, Exit- und Abbruchzustände bleiben unterscheidbar.
  Repository-, Index-, Objekt-, Konfigurations- und Executable-Umleitungen aus
  der geerbten Umgebung werden entfernt. Interaktive Credential- und Askpass-
  Wege sind zusätzlich abgeschaltet; konfigurierte SSH- und Credential-Helper
  dürfen nicht unbemerkt eine GUI-Eingabe öffnen. Für den eigentlichen Lauf
  startet Fastra eine eigene Prozessgruppe. Abbruch oder Timeout senden SIGTERM
  und nach kurzer Frist SIGKILL an diese Gruppe, sodass auch Git-Hooks und
  geforkte Helper beendet werden. Eine kurze Drain-Frist verhindert, dass ein
  geerbter stdout-/stderr-Descriptor den Repository-Slot dauerhaft hält. Eine
  eigene hoch priorisierte Deadline-Queue verhindert, dass Timeout- und
  Eskalationsfristen hinter umfangreicher Utility-Arbeit verspätet auslösen.
- `git status --porcelain=v2 --branch -z` liefert Status, exakten HEAD-OID,
  Branch/Detached, Upstream und Ahead/Behind. NUL ist die einzige Datensatzgrenze;
  Sonderzeichen in Pfaden werden nicht nachträglich „entquotet“. Rohe Pfadbytes
  bleiben die eindeutige Identität. Nicht als UTF-8 darstellbare Pfade sind
  sichtbar, aber für einzelne Dateiaktionen gesperrt, weil `Process.arguments`
  sie nicht verlustfrei adressieren kann.
- Ein app-weiter Operationskoordinator serialisiert kollidierende Vorgänge pro
  kanonischem Repository und dedupliziert identische Fetches und Refreshes.
  Verschiedene Repositories bleiben unabhängig. Ein vollständiger Read-Batch
  hält denselben Slot über Status, Branches und Graph, damit keine Mutation
  dazwischenläuft. Der app-weite Store verteilt eine monotone Snapshot-Revision
  an alle Fenster; Generation und Repositorypfad verwerfen verspätete Antworten
  und Aktionsketten. Normale Dateispeicherungen laden nur den Status neu, nicht
  die bis zu 2000 Commits umfassende Historie.
- Worktrees teilen teilweise ein Common Directory. Fastra ermittelt es
  asynchron mit `git rev-parse --path-format=absolute --git-common-dir` und
  registriert erst eine verifizierte Antwort als gemeinsamen Lock-Key. Bei
  Fehlern bleibt der kanonische Worktree-Root der ehrliche Fallback.
- Auto-Fetch ist eine globale Fastra-Präferenz und niemals Pull. Standardintervall
  sind 180 Sekunden, zulässig sind 60 bis 3600 Sekunden. Pull-Strategien werden
  explizit als Rebase, Merge oder Fast-Forward-only ausgeführt.
- Genau ein appweiter Scheduler läuft nur bei aktiver App. Er misst die
  Fälligkeit je Repository ab dessen letztem Versuch, dedupliziert Fenster
  desselben Repositories, lässt verschiedene Repositories parallel und bricht
  den Auto-Fetch-Lease beim letzten geschlossenen Beobachter ab. Ist „Bei App-
  Aktivierung abrufen“ aus, wartet auch ein noch nie abgerufenes Repository nach
  der Aktivierung das volle Intervall. Remote-Erkennung verwendet ausschließlich
  das lokale `git remote`; „Später“ verschiebt die Erstfrage um 24 Stunden.
- Pull prüft Upstream, unaufgelöste Konflikte und die von Git aufgelösten Marker
  für Merge, Rebase, Cherry-pick, Revert und Bisect. Lokale Änderungen werden
  sichtbar bestätigt. Prüfung, Bestätigung, eine zweite frische Status-/Marker-
  Prüfung und Pull halten einen einzigen exklusiven Repository-Slot; änderte sich
  der Status, wird vor der Mutation abgebrochen. Jede Strategie übergibt
  `--no-autostash`, Merge zusätzlich `--ff`; Repository-Konfiguration kann diese
  Sicherheitsgrenzen nicht still aufweichen. Fastra erzeugt weder Stash noch Push
  oder Sync als Nebenwirkung. Auch Fehler und Konflikte lösen einen vollständigen
  Refresh aus.
- Schreibende Mehrfachänderungen außerhalb von Git behalten unverändert ihre
  vollständige Vorschau- und Apply-Grenze.
- Der Graph markiert HEAD ausschließlich durch die exakte Status-OID. Ein
  eigener kontrastreicher Halo, eine dezente Zeilenfläche und das sichtbare
  `HEAD · Branch`- beziehungsweise Detached-Label sind von der inneren
  Merge-Ringform unabhängig. Decorations bleiben zusätzliche Labels und sind
  niemals Quelle der HEAD-Entscheidung.
- Graph-Metadaten und Dateiänderungen kommen aus einem bytebasierten
  `git log -z`-Protokoll. Raw- und Numstat-Pfade werden vor der Anzeige nicht
  zeilen- oder tabbasiert als Text zerlegt; Rename-Quelle und -Ziel bleiben
  getrennte NUL-Felder. Ungültiges UTF-8 bleibt sichtbar, sperrt aber die
  nicht verlustfrei mögliche Git-Aktion.
- Git-Diffs besitzen eine typisierte, repositorygebundene Request-Identität.
  Status-Dateien verwenden getrennte Index-/Arbeitsbaumquellen; Graph-Dateien
  vergleichen Root-Commits ausdrücklich mit dem leeren Baum und andere Commits
  mit dem sichtbaren ersten Eltern-Commit. Falls nach einem Graph-Refresh keine
  sichere Elterninformation mehr vorliegt, bleibt der bisherige Unified-`show`-
  Tab der ehrliche Fallback.
- Der reduzierte Vorher-/Nachher-Diff parst strikt UTF-8-dekodierbare Git-Patches
  mit explizit deaktivierten Farben, externen Diff-Treibern und Textconv. Literal
  Pathspecs, Rename-Erkennung und 24 kontrollierte Kontextzeilen liefern
  die Daten für eine gemeinsame `LazyVStack`. Ausgabe ist auf 4 MiB, die
  Darstellung auf 50.000 Zeilen, 128 KiB pro Zeile und 2.000 Hunks begrenzt;
  Intraline-Markierung endet bewusst bei 4.096 Zeichen und der Ruler bei 160
  Markierungen. Binärdateien werden pro Datei als Metadatenhinweis gezeigt.
  Combined-/Konflikt-Diffs bleiben vollständig auswählbar als Unified-Fallback,
  statt als leerer Zweispalten-Diff zu erscheinen. Alignment, Falten,
  Navigation und Ruler sind pure, separat getestete Modelle.
- „Terminal im aktuellen Ordner …“ übergibt eine Verzeichnis-URL direkt an
  `NSWorkspace`. macOS stellt keine stabile öffentliche API für eine beliebige
  Standard-Terminal-App samt Arbeitsverzeichnis bereit; deshalb ist die über
  Bundle-ID gefundene Terminal.app der dokumentierte native Fallback. Es gibt
  weder Shell-/AppleScript-Konstruktion noch ein integriertes Terminal.
- Konflikthilfe bleibt Teil des normalen CodeEdit-Editors. Ein strikter
  UTF-16-bewusster Parser erkennt normale und diff3-Marker samt CRLF, Labels und
  mehreren Blöcken; unvollständige oder verschachtelte Strukturen werden nicht
  verändert. Oberer, unterer und beide Blöcke ersetzen den gesamten Markerbereich
  über die native TextView-Mutation und sind dadurch mit Befehl-Z rückgängig.
  Binäre, nicht sicher dekodierbare und nur abschnittsweise geladene Dateien
  erhalten keine vorgetäuschte Textauflösung. Vor dem Anzeigen der Textaktionen
  fragt Fastra `binary`, `text`, `diff`, `merge` und `conflict-marker-size`
  pfadspezifisch über `git check-attr -z` ab. Der NUL-Parser verlangt jeden
  erwarteten Attributsatz mit dem exakten rohen Pfad; Fehler bleiben fail-closed
  im Terminalpfad. Damit gilt Gits Binärklassifikation auch dann, wenn die
  aktuellen Arbeitsbaumbytes zufällig als UTF-8 dekodierbar sind.
- „Als gelöst markieren“ setzt einen gespeicherten Editorstand voraus. Fastra
  erfasst Dateibytes, Modus, Konfliktstufen, Attribute, relevante Filter- und
  Konvertierungskonfiguration, Markerbreite sowie HEAD-/Ref-/Indexpfade. Der Blob
  entsteht mit `hash-object -w --path=<Pfad> --stdin`, damit Clean-Filter, EOL
  und `working-tree-encoding` genau wie bei `git add` gelten. Vor der Mutation
  startet Fastra interaktiv `git update-index -z --index-info`; Git hält dadurch
  seinen offiziellen Index-Lock. Parallel hält eine vorbereitete
  `git update-ref --stdin`-Verify-Transaktion den exakten symbolischen HEAD-Ref.
  Erst nach einer dritten bytegenauen Revalidierung wird genau ein NUL-terminierter
  Stage-0-Datensatz übergeben. Lock-, Timeout-, Abbruch- und Pipe-Fehler brechen
  vor diesem Punkt ohne Mutation ab; nach erfolgreicher Übergabe wird das reale
  Ergebnis gemeldet statt fälschlich „abgebrochen“. Verbleibende Markersequenzen
  brauchen eine eigene bewusste Ausnahme. Merge, Rebase, Cherry-pick und Revert
  verwenden die von Git aufgelösten Markerpfade auch in Worktrees; Continue
  akzeptiert nur den bereits vorhandenen Git-Committext und öffnet keinen
  unsichtbaren interaktiven Editor.
- Branch-Erstellung, Stash, Stash Pop, Cherry-pick, Revert und Force Push with
  Lease laufen als getrennte Argumentarrays nach Status-/Operationsprüfung,
  Nutzerentscheidung und identischer Revalidierung im selben Slot. Stash Pop,
  Cherry-pick und Revert verlangen einen sauberen Arbeitsbaum. Force-Push ist
  nur für einen lokalen symbolischen Branch mit eindeutig aufgelöstem Upstream
  vorhanden. Fastra friert Quell-OID, Remote, Ziel-Ref und erwartete entfernte
  OID vor der Bestätigung ein und pusht `<Quell-OID>:<Ziel-Ref>` ausschließlich
  mit einem ref-spezifischen `--force-with-lease`, nie mit `--force`.
- Die Commitpfade lesen `user.name` und `user.email` mit Git-Includes und
  `includeIf` repository-lokal und global getrennt. Eine app-weite Identity-
  Schranke umschließt diese Reads, alle identitätsabhängigen Mutationen und
  Schreibvorgänge über Repositorygrenzen hinweg. Die Konfiguration ist
  standardmäßig `--local`; `--global` verlangt Auswahl und eine zweite
  ausdrückliche Bestätigung. Name und E-Mail werden als getrennte Argumente
  seriell geschrieben, gemeinsam verifiziert und bei einem Teilfehler auf den
  vorherigen Zustand zurückgerollt; Werte erscheinen nicht im Log.

## Pakete und Reviews

1. **Fundament:** Porcelain-v2-Status, robuster Prozesslauf, typisierte
   Präferenzen, Operationskoordinator, Snapshot/Refresh-Pipeline und gehärteter
   Lokalisierungs-Audit.
2. **Fetch und Pull:** Erstentscheidung, Einstellungen, App-Aktivierung/Timer,
   Fetch-Alter und Fehlerzustand, verständliche Ahead/Behind-Anzeige sowie Pull
   mit gemerkter expliziter Strategie.
3. **Graph und Diff:** exakte HEAD-Markierung, reduzierter read-only
   Side-by-side-Diff mit gemeinsamer Zeilenliste, Hunk-Navigation,
   Intra-Zeilen-Markierung und externer Terminalaufruf.
4. **Konflikte und Aktionen:** Textkonfliktmodell, Undo-fähige Übernahmen,
   Merge-/Rebase-Fortsetzen und -Abbrechen, Binärgrenzen, Stash, Branch ab Commit,
   Cherry-pick, Revert, Force-with-Lease und Git-Identität.
5. **Integration und Release-Abnahme:** Accessibility, Deutsch/Englisch,
   Dokumentation, Version, vollständige Headless-, Bundle- und visuelle Prüfung.

Alle fünf Pakete sind implementiert. Nach jedem Implementierungspaket prüften
zwei read-only Reviews getrennt (a) Korrektheit, Nebenläufigkeit, Git-Sicherheit
und Datenverlust sowie (b) UX, Accessibility, Lokalisierung und Testabdeckung.
Bestätigte Findings wurden jeweils durch denselben Paket-Writer korrigiert und
gezielt erneut geprüft. Paket 5 konsolidiert die öffentliche Dokumentation und
Version 1.18.0; die vollständigen Headless- und Bundle-Ergebnisse stehen nach
dem reproduzierbaren Abschlusslauf im nächsten Abschnitt. Eine fokuserfordernde
visuelle Abnahme ist keine stillschweigende Voraussetzung für „Tests grün“,
sondern bleibt als eigenes Gate sichtbar.

## Erfolgskriterien und reproduzierbare Tests

- **Status:** Pure Byte-Tests decken Branch mit/ohne Upstream, Ahead, Behind,
  beides zusammen, Detached HEAD, initiales Repository, Konflikte, Rename mit
  getrenntem Quell-/Zielpfad sowie Leerzeichen, Nicht-ASCII, Tab und Zeilenumbruch
  ab. HEAD wird nie aus Graph-Decorations geschätzt.
- **Prozess:** Ein kontrolliertes temporäres Executable schreibt gleichzeitig
  mehr als einen Pipe-Puffer nach stdout und stderr. Der Test muss ohne Timeout
  enden und beide Ausgaben behalten. Separate Tests prüfen ehrlichen Startfehler,
  Abbruch vor und nach Prozessstart, Timeout, Argumentarray, Ausgabegrenze samt
  sichtbarem Kürzungshinweis, literal Pathspecs sowie die bereinigte
  Prompt-/Repository-/Konfigurationsumgebung. Reale temporäre Repositories prüfen
  Dateinamen mit Pathspec-Magic und führendem Bindestrich.
- **Präferenzen:** Frische und ältere UserDefaults-Suites prüfen Ask/Automatic/
  Disabled, Migration, Standard 180, Clamp 60…3600, Fetch bei Aktivierung,
  Remote-Auswahl, Prune und Pullstrategie. Andere Defaults bleiben unverändert.
- **Koordination:** Ein kontrollierbarer Fake-Executor beweist identische
  Same-Repo-Fetch-Deduplizierung, Same-Repo-Serialisierung, Parallelität zweier
  Repositories, stornierte Leases, Freigabe nach Timeout, unteilbare Read-Batches,
  Store-Deduplizierung und Fenster-Fanout. Repo-Wechseltests unterbrechen
  `add`→`commit` und Push-Preflight→Push vor dem Folgebefehl.
- **Fetch/Pull:** Temporäre lokale Repositories und Bare-Remotes prüfen
  Erstentscheidung, Zeitgrenzen, mehrere Fenster, Projektwechsel, Fehler,
  Dirty/kein Upstream/divergent/Konflikt und die exakten Pull-Argumente. Kein Test
  darf automatisch stashen, pushen oder das echte Arbeitsrepository verändern.
  Der Paket-2-Lauf deckt zusätzlich Common-Dir-Worktrees, Abbruch beim letzten
  Fenster, Inaktivität ohne Timer, relevante/alle Remotes samt Prune, Fetch-
  Fehler/Retry/Stale sowie alle fünf laufenden Operationstypen ab.
- **Graph:** NUL-/Byte-Fixtures und ein reales temporäres Repository decken
  normales und detached HEAD, Merge-HEAD, Rename sowie Pfade mit Leerzeichen,
  Unicode, Tab und Zeilenumbruch ab. Kontrollierte Store-Races prüfen externe
  HEAD-Wechsel, maximal zwei Konsistenz-Retries und ausbleibende Publikation bei
  dauerhaft gerissenen Status-/Graph-Batches.
- **Diff-Datenquelle:** Ein reales temporäres Repository prüft Root-, Index-,
  Arbeitsbaum- und unversionierte Diffs mit Leerzeichen, Unicode,
  Pathspec-Magic und führendem Bindestrich. Pure Tests prüfen zusätzlich
  Alignment, getrennte EOF-Marker, Falten, manuelle Hunk-Auswahl,
  Refresh-Clamping, Overview-Ruler, Intraline-Grenzen, ungültiges UTF-8,
  Binärmetadaten sowie Byte-, Einzelzeilen- und Hunklimits. Ein real erzeugter
  Merge-Konflikt prüft den vollständigen Combined-Unified-Fallback. Kontrollierte
  Executor-Tests prüfen Tab-Schließen, Load-Generationen, trailing Refresh und
  Exit 1 bei erneut geladenen unversionierten Dateien.
- **Terminal:** Injizierte Locator-/Open-Closures beweisen die unveränderte
  Übergabe von Verzeichnis- und App-URLs; Auflösung priorisiert Projektroot vor
  aktiver Datei. Tests prüfen Utility-Queue für Volume-I/O, Main-Thread für
  NSWorkspace-Schritte, normale Dateien, fehlende App und Open-Fehler.
- **Konflikte und Zusatzaktionen:** Pure Parser-Fixtures prüfen normale und
  diff3-Marker, benutzerdefinierte Markerbreiten, CRLF, Labels, mehrere Blöcke,
  manuelle Bearbeitung sowie unvollständige und verschachtelte Marker. Der echte
  Workspace→CodeEdit→UndoManager-Pfad prüft obere, untere und beide Übernahmen
  jeweils mit Undo und Redo. Reale temporäre Repositories prüfen Merge sowie
  Rebase mit Merge- und Apply-Backend für Continue, Skip und Abort, unveränderte
  Committexte, echte NUL-Binärkonflikte, per `.gitattributes` trotz UTF-8-Inhalt
  als `binary` klassifizierte Konflikte, mehrere diff3-Blöcke und verknüpfte
  Worktrees. Die Attributtests belegen den fail-closed Terminalpfad samt
  lokalisiertem Modellgrund, ausbleibende Text-/Stage-Aktionen, unveränderte
  Bytes und erhaltene Unmerged-Stufen. Die tatsächliche visuelle Darstellung
  dieser Hilfe ist in der unten dokumentierten visuellen Abnahme geprüft.
  Der exakte Stage-0-Pfad wird unter echten Git-Index-/Ref-Locks mit EOL-,
  `working-tree-encoding`- und Clean-Filter-Konvertierungen, Detached HEAD,
  konkurrierendem HEAD, Lock-Kollision, Pipe-Fehler, Abbruch und Timeout geprüft.
  Weitere Repositorytests decken Branch, Stash mit und ohne unversionierte
  Dateien, Pop, Cherry-pick, Revert und fest aufgelöstes Force-with-Lease ab.
  Identity-Tests verwenden isolierte HOME/XDG-Verzeichnisse und prüfen lokale
  sowie globale Paarwrites, Includes/`includeIf`, app-weite Race-Barriere,
  Rollback, Abbruch und unterdrücktes Askpass.
- **Integration:** `swift test`, Lokalisierungs-Audit, Build, portable App und
  In-App-Selbsttests folgen den Exit-Code-Regeln des Projekts. Visuelle Abnahme
  umfasst Light/Dark, erhöhten Kontrast, Tastatur, Tooltips, VoiceOver sowie
  Auswahl und Kopie langer Unified-/Side-by-side-Ausgaben. Diese visuelle
  Abschlussprüfung ist nicht durch die Unit-Tests ersetzt.

## Verifizierter Abschlusslauf

Der vollständige automatisierte Integrationslauf vom 2026-07-16 ist grün:

- `cd app && swift test`: 969 Tests in 28 Suiten bestanden, Exit 0.
- `./localization-audit.sh`: 297 SwiftUI-Schlüssel, 420 literale
  L10n-Schlüssel und 903 englische Einträge vollständig, Exit 0.
- `./build.sh`: Debug-App gebaut, gebündelt und lokal installiert, Exit 0.
- `./verify-portable-app.sh .build/debug/Fastra.app .build/debug`: App ohne
  SwiftPM-Build-Fallback gestartet; der `localization`-Selbsttest lief aus dem
  gepackten Bundle, Exit 0.
- `./selftest.sh`: 26 PASS, 0 echte Fehler und 0 Umgebungsfehler, Exit 0.

Der Lauf verwendet ausschließlich lokale temporäre Repositories und Bare-
Remotes. Release-Build, Signatur, Notarisierung, Tag, öffentliches Artefakt und
Push sind nicht Bestandteil dieses Abschlusslaufs.

## Visuelle Abnahme

Die fokuserfordernde Prüfung wurde nach Freigabe am 2026-07-16 mit dem gebauten
Debug-Bundle auf einem Apple-Silicon-Mac durchgeführt. Alle Repositorys, Remotes
und Identitäten waren wegwerfbare lokale Fixtures; Fastra wurde anschließend
geschlossen und sein Erscheinungsbild wieder auf „Automatisch“ gesetzt.

- **Changes, Diff und Graph:** Die deutsche dunkle Seitenleiste zeigte getrennte
  staged/unstaged/untracked-Gruppen, Rollup, Commitfeld und verständliche
  Accessibility-Namen. Der echte Side-by-side-Diff zeigte zwei entfernte Hunks,
  vier Änderungsblöcke, Faltungen, Ruler und Vor/Zurück-Navigation; ganze Zeilen
  blieben auswählbar. Der Graph zeichnete Branch-, Merge- und Tag-Lanes und
  markierte den exakten Commit sichtbar mit `HEAD · main`.
- **Textkonflikt:** Ein echter diff3-Merge mit drei Konflikten prüfte Navigation,
  Basisumschalter, oberen/unteren/beide Blöcke und deaktiviertes Continue. Die
  Übernahme beider Seiten verringerte den Zähler; natives Undo und Redo stellten
  den Inhalt wieder her beziehungsweise wendeten ihn erneut an. Abschließend
  wurde der ursprüngliche Markerstand wiederhergestellt und gespeichert.
- **Groß/Binär:** Eine 33,8-MiB-Datei öffnete schreibgeschützt in 129 Abschnitten
  und navigierte von Abschnitt 1 zu 2. Ein per `.gitattributes` als binär
  klassifizierter UTF-8-Konflikt zeigte den Git-Grund und ausschließlich Hilfe,
  Status sowie den Terminalausweg; Textübernahme und Stage-Aktion fehlten,
  Continue blieb deaktiviert.
- **Identität und Lease:** Die repository-lokale Identity-Auswahl war Default.
  Der globale Weg zeigte die unabhängige zweite Bestätigung und wurde dort
  abgebrochen; die echte globale Konfiguration blieb unverändert. Die
  Force-with-Lease-Bestätigung zeigte lokalen OID, exakt ein Remote-Ziel und den
  erwarteten Lease-OID; auch sie wurde abgebrochen und der Remote blieb
  unverändert.
- **Sprache, Erscheinungsbild und Accessibility:** Der Rundgang lief in Deutsch
  und Englisch sowie Dark und app-lokal erzwungenem Light. Zwei dabei gefundene
  deutsche dynamische Hilfetexte wurden ergänzt und danach im englischen
  Accessibility-Baum als `Hide Sidebar` und `Hide Markdown Preview` verifiziert.
  Der macOS-Accessibility-Baum, den VoiceOver nutzt, las HEAD, Fetch-Alter,
  Hunk-/Konfliktzähler, deaktivierte Vorgänge sowie Binär-/Chunked-Hilfe aus;
  die zentralen Wege waren zugleich mit sichtbaren Mausaktionen erreichbar.

Der In-App-Selbsttest `contrast` prüfte zusätzlich drei echte Eingabefelder und
fand keines unter seinem Verhältnis-Grenzwert 2,0. Nach unmittelbarer Freigabe
wurde außerdem der macOS-Schalter „Kontrast erhöhen“ temporär aktiviert. Changes,
Graph samt HEAD-Halo und Konfliktleiste zeigten deutlichere Konturen, lesbare
Zustände und unveränderte Accessibility-Namen. Anschließend wurden Fastra und
die Systemeinstellungen geschlossen; „Kontrast erhöhen“ und das dadurch
mitaktivierte „Transparenz reduzieren“ standen wieder auf `0`, Fastras
Erscheinungsbild wieder auf `system`. Damit ist das visuelle Gate geschlossen.

## Bewusste Grenzen

Fastra wird keine Hosting-API, Pull-Request-Verwaltung, Submodul-/Worktree-UI,
Git-LFS-Verwaltung, vollständige Blame-Ansicht oder komplexes interaktives Rebase.
Der Diff bleibt bewusst reduziert und read-only; Binärdateien und nicht sicher
dekodierbare Inhalte werden ehrlich begrenzt. Ein durch das 4-MiB-Limit
gekürzter Patch wird nicht teilweise als vermeintlich vollständiger Diff
gezeigt. Auto-Fetch verändert weder
Arbeitsbaum noch Branch. Öffentliche Veröffentlichung, Tag und notarisiertes
Artefakt sind nicht Teil der Implementierungspakete ohne gesonderten Auftrag.
