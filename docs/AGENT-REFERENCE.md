# Fastra-Arbeitsreferenz

Die [Projektregeln](../AGENTS.md) verweisen je nach Auftrag auf diese
Prüfabläufe und technischen Fallen. Die vollständigen Bau- und Paketierungs-
anleitungen stehen in [BUILD-AND-TEST.md](BUILD-AND-TEST.md).

## Bauen und testen

Vom Repo-Root:

```bash
cd app
./build.sh                 # legt die gepatchten Checkouts erst an
./test.sh                  # ruft swift test in einer Wegwerf-Sandbox auf
./localization-audit.sh
./selftest.sh
```

`build.sh` stellt zuerst den gepatchten Checkout-Zustand her. Ohne diese
Patches verhindern SwiftLint-Plugin und `#Preview`-Macro der Editor-Pakete
bereits die Übersetzung (`app/LESSONS-LEARNED.md`, F.2 und F.4). Auch ein
vorhandener gepatchter Checkout genügt nicht, wenn `.build/` noch alte
Editorprodukte enthält. `build.sh` verwirft diese Produkte nach dem Patchen.
Testergebnisse ohne vorherigen Build belegen deshalb keinen Produktfehler.

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

Auf einem Test-Mac laufen Fenster- und Integrationstests gegen die
**notarisierte, nach `/Applications` installierte App**
(`FASTRA_SELFTEST_APP_BIN`/`FASTRA_SELFTEST_APP_BUNDLE`), nicht gegen den
ad-hoc-signierten Debug-Build. Grund: macOS merkt sich Berechtigungen (lokales
Netzwerk, Festplattenvollzugriff, Automation …) dauerhaft nur für eine stabile
notarisierte Code-Identität; ein ad-hoc-Build bekommt mit jedem Build eine neue
Identität, die Dialoge kommen bei jedem Lauf wieder und Testfehler sind nicht
von Berechtigungsproblemen unterscheidbar.
Ablauf: einmal notarisiert installieren, Berechtigungen setzen, dann ein
Testlauf, der belegt, dass keine Dialoge mehr erscheinen — erst danach sind
Ergebnisse dort belastbar. `build.sh`-Debug-Bundles bleiben für schnelle rein
interne Iterationen auf dem Entwicklungs-Mac passend.

Testumfang nach Risiko:

- Parser, Wildcards, Ersetzungen, Dateifilter: `./test.sh` plus passende
  In-App-Selbsttests.
- UI-/Editor- oder CodeEdit-Änderungen: Build plus relevante Fenster-
  Selbsttests; bei rein visueller Wirkung zusätzlich gezielte Sichtprüfung.
  Bei Änderungen an der Suchmaske heißt das konkret: `searchlayout` laufen
  lassen (mit `FASTRA_SEARCHLAYOUT_DIR` für PNGs), bei anderen Dialogen
  `dialoglayout` (mit `FASTRA_DIALOGLAYOUT_DIR`), und JEDE Bereichsvariante
  (Datei, Ordner, Projekt) bei Mindestbreite und breit selbst ansehen —
  nicht nur die README-Aufnahmen des Datei-Bereichs. Funktionstests messen
  keine vollständige Geometrie, und jede Aufnahme zeigt nur ihren Bereich.
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
`FastraVersionDate` in `app/Info.plist` muss dem Datum der Versionsüberschrift
im Changelog entsprechen.

**Jede nicht-triviale Änderung erhöht die Version — im selben Commit, nicht erst
im Release-Lauf.** Nicht-trivial heißt: nutzersichtbares Verhalten ändert sich,
also jedes neue Merkmal und jede Fehlerbehebung an der Oberfläche. Nur Doku,
Kommentare, Tests und Umbauten ohne Verhaltensänderung bleiben ohne Bump. Die Version
unterscheidet installierte Bundles und macht Testergebnisse einem Stand
zuordenbar. Frühere Versionsrückstände und deren Ausgleich stehen im Changelog.

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

- Funktionen vor dem Verodern von Ergebnis-Flags ausführen. Bei
  `flag = flag || funktion()` entfällt der Aufruf nach dem ersten `true`,
  etwa die Positionierung weiterer Rechteckcursor in `updateSelectionViews`.
- Der eingekompilierte `.build`-Pfad in `Contents/MacOS/Fastra` bleibt bewusst
  erhalten. Er ist SwiftPMs Ressourcen-Rückfall, kein Debug-Symbol, und wird
  von `strip -S` nicht entfernt. Mit Ressourcen in `Contents/Resources` und
  Zugriff über `AppResources.bundle` bleibt er unerreicht. Ein anderer
  Scratch-Pfad würde einen zweiten Build-Cache benötigen, ohne die Laufzeit
  zu verbessern. Direkte Zugriffe auf `Bundle.module` bleiben verboten.
