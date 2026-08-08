# Fastra — Roadmap

Hier stehen nur offene Produktarbeit und bewusst zurückgestellte Grenzen.
Erledigte Arbeit und historische Entscheidungen stehen in
[CHANGELOG.md](CHANGELOG.md).

## Jetzt

- **Tests räumen ihre Preferences-Domains nicht auf** (gemeldet 2026-07-28):
  Jeder Testlauf legt unter `~/Library/Preferences` eigene Domains mit UUID im
  Namen an und lässt sie liegen — gefunden wurden 3713 plists (~22 MB), Muster
  `FastraTests.GitPreferences.<UUID>` (1419), `FastraTests.PatternLibrary.<UUID>`
  (482), `Fastra-DiffLifecycle-<UUID>`, `fastra-test-extchange-<UUID>`,
  `search-jump-first/second-<UUID>`; dazu Altbestand des archivierten Vorläufers
  cregex. Das ist nicht nur Unordnung: `cfprefsd` kam mit der Domain-Flut nicht
  mehr klar — `defaults read com.apple.Terminal` lieferte NICHTS mehr, und
  Terminal.app startete mit dem Standardprofil statt Daniels Einstellungen; nach
  Löschen der 3713 Dateien und cfprefsd-Neustart war alles wieder normal.
  **Zu tun:** Tests entfernen ihre Domain im `tearDown`
  (`removePersistentDomain` für den jeweiligen Suite-Namen, alternativ
  `defaults delete`); zusätzlich ein Guard am Suite-Ende, der meldet, wenn eine
  Test-Domain übrig bleibt.
- **4D-Parameterhilfe/Typeahead: verbliebene Komponenten-/Plugin-Grenzen**
  (verbleibende Grenze nach der Komponentenmethoden-Unterstützung; diese ist mit
  v1.50.0 umgesetzt — Typeahead + Signaturhilfe aus `.4dbase`, `.4DZ` und
  Methodendokumentation, nur geteilte Methoden, Projektmethode gewinnt):
  - **Plugins:** erst angehen, wenn ein reales Projekt mit `Plugins`-Ordner
    als Fixture verfügbar ist — Struktur dann zuerst am echten Bundle
    erheben, nichts aus Erinnerung raten (im verfügbaren Referenzprojekt
    existiert kein solcher Ordner).
  - **GitHub-Abhängigkeiten:** `Project/Sources/dependencies.json` kann
    Komponenten benennen, die nicht unter `<Projekt>/Components/` liegen
    (z. B. von 4D verwaltete Downloads). Bewusst offen, bis der reale
    Ablageort an einem echten Projekt erhoben ist.
  - **Benannte klassische Parameter:** 4D-Methodendoku kompilierter
    Komponenten deklariert Parameter teils als benannte Variablen
    (`C_LONGINT($pid_i)`) — der Parser zählt ehrlich nur `$N`/`#DECLARE`;
    das Panel zeigt dann `(…)`. Eine Zuordnung benannter Deklarationen zu
    Parameterpositionen wäre Raterei und bleibt bewusst außen vor.
- **Soft Wrap, Rechteckauswahl und Einrückung** (beschlossen 2026-07-19):
  Umsetzung in vier getrennten Etappen mit eigener Verifikation und Version.
  **Umgesetzt: Etappe 1 (Formatprofile und Fußzeilen-Bedienung, v1.40.0),
  Etappe 2 (Umbruchziele und Seitenlinie, v1.41.0) und Etappe 3
  (Rechteckauswahl unter Soft Wrap, v1.42.0).** Offen bleibt Etappe 4
  (Einrückungsprofile, intelligentes Einfügen und Folgezeilen-Einrückung).
