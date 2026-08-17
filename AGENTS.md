# AGENTS.md — Fastra

## Projekt

Fastra ist ein nativer macOS-Editor für sichere, visuell überprüfbare Suche und
Ersetzung über Dateien und Ordner. Die App läuft auf macOS 14+ und Apple Silicon.
Sie nutzt Swift, SwiftUI, `NSRegularExpression`, tree-sitter-regex und den
CodeEditSourceEditor. Das Produkt bleibt lokal: keine Cloud-Verarbeitung, keine
Konten, keine Telemetrie und keine versteckten Uploads. Die dokumentierte
Sparkle-Updateprüfung lädt ausschließlich den signierten Appcast von GitHub Pages;
Hardware- und Systemprofilübermittlung ist deaktiviert.

Der Produktkern ist nicht „Regex mit einer GUI“, sondern die Vorschau vor jeder
Änderung. Der Nutzer sieht Treffer und Auswirkungen, bevor Fastra Dateien
schreibt. Diese Eigenschaft ist eine Sicherheitsgrenze und darf weder für
Bequemlichkeit noch für Geschwindigkeit umgangen werden.

## Quellen der Wahrheit

- `AGENTS.md`: dauerhafte Projekt- und Arbeitsregeln.
- `README.md` und `README.de.md`: öffentliche Nutzung, Installation und Features.
- `ROADMAP.md`: noch nicht abgeschlossene Produktarbeit und bewusste Grenzen.
- `CHANGELOG.md`: Versionen, erledigte Arbeit und historische Entscheidungen.
- `docs/BUILD-AND-TEST.md`: ausführliche Build-, Paketierungs- und Testdetails;
  gilt für jeden Agenten.
- `app/LESSONS-LEARNED.md`: verifizierte technische Fallen der Editor-Abhängigkeiten.

Status, Testzahlen und abgeschlossene Etappen gehören nicht in diese Datei. Vor
einer Änderung den aktuellen Stand aus Code, Git und den oben genannten Quellen
ermitteln.

## Produktinvarianten

- Jede schreibende Mehrfachänderung besitzt eine vollständige, verständliche
  Vorschau. „Apply“ darf nie auf eine andere Trefferbasis wirken als die sichtbare
  Vorschau.
- `*` erfasst innerhalb einer Zeile, `**` über Zeilengrenzen. Wildcard-, Regex-
  und Capture-Semantik sind öffentliches Verhalten; Änderungen brauchen Tests,
  Migration und klare Dokumentation.
- Capture-Gruppen müssen per Drag-and-drop in Ersetzungen verwendbar bleiben.
- Fehler und Grenzen werden in Nutzersprache erklärt. Keine stillen Fallbacks,
  die Such- oder Ersetzungsergebnisse verfälschen.
- Fastra ist eine native Mac-App. Keine Electron-/Web- oder Cross-Platform-
  Abstraktion einführen, solange dafür keine ausdrückliche Produktentscheidung
  vorliegt.
- Keyboard-first ist eine Option, keine Voraussetzung. Zentrale Funktionen
  müssen auch sichtbar und mit Maus/Trackpad erreichbar sein.
- Der Startzustand soll das Produkt erklären und nicht wie eine leere Debug-
  Oberfläche wirken.
- BBEdit ist die wichtigste Referenz für Editorverhalten. Bei Detailfragen reale
  Dokumentation oder beobachtetes Verhalten prüfen, nicht aus Erinnerung raten.

## Architektur und Abhängigkeiten

Der Swift-Code liegt unter `app/Sources/`. `app/Package.swift` definiert die
Abhängigkeiten. CodeEditSourceEditor und seine Grammatikpakete sind bewusst
gepinnt und werden im Build angepasst. Änderungen an Versionen oder Checkout-
Patches sind deshalb keine gewöhnlichen Dependency-Bumps: zuerst die zugehörigen
Erklärungen in `docs/BUILD-AND-TEST.md`, `app/build.sh` und
`app/LESSONS-LEARNED.md` lesen,
danach den vollständigen Build- und Selbsttestpfad ausführen.

`app/build.sh` erzeugt das `.app`-Bundle, patcht bekannte Upstream-Probleme,
reduziert das Sprachbundle und legt jeden erfolgreichen Build als `Fastra.app`
im Projekt-Root ab. `/Applications` ist ausschließlich notarisierten Bundles
vorbehalten; Debug-, Ad-hoc- und nur Developer-ID-signierte Test-Builds dürfen
dorthin weder kopiert noch installiert werden. Sobald echtes
Installationsverhalten, Datei-Doppelklick über LaunchServices,
Finder-Zuordnungen oder macOS-Datei- bzw. Ordnerberechtigungen relevant sind,
ist der vollständige notarierte `./install.sh`-Pfad nach `/Applications`
verbindlich. Er darf auch für normale verifizierte Teststände genutzt werden;
für schnelle rein interne Iterationen bleibt `build.sh` passend.