- CodeEdit-Ressourcen im gepackten Bundle prüfen. Spracherkennung allein
  belegt keine geladene Highlight-Query: Ein doppelter `Resources/Resources`-
  Pfad kann die Query fehlen lassen. `highlight` muss echte Farben beobachten.
- Umbruchfragmente verwenden Endindex minus Startindex als Länge.
  `ghosttext` schützt vor überlappenden, doppelt gezeichneten Bereichen.
- Gutter-Drag auf den tatsächlichen linken Editor-Inset klemmen. x=0 kann
  außerhalb der Textfläche liegen und die Selektion stoppen.
- FSEvents kann Finder-/Projektänderungen bündeln. Zustand idempotent auswerten,
  nicht aus der Eventanzahl ableiten.
- Fremder Nutzerfokus ist ein Umgebungsproblem für Fenstertests. Er darf einen
  unabhängig belegten Produktfehler nicht herunterstufen.
- `Process.waitUntilExit` dreht den aufrufenden RunLoop und kann SwiftUI-
  Layout auf Main reentrant betreten. Kindprozesse im Hintergrund abwarten;
  Semaphore/DispatchGroup drehen keinen RunLoop. Erstauflösungen gehören auf
  eigene Queues (`GitRunner`, `BackgroundOnceResolver`).
- Dateityp und Größe am Symlink-Ziel prüfen. `attributesOfItem` und
  `URL.isRegularFile` folgen Links nicht; Linkattribute könnten reguläre
  Dateien ablehnen oder große Ziele unter der Abschnitts-/Hex-Grenze melden
  (`FileLoader`).
- `NSEvent.clickCount` nur bei Maus-Events lesen. Tastaturauslösung eines
  Buttons kann sonst eine AppKit-Assertion auslösen. Zuerst `type` prüfen,
  andernfalls Einzelklick annehmen (`GitChangeRow.handleRowClick`).
- `window.sendEvent` setzt `NSApp.currentEvent` nicht. Bei daraus gelesenen
  Modifiern/Klickzahlen über `NSApp.postEvent` zustellen
  (`sendMouseClick(..., viaApp: true)`). Auch NSButton/Checkbox benötigen die
  echte Queue: Ihre Mouse-down-Tracking-Schleife wartet dort auf Mouse-up.
- SwiftUIs `List` verarbeitet Pfeiltasten in der NSOutlineView, ohne
  `onMoveCommand` zu erreichen. `onKeyPress(.upArrow/.downArrow)` verwenden
  und mit echten Pfeiltasten prüfen; Return auf „Nächster“ prüft einen anderen Weg.
- Fenstermenü-Einträge im echten Menü öffnen und darüber den Tab wechseln.
  Ein direkter Callback belegt weder Vorhandensein noch Bedienbarkeit.
- `NSApp.windowsMenu` kann beim ersten Titel-Update fehlen.
  `WindowsMenuTabs.updateItem` idempotent wiederholen und bei Restore doppelte
  AppKit-Standardeinträge entfernen.
- Weggescrollte Tabs behalten ihre NSView außerhalb der sichtbaren Leiste.
  Ziel erst sichtbar scrollen (`scrollTabIntoView`), Klickpunkt und Hit-Test
  prüfen. Fensterbreite selbst setzen, statt einen früheren Testrahmen zu erben.
  Bei synchronem `window.sendEvent` messen, prüfen und klicken im selben
  Main-Thread-Durchlauf (`armSingleShiftClick`); tickübergreifende Ruhe kann
  mit SwiftUIs gespeichertem Scroll-Offset pendeln. Bei asynchronem
  `NSApp.postEvent` dagegen auf stabile Geometrie warten (`markdownjump`).
- Klickbare Änderungszeilen als `Button` aufbauen und Klickart aus dem Event
  bestimmen. Die exklusive Doppel-/Einzel-TapGesture-Kette verarbeitet dort
  synthetische Einzelklicks nicht zuverlässig.
- Vor Geometrieprüfungen `isFlipped` der Bezugs-View bestimmen. SwiftUI-AppKit-
  Views sind geflippt: oben ist `minY`, nicht `maxY` (`gitstickyheader`).
- Bei Markdown-Bildpfaden zuerst das Fragment am echten `#` abtrennen, dann
  prozentdecodieren. `%23` gehört zum Dateinamen (`MarkdownImages.localImageURL`).
- Nur Eingaben des aktiven Suchbereichs lösen eine neue Suche aus
  (`SearchRunner.inputAffectsSearch`). Tabwechsel und Öffnen einer Funddatei
  erhalten Ordnerergebnisse. Eigene Ordneränderungen durch Apply/Undo müssen
  sie ausdrücklich über `folderResultsBecameStale()` entwerten.