- **Wunschpaket 3** (beschlossen 2026-07-18):
  **Alle acht Etappen umgesetzt:** Etappe 1 (Diff-Kern & Datei-Diff
  dual-pane, v1.32.0), Etappe 2 (Git-Diff auf gemeinsamem Renderer,
  v1.33.0), Etappe 3 (Dateinamens-Filter in der Projektansicht,
  v1.34.0), Etappe 4 (tool4d-Ersteinrichtungshilfe, v1.35.0),
  Etappe 5 (4D-Struktur-Hinweise, v1.36.0), Etappe 6
  (4D-Vervollständigung/`.4DForm`-Schema/Export-Transformation,
  v1.37.0), Etappe 7 (Alt-Doppelklick „Gehe zum Ziel“, v1.38.0), Etappe 8
  (4D-Syntaxdiagnosen via tool4d-LSP, v1.39.0).**
  - **Bewusst NICHT in Etappe 1** (Kandidaten für eigene Aufträge):
    Ordner-Vergleich, „Apply to Left/Right“-Übernahme einzelner
    Unterschiede ins Dokument, Export der Differenzen-Liste.
  - **Bekannte Grenze des Datei-Diffs:** Nach Abzug gemeinsamer
    Anfangs-/Endzeilen verarbeitet der Vergleich bis zu 30.000 Zeilen
    Unterschiedsbereich (Myers-Diff ist im schlechtesten Fall
    quadratisch). Sehr große Dateien mit über die GANZE Länge
    verstreuten Änderungen lehnt er deshalb ehrlich ab; ein
    Anker-basierter Diff (Patience-Stil) für solche Fälle wäre ein
    möglicher späterer Ausbau.
- **Wunschpaket 2** (beschlossen 2026-07-18): Alle fünf Etappen sind mit
  v1.27.0–v1.31.0 umgesetzt (Navigation & Chrome, Suchdialog, Sprachmenü
  mit wählbarem 4D, Hilfe samt `help-audit`-Mechanik, assistiertes
  Markdown-Schreiben mit Bild-Paste/-Drop). Bewusst offen: Echtes
  WYSIWYG („Schreibmodus“) ist ausgeklammert — Daniel entscheidet nach
  gelebter Erfahrung mit Etappe 5 separat und nur auf ausdrücklichen Auftrag.
- **Wunschpaket Juli 2026** (beschlossen 2026-07-17): Die sechs Etappen sind
  mit v1.20.0–v1.25.0 umgesetzt. Bewusst offen geblieben:
  - **4D-Farbdetails:** Underline (Konstanten) kennt das CESE-Attributmodell
    nicht; `errors`/`plug_ins`/`member` aus den Farbvorgaben entfallen
    mangels Analyse bzw. Unterscheidbarkeit (siehe Slot-Mapping in
    `EditorView.swift`).

## Robustheit-Nacharbeit aus dem Code-Review 2026-08-02

Beim Review vom 2026-08-02 bestätigte, aber bewusst nicht sofort gefixte
Punkte (die akuten Funde sind mit v1.60.1 behoben). Gebündelt nach Thema:

- **I/O-Härtung:** blockierendes `open` vor der Typprüfung bei FIFOs
  (`FileSnapshot.swift:59`); Symlink-TOCTOU zwischen Attributprüfung und
  Lesen (`FileLoader.swift:109`); Apply schreibt auf die Symlink-URL statt
  des kanonischen Ziels (`FolderSearch.swift:185`); `readToEnd()` ohne
  Größengrenze (`FileSnapshot.swift:70`); 4DZ-Zentralverzeichnis bis ~4 GiB
  am Stück (`FourDZipArchive.swift:70`); Komponentengröße 0/Symlink
  (`FourDComponentIndex.swift:128`).
- **Git-Pfad:** expliziter Refspec statt `git push <remote> HEAD`
  (`GitActions.swift:303`) und Push-Ziel unmittelbar vor dem Push erneut
  binden (`GitActions.swift:287`); Konfliktdateien beim Mehrfach-Verwerfen
  ausnehmen (`GitChangesSelection.swift:88`); Teil-Löschfehler nicht
  verschlucken (`GitActions.swift:152`); Doppel-Öffnen/Projektwechsel-Race
  im Änderungen-Panel (`GitChangesView.swift:511`).