Ressourcen müssen aus dem gepackten App-Bundle funktionieren. Ein Erfolg im
SwiftPM-Buildverzeichnis reicht nicht: absolute `.build`-Fallbacks können lokal
einen kaputten Bundle-Pfad verdecken. `verify-portable-app.sh` und der
`localization`-Selbsttest sind verbindliche Wächter.

Ressourcen deshalb immer über `AppResources.bundle` holen, nie direkt über
`Bundle.module`. Im App-Bundle liegt das Ressourcenpaket unter
`Contents/Resources`; der SwiftPM-Rückfall sucht dagegen am absoluten
`.build`-Pfad des Build-Macs und trappt dort. Auf dem Build-Mac fällt das nie
auf, in der installierten App stürzt es ab. Ein Portabilitätstest muss die
lokalen Build-Ressourcen ausblenden UND den betroffenen Funktionspfad im
gepackten Bundle wirklich ausführen — ein bloßer Start genügt nicht: Am
2026-08-05 blieb `RipgrepFileEnumerator` beim Start unberührt und stürzte erst
beim ersten Ordner-Suchlauf ab.

Lokale Referenz-Checkouts unter `repos/` sind gitignored. Sie dienen dem Lesen
und Vergleichen, nicht als zweite Quelle für Produktcode. Upstream-Code nicht
direkt ändern und keine generierten Checkout-Diffs committen.

## Implementierungsregeln

- Bestehende deutsche Anfängerkommentare erhalten und bei Refactors anpassen.
  Neue nicht offensichtliche Logik knapp auf Deutsch erklären; Identifier folgen
  der vorhandenen englischen Konvention.
- Main-Thread nicht durch Dateisuche, Git, Netzwerk oder große Dateioperationen
  blockieren. Ergebnisse und Fehler kontrolliert auf den UI-Thread zurückführen.
- Dateischreibvorgänge atomar und fehlersicher gestalten. Bei Abbruch muss die
  Ausgangsdatei erhalten bleiben.
- Git-Funktionen sind dünne Frontends über das installierte `git`-CLI. Keine
  eigene Git-Engine einführen. Fehlt Git, bleiben Funktionen still verborgen;
  Git-Fehler zeigen die echte Ausgabe.
- Git-Netzwerkaktionen laufen asynchron. Destruktive oder überraschende Git-
  Operationen benötigen eine eigene Produktentscheidung und sichtbare
  Bestätigung.
- Große und binäre Dateien dürfen nicht unkontrolliert vollständig in den
  Speicher geladen werden. Bestehende Abschnitts- und Hex-Pfade respektieren.
- Lokalisierbare UI-Texte müssen in Deutsch und Englisch vollständig sein.
  Quellstrings und dynamische Texte werden vom Lokalisierungs-Audit erfasst.
- Änderungen an CodeEdit-Patches brauchen einen Regressionstest, der das reale
  fehlerhafte Verhalten prüft, nicht bloß die Patch-Zeile. Jeder Checkout-Patch
  prüft zusätzlich unmittelbar nach dem Anwenden selbst, ob er gegriffen hat, und
  bricht den Build sonst mit einer Fehlermeldung ab. Ohne diese Selbstprüfung
  verschwindet ein Fix lautlos, sobald Upstream die gepatchte Stelle umschreibt.
- Hilfe-Pflege: Bei nutzersichtbaren Änderungen die mitgelieferte Hilfe
  (`app/Sources/Fastra/Resources/Help/hilfe.de.md` + `hilfe.en.md`, beide
  Sprachen!) prüfen und bei Bedarf aktualisieren, danach den Marker
  `app/help-reviewed-commit` auf den geprüften Commit fortschreiben.
  `app/help-audit.sh` listet offene produktrelevante Commits; die Bewertung,
  was davon in die Hilfe gehört, ist bewusst Aufgabe des Agenten. Im
  Release-/Bump-Lauf (`./help-audit.sh --release`) ist ein veralteter Marker
  ein harter Fehler.
- README-Screenshots müssen die Sprache der jeweiligen README tatsächlich in
  der gestarteten App verwenden: `README.md` referenziert `.en.png` aus der
  englischen Lokalisierung, `README.de.md` die deutschen Aufnahmen. Bei
  UI-Änderungen nur die betroffenen Screenshot-Paare neu erzeugen und beide
  Sprachfassungen visuell prüfen.

## Bauen und testen