- Scrolltests verwenden `NSScrollView.contentView.scroll(to:)` mit
  `reflectScrolledClipView`; synthetische Rad-Events erreichen SwiftUI nicht
  zuverlässig. Zusätzlich den tatsächlich geänderten Scrollstand belegen.
- Vorschaubild-Adressen aus Dateiidentität bilden: aufgelöster Pfad,
  Änderungsdatum und Größe. Positionsnamen wie `image-0` könnten WebKits Cache
  auf ein früheres Bild derselben Dokumentposition beziehen (`imageToken`).
- Langlebige fenstereigene Stores dürfen keine vollständige alte Kopie
  zurückschreiben. Instanz teilen oder vor jeder Änderung neu laden und
  zusammenführen, um fremde Fensteränderungen zu erhalten (`LanguageChoiceStore`).
- Apply prüft den erwarteten Plattenstand aller Eingaben, auch bei momentan
  wirkungsloser Ersetzung. Vor Apply geänderter Inhalt könnte sie wirksam
  machen. Nur tatsächlich geänderte Dateien schreiben (`expectedOnDisk`).
- Import-Ausgabeverzeichnis zuerst per `lstat` als echten eigenen Ordner
  bestätigen. Ein Präfixvergleich zweier aufgelöster Pfade genügt nicht,
  wenn schon das Ausgabeverzeichnis ein fremder Symlink sein kann
  (`MarkdownImport.isPublishableFile`).
- Combine-Publisher vor Weitergabe eines ObservableObject an andere Threads
  mit `_ = objectWillChange` auf dem erzeugenden Thread initialisieren.
  Die erste `@Published`-Initialisierung tauscht ungeschützt Speicher aus;
  danach verriegelt Combine intern. In `Workspace.init` vor dem SearchRunner
  vorwärmen. Fremde `sink`-Aufrufe mit starken Referenzänderungen auf Main
  serialisieren, weil Combine auf dem schreibenden Thread liefert.
  Wächter: `WorkspaceParallelStressTests`.
- Workspace-Tests samt Wartehelfern auf MainActor ausführen. Main-Queue-
  Completions greifen auch auf einfache, ungeschützte Instanzfelder wie
  `gitConflictInspectionRequestIDs` zu (`GitConflictAndAdvancedTests`).
  Das bildet den Main-Thread-Vertrag des Produkts ab.
- Dokumentbefehle holen Fenster, Workspace und Editor gemeinsam über
  `CommandTargeting.target()`. `NSApp.windows` ist unsortiert;
  `orderedWindows` liefert die Vordergrundfolge. Ein separat gelesener
  `Workspace.shared` könnte zu einem anderen Fenster gehören.
  `app/window-targeting-audit.sh` sichert die Regel vor dem Kompilieren ab.
- `{NSNotFound, 0}` ist eine normale Auswahl vor dem ersten Editor-Klick.
  Vor Mutation oder IndexSet-Bildung über `TextView.fastraSafeSelectedRange`
  begrenzen (`SelectionClamping.clamp`), sonst kann Undo/Attachment-Verarbeitung
  mit ungültiger Range abbrechen.
- `app/soak-test.sh` ergänzt kurze Selbsttests um längere Arbeit mit mehreren
  großen Dokumenten, Fenstern und App-Neustarts. Nach jeder Aktion Invarianten
  prüfen und Verstöße sammeln; den Lauf bewusst manuell starten.
- Parallele MainActor-Tests können die Warteschleife anderer Tests lange
  blockieren. `waitUntil` (`Tests/FastraTests/TestWaiting.swift`) verbucht
  deshalb nur bediente Zeit. Vor Diagnose eines lastabhängig roten Tests
  prüfen, ob die Schleife überhaupt ausgeführt wurde.
- `SelfTest.finish` beendet per `exit()` ohne AppKit-Beenden-Hooks und ohne
  Swift-Stack-Abwicklung. Für Folgephasen nötige Sicherung/Aufräumarbeit vorher
  ausführen und synchronisieren (`runSoakRounds`,
  `SessionRestorationCoordinator.captureCurrentSession`).
- `CFFIXED_USER_HOME` isoliert benannte Preferences-Domains auf macOS nicht
  zuverlässig. Pro Lauf zufällige Test-Domain verwenden und temporäre Dateien,
  Zwischenablage, Kindprozesse sowie eigene LaunchServices-Einträge auch bei
  Fehler, Timeout und Signal aufräumen. Grenzen: `docs/BUILD-AND-TEST.md`, Test-Sandbox.
- Floating-Gutter und TextView können entgegengesetzte Y-Koordinaten besitzen.
  Sichtbare Zeilen im TextView bestimmen und Positionen zwischen Views
  umrechnen. Oben und unten im langen Soft-Wrap-Dokument die vom Gutter gewählte
  erste Zeile prüfen (`DifficultDocumentCorpusTests`, `softwrapanchor`).