- **Nebenläufigkeit/UI:** `Workspace.shared`-Setter vs. Kontextaktivierung
  seriell auf dem Main-Thread (`Workspace.swift`, `sharedStorage`/`sharedLock`);
  Projekt-Scan als
  strukturierter, abbrechbarer Task (`Workspace.swift:2832`);
  Scroll-Restore-Generation pro Editor statt prozessweit
  (`EditorView.swift:954`); Markdown-Import-Anzeige an Besitzer-Fenster
  binden (`EditorView.swift:301`); Restore-Completion nicht an die
  Workspace-Lebenszeit koppeln (`SessionRestoration.swift:242`);
  Signaturabruf von der MainActor-Blockade lösen
  (`FourDSignatureHelpPanel.swift:119`).
- **Undo/Apply-Speicher:** Backups sequenziell statt alle vorab laden
  (`ApplyEngine.swift:1182`) und `.restored`-Einträge vor dem Backup-Zugriff
  überspringen (`ApplyEngine.swift:1185`).
- **4D-Sprachhelfer:** Tokenizer-Komplexität begrenzen
  (`FourDTokenizer.swift:292`); Completion nicht in Kommentar/String
  (`FourDCompletion.swift:203`) und manueller Ein-Zeichen-Trigger
  (`FourDCompletion.swift:225`); Blockkommentare in der Signaturhilfe
  (`FourDSignatureHelp.swift:223`); Dateipfad case-korrekt aus dem Index
  (`FourDSignatureHelp.swift:349`); Symlink-Methoden indexieren
  (`FourDProjectMethodIndex.swift:43`).
- **Selbsttest-/Skript-Hygiene:** Umgebungsfehler als Exit 2 kennzeichnen
  (`SelfTest.swift:11043`, `:11181`); Janitor-Spur bei pkill-Fehler behalten
  (`TestDefaultsJanitorTests.swift:99`); screenshot-run stellt den vorherigen
  Appearance-Wert exakt wieder her (`screenshot-run.sh:54`).
- **Editor-Details:** Doppelklick bei zerlegtem Unicode
  (`build.sh:1375`-Patch); Spaltenselektion ohne komplette Zeilenkopie
  (`app/Patches/CodeEditTextView/TextView+ColumnSelection.swift`,
  `fastraVisualColumn`/`fastraOffset(forColumn:in:edge:)`); Emoji-Selektor an
  Rangegrenzen (`TextOperations.swift:1063`); `closingTail()` ans Dokumentende
  (`MarkdownHTMLWhitelist.swift`, `MarkdownHTMLSanitizing.apply(to:)`).
- **Toter Code:** `planSHA256` an der Apply-Grenze prüfen oder entfernen
  (`ApplyEngine.swift:174`); Test-only `apply(plan:)` auf den produktiven
  Transaktionskern führen (`ApplyEngine.swift:934`).

## Nacharbeit aus dem Code-Review 2026-08-06 (Abendlauf)

Beide Punkte betreffen die Markdown-Vorschau und hängen zusammen: Sie brauchen
denselben Umbau — das Rendern eines Fragments in den Hintergrund, abgesichert
über eine Generationsnummer. Deshalb bewusst gemeinsam und nicht nebenbei. Die
übrigen sieben Funde des Laufs sind mit v1.63.2 behoben.