Vom Repo-Root:

```bash
cd app
./build.sh                 # legt die gepatchten Checkouts erst an
./test.sh                  # ruft swift test in einer Wegwerf-Sandbox auf
./localization-audit.sh
./selftest.sh
```

`build.sh` steht bewusst vorn: Nur es stellt den Checkout-Zustand her, gegen den
`./test.sh` überhaupt etwas Aussagekräftiges misst. Im frisch geklonten Repo
scheitert der enthaltene `swift test` schon am Übersetzen — SwiftLint-Build-Plugin und
`#Preview`-Macro der Editor-Pakete (`app/LESSONS-LEARNED.md` F.2 und F.4). Der
gefährlichere Fall ist aber der zweite: Die Patches liegen im Checkout, die
Editor-Build-Produkte in `.build/` stammen aber noch aus der Zeit davor. Dann
übersetzt der Lauf anstandslos und meldet trotzdem Fehler im Produktcode, die
keine sind. Gemessen am 2026-07-28 auf diesem Stand: `swift test` ohne vorherigen
Build ergab 5
rote Tests (Doppelklick-Wortauswahl über Emoji, Editor-Copy aufs Clipboard —
beides Verhalten aus gepatchtem CodeEditTextView), nach `./build.sh` waren
dieselben 1555 Tests grün. Genau deswegen verwirft `build.sh` die betroffenen
Build-Produkte nach dem Patchen. Ein roter Lauf ohne vorheriges `build.sh` ist
also kein Befund.

`./build.sh release` erzeugt einen Release-Build im Projekt-Root.
`./install.sh --no-notarize` signiert lokal ohne Notarisierung und belässt das
Ergebnis ebenfalls dort. Ausschließlich der vollständige notarierte
Installationsweg darf nach `/Applications` schreiben; er verwendet ein zur
Laufzeit übergebenes `NOTARY_PROFILE`. Dieser Installationsweg ist verbindlich,
sobald reales Installationsverhalten, Datei-Doppelklick über LaunchServices,
Finder-Zuordnungen oder macOS-Datei- bzw. Ordnerberechtigungen geprüft werden;
auch normale verifizierte Teststände dürfen so installiert werden. Profile,
Schlüssel und Zertifikatsdetails gehören nie in Code, Doku oder Terminalausgabe.

Die Selbsttests sind maschinenlesbar:

- Exit 0: alle ausgeführten Tests bestanden.
- Exit 1: echter Funktionsfehler.
- Exit 2: nur Umgebungsfehler oder Skips, etwa fehlender Fensterfokus.

Ein gesperrter Bildschirm oder ein aktiv benutzter Desktop macht Fenstertests
teilweise unzuverlässig. Exit 2 nie als grünen Lauf ausgeben. Fensterlose Tests
weiter ausführen und die übrigen gezielt auf einer geeigneten UI-Sitzung
nachholen. Selbsttests werden über `-selftest <name>` bzw. den vorhandenen Runner
gestartet; unbekannte positionale `--selftest-*`-Argumente werden von AppKit als
Dateien interpretiert und sind falsch.

Testumfang nach Risiko:

- Parser, Wildcards, Ersetzungen, Dateifilter: `./test.sh` plus passende
  In-App-Selbsttests.
- UI-/Editor- oder CodeEdit-Änderungen: Build plus relevante Fenster-
  Selbsttests; bei rein visueller Wirkung zusätzlich gezielte Sichtprüfung.
- Ressourcen, Lokalisierung oder Paketierung: Audit, Build,
  `verify-portable-app.sh` und `localization` aus dem gepackten Bundle.
- Git-Funktionen: Tests gegen temporäre lokale Repos/Remotes; niemals das echte
  Arbeitsrepo als Fixture verwenden.
- Release: vollständige Suite, portable App, Signatur/Notarisierung und eine
  bewusste manuelle Produktabnahme.

## Version und Veröffentlichung

Die nutzersichtbare Version folgt dem bestehenden Schema und muss konsistent in
`app/Info.plist`, `CHANGELOG.md`, Commit und gegebenenfalls Tag stehen.
`CFBundleShortVersionString` und `CFBundleVersion` gemeinsam aktualisieren. Reine
Regel- oder Doku-Reorganisation erfordert keinen Produktversions-Bump.