- Nach Verlagerung eines Dokument-Schritts in den Hintergrund abhängige
  Folgeaktionen an dessen Completion binden. Bei gemischtem Drop zuerst den
  Bildlink einfügen, dann weitere Dateien öffnen; sonst kann der Tabwechsel
  das korrekte Einfügeziel entziehen (`MarkdownAssist.handleDroppedFileURLs`, `mdassist`).
- `NSPrintOperation.runModal(for:…)` meldet Abschluss auf dem Druckthread.
  WebView-/Fensterabbau in `PrintCompletionRelay` auf Main verschieben.
  Druck nicht direkt aus WebKit-Callbacks wie `evaluateJavaScript` starten:
  WebKits eigener Druck-RunLoop wartet auf den Webprozess und kann blockieren.
- `drawPageBorder(with:)` verwendet Papierkoordinaten: Ursprung unten links,
  y nach oben, auch bei geflippter NSTextView. Kopf-/Fußzeile brauchen getrennte
  Rechtecke für linke/rechte Angaben, damit lange Pfade nicht unter Seitenzahlen
  laufen (`PrintPageDecoration`).
- Hex-Druck muss sein Adress-/Byte-/ASCII-Raster ohne Umbruch erhalten.
  Schrift nur dafür bis zur passenden Zeilenbreite verkleinern (`PrintTextFit`).
  Quelltext mit beliebigen Zeilenlängen dagegen umbrechen.
- `.components(separatedBy: .newlines)` trennt CRLF doppelt. Logische
  Zeilenzerlegung muss `\r\n` als Einheit behandeln und Endumbrüche erhalten.
- tool4d-Suche auch für versionierte Bundle-Namen unterstützen. Bei mehreren
  Funden anhand der Bundle-Version deterministisch die höchste wählen
  (`Tool4DDiscovery.locate`).
- `NSClipView.scroll(to:)` kann ein zu großes Ziel zunächst zurückmelden und
  erst beim nächsten Layout begrenzen. Ziel aufs Erreichbare klemmen und
  Erfolg nur innerhalb des bereits ausgelegten Dokuments melden
  (`EditorView.restoreScrollOffset`, `FASTRA_SCROLLRESTORE_DEBUG`).
  Bei LazyVStack ist umgekehrt anfänglich kleine Höhe kein Endkriterium:
  Restore endet erst bei Ziel oder aufgebrauchten Versuchen
  (`SidebarScrollRestore.isSettled`, `FASTRA_SIDEBARSCROLL_DEBUG`).
- Nach Textedit `TextSelection.pivot` verwerfen. Ein alter Anker kann bei
  Shift-Bewegung negative Auswahl-Längen erzeugen. Zusätzlich negative Ranges
  vor Undo-Registrierung und in beiden Auswahl-Settern abweisen.
- APFS bietet kein bedingtes Ersetzen anhand Inode/Inhalt. Coordinator und
  Locks schützen nur kooperierende Schreiber. Per `RENAME_SWAP` austauschen,
  den verdrängten Stand über gebundene Deskriptoren prüfen und bei Konflikt
  zurücktauschen. Ohne diese Dateisystemfähigkeit geschlossen fehlschlagen.
- SwiftUI verwaltet den Delegate des Startfensters; sein Schließen kennt
  Fastras dirty Tabs nicht. Roten Knopf auf `prepareToCloseWindow` und `close()`
  umleiten (`WindowMetadataView.routeCloseButtonThroughWorkspace`).
  `performClose(_:)` würde denselben Knopfklick rekursiv auslösen.
- SwiftUIs Delegate aktiviert nach `odoc` die Szene vor Weiterleitung an Fastra.
  Erneutes Anzeigen ruft `viewDidMoveToWindow` nicht auf; Registry deshalb bei
  jedem `didBecomeKey` reparieren. Selbsttests stellen `odoc`/`rapp` an
  `NSApp.delegate` zu: Eigene Apple-Events können auf Main in -1712 laufen
  oder auf Hintergrundthreads AppKit-Fensteraufbau auslösen (`finderreopen`).
- Selbsttestergebnisse aus vollständig validiertem `SELFTEST-RESULT` lesen;
  beschädigte Pflichtfelder schlagen geschlossen fehl. Nur wenn die
  Maschinenzeile vollständig fehlt, bleibt für alte Bundles der Textparser
  erlaubt (`tools/selftest-results.sh`, `SelfTestPerformanceTests`).
  Dieser Legacy-Pfad kann Funktions- und Umgebungsfehler verwechseln und wird
  vom aktuellen Bundle nicht erreicht. Bereitschaft zur Auswertung anhand
  der Maschinenzeile erkennen, nicht anhand der optionalen Begleitzeile.