- **Ein extern ausgetauschtes Bild aktualisiert die offene Vorschau nicht**
  (`MarkdownPreview.swift`, `MarkdownRichTextView.update`): Bei unverändertem
  Markdown kehrt die Aktualisierung zurück, bevor die Bild-Adressen neu
  berechnet werden. Für die referenzierten Bilddateien gibt es keinen
  Beobachter, also löst ein Überschreiben am gleichen Pfad gar nichts aus —
  die Vorschau zeigt die alte Fassung, bis sich Markdown, Dokumentpfad oder
  Darstellungsstil ändern. **Zu tun:** die Elternordner der referenzierten
  Bilder über FSEvents beobachten (`ProjectFileWatcher` als Vorlage, aber
  mehrere Pfade und ohne Projektbindung) und bei einer Änderung
  generationengesichert ein frisches Fragment einspielen. **Prüfen:** nicht
  nur als Unit-Test — der echte Vorschau-Pfad braucht eine Fenstersitzung,
  ein Bild am gleichen Pfad überschreiben und die Anzeige wirklich ansehen.
- **Das Fragment entsteht auf dem UI-Thread** (`MarkdownPreview.swift`,
  `MarkdownRichText.renderedFragment`): Jeder Renderlauf kostet einen
  cmark-Durchlauf und je Bild einen Dateisystemzugriff. Bei vielen Bildern
  oder Bildern auf einem eingebundenen Netzlaufwerk kann das Tippen dadurch
  sichtbar hängen. Der doppelte Lauf beim Vollreload ist mit v1.63.2 weg
  (`htmlDocument(fragment:…)`), das Rendern selbst läuft weiter auf dem
  UI-Thread. **Zu tun:** das Rendern auf eine eigene serielle Queue legen und
  das Ergebnis generationengesichert zurückgeben. **Achtung:**
  `cmark_gfm_core_extensions_ensure_registered()` schreibt in eine globale
  Registrierung — alle Renderwege müssten dann über dieselbe serielle Queue
  laufen, sonst entsteht ein Wettlauf.

## Kleine offene Ideen

- **Markdown-Umwandlung: bewusst offen gelassen** (umgesetzt 2026-07-26 über
  `poormans-text --formats`):
  - Der Formatkatalog wird beim Start vorgewärmt und fünf Minuten
    zwischengespeichert. Wird `poormans-text` in dieser Zeit aktualisiert,
    braucht es einen Fastra-Neustart. Bewusst so — eine Invalidierung über
    einen Dateiwächter wäre für den Nutzen zu viel Maschinerie.
  - Es läuft immer nur EINE Umwandlung gleichzeitig; der Befehl ist währenddessen
    gesperrt. Eine Warteschlange lohnt erst, wenn Stapelumwandlung gewünscht ist.
  - Kein Fortschritt und kein Abbruch während einer Umwandlung. Dafür wäre die
    direkte Library-Anbindung statt des CLI-Aufrufs nötig (siehe
    `poormans_text/ROADMAP.md`).
  - Der Katalog fragt nur, OB ein Werkzeug installiert ist, nicht welche
    Eingabeformate dessen Version beherrscht. Ein sehr altes Pandoc könnte
    deshalb erst beim Umwandeln scheitern — dann mit echter Fehlermeldung.

- **Hilfe später hübscher:** Die mitgelieferte Hilfe (Etappe 4 Wunschpaket
  2026-07b) ist bewusst reiner Text ohne Bilder. Screenshots/Illustrationen
  der zentralen Abläufe (Suchmaske, Vorschau→Apply, Git-Seitenleiste) wären
  ein sinnvoller späterer Ausbau.

- **Datei-Drag vom Dokument-Tab:** Mit dem titellosen Fensterchrome entfiel
  das Ziehen der Datei aus der Titelzeile (Proxy-Icon) ersatzlos. Möglicher
  Ersatz wäre ein `.onDrag` der Datei-URL direkt am Tab — nur bei echtem Bedarf.

- **Willkommen als Platzhalter statt eigenem Tab:** Von Daniel am 2026-07-30
  entschieden, umgesetzt und am installierten Stand abgenommen („Passt nun",
  nach Entfernen der anfänglichen Projekt-Sperre; siehe CHANGELOG
  Unreleased). Die README-Screenshots zeigen den Willkommensbildschirm
  nicht und bleiben unverändert. Offen sind nur noch die fokus-pflichtigen
  Fenster-Selbsttests (welcomenew, newwindow, cmdw, sessionrestore,
  coldopen) auf einer geeigneten UI-Sitzung.