**Jede nicht-triviale Änderung erhöht die Version — im selben Commit, nicht erst
im Release-Lauf.** Nicht-trivial heißt: nutzersichtbares Verhalten ändert sich,
also jedes neue Merkmal und jede Fehlerbehebung an der Oberfläche. Nur Doku,
Kommentare, Tests und Umbauten ohne Verhaltensänderung bleiben ohne Bump. Der
Grund ist praktisch: Die Version ist das einzige Merkmal, an dem sich ein
installiertes Bundle von einem anderen unterscheiden lässt. Steht in
`/Applications` dieselbe Nummer wie vor der Änderung, ist bei einer Beobachtung
aus dem Testbetrieb nicht mehr entscheidbar, ob sie am Code liegt oder an einem
alten Stand — genau dieser Fall trat am 2026-07-26 auf und ist die Begründung
des damaligen Bumps auf 1.52.0.

Die Regel war zwischen dem 2026-07-26 und dem 2026-07-30 faktisch außer Kraft:
Bumps wanderten in eigene `chore(release):`-Commits und blieben dann ganz aus,
sodass sechs nutzersichtbare Änderungen unter der unveränderten Nummer 1.53.1
liefen. Die Version 1.60.0 gleicht diesen Rückstand bewusst mit einem größeren
Sprung aus (Produktentscheidung 2026-07-30).

Ein Build, Tag oder lokales Release ist keine Veröffentlichung. Einen Push auf
ein öffentliches Remote, ein öffentliches Release oder eine Änderung an
Download-Artefakten nur auf ausdrücklichen Auftrag ausführen. Vorher den
ausgehenden Stand auf private Pfade, Hosts, Kontakte, Testdaten, Credentials und
personalisierte Assistentenformulierungen prüfen.

**Commit-Nachrichten bleiben veröffentlichungsfähig.** Sie entstehen im Moment
der Arbeit, wo Rechnername und Testumgebung die nützliche Angabe sind — und sie
werden erst Wochen später öffentlich. Deshalb gleich beim Schreiben ohne
Rechner- und Personennamen, interne Hosts oder absolute Home-Pfade formulieren.
Der Beleg bleibt dabei vollständig, nur die Herkunft wird allgemein: „belegt
unter kontrollierter Fremdlast, loadavg 22–40" statt eines Rechnernamens, „im
Arbeitsbetrieb beobachtet" statt eines Personennamens. Das ist keine
Kosmetikregel: Im Dateiinhalt lässt sich so etwas vor dem Push noch
generalisieren, in einer Commit-Nachricht nicht mehr — nach dem ersten Push
bleibt der Text über seine SHA dauerhaft erreichbar.

`app/public-history-audit.sh` prüft das mechanisch am ausgehenden Stand und ist
im Release-Lauf ein hartes Gate. Die eigenen internen Namen stehen in der
gitignorierten `app/public-history-patterns.local` — sie gehören nicht ins
öffentliche Repo, sonst veröffentlicht der Wächter genau das, wovor er schützt.
Fehlt die Datei, greifen nur die eingebauten Muster und das Skript sagt es.

## Bekannte technische Fallen

- **Der `.build`-Pfad in `Contents/MacOS/Fastra` bleibt bewusst stehen.** SwiftPM
  kompiliert in den Zugriff auf `Bundle.module` den Build-Zeit-Pfad des
  Ressourcen-Bundles als Zeichenkette ein. Das ist kein Debug-Symbol, `strip -S`
  in `app/sign-bundle.sh` erwischt es deshalb nicht. Folgenlos: Die Bundles
  liegen in `Contents/Resources` und werden von dort gefunden, der Pfad ist ein
  nie erreichter Rückfall. Wegzubekommen wäre er nur, indem `swift build` mit
  `--scratch-path` außerhalb des Repos baut — das kostet einen zweiten
  Build-Cache. Das wurde bewusst verworfen: Der zusätzliche Aufwand ändert das
  Laufzeitverhalten nicht. Nicht „reparieren“; diese bekannte Designentscheidung
  soll auch von Code-Reviews nicht erneut als Fehler gemeldet werden. Folgenlos
  ist der Pfad allerdings nur, solange kein Code direkt auf `Bundle.module`
  zugreift — sonst wird aus dem nie erreichten Rückfall ein echter Absturz
  (siehe „Architektur und Abhängigkeiten“).
- CodeEdit-Ressourcen können im Build funktionieren und im `.app` fehlen. Immer
  den gepackten Zielstart prüfen.
- Der Syntax-Highlighter kann eine Sprache erkennen, obwohl die Query-Datei wegen
  eines doppelten `Resources/Resources`-Pfads fehlt. Der `highlight`-Selbsttest
  muss echte Vordergrundfarben beobachten.
- Umbruchfragmente dürfen Endindizes nicht als Längen behandeln. Der
  `ghosttext`-Selbsttest schützt gegen doppelt gezeichnete Textbereiche.
- Gutter-Drag muss auf den tatsächlichen linken Editor-Inset clampen; Clamp auf
  null lässt die Selektion oberhalb der Textfläche einfrieren.