- **Datenschutz und Sicherheit der Markdown-Vorschau erklären** (Idee
  2026-07-28): Ein kurzer Abschnitt in README und mitgelieferter Hilfe, der
  beschreibt, wie Fastra Markdown anzeigt und welcher Kompromiss dahintersteht.
  Der Punkt ist nicht „sicherer als andere", sondern **nachvollziehbar**: Ein
  Vorschaufenster rendert fremde Dokumente, und Leser sollen wissen, was dabei
  passiert.

  Zu erklären wäre die bewusste Mitte. Vollständige HTML-Unterdrückung macht
  verbreitete GitHub-READMEs unbrauchbar — ein zentriertes Logo in
  `<p align="center"><img …></p>` ist der Normalfall. Fastra rendert deshalb
  eine kleine, fest umrissene Menge an Elementen, einschließlich `<img>`, und
  hält gleichzeitig fest: `default-src 'none'` verbietet jeden Netzabruf,
  entfernte Bilder werden neutralisiert, lokale laufen über interne Tokens,
  der Prüfer erzeugt die Ausgabe neu statt Eingabebytes durchzureichen,
  `script-src` nutzt einen Nonce pro Render statt `'unsafe-inline'`, und
  unsichere Link-Schemata (`javascript:`, `vbscript:`, `file:`, `data:`)
  prüft Fastra selbst. Kein `<script>`, `<style>`, `<iframe>`, `<svg>`,
  `<math>`, keine Ereignis-Attribute, kein `style`, `class` oder `id`.

  **Zum Vergleich mit anderen Werkzeugen:** Umgesetzt ist das in README und
  Hilfe bewusst ohne Produktnamen und ohne Werturteil — beschrieben wird der
  Mechanismus, den die wenigsten kennen (entfernte Bilder verraten das Öffnen;
  Formel- und Diagrammbibliotheken kommen beim Anzeigen von einem CDN), samt
  Hinweis, dass beides meist umstellbar ist, und einer Anleitung zum
  Selbst-Nachprüfen. Diese Form altert nicht mit fremden Versionsnummern.

  Sollte je ein konkreter Vergleich gewünscht sein: nur mit eigener, aktueller
  Messung, und dabei zwischen der VORGEFUNDENEN Konfiguration und der
  Auslieferungs-Voreinstellung unterscheiden — die sind nicht dasselbe, und
  eine Aussage über die Voreinstellung braucht eine frische Umgebung. Die
  Einzelmessung vom 2026-07-28 liegt in der privaten Projektdokumentation,
  nicht hier: Ein öffentliches Repo ist kein Ort für Befunde über fremde
  Software, die niemand gegengeprüft hat.

## Bekannte Fehler

- **Der Selbsttest-Runner meldet `projectperf` als echten Funktionsfehler,
  obwohl ihm nur die Umgebung fehlt** (2026-07-30). Der Test braucht über
  `FASTRA_PROJECT_PERF_ROOT` einen externen, nur gelesenen Realbestand mit
  `userPreferences.*`- und `DerivedData`-Anteilen; fehlt die Variable oder
  passt der Ordner nicht, scheitert er mit `finish(false, …)` und zählt damit
  in die echten FAILs statt in die Umgebungs-FAILs (Exit 1 statt 2). Er steht
  bewusst nicht in `ALL_TESTS`, taucht aber in `WINDOWLESS_TESTS` auf und
  wandert so leicht in eine handverlesene Testliste. `tool4dlsp` zeigt im
  selben Runner, wie es richtig geht — dort wird der fehlende Realbestand als
  Umgebungsproblem ausgewiesen. Beim Anfassen dieselbe Klassifizierung
  nachziehen.