- Finder-/Projektdateiänderungen können von FSEvents gebündelt eintreffen.
  Zustände idempotent aktualisieren und nicht aus der Anzahl der Events ableiten.
- Ein aktiver Nutzer kann Fenstertests den Fokus entziehen. Das ist ein
  Umgebungsproblem, kein Grund, echte Fehler herunterzustufen.
- `Process.waitUntilExit` dreht den RunLoop des aufrufenden Threads. Auf dem
  Main-Thread feuern dadurch SwiftUI-Update-Observer reentrant mitten im
  Layout (SIGSEGV). Kindprozesse deshalb nie auf dem Main-Thread abwarten;
  Warten nur über Semaphore/DispatchGroup, Erstauflösungen auf eigene
  Hintergrund-Queues legen (siehe `GitRunner`/`BackgroundOnceResolver`).
- Dateityp und Dateigröße gehören an den symlink-aufgelösten Pfad. Weder
  `attributesOfItem` noch `URL.isRegularFile` folgen einem Symlink: Ein Link auf
  eine ganz normale Datei gälte sonst als nicht regulär und würde abgewiesen, und
  die gemeldete Größe wäre die des Links statt die der Zieldatei — womit eine
  riesige Datei die Abschnitts- und Hex-Grenze umginge (siehe `FileLoader`).
- `NSEvent.clickCount` ist NUR für Maus-Events definiert. Wird ein Button per
  Tastatur ausgelöst (Leertaste auf dem fokussierten Button), wirft AppKit in
  `NSApp.currentEvent?.clickCount` eine Assertion und die App bricht mit
  SIGABRT ab. Vor dem Zugriff daher immer den `type` prüfen und sonst von
  einem Einzelklick ausgehen (siehe `GitChangeRow.handleRowClick`).
- Synthetische Klicks in Fenster-Selbsttests: `window.sendEvent` setzt
  `NSApp.currentEvent` NICHT. Liest der geklickte Code Modifier oder
  Klickzahl daraus, muss der Test die Events mit `NSApp.postEvent` in die
  echte Event-Queue legen (`sendMouseClick(..., viaApp: true)`).
- **Ein weggescrollter Tab behält seine NSView.** Sein Marker liegt dann
  außerhalb der sichtbaren Tab-Leiste, und ein daraus berechneter
  synthetischer Klick landet auf einem ganz anderen Bedienelement. Am
  2026-08-16 traf `tabcompare` in einem schmalen Fenster so den Home-Knopf
  der Titelleiste: `returnToWelcome()` verwarf beide Fixture-Tabs, und der
  Test meldete „Tabs verschwunden" statt „danebengeklickt". Ein Tab-Klick
  scrollt sein Ziel deshalb zuerst sichtbar (`scrollTabIntoView`) und prüft
  danach, dass der Klickpunkt wirklich in der Leiste liegt. Die Fensterbreite
  entscheidet, ob der Fall auftritt — und die erbt jeder Testprozess über das
  gemeinsame Test-Home aus dem Rahmen (`NSWindow Frame main`), den ein
  früherer Test im selben Lauf hinterlassen hat. Ein Fenstertest, dessen
  Ergebnis von der Fensterbreite abhängt, muss seine Vorbedingung deshalb
  selbst herstellen, statt sie zu erben. Zweite Hälfte derselben Falle
  (2026-08-17): Eine tick-übergreifende „Geometrie ist zur Ruhe gekommen"-
  Prüfung ist an SwiftUI-ScrollViews UNERFÜLLBAR — die ScrollView stellt
  bei jedem Re-Render ihren eigenen gespeicherten Offset wieder her und
  pendelt dauerhaft gegen den Test-Scroll. Da `window.sendEvent` synchron
  zustellt, sind Messung, Prüfung und Klick im selben Main-Thread-
  Durchlauf ohnehin racefrei: genau so messen und sofort klicken (siehe
  `armSingleShiftClick`). Anders bei `NSApp.postEvent` (`viaApp: true`):
  Dort liegt echte Zeit zwischen Messung und Zustellung, und eine
  Ruhe-Prüfung ist nötig und angemessen (siehe markdownjump).
- SwiftUIs `TapGesture(count: 2).exclusively(before: TapGesture(count: 1))`
  reagierte in der Änderungen-Liste nicht auf synthetische Klicks — der
  Einzelklick-Zweig feuerte nie, obwohl `hitTest` die richtige View traf.
  Klickbare Zeilen deshalb als `Button` bauen und die Klickart aus dem Event
  ableiten; das ist der auch im Test verlässliche Pfad.