- **`selftest.sh` lässt seine Fehlerdateien liegen.** Der Runner legt pro Test
  mit `mktemp` eine Datei für stderr an und entfernt sie nicht wieder. Ein
  vollständiger Lauf hinterlässt so rund achtzig Dateien im Temp-Ordner.
  Harmlos, aber unsauber — beim nächsten Anfassen des Runners aufräumen.

- **`SmartPaste.markdownFromClipboard` beendet beim Fristablauf nur das direkte
  Kind.** Startet das Umwandlungswerkzeug seinerseits Kinder, überleben die den
  Abbruch. Richtig wäre, die ganze Prozessgruppe zu beenden.

- **Warteschleifen mit `Task.yield()` in vier Testdateien** (EmptyScratchTab,
  ExternalChange, WorkspaceLoad, OpenFileOrFolder). Sie drehen frei, bis eine
  Bedingung eintritt, statt auf ein Signal zu warten — unter Fremdlast der
  wahrscheinlichste Kandidat für sporadische Hänger. Auf robustes Warten
  umstellen.

- **Klemmung auch auf der SCHREIB-Seite der Auswahl.** Die Lese-Seite ist mit
  v1.64.0 erledigt: Alle Zugriffe gehen über `TextView.fastraSafeSelectedRange`
  (`SelectionClamping.clamp`), nachdem ein `NSNotFound`-Bereich die Anwendung
  im Undo-Verwalter abbrechen ließ. Offen bleibt die Gegenrichtung: Auch
  `setSelectedRange` sollte einen ungültigen Bereich abweisen, statt ihn
  anzunehmen — der Attachment-Beobachter von CodeEditTextView baut daraus ein
  `IndexSet`, und `IndexSet.insert(range:)` trappt bei `NSNotFound`
  (zweimal beobachtet, ausgelöst von Selbsttests; die sind inzwischen
  gehärtet).

## Aus dem Dauertest und den Betriebsmeldungen (2026-08-07/08)

Der lange Dauertest (`app/soak-test.sh`) läuft — seit dem Realismus-Ausbau
auch mit echten Dokumenten, RTFD-Umwandlung samt sofortiger
Weiterbearbeitung, einem echten 4D-Projekt (Completion, Signaturhilfe,
ALT-Doppelklick), Fenstergeometrie, Kopieren/Einfügen zwischen Fenstern und
echten Menübefehlen (private Datenquellen in der gitignorierten
`app/soak-test.local`). Diese Punkte hat er oder der Arbeitsbetrieb gemeldet
und sie sind noch offen.

- **Ein geschlossenes Fenster kommt beim Öffnen einer weiteren Datei zurück**
  (mit 1.63.3 reproduziert). Verdacht: `Workspace.init` ruft
  `deliverPendingOpenFiles()`, also löst jedes neu erzeugte Fenster eine
  Nachlieferung aus dem Öffnen-Puffer aus.
- **Die Ansicht kriecht beim Markieren mit der Maus nach unten** — nur in
  Markdown, auch wenn die Markierung nach oben wandert. Nicht reproduzierbar;
  trat nach längerer Arbeit mit mehreren umgewandelten Protokollen auf. Der
  Selbsttest `dragnoscroll` fängt es nicht ein: Die synthetischen
  Drag-Ereignisse kommen nicht einzeln an, die Auswahl bleibt in jedem Lauf
  gleich groß. Verdacht ist der Fastra-Patch in
  `SourceEditor.updateControllerWithState`, der bei ungleichen
  `cursorPositions` mit `scrollToVisible: true` nachzieht, obwohl der
  SwiftUI-Zustand runloop-versetzt veraltet ist.
- **Das Fenstermenü listete nur eine von zwei offenen Dateien.** In kurzer
  Nachstellung korrekt — also zustandsabhängig.