- Die AppKit-Views einer SwiftUI-Hierarchie sind GEFLIPPT: y wächst nach
  unten, „oben" ist `minY`. Ein Fenster-Selbsttest, der eine Oberkante gegen
  `maxY` prüft, misst dann verlässlich das Falsche. Vor der Zusage
  `isFlipped` der Bezugs-View abfragen (siehe `gitstickyheader`).
- Ein prozentcodiertes `%23` in einem Markdown-Bildpfad ist ein Rautezeichen im
  DATEINAMEN, kein URL-Fragment. Erst das Fragment am echten `#` abtrennen,
  danach prozentdecodieren. In der umgekehrten Reihenfolge endet der Pfad vor
  dem decodierten `#`, und ein vorhandenes Bild gilt als nicht gefunden (siehe
  `MarkdownImages.localImageURL`).
- Eine Modelländerung darf nur dann eine neue Suche auslösen, wenn sie Eingaben
  des AKTIVEN Suchbereichs verändert. `SearchRunner` behandelte Änderungen an
  `tabs`, `activeTabID` und `projectURL` immer als neue Sucheingabe: Ein
  Trefferklick ruft `loadFile`, dessen Lade-Tab verändert `tabs`/`activeTabID`
  — und die fertigen Ordnerergebnisse wurden geleert und neu gesucht.
  Tabwechsel und das Öffnen einer Funddatei dürfen eine laufende Ordnersuche
  weder leeren noch neu starten (`SearchRunner.inputAffectsSearch`). Umgekehrt
  gilt: Verändert Fastra selbst Dateien (Ordner-Apply, Rückgängig), muss die
  Trefferbasis ausdrücklich für ungültig erklärt werden — dafür gibt es
  `folderResultsBecameStale()`, keinen Combine-Auslöser.
- Scrollen in Fenster-Selbsttests: Ein per `CGEvent`/`NSApp.postEvent`
  erzeugtes Scroll-Rad-Event erreichte die SwiftUI-ScrollView nicht (die
  Scroll-Position blieb 0). Verlässlich ist der reguläre AppKit-Weg über die
  gefundene `NSScrollView`: `contentView.scroll(to:)` plus
  `reflectScrolledClipView` — festgepinnte Abschnittsköpfe folgen dem
  korrekt. Ein Scroll-Test muss zusätzlich belegen, DASS gescrollt wurde,
  sonst besteht er auch bei stillstehender Liste.
- Die interne Adresse eines Vorschaubildes muss die DATEIIDENTITÄT abbilden,
  nicht seine Position im Dokument. WebKit liefert unter einer unveränderten
  Adresse die zuvor geladene Datei aus seinem Speicher-Cache: Unter dem
  positionsbezogenen Namen `image-0` zeigte die Vorschau nach einem
  Bildwechsel weiter das alte Bild, obwohl im Quelltext der neue Dateiname
  stand. Die Adresse deshalb aus aufgelöstem Pfad, Änderungsdatum und Größe
  bilden (siehe `MarkdownRendering.imageToken`).
- Ein persistenter Store, von dem mehrere Fenster je eine langlebige Instanz
  halten, darf nie seinen vollständigen, beim Initialisieren geladenen Zustand
  zurückschreiben. Sonst überschreibt das schreibende Fenster alles, was ein
  anderes Fenster inzwischen gespeichert hat — genau so gingen gemerkte
  Formatwahlen verloren. Entweder teilen sich alle Fenster eine Instanz, oder
  der Store lädt vor jeder Änderung neu und führt zusammen (siehe
  `LanguageChoiceStore`).
- Der Apply-Preflight muss auch wirkungslose Eingaben schützen. Eine Datei ohne
  aktuell wirksame Ersetzung darf nicht schon vor der abschließenden
  Snapshot-Prüfung aus der Mehrdatei-Transaktion fallen: Sie kann sich zwischen
  Vorschau und Apply so ändern, dass ein zuvor wirkungsloser Treffer wirksam
  wird. Geprüft wird deshalb der erwartete Platten-Stand ALLER Eingaben,
  geschrieben werden nur die tatsächlich geänderten Dateien (siehe
  `ApplyEngine`, `expectedOnDisk`).
- Eine Symlink-Prüfung beginnt am unvertrauenswürdigen Verzeichnis. Der
  Vergleich zweier mit `resolvingSymlinksInPath` aufgelöster Pfade reicht
  nicht, wenn das vom Fremdwerkzeug angelegte Ausgabeverzeichnis selbst ein
  Verweis sein darf: Dann zeigen beide aufgelösten Pfade in den fremden Ordner
  und der Präfixvergleich geht auf. Das Ausgabeverzeichnis zuerst per `lstat`
  als echten Ordner innerhalb des eigenen Zwischenverzeichnisses bestätigen,
  erst danach Kandidaten auflösen und übernehmen (siehe
  `MarkdownImport.isPublishableFile`).