- **`GoToTargetGesture` nutzt `Workspace.shared` statt des Event-Fensters**
  (`GoToTarget.swift`, beim Umbau auf `CommandTargeting` übersehen). Beim
  ALT-Doppelklick in einem Hintergrundfenster könnte der Sprung deshalb im
  falschen Fenster landen — dieselbe Fehlerklasse wie die mit 1.64.0
  behobenen Menübefehle. Der Dauertest klickt bisher nur im
  Vordergrundfenster und kann es deshalb noch nicht belegen.

- **`folderSearch_deduplicatesOverlappingRoots` einmal rot** (2026-07-28,
  nicht reproduziert). Der Test meldete 0 statt 1 Treffer in einem
  vollständigen `swift test`; isoliert dreimal und in zwei weiteren
  vollständigen Läufen grün. Passt zur Klasse der lastabhängigen Befunde
  dieses Tages. Bei erneutem Auftreten notieren, ob der Lauf unter Fremdlast
  stand, und den Kandidatenpfad der Datei-Set-Wurzeln prüfen.

- **„Timeout gewinnt deterministisch gegen einen bereits vorhandenen
  Ref-Lock" sporadisch rot** (`GitConflictAndAdvancedTests.swift:786`,
  beobachtet 2026-08-07 in zwei von sechs vollständigen `swift test`-Läufen).
  Die Erwartung, dass `index.lock` weg ist, wird direkt nach der Completion
  geprüft; das aufgerufene `git` hat seinen Lock zu diesem Zeitpunkt aber
  nicht zwingend schon entfernt. Beim Anfassen auf ein Warten mit kurzer
  Frist umstellen statt auf eine Momentaufnahme.

## Offene Beobachtungen (nicht reproduziert)

- **⌘⇧+Pfeiltasten ohne Wirkung auf einem anderen Mac** (Daniel-Meldung
  2026-07-29; auf dem Entwicklungs-Mac funktioniert es). Befund: Fastras eigenes
  Key-Routing (`KeyRouting.route`) fasst ⌘- und ⌘⇧-Pfeilkombinationen nicht
  an — sie gehen unverändert an den Editor durch; es gibt also keinen
  Fastra-Code, der das nur auf einem Rechner abschalten könnte. Verdacht:
  Umgebung des anderen Macs (systemweite oder App-Tastenkürzel, die
  ⌘⇧+Pfeil abfangen, Sonderbelegung der Tastatur). Bei erneutem Auftreten
  auf dem betroffenen Mac prüfen: Systemeinstellungen → Tastatur →
  Kurzbefehle auf Konflikte, und ob dieselbe Kombination in TextEdit
  funktioniert (falls nein, ist es kein Fastra-Thema).

- **Fenster ganz ohne Tabs mit tippbarer Editorfläche nach App-Start**
  (Daniel-Meldung 2026-07-29, einmalig, kein Repro). Analyse: `tabs` kann
  nur über den Fensterschließen-Pfad (`prepareToCloseWindow`) dauerhaft leer
  werden; SwiftUI hält Szene samt Workspace am Leben und kann das Fenster
  später wieder anzeigen (Dock-Klick wirkt wie App-Start) — dann stand ein
  Fenster ohne Tabs da, dessen Editor ins Leere schrieb. Zweifach
  abgesichert: Nach dem Leeren kehrt der Workspace sofort in den
  Willkommens-Zustand zurück, und ein Fenster ohne jeden Tab zeigt zur Not
  die Willkommensseite statt des Geister-Editors. Sollte es dennoch wieder
  auftreten: notieren, ob die App vorher wirklich beendet war (⌘Q) oder nur
  alle Fenster geschlossen waren.

## Ältere offene Beobachtungen (2026-07-24/25, nicht reproduziert)