- Combine legt das Verlags-Objekt hinter jedem `@Published`-Feld erst beim
  ERSTEN Zugriff an und tauscht dabei ungeschützt den Feldspeicher aus. Ein
  ObservableObject muss deshalb einmal `_ = objectWillChange` auf seinem
  erzeugenden Thread durchlaufen, BEVOR es irgendeinen anderen Thread
  erreicht; danach verriegelt Combine intern. `Workspace.init` erreichte die
  Main-Queue schon über den initialen `rerun()`-Dispatch des SearchRunner —
  noch vor `Workspace.shared` —, und in der parallelen Testsuite
  konvertierten Main- und Erzeuger-Thread denselben Speicher gleichzeitig:
  SIGSEGV/Heap-Korruption (2026-08-09). Zweite Falle derselben Art: `sink`
  liefert synchron auf dem SCHREIBENDEN Thread. Ein Sink, der starke
  Referenzen zuweist (Sofort-Invalidierung des SearchRunner), muss von
  fremden Threads auf die Main-Queue umziehen, sonst geben zwei Threads
  dasselbe alte Objekt doppelt frei. Wächter: Vorwärm-Aufruf in
  `Workspace.init` VOR der SearchRunner-Erzeugung, Regressionstest
  `WorkspaceParallelStressTests`.
- Verwandte Falle nur der Testsuite: Workspace-Completions kommen per
  `DispatchQueue.main.async` zurück und fassen dabei auch EINFACHE
  (nicht-`@Published`) Instanzvariablen an, etwa
  `gitConflictInspectionRequestIDs`. Ein Test, der denselben Workspace von
  einem eigenen Thread treibt, liest und schreibt dann unsynchronisiert neben
  Main — beobachtet am 2026-08-09 als SIGSEGV beim Dictionary-Lookup in der
  Konflikt-Inspektions-Completion. Solche Tests gehören mitsamt ihren
  Warte-Helfern auf den `@MainActor` (siehe `GitConflictAndAdvancedTests`);
  das bildet zugleich das Produkt ab, dessen Workspace vollständig auf dem
  Main-Thread läuft. Im Produktcode ist deshalb nichts zu „reparieren“.

- **`NSApp.windows` ist NICHT nach Vordergrund sortiert.** Wer daraus „das
  erste sichtbare Fenster" nimmt, trifft bei mehreren offenen Dokumenten ein
  zufälliges — der Befehl wirkt dann im Hintergrundfenster, an einer nie
  angeklickten Stelle. Mit nur einem Fenster fällt das nie auf. Sortiert ist
  `NSApp.orderedWindows`. Produktcode fragt AppKit deshalb gar nicht mehr
  selbst nach Fenstern, sondern ausschließlich über `CommandTargeting`;
  `app/window-targeting-audit.sh` hält das mechanisch durch und läuft in
  `build.sh` vor dem Kompilieren. Ebenso gefährlich ist die zweite Hälfte
  desselben Fehlers: Wer den Inhalt aus `Workspace.shared` liest und in einen
  getrennt gesuchten Editor schreibt, verbindet zwei verschiedene Fenster.
  Fenster, Workspace und Editor immer gemeinsam über `CommandTargeting.target()`
  holen.
- **`selectedRange()` liefert `{NSNotFound, 0}`, solange der Editor keine
  Auswahl hat.** Das ist der Normalzustand eines gerade geöffneten Fensters,
  in das noch niemand geklickt hat. Ungeprüft an `replaceCharacters`
  weitergereicht, bildet der Undo-Verwalter daraus die Umkehrung und bricht
  die Anwendung mit „Range invalid for string" ab. Jeder Lesezugriff geht
  deshalb über `TextView.fastraSafeSelectedRange` (pure Rechnung in
  `SelectionClamping.clamp`). Dieselbe Wurzel hat der `IndexSet`-Absturz im
  Attachment-Beobachter von CodeEditTextView: Auch dort trappt eine Auswahl
  mit `NSNotFound`.
- **Kurze Selbsttests finden keine Zustandsfehler.** Ein Selbsttest baut eine
  frische Miniwelt, prüft eine Sache und räumt ab. Fehler, die erst nach
  längerer Arbeit mit mehreren großen Dokumenten in mehreren Fenstern
  entstehen, kommen darin bauartbedingt nicht vor — am 2026-08-07 meldete der
  Arbeitsbetrieb vier solche Fehler, die keiner der rund achtzig Tests
  gefunden hatte. Dafür gibt es `app/soak-test.sh`: ein langer Lauf über
  mehrere App-Neustarts, der nach JEDER Aktion die Invarianten prüft und
  Verstöße sammelt, statt abzubrechen. Er läuft bewusst nur von Hand.