- **Editor-Befunde 2026-07-24/25:** Der Return-/Tipp-Scroll-Befund ist mit
  v1.50.1 GELÖST (State-Reconcile-Race, F.23; Daniel-verifiziert am
  Live-Repro), ebenso der dabei entdeckte ⌘V+⌘Z-Crash (F.24). Offen
  bleiben zwei Beobachtungen aus der Sitzung VOR dem cfprefsd-Neustart
  vom 2026-07-24, seither nicht wieder aufgetreten: Palette-Emoji erschien
  erst nach dem zweiten Einfügen; Shift+← hinter Emojis erweiterte die
  Markierung sichtbar nicht. Beide passen zur selben Klasse „laufende
  Sitzung zeichnet veraltet“ (F.18); Wächter `typescroll` läuft im
  Standardlauf. Bei erneutem Auftreten: notieren, ob ein App-Neustart es
  behebt, und `FASTRA_TYPESCROLL_FIXTURE=<Dateikopie> ./selftest.sh
  typescroll` auf dem betroffenen Stand fahren.

- **Emoji „in zwei Zeichen zerplatzt“** (Daniel-Meldung, wahrscheinlich noch
  v1.46.8): Mit v1.48.0 nicht reproduzierbar — Dateibytes intakt,
  Attributläufe/Fragmente/Glyphen über 121 Umbruchbreiten sauber, Fenster-
  Screenshot einwandfrei. Wächter `emojisplit` läuft im Standardlauf.
  Daniel prüft mit v1.49.0 gegen; bei erneutem Auftreten Fensterbreite oder
  Screenshot zur Meldung geben.
- **„Tab-Wechsel repariert die Emoji-Darstellung“** (Daniel-Meldung
  2026-07-27). Die beiden greifbaren Teile des Befunds sind geklärt und in
  v1.52.1/v1.52.2 abgearbeitet: Der Editor legte attributierten Text (RTF)
  aufs Clipboard, dessen RTF-nach-HTML-Weg U+FE0F verlor, und in der
  gemeldeten Datei steht über die ganze Git-Historie das nackte `⏸` ohne
  Variantenselektor, das Editor und Vorschau systembedingt unterschiedlich
  zeigen (Wächter `emojipreview`). Offen bleibt allein die Beobachtung, dass
  ein Tab-Wechsel die Darstellung verändert hat: Der Wächter `emojipaste`
  prüft Speicherinhalt, Attributläufe, Glyph-Runs, gezeichnete Pixel und die
  Live-Vorschau an 13 Einfügestellen und findet nichts. Passt zur Klasse
  „laufende Sitzung zeichnet veraltet“ (F.18). Bei erneutem Auftreten
  notieren: Editor-Text oder Vorschau, Fensterbreite, ob ein App-Neustart
  genügt, und welche Codepoints die Datei an der Stelle wirklich enthält.

  **Zwischenstand 2026-07-28:** Daniel hat die notarisierte v1.53.1 im echten
  Einsatz benutzt und meldet die Emoji-Darstellung auf beiden Seiten — Editor
  und Vorschau — als korrekt. Das ist der erste positive Gegenbefund seit der
  Meldung; die Beobachtung bleibt aber notiert, weil ein einzelner guter Lauf
  eine sporadische Zeichenfrage nicht ausschließt. Die Wächter `emojipaste`,
  `emojipreview` und `emojisplit` laufen weiter im Standardlauf.

- **Kurzzeitig doppelte Zeilenhöhe** beim Emoji-Einfügen über die
  Emoji-Palette (normalisierte sich nach dem nächsten Einfügen von selbst).
  Nicht reproduziert; passt zur Klasse „stehengebliebene Layoutfragmente
  nach Einfügung“ (F.18). Beobachtung im Blick behalten, bei erneutem
  Auftreten sofort Repro-Schritte notieren.

## Später – nur auf ausdrückliche Anfrage

- **Cross-Platform-Portabilität (Windows/Linux):** Weder Machbarkeit noch
  Implementierung werden ohne ausdrücklichen Auftrag untersucht.
- **Monetarisierung:** Entschieden 2026-07-18 — Fastra ist Open Source;
  keine Lizenz-, Trial- oder Bezahlfunktionen. Höchstens ein
  Donation-Button kommt eventuell später, aber vorerst nicht und nur auf
  ausdrücklichen Auftrag.