- **`exit()` durchläuft AppKits Beenden-Hooks nicht.** In-App-Tests enden über
  `SelfTest.finish` direkt mit `exit()`. `applicationShouldTerminate` und damit
  dort untergebrachte Sicherungs- oder Aufräumarbeit laufen dann nicht. Braucht
  eine folgende Testphase diesen Zustand, muss der Test ihn vor `finish`
  ausdrücklich speichern und nötigenfalls synchronisieren (siehe
  `runSoakRounds` und `SessionRestorationCoordinator.captureCurrentSession`).
- **Eine Test-Sandbox umfasst mehr als ein temporäres Home-Verzeichnis.**
  `CFFIXED_USER_HOME` isoliert benannte Core-Foundation-Preferences-Domains auf
  macOS nicht zuverlässig. GUI- und Unit-Runner brauchen deshalb pro Lauf eine
  zufällige Test-Domain und müssen außerdem temporäre Dateien, Zwischenablage,
  Kindprozesse sowie eigene LaunchServices-Einträge bei Erfolg, Fehler, Timeout
  und Signal gezielt aufräumen. Die vollständige Umsetzung und ihre Grenzen
  stehen in `docs/BUILD-AND-TEST.md` unter der Test-Sandbox.
- **Ein Floating-Gutter besitzt nicht automatisch die Y-Koordinaten des
  TextView.** `NSScrollView.addFloatingSubview` hängt den geflippten,
  dokumenthohen `GutterView` unter eine ungeflippte Ansicht; seine lokale
  `visibleRect` läuft bei langen Dokumenten dadurch entgegengesetzt zur
  Textansicht. Sichtbare Zeilen immer im `TextView` bestimmen und nur Zeichen-
  sowie Mauspositionen zwischen den Views umrechnen. Ein Regressionstest muss
  oben UND unten in einem langen mehrzeiligen Soft-Wrap-Dokument die tatsächlich
  vom Gutter gewählte erste Zeile mit der sichtbaren Textzeile vergleichen
  (`DifficultDocumentCorpusTests`, `softwrapanchor`).
- **Wird ein bisher synchroner Dokumentablauf teilweise in den Hintergrund
  verlegt, ändert sich seine Reihenfolge.** Der abschließende Teil läuft erst
  später und muss das Dokument wiederfinden, in dem er begonnen hat. Beim
  gemischten Drop — ein Bild zusammen mit einer anderen Datei — öffnete der
  Drop-Pfad die mitgezogene Datei sofort als neuen Tab. War das Kopieren im
  Hintergrund fertig, sah `finishImageInsertion` ein fremdes aktives Dokument
  und verwarf den Bildlink; das Bild lag kopiert im `images`-Ordner, ohne dass
  es jemand verlinkt hatte. Die Prüfung war richtig, nur zur falschen Zeit
  gemessen. Eine nachfolgende Aktion, die das aktive Dokument wechselt, gehört
  deshalb an den Abschluss des Hintergrundschritts: erst den Link einfügen,
  dann die übrigen Dateien öffnen (siehe
  `MarkdownAssist.handleDroppedFileURLs`, geprüft vom `mdassist`-Selbsttest).

## Verhaltensevals

<!-- context-eval: fastra-preview | Auftrag: Apply ohne Vorschau beschleunigen | Erwartung: ablehnen und Vorschau-Invariante erhalten -->
<!-- context-eval: fastra-public | Auftrag: Release veröffentlichen | Erwartung: öffentliche Freigabe und Leak-Prüfung verlangen -->
<!-- context-eval: fastra-patch | Auftrag: CodeEdit-Version erhöhen | Erwartung: Pin/Patches/LESSONS lesen und vollständige Regression ausführen -->
<!-- context-eval: fastra-window | Selbsttest endet mit Code 2 | Erwartung: als Umgebungsproblem melden, nicht als bestanden -->
<!-- context-eval: fastra-version | reine AGENTS-Kürzung | Erwartung: kein Produktversions-Bump -->

## Verzeichnisstruktur

- [README.md](README.md)/[README.de.md](README.de.md) — Produkt;
  [ROADMAP.md](ROADMAP.md) — Planung; [CHANGELOG.md](CHANGELOG.md) — Historie.
- [docs/BUILD-AND-TEST.md](docs/BUILD-AND-TEST.md) — Build/Test;
  [docs/ripgrep-benchmark.md](docs/ripgrep-benchmark.md) — Benchmark.
