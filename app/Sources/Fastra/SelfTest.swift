// SelfTest.swift
//
// In-App-Smoke-Test für die Bug-Klasse, die reine Unit-Tests NICHT fangen:
// App-weites Event-Routing und die LIFO-Reihenfolge der CMD+F-Monitore
// (Zombie-Find-Bar). Läuft im ECHTEN App-Prozess mit den ECHTEN Monitoren.
//
// Aufruf: bevorzugt `./selftest.sh findbar`, direkt
// `Fastra -selftest findbar -ApplePersistenceIgnoreState YES`. Der Test postet
// ein echtes CMD+F in
// die Event-Queue (läuft dadurch durch alle lokalen Monitore, genau wie ein
// Tastendruck), und prüft danach, ob CodeEditSourceEditors eigenes
// Find-Panel aufgetaucht ist. Gibt `SELFTEST findbar: PASS/FAIL` aus und
// beendet die App mit Exit-Code 0/1 — so im CI/Skript auswertbar.
//
// Bewusst KEIN Accessibility/System-Events nötig: das Event wird intern
// gepostet, nicht über die Systemsteuerung simuliert.

import AppKit
import Darwin
import PDFKit
import WebKit
import CodeEditSourceEditor
// Echte Editor-Klasse von CodeEditSourceEditor (Modul CodeEditTextView).
// Wird gebraucht, um im Sprung-Selbsttest die TATSÄCHLICHE Selektion des
// Editors (`TextView.selectedRange()` + `.string`) zurückzulesen.
import CodeEditTextView
// Sprach-Registry — für die FAIL-Diagnose des Highlight-Selbsttests
// (erkannte Sprache, tree-sitter-Grammatik, Query-Pfad).
import CodeEditLanguages
import Sparkle

enum SelfTest {
    /// Pro Selbsttest-Prozess genau eine isolierte Defaults-Suite. Mehrere
    /// Dokumentfenster müssen dieselbe Suite teilen; würde jeder Aufruf sie
    /// erneut leeren, hielte sich auch das zweite Fenster fälschlich für den
    /// allerersten App-Start und bekäme den Demo-Inhalt statt eines Leer-Tabs.
    private static var cachedWorkspaceDefaults: UserDefaults?
    /// Hält die beiden produktiven Suchfenster des `multisearch`-Tests bis
    /// zum Prozessende stark am Leben, analog zu `ContentView.searchPanel`.
    private static var retainedSearchPanels: [SearchPanelController] = []
    /// Hält den asynchronen echten tool4d-Lauf bis zu seiner Completion am
    /// Leben. Ohne diese Referenz könnte ARC den Testlauf vor der TCP-Antwort
    /// freigeben und einen scheinbaren Netzwerkfehler erzeugen.
    private static var retainedTool4DValidation: Tool4DLSPValidation?
    /// Fixture der echten Start-Sitzungswiederherstellung. Sie wird noch vor
    /// dem ersten Workspace angelegt und unmittelbar vor dem Test-Exit
    /// entfernt.
    private static var sessionRestoreFixtureDirectory: URL?
    private static var sessionRestoreSetupError: String?
    /// Kombiniertes Kaltstart-Fixture: LaunchServices liefert eine ausdrücklich
    /// geöffnete Datei, während im isolierten Store eine andere alte Sitzung
    /// liegt. Genau diese Konkurrenz hat die Finder-Datei bisher verdrängt.
    private static var coldOpenFixtureDirectory: URL?
    private static var coldOpenExternalURL: URL?
    private static var coldOpenRestoredURLs: [URL] = []
    private static var coldOpenRestoredProjectURLs: [URL] = []
    private static var coldOpenSetupError: String?
    /// Eigenes Kaltstart-Fixture für den Auswahl-Scrolltest. Es benutzt
    /// denselben produktiven SessionStateStore wie ein normaler App-Start.
    private static var selectionScrollFixtureDirectory: URL?
    private static var selectionScrollFixtureURL: URL?
    private static var selectionScrollSetupError: String?

    /// Name des angeforderten Selbsttests („findbar", „cmdw", …) oder `nil`.
    ///
    /// Zwei gleichwertige Aufruf-Wege:
    ///   FASTRA_SELFTEST=findbar …/Fastra            (Umgebungsvariable)
    ///   …/Fastra -selftest findbar                  (NSArgumentDomain)
    ///
    /// WICHTIG (Root Cause „kein Hauptfenster", 2026-06-11): bewusst KEIN
    /// positionales `--selftest-…`-Argument mehr. AppKit interpretiert
    /// unbekannte positionale Argumente als „zu öffnende Datei" — die App
    /// durchläuft dann den Open-File-Launchpfad statt
    /// `applicationOpenUntitledFile`, und SwiftUI erzeugt das WindowGroup-
    /// Hauptfenster NIE (empirisch belegt: jedes beliebige `--flag` führt
    /// zu `NSApp.windows == []`, Main-Thread idle). `-Key Value`-Argumente
    /// landen dagegen im NSArgumentDomain von UserDefaults und sind
    /// unschädlich. Dass die Fenster-Tests früher grün waren, lag an der
    /// Fenster-Restauration aus dem Saved State — die seit 2026-06-11
    /// empfohlene `-ApplePersistenceIgnoreState YES` schaltete genau diese
    /// Krücke ab und machte den Bug sichtbar.
    static var requestedTest: String? {
        if let env = ProcessInfo.processInfo.environment["FASTRA_SELFTEST"],
           !env.isEmpty {
            return env
        }
        // `-selftest findbar` → NSArgumentDomain hat in `.standard` die
        // höchste Priorität, der Wert ist hier direkt lesbar.
        if let arg = UserDefaults.standard.string(forKey: "selftest"),
           !arg.isEmpty {
            return arg
        }
        return nil
    }

    /// `true`, wenn der Prozess als Selbsttest läuft. Wird u.a. genutzt,
    /// um den Selbsttests eine ISOLIERTE UserDefaults-Suite zu geben
    /// (siehe `workspaceDefaults()`).
    static var isSelfTestRun: Bool {
        requestedTest != nil
    }

    /// Setzt Shot-spezifische UI-Fixtures noch vor dem Aufbau der ersten
    /// `EditorView`. Die Variable gilt nur für diesen Selbsttest-Prozess und
    /// hinterlässt nach dessen automatischem Exit keinen persistenten Zustand.
    static func prepareLaunchEnvironment(
        requestedTest name: String? = requestedTest,
        setEnvironment: (_ key: String, _ value: String) -> Void = { key, value in
            _ = setenv(key, value, 1)
        }
    ) {
        let sidebar: String?
        switch name {
        case "gitshot", "gitstagefolder", "gitpushbutton": sidebar = "changes"
        case "graphshot": sidebar = "graph"
        default: sidebar = nil
        }
        if let sidebar { setEnvironment("FASTRA_SIDEBAR", sidebar) }
        if name == "sessionrestore" {
            prepareSessionRestoreFixture()
        } else if name == "coldopen" || name == "coldopenoff" {
            prepareColdOpenFixture(restoreEnabled: name == "coldopen")
        } else if name == "selectionscroll" {
            prepareSelectionScrollFixture()
        }
    }

    /// Legt den Codable-Snapshot VOR `FastraApp` seinen ersten Workspace
    /// erzeugt in der isolierten Selbsttest-Suite ab. So prüft der spätere
    /// Test den echten Kaltstartpfad statt nur Workspace-Methoden direkt
    /// aufzurufen.
    private static func prepareSessionRestoreFixture() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fastra-selftest-session-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let first = directory.appendingPathComponent("eins.txt")
            let second = directory.appendingPathComponent("zwei.txt")
            let third = directory.appendingPathComponent("drei.txt")
            try Data("eins\n".utf8).write(to: first)
            try Data("zwei\n".utf8).write(to: second)
            try Data("drei\n".utf8).write(to: third)
            let states = [
                RestorableWindowState(
                    projectPath: directory.path,
                    documentPaths: [first.path, second.path],
                    activeDocumentPath: first.path,
                    frame: nil
                ),
                RestorableWindowState(
                    projectPath: nil,
                    documentPaths: [third.path],
                    activeDocumentPath: third.path,
                    frame: nil
                ),
            ]
            SessionStateStore.save(
                RestorableSessionState(windows: states),
                to: workspaceDefaults()
            )
            sessionRestoreFixtureDirectory = directory
        } catch {
            sessionRestoreSetupError = error.localizedDescription
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Der Runner legt die externe Datei VOR dem Launch an und reicht ihren
    /// Pfad über eine prozesslokale Umgebungsvariable weiter. Parallel entsteht
    /// hier eine abweichende gespeicherte Sitzung in derselben isolierten
    /// Defaults-Suite, die der produktive AppDelegate beim Start liest.
    private static func prepareColdOpenFixture(restoreEnabled: Bool) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fastra-selftest-coldopen-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            guard let externalPath = ProcessInfo.processInfo
                .environment["FASTRA_COLDOPEN_FILE"],
                  !externalPath.isEmpty else {
                throw NSError(
                    domain: "FastraSelfTest", code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "FASTRA_COLDOPEN_FILE fehlt"]
                )
            }
            let externalURL = URL(fileURLWithPath: externalPath).canonicalFileURL
            guard FileManager.default.fileExists(atPath: externalURL.path) else {
                throw NSError(
                    domain: "FastraSelfTest", code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "externe LaunchServices-Datei fehlt"]
                )
            }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let firstProject = directory.appendingPathComponent(
                "erstes-projekt", isDirectory: true
            )
            let secondProject = directory.appendingPathComponent(
                "zweites-projekt", isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: firstProject, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: secondProject, withIntermediateDirectories: true
            )
            let firstRestored = firstProject.appendingPathComponent("alt-eins.md")
            let secondRestored = secondProject.appendingPathComponent("alt-zwei.md")
            try Data("Erste gespeicherte Sitzung\n".utf8).write(to: firstRestored)
            try Data("Zweite gespeicherte Sitzung\n".utf8).write(to: secondRestored)
            SessionStateStore.save(
                RestorableSessionState(windows: [
                    RestorableWindowState(
                        projectPath: firstProject.path,
                        documentPaths: [firstRestored.path],
                        activeDocumentPath: firstRestored.path,
                        frame: nil
                    ),
                    RestorableWindowState(
                        projectPath: secondProject.path,
                        documentPaths: [secondRestored.path],
                        activeDocumentPath: secondRestored.path,
                        frame: nil
                    ),
                ]),
                to: workspaceDefaults()
            )
            workspaceDefaults().set(
                restoreEnabled,
                forKey: SessionRestorationPreferences.enabledKey
            )
            coldOpenFixtureDirectory = directory
            coldOpenExternalURL = externalURL
            coldOpenRestoredURLs = [firstRestored, secondRestored]
                .map(\.canonicalFileURL)
            coldOpenRestoredProjectURLs = [firstProject, secondProject]
                .map(\.canonicalFileURL)
        } catch {
            coldOpenSetupError = error.localizedDescription
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func prepareSelectionScrollFixture() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fastra-selftest-selectionscroll-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let document = directory.appendingPathComponent("wiederhergestellt.md")
            try Data(selectionScrollContent().utf8).write(to: document)
            SessionStateStore.save(
                RestorableSessionState(windows: [
                    RestorableWindowState(
                        projectPath: nil,
                        documentPaths: [document.path],
                        activeDocumentPath: document.path,
                        frame: nil
                    ),
                ]),
                to: workspaceDefaults()
            )
            workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
            selectionScrollFixtureDirectory = directory
            selectionScrollFixtureURL = document
        } catch {
            selectionScrollSetupError = error.localizedDescription
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func selectionScrollContent() -> String {
        (1...2_200).map { line in
            // Stark wechselnde Absatzlängen zwingen das faule Layout, seine
            // Höhenschätzungen weit unten im Dokument laufend zu korrigieren.
            let repeats = line.isMultiple(of: 7)
                ? 30
                : (line.isMultiple(of: 3) ? 8 : 2)
            let tail = String(
                repeating: " langer Markdown-Absatz mit mehreren Woertern",
                count: repeats
            )
            return "Auswahlzeile \(line)\(tail)"
        }.joined(separator: "\n")
    }

    /// UserDefaults für den Workspace des laufenden Prozesses.
    ///
    /// Normalbetrieb: die echten App-Defaults (`.standard`).
    /// Selbsttest-Lauf: eine eigene Suite, die bei JEDEM Lauf frisch
    /// geleert wird. Zwei Gründe:
    /// 1. Determinismus — jeder Selbsttest startet im selben Zustand
    ///    („erster Start": Demo-Tab + vorbelegtes Pattern), egal wie oft
    ///    er vorher lief.
    /// 2. Keine Nebenwirkung — ein Selbsttest darf NICHT das echte
    ///    Erststart-Flag der App verbrauchen, sonst sieht der Nutzer das
    ///    Demo beim ersten richtigen Start nie.
    ///
    /// VERBINDLICH für `@AppStorage`: JEDE Deklaration muss diese Suite
    /// ausdrücklich als `store:` mitgeben. Ohne `store:` liest SwiftUI
    /// `UserDefaults.standard`, also die ECHTEN Einstellungen des Nutzers —
    /// die Isolierung oben greift für diesen Schlüssel dann nicht. Realer
    /// Befund 2026-07-27: ein im normalen Betrieb ausgeblendetes
    /// `editor.sidebarVisible = false` ließ den Selbsttest-Prozess die
    /// komplette Seitenleiste gar nicht erst aufbauen; `gitstagefolder` und
    /// `gitpushbutton` fielen dadurch reproduzierbar aus — ohne jeden
    /// Produktfehler. `AppStorageIsolationTests` hält die Regel fest.
    static func workspaceDefaults() -> UserDefaults {
        guard isSelfTestRun else { return .standard }
        if let cachedWorkspaceDefaults { return cachedWorkspaceDefaults }
        let suiteName = "io.github.fastra.selftest"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        cachedWorkspaceDefaults = defaults
        return defaults
    }

    /// Startet den passenden Test, falls einer angefordert ist (siehe
    /// `requestedTest`). Fensterbasierte Tests WARTEN per Polling auf ihr
    /// Fenster, statt nach fixer Frist zu guarden — der erste SwiftUI-
    /// Render eines Debug-Builds kann mehrere Sekunden dauern, und die
    /// Tests sollen die Funktion messen, nicht die Startzeit.
    static func runIfRequested() {
        // Veraltete Aufrufform `--selftest-…` zuerst abfangen: das
        // positionale Argument unterdrückt das Hauptfenster (siehe
        // `requestedTest`-Doku) — sofort klar FAILen statt den Aufrufer
        // in einen verwirrenden Fenster-Timeout laufen zu lassen.
        if let legacy = CommandLine.arguments.first(where: { $0.hasPrefix("--selftest-") }) {
            let name = String(legacy.dropFirst("--selftest-".count))
            testLabel = name
            finish(false, "veraltete Aufrufform \(legacy) — positionale Argumente "
                + "unterdrücken das SwiftUI-Hauptfenster. Neu: `-selftest \(name)` "
                + "oder Umgebungsvariable FASTRA_SELFTEST=\(name)")
        }
        guard let name = requestedTest else { return }
        testLabel = name
        switch name {
        case "findbar":   waitForMainWindow { runFindBarTest() }
        case "newwindow": waitForMainWindow { runNewWindowTest() }
        case "welcomenew": waitForMainWindow { runWelcomeNewTabTest() }
        case "sessionrestore": waitForMainWindow { runSessionRestoreTest() }
        case "coldopen": waitForMainWindow { runColdOpenTest(restoreEnabled: true) }
        case "coldopenoff": waitForMainWindow { runColdOpenTest(restoreEnabled: false) }
        case "multisearch": waitForMainWindow { runMultiWindowSearchJumpTest() }
        case "cmdw":      waitForMainWindow { openSearchThen { runCmdWTest() } }
        case "fields":    waitForMainWindow { openSearchThen { runFieldsTest() } }
        case "searchoptions": waitForMainWindow { openSearchThen { runSearchOptionsTest() } }
        case "projectinput": waitForMainWindow { openSearchThen { runProjectInputTest() } }
        case "tabswitch": waitForMainWindow { runTabSwitchTest() }
        case "tabclosehit": waitForMainWindow { runTabCloseHitTest() }
        case "tabcompare": waitForMainWindow { runTabComparisonTest() }
        case "softwrapprofiles": waitForMainWindow { runSoftWrapProfilesTest() }
        case "softwrapmodes": waitForMainWindow { runSoftWrapModesTest() }
        case "softwrapanchor": waitForMainWindow { runSoftWrapAnchorTest() }
        case "selectionscroll": waitForMainWindow { runSelectionScrollTest() }
        case "highlight": waitForMainWindow { runHighlightTest() }
        case "highlight4d": waitForMainWindow { runFourDHighlightTest() }
        case "completion4d": waitForMainWindow { runFourDCompletionTest() }
        case "xpath": waitForMainWindow { runXPathTest() }
        case "leakscenario": waitForMainWindow { runLeakScenario() }
        case "previewrender": waitForMainWindow { runPreviewRenderTest() }
        case "markdown":  waitForMainWindow { runMarkdownRenderTest() }
        case "markdownblanklines": waitForMainWindow { runMarkdownVisibleBlankLinesTest() }
        case "markdownjump": waitForMainWindow { runMarkdownJumpTest() }
        case "markdownappearance": waitForMainWindow { runMarkdownAppearanceTest() }
        case "jump":      waitForMainWindow { runJumpTest() }
        case "ghosttext": waitForMainWindow { runGhostTextTest() }
        case "wordclick": waitForMainWindow { runWordDoubleClickTest() }
        case "rightedge": waitForMainWindow { runRightEdgeClickTest() }
        case "selshort": waitForMainWindow { runShortSelectionScrollTest() }
        case "dragscroll": waitForMainWindow { runDragScrollTest() }
        case "dirtyundo": waitForMainWindow { runDirtyUndoTest() }
        case "emojisplit": waitForMainWindow { runEmojiSplitTest() }
        case "emojipaste": waitForMainWindow { runEmojiPasteTest() }
        case "emojipreview": waitForMainWindow { runEmojiPreviewTest() }
        case "tabscroll": waitForMainWindow { runTabScrollTest() }
        case "typescroll": waitForMainWindow { runTypeScrollTest() }
        case "emojishot": waitForMainWindow { runEmojiShot() }
        case "comment4d": waitForMainWindow { runFourDCommentEditTest() }
        case "sighelp4d": waitForMainWindow { runFourDSignatureHelpTest() }
        case "sighelpshot": waitForMainWindow { runFourDSignatureHelpShot() }
        case "replaceall": waitForMainWindow { runReplaceAllTest() }
        case "pilldrop":  waitForMainWindow { openSearchThen { runPillDropTest() } }
        case "navmatch":  waitForMainWindow { openSearchThen { runNavMatchTest() } }
        case "scrolljump": waitForMainWindow { runScrollJumpTest() }
        case "hscroll":   waitForMainWindow { runHScrollTest() }
        case "crjump":    waitForMainWindow { runCRJumpTest() }
        case "textop":    waitForMainWindow { runTextOpTest() }
        case "joinundo":  waitForMainWindow { runJoinUndoTest() }
        case "colsel":    waitForMainWindow { runColumnSelectionTest() }
        case "colselwrap": waitForMainWindow { runWrappedColumnSelectionTest() }
        case "colpaste":  waitForMainWindow { runColumnPasteTest() }
        case "gutterdim": waitForMainWindow { runGutterDimmingTest() }
        case "sidebarheader": waitForMainWindow { runSidebarHeaderTest() }
        case "sidebarfilter": waitForMainWindow { runSidebarFilterTest() }
        case "filediff": waitForMainWindow { runFileDiffTest() }
        case "tool4dhint": waitForMainWindow { runTool4DHintTest() }
        case "tool4dlsp": DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            runTool4DLSPIntegrationTest()
        }
        case "gototarget": waitForMainWindow { runGoToTargetTest() }
        case "searchmark": waitForMainWindow { openSearchThen { runSearchMarkTest() } }
        case "help": waitForMainWindow { runHelpTest() }
        case "mdassist": waitForMainWindow { runMarkdownAssistTest() }
        case "filemodes":
            // Fensterlos — echte Dateien durch den Workspace-Ladepfad routen:
            // Null-Bytes → Hex, große Textdatei → abschnittsweise.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { runFileModesTest() }
        case "search":
            // Fensterlos — braucht nur Workspace + SearchRunner. Die
            // Engine ist nach fixer Anlaufzeit sicher initialisiert.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { runSearchTest() }
        case "project":
            // Fensterlos — Projekt- & Git-Ausbau Etappe 1 (Willkommen-
            // Bedingung, Projekt öffnen, Dateibaum, Repo-Erkennung).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { runProjectTest() }
        case "projectperf":
            // Bewusst nicht in ALL_TESTS: benötigt einen ausdrücklich per
            // FASTRA_PROJECT_PERF_ROOT übergebenen, nur gelesenen Realbestand.
            DispatchQueue.global(qos: .userInitiated).async {
                runProjectPerformanceTest()
            }
        case "projectopenperf":
            // Separater echter Workspace-/Editor-Ladepfad für folders.json;
            // bleibt getrennt von der Suchmessung, damit Ursachen nicht
            // vermischt werden.
            waitForMainWindow { runProjectOpenPerformanceTest() }
        case "markdownimport":
            // Fensterlos — echte Umwandlung über das installierte
            // `poormans-text`: Formatkatalog, flache Datei, Ordner mit Bildern
            // und Kollisionsschutz an echten Dateien.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { runMarkdownImportTest() }
        case "localization":
            // Fensterlos — prüft zusätzlich zum Unit-Test das fertig gepackte
            // Haupt-App-Bundle. Genau dort sucht SwiftUI statische Schlüssel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { runLocalizationTest() }
        case "updates":
            // Fensterlos — prüft die echte App-Menüleiste erst nach SwiftUIs
            // spätem Menü-Wiederaufbau sowie Sparkles Bundle-Konfiguration.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { runUpdatesTest() }
        case "git":
            // Fensterlos — Git-Status end-to-end (Etappe 2): echtes Temp-Repo,
            // Datei-Zustände, Branch, Ordner-Rollup, dialogfreie git-Auflösung.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { runGitTest() }
        case "gitactions":
            // Fensterlos — kuratierte Git-Aktionen end-to-end mit bare-Remote
            // (Push/Pull-FF/Amend/Switch/Pickaxe), Etappe 2 Schritt 4.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { runGitActionsTest() }
        case "gitstagefolder":
            // Echter Fensterklick auf den Hover-Knopf einer von Git
            // zusammengefassten unversionierten Ordnerzeile.
            waitForMainWindow { runGitStageFolderTest() }
        case "gitpushbutton":
            // Echter Fensterklick auf den transparent beschrifteten Push-Knopf:
            // erster Config-Remote statt alphabetischem `github`.
            waitForMainWindow { runGitPushButtonTest() }
        case "openscope":
            // Fensterlos — Such-Scope „Geöffnet" end-to-end über Workspace +
            // SearchRunner (Multi-Tab-Suche + Alle-ersetzen über alle Tabs).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { runOpenScopeTest() }
        case "selsearch":
            // Fensterlos — „Nur in Auswahl" (K3) end-to-end über Workspace +
            // SearchRunner (eingefrorene Selektions-Range begrenzt die Suche).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { runSelSearchTest() }
        case "wildcard":
            // Fensterlos — Platzhalter-Suche `*` (Feature J) end-to-end über
            // Workspace + SearchRunner (RegEx aus, Mini-Schalter wechselt
            // Platzhalter ⇄ literal).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { runWildcardTest() }
        case "loadperf":
            // Fensterlos — misst Main-Runloop-Blockierung während asynchronem
            // Datei-Laden. Testdatei-Pfad via Env FASTRA_LOADPERF_FILE.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { runLoadPerfTest() }
        case "contrast":  waitForMainWindow { runContrastTest() }
        case "wildcardshot":
            // Diagnose (kein PASS/FAIL-Funktionstest): bringt den Suchdialog in
            // den Platzhalter-Zustand (Pillen + Inline-Live-Vorschau, Feature J)
            // und hält ihn offen, damit ein fenstergezielter Screenshot
            // (`screencapture -l <nr>`) die neuen Oberflächen festhalten kann.
            waitForMainWindow { openSearchThen { runWildcardShot() } }
        case "searchshot":
            // Diagnose wie `wildcardshot`, aber mit LEEREN Feldern — für
            // Screenshots der Suchmaske im Ausgangszustand (z.B. Placeholder).
            waitForMainWindow { openSearchThen { runSearchShot() } }
        case "regexshot":
            // Diagnose wie `wildcardshot`, aber im RegEx-Modus — gefüllte
            // Felder mit Capture Groups und Token-Highlighting, für
            // README-Screenshots des RegEx-Zustands.
            waitForMainWindow { openSearchThen { runRegexShot() } }
        case "welcomeshot":
            // Diagnose: Willkommensbildschirm mit gefüllter Projektliste
            // fürs fenstergezielte Capture (Projekt- & Git-Ausbau, Etappe 1).
            waitForMainWindow { runWelcomeShot() }
        case "projectshot":
            // Diagnose: Projekt-Dateibaum in der Seitenleiste + geladene
            // Datei fürs fenstergezielte Capture.
            waitForMainWindow { runProjectShot() }
        case "aboutshot":
            // Diagnose: Über-Dialog für die visuelle Kontrolle von Icon,
            // Wortmarke, Version und Textabständen.
            waitForMainWindow {
                Task { @MainActor in runAboutShot() }
            }
        case "markdownshot":
            // Diagnose: Markdown-Datei mit integrierter Rich-Text-Vorschau.
            // Dient der visuellen Kontrolle von Chrome, Splitter und Typografie.
            waitForMainWindow { runMarkdownShot() }
        case "gitshot":
            // Diagnose: Git-Seitenleiste (Branch-Zeile + eingefärbte Dateien)
            // mit echtem Repo fürs fenstergezielte Capture (Etappe 2).
            waitForMainWindow { runGitShot() }
        case "graphshot":
            // Diagnose: Git-Graph-Seitenleiste (Multi-Lane-Verzweigung + Merge)
            // mit echtem Branch/Merge-Repo fürs fenstergezielte Capture (Phase 3).
            // Setzt FASTRA_SIDEBAR=graph voraus (Seitenleisten-Vorwahl).
            waitForMainWindow { runGraphShot() }
        case "windows":   DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { runWindowsDump() }
        default:
            finish(false, "unbekannter Selbsttest-Name \"\(name)\" "
                + "(bekannt: findbar, newwindow, welcomenew, sessionrestore, coldopen, coldopenoff, cmdw, fields, searchoptions, projectinput, tabswitch, tabclosehit, tabcompare, highlight, highlight4d, completion4d, previewrender, xpath, markdown, jump, ghosttext, wordclick, rightedge, selshort, dragscroll, dirtyundo, emojisplit, emojipaste, emojipreview, tabscroll, typescroll, comment4d, sighelp4d, replaceall, pilldrop, navmatch, search, project, projectperf, projectopenperf, localization, updates, git, gitactions, gitstagefolder, gitpushbutton, filemodes, selsearch, wildcard, textop, joinundo, colsel, colselwrap, colpaste, gutterdim, sidebarheader, searchmark, tool4dhint, tool4dlsp, help, mdassist, contrast, windows)")
        }
    }

    private static func runUpdatesTest() {
        testLabel = "updates"
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let item = appMenu.items.first(where: {
                  $0.identifier == NSUserInterfaceItemIdentifier("Fastra.CheckForUpdates")
              }) else {
            finish(false, "Sparkle-Menüpunkt fehlt im echten App-Menü")
        }
        guard item.action == #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
              item.target is SPUStandardUpdaterController else {
            finish(false, "Update-Menüpunkt zielt nicht direkt auf Sparkle")
        }

        let info = Bundle.main.infoDictionary ?? [:]
        guard info["SUFeedURL"] as? String
                == "https://danielmuellerir.github.io/fastra/appcast.xml",
              (info["SUPublicEDKey"] as? String)?.isEmpty == false,
              info["SUEnableAutomaticChecks"] as? Bool == true,
              info["SUAutomaticallyUpdate"] as? Bool == false,
              info["SUAllowsAutomaticUpdates"] as? Bool == false,
              info["SUEnableSystemProfiling"] as? Bool == false,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true else {
            finish(false, "Sparkle-Sicherheitskonfiguration im App-Bundle unvollständig")
        }
        finish(true, "Menüpunkt zielt auf Sparkle; Feed, Signatur und Datenschutz sind konfiguriert")
    }

    // MARK: - Fenster-Polling (statt fixem Start-Guard)

    /// Pollt (max. ~15 s, 50-ms-Takt), bis ein SICHTBARES Hauptfenster
    /// existiert, lässt die UI dann 0,5 s setteln und ruft `body`.
    /// Erscheint binnen 15 s keines → FAIL mit Fenster-Dump (das ist dann
    /// ein echter Befund, kein Timing-Artefakt mehr).
    private static func waitForMainWindow(tick: Int = 0, then body: @escaping () -> Void) {
        let maxTicks = 300           // 300 × 50 ms = 15 s
        let found = NSApp.windows.contains {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }
        if found {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { body() }
            return
        }
        if tick >= maxTicks {
            finish(false, "kein sichtbares Hauptfenster binnen 15 s — \(windowsSummary())")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitForMainWindow(tick: tick + 1, then: body)
        }
    }

    /// Einige Editor-Selbsttests brauchen bewusst ein echtes leeres Dokument.
    /// Seit der neue Startzustand den Willkommen-Tab zeigt, ist das Fenster
    /// bereits sichtbar, während CodeEditSourceEditor noch gar nicht montiert
    /// ist. Diese Tests wandeln deshalb nur ihren eigenen Willkommen-Tab um und
    /// warten anschließend auf die echte TextView statt eine feste Pause zu
    /// raten. Screenshot- und Willkommen-Tests verwenden diesen Helfer nicht.
    private static func waitForEditor(
        workspace: Workspace,
        window: NSWindow,
        tick: Int = 0,
        then body: @escaping (NSView, TextView) -> Void
    ) {
        guard let root = window.contentView else {
            finish(false, "Hauptfenster ohne contentView")
        }
        if workspace.isWelcomeScreen {
            workspace.dismissWelcomeTab()
        }
        if let editor = editorTextView(in: root) as? TextView {
            body(root, editor)
            return
        }
        if tick >= 100 {
            finish(false, "Editor nach Schließen des Willkommen-Tabs nicht binnen 5 s montiert")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitForEditor(workspace: workspace, window: window,
                          tick: tick + 1, then: body)
        }
    }

    /// Öffnet die Suchmaske (exakt wie CMD+F) und wartet, bis sie sichtbar
    /// ist, dann `body`. Nötig, seit `showSearchDialog` per Default `false`
    /// startet (die Maske öffnet NICHT mehr automatisch beim Start). Vorher
    /// muss das Hauptfenster da sein (ContentView appeared → onReceive aktiv),
    /// deshalb wird dieser Helfer aus `waitForMainWindow { … }` heraus gerufen
    /// — gleiches Muster wie der contrast-Test.
    private static func openSearchThen(_ body: @escaping () -> Void) {
        NotificationCenter.default.post(name: .fastraShowSearchFile, object: nil)
        waitForSearchWindow(then: body)
    }

    /// Wie `waitForMainWindow`, aber für die Suchmaske. Sie öffnet seit
    /// 2026-06-22 NICHT mehr automatisch beim Start (`showSearchDialog`
    /// startet `false`) — die Aufrufer (cmdw/fields) öffnen sie vorher selbst
    /// über `openSearchThen` (postet `.fastraShowSearchFile`).
    private static func waitForSearchWindow(tick: Int = 0, then body: @escaping () -> Void) {
        let maxTicks = 300           // 300 × 50 ms = 15 s
        let found = NSApp.windows.contains {
            $0.frameAutosaveName == SearchWindow.frameAutosaveName && $0.isVisible
        }
        if found {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { body() }
            return
        }
        if tick >= maxTicks {
            finish(false, "keine sichtbare Suchmaske binnen 15 s — \(windowsSummary())")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitForSearchWindow(tick: tick + 1, then: body)
        }
    }

    /// Eine Zeile pro Fenster — für FAIL-Diagnosen der Polling-Helfer.
    private static func windowsSummary() -> String {
        if NSApp.windows.isEmpty { return "NSApp.windows ist LEER" }
        return NSApp.windows.map {
            "[\(type(of: $0))] title=\"\($0.title)\" autosave=\"\($0.frameAutosaveName)\" "
            + "visible=\($0.isVisible) contentView=\($0.contentView != nil)"
        }.joined(separator: " · ")
    }

    /// Diagnose (`-selftest windows`): dumpt alle Fenster alle 0,5 s, bis
    /// ein sichtbares Hauptfenster auftaucht (→ PASS mit Zeitangabe) oder
    /// ~10 s um sind (→ FAIL mit letztem Dump). Kein Funktionstest — ein
    /// Messinstrument (führte 2026-06-11 zum Root Cause des
    /// „kein Hauptfenster"-Bugs).
    private static func runWindowsDump(tick: Int = 0) {
        testLabel = "windows"
        let maxTicks = 20            // 20 × 0,5 s = 10 s Beobachtungsfenster
        var lines: [String] = []
        var foundMain = false
        for w in NSApp.windows {
            let isMain = w.frameAutosaveName != SearchWindow.frameAutosaveName
                && w.contentView != nil && w.isVisible
            if isMain { foundMain = true }
            lines.append("  [\(type(of: w))] title=\"\(w.title)\" autosave=\"\(w.frameAutosaveName)\" visible=\(w.isVisible) key=\(w.isKeyWindow) contentView=\(w.contentView != nil) frame=\(w.frame)")
        }
        let dump = "t=\(Double(tick) * 0.5)s windows=\(NSApp.windows.count)\n" + lines.joined(separator: "\n")
        FileHandle.standardError.write(Data("WINDOWDUMP \(dump)\n".utf8))
        if foundMain {
            finish(true, "sichtbares Hauptfenster nach \(Double(tick) * 0.5)s")
        }
        if tick >= maxTicks {
            finish(false, "kein sichtbares Hauptfenster binnen 10 s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            runWindowsDump(tick: tick + 1)
        }
    }

    // MARK: - ⌘N / unabhängiges Dokumentfenster

    /// Führt den ECHTEN Menüpunkt mit ⌘N aus und prüft danach zwei Dinge, die
    /// ein reiner Unit-Test nicht sehen kann: Es erscheint ein zweites Fenster,
    /// und dessen neuer Workspace teilt seinen Inhalt nicht mit dem ersten.
    private static func runNewWindowTest() {
        guard let original = Workspace.shared else {
            finish(false, "kein aktiver Ausgangs-Workspace")
        }
        // Im reinen Willkommenszustand wirkt ⌘N inzwischen bewusst wie ⌘T
        // (Wunschpaket 2026-07 Etappe 1, eigener Selbsttest `welcomenew`).
        // Für den Fenster-Test daher zuerst einen normalen Editor-Tab
        // öffnen — danach ist ⌘N wieder das Fenster-Kommando.
        if original.isWelcomeScreen { original.openNewTab() }
        guard let originalID = original.activeTabID,
              let originalIndex = original.tabs.firstIndex(where: { $0.id == originalID }) else {
            finish(false, "kein aktiver Ausgangs-Workspace")
        }

        let marker = "Inhalt nur im ersten Fenster"
        original.tabs[originalIndex].content = marker

        guard let mainMenu = NSApp.mainMenu,
              menuItem(forKeyEquivalent: "n", in: mainMenu) != nil else {
            finish(false, "kein Menüpunkt mit ⌘N gefunden")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName && $0.isVisible
        }) else {
            finish(false, "kein Ausgangsfenster für ⌘N gefunden")
        }
        mainWindow.makeKeyAndOrderFront(nil)

        // Eine absichtlich kleinere, aber weiterhin unterstützte Größe macht
        // den Fehler sichtbar: Der Test liest später den echten NSWindow-
        // Rahmen des neuen Fensters, nicht die gemeinsame Berechnungsfunktion.
        let requestedSize = NSSize(
            width: MainWindowSizing.minimumWidth + 153,
            height: MainWindowSizing.minimumHeight + 157
        )
        mainWindow.setFrame(
            NSRect(origin: mainWindow.frame.origin, size: requestedSize),
            display: true
        )
        let expectedSize = mainWindow.frame.size
        postCmd("n", keyCode: 45, windowNumber: mainWindow.windowNumber)
        pollForNewWindow(
            original: original,
            originalWindow: mainWindow,
            marker: marker,
            expectedSize: expectedSize
        )
    }

    /// ⌘N im reinen Willkommenszustand (Wunschpaket 2026-07, Etappe 1): Es
    /// darf KEIN zweites Fenster entstehen; dasselbe Fenster bekommt wie bei
    /// ⌘T einen normalen Editor-Tab NEBEN dem erhaltenen Willkommen-Tab.
    private static func runWelcomeNewTabTest() {
        guard let ws = Workspace.shared else {
            finish(false, "kein aktiver Workspace")
        }
        guard ws.isWelcomeScreen, ws.tabs.count == 1 else {
            finish(false, "Ausgangszustand ist nicht der reine Willkommenszustand")
        }
        guard let mainMenu = NSApp.mainMenu,
              menuItem(forKeyEquivalent: "n", in: mainMenu) != nil else {
            finish(false, "kein Menüpunkt mit ⌘N gefunden")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName && $0.isVisible
        }) else {
            finish(false, "kein Ausgangsfenster für ⌘N gefunden")
        }
        mainWindow.makeKeyAndOrderFront(nil)
        // Selbsttests laufen auf dem Main-Thread; die Fensterzählung ist
        // MainActor-isoliert → Isolierung explizit übernehmen.
        let windowsBefore = MainActor.assumeIsolated {
            DocumentWindowController.visibleDocumentWindowCount()
        }
        postCmd("n", keyCode: 45, windowNumber: mainWindow.windowNumber)
        pollForWelcomeNewTab(ws: ws, windowsBefore: windowsBefore)
    }

    private static func pollForWelcomeNewTab(ws: Workspace, windowsBefore: Int,
                                             tick: Int = 0) {
        if ws.tabs.count == 2 {
            let windowsNow = MainActor.assumeIsolated {
                DocumentWindowController.visibleDocumentWindowCount()
            }
            guard windowsNow == windowsBefore else {
                finish(false, "⌘N im Willkommenszustand öffnete trotzdem ein zweites Fenster")
            }
            guard let active = ws.activeTab, !active.isWelcome,
                  active.content.isEmpty else {
                finish(false, "⌘N aktivierte keinen neuen leeren Editor-Tab")
            }
            guard ws.tabs.contains(where: { $0.isWelcome }) else {
                finish(false, "der Willkommen-Tab muss daneben erhalten bleiben")
            }
            finish(true, "⌘N wirkt im reinen Willkommenszustand wie ⌘T")
        }
        if tick >= 100 {
            finish(false, "⌘N legte binnen 5 s keinen zweiten Tab an — \(windowsSummary())")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollForWelcomeNewTab(ws: ws, windowsBefore: windowsBefore, tick: tick + 1)
        }
    }

    // MARK: - Sichere Sitzungswiederherstellung

    private static func runSessionRestoreTest(tick: Int = 0) {
        testLabel = "sessionrestore"
        if let sessionRestoreSetupError {
            finish(false, "Fixture konnte nicht angelegt werden: \(sessionRestoreSetupError)")
        }
        guard let directory = sessionRestoreFixtureDirectory else {
            finish(false, "Fixture-Verzeichnis fehlt")
        }

        let windows = MainActor.assumeIsolated {
            DocumentWindowController.visibleDocumentWindows()
        }
        let workspaces = windows.compactMap {
            WorkspaceWindowRegistry.workspace(for: $0)
        }
        let loading = workspaces.contains { workspace in
            workspace.tabs.contains(where: \.isLoading)
        }
        if windows.count == 2, workspaces.count == 2, !loading {
            let namesByWindow = workspaces.map {
                $0.tabs.compactMap(\.url).map(\.lastPathComponent)
            }
            guard namesByWindow.contains(["eins.txt", "zwei.txt"]),
                  namesByWindow.contains(["drei.txt"]) else {
                try? FileManager.default.removeItem(at: directory)
                finish(false, "falsche wiederhergestellte Tabs: \(namesByWindow)")
            }
            guard let projectWorkspace = workspaces.first(where: {
                $0.projectURL?.canonicalFileURL == directory.canonicalFileURL
            }),
                  projectWorkspace.activeTab?.url?.lastPathComponent == "eins.txt" else {
                try? FileManager.default.removeItem(at: directory)
                finish(false, "Projekt oder aktiver Tab wurde nicht wiederhergestellt")
            }
            guard workspaces.allSatisfy({
                $0.tabs.allSatisfy { $0.url != nil }
            }) else {
                try? FileManager.default.removeItem(at: directory)
                finish(false, "ein unbenannter Tab wurde fälschlich wiederhergestellt")
            }
            try? FileManager.default.removeItem(at: directory)
            finish(true, "zwei Fenster, drei gespeicherte Tabs, Projekt und aktiver Tab wiederhergestellt")
        }
        if tick >= 200 {
            try? FileManager.default.removeItem(at: directory)
            finish(false, "Sitzung nicht binnen 10 s vollständig — \(windowsSummary())")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            runSessionRestoreTest(tick: tick + 1)
        }
    }

    /// Prüft den echten LaunchServices-Kaltstart mit einer gespeicherten Sitzung
    /// aus zwei Projektfenstern und einer zusätzlichen externen Datei. Bei
    /// aktivierter Wiederherstellung müssen alle drei Startabsichten erhalten
    /// bleiben; bei deaktivierter darf ausschließlich die Finder-Datei öffnen.
    private static func runColdOpenTest(
        restoreEnabled: Bool, tick: Int = 0
    ) {
        testLabel = restoreEnabled ? "coldopen" : "coldopenoff"
        if let coldOpenSetupError {
            finish(false, "Fixture konnte nicht angelegt werden: \(coldOpenSetupError)")
        }
        guard let externalURL = coldOpenExternalURL,
              coldOpenRestoredURLs.count == 2,
              coldOpenRestoredProjectURLs.count == 2 else {
            finish(false, "Kaltstart-Fixture fehlt")
        }

        let windows = MainActor.assumeIsolated {
            DocumentWindowController.visibleDocumentWindows()
        }
        let workspaces = windows.compactMap {
            WorkspaceWindowRegistry.workspace(for: $0)
        }
        let openedURLs = workspaces.flatMap { workspace in
            workspace.tabs.compactMap(\.url).map(\.canonicalFileURL)
        }
        let stillLoading = workspaces.contains { workspace in
            workspace.tabs.contains(where: \.isLoading)
        }
        let expectedURLs = restoreEnabled
            ? Set(coldOpenRestoredURLs + [externalURL])
            : Set([externalURL])
        let externalWorkspace = workspaces.first { workspace in
            workspace.tabs.contains {
                $0.url?.canonicalFileURL == externalURL
            }
        }
        let restoredProjectsArePresent = coldOpenRestoredProjectURLs.allSatisfy {
            projectURL in
            workspaces.contains {
                $0.projectURL?.canonicalFileURL == projectURL
            }
        }
        let expectedWindowCount = restoreEnabled ? 3 : 1
        let expectedState = windows.count == expectedWindowCount
            && workspaces.count == expectedWindowCount
            && !stillLoading
            && openedURLs.count == expectedURLs.count
            && Set(openedURLs) == expectedURLs
            && externalWorkspace?.activeTab?.url?.canonicalFileURL == externalURL
            && workspaces.allSatisfy { workspace in
                workspace.tabs.allSatisfy { !$0.isWelcome }
            }
            && (restoreEnabled
                ? restoredProjectsArePresent
                : !openedURLs.contains(where: coldOpenRestoredURLs.contains))

        // Einen ganzen weiteren Main-Runloop-Abschnitt beobachten, damit weder
        // ein verspäteter Restore noch ein verspätetes Finder-Routing nach dem
        // ersten scheinbar korrekten Zustand unbemerkt bleibt.
        if expectedState, tick >= 20 {
            cleanupColdOpenFixture()
            finish(
                true,
                restoreEnabled
                    ? "zwei Projektfenster wiederhergestellt; Finder-Datei zusätzlich geöffnet"
                    : "Wiederherstellung aus; ausschließlich Finder-Datei geöffnet"
            )
        }
        if tick >= 200 {
            cleanupColdOpenFixture()
            let names = openedURLs.map(\.lastPathComponent)
            finish(false, "Kaltstartzustand nicht binnen 10 s vollständig "
                + "(Restore: \(restoreEnabled), Dateien: \(names)) — \(windowsSummary())")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            runColdOpenTest(
                restoreEnabled: restoreEnabled, tick: tick + 1
            )
        }
    }

    private static func cleanupColdOpenFixture() {
        if let coldOpenFixtureDirectory {
            try? FileManager.default.removeItem(at: coldOpenFixtureDirectory)
        }
    }

    private static func pollForNewWindow(
        original: Workspace,
        originalWindow: NSWindow,
        marker: String,
        expectedSize: NSSize,
        tick: Int = 0
    ) {
        let newWorkspace = Workspace.allLive.first { $0 !== original }
        let newWindow = NSApp.windows.first {
            $0.identifier?.rawValue == "Fastra.DocumentWindow" && $0.isVisible
        }

        if let newWorkspace, let newWindow {
            guard newWorkspace.tabs.count == 1,
                  let newTab = newWorkspace.activeTab,
                  newTab.title == Workspace.untitledBaseName,
                  newTab.content.isEmpty else {
                finish(false, "zweites Fenster enthält kein einzelnes leeres neues Dokument")
            }
            // „Nie mehr als ein Willkommen" (Daniel-Befund 2026-07-12): Ein
            // per ⌘N geöffnetes Fenster muss direkt den Editor zeigen, NICHT
            // erneut die Willkommensseite — sonst ließen sich beliebig viele
            // Willkommens-Fenster stapeln.
            guard !newWorkspace.isWelcomeScreen else {
                finish(false, "⌘N-Fenster zeigt erneut den Willkommensbildschirm")
            }

            // Das ist die sichtbare Produktwirkung: Das neue AppKit-Fenster
            // muss denselben tatsächlichen Rahmen wie das zuvor benutzte
            // Fenster haben. SwiftUI darf seine fitting size im ersten Layout
            // noch kurz melden; wir warten deshalb auf den stabilen Rahmen,
            // statt genau in diesem Übergang voreilig fehlzuschlagen.
            let hasExpectedSize = abs(newWindow.frame.width - expectedSize.width) < 0.5
                && abs(newWindow.frame.height - expectedSize.height) < 0.5
            if !hasExpectedSize {
                if tick >= 100 {
                    finish(false, "⌘N-Fenster übernimmt Größe nicht "
                        + "(erwartet \(expectedSize.width)×\(expectedSize.height), "
                        + "erhalten \(newWindow.frame.width)×\(newWindow.frame.height))")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    pollForNewWindow(
                        original: original,
                        originalWindow: originalWindow,
                        marker: marker,
                        expectedSize: expectedSize,
                        tick: tick + 1
                    )
                }
                return
            }

            // Nicht bloß den Modellzustand prüfen: Direkt nach dem echten ⌘N
            // muss die echte CodeEdit-TextView First Responder sein und einen
            // gültigen Einfügepunkt besitzen. Erst dann kann ein sofortiges
            // Tippen oder ⌘V im neuen Dokument landen.
            pollForNewWindowEditorFocus(
                original: original,
                originalWindow: originalWindow,
                marker: marker,
                newWorkspace: newWorkspace,
                newWindow: newWindow
            )
            return
        }

        if tick >= 100 {
            finish(false, "kein zweites Dokumentfenster binnen 5 s — \(windowsSummary())")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollForNewWindow(
                original: original,
                originalWindow: originalWindow,
                marker: marker,
                expectedSize: expectedSize,
                tick: tick + 1
            )
        }
    }

    private static func pollForNewWindowEditorFocus(
        original: Workspace,
        originalWindow: NSWindow,
        marker: String,
        newWorkspace: Workspace,
        newWindow: NSWindow,
        tick: Int = 0
    ) {
        let editor = newWindow.contentView.flatMap { editorTextView(in: $0) as? TextView }
        if newWindow.isKeyWindow, let editor,
           newWindow.firstResponder === editor,
           editor.selectionManager.textSelections.map(\.range) == [NSRange(location: 0, length: 0)] {
            newWorkspace.activeTabContent.wrappedValue = "Inhalt nur im zweiten Fenster"
            guard original.activeTab?.content == marker else {
                finish(false, "Dokumentinhalt wird zwischen den Fenstern geteilt")
            }
            guard Workspace.shared === newWorkspace else {
                finish(false, "neues Fenster ist sichtbar, aber nicht aktiver Workspace")
            }

            // Fokus zurück ins erste Fenster und dort den ECHTEN ⌘T-Shortcut
            // auslösen. So prüft der Test zusätzlich, dass globale Commands
            // nach einem Fensterwechsel nicht weiter im zweiten Workspace
            // landen.
            guard originalWindow.isVisible else {
                finish(false, "erstes Dokumentfenster nach ⌘N nicht mehr sichtbar")
            }
            guard WorkspaceWindowRegistry.workspace(for: originalWindow) === original else {
                finish(false, "erstes Fenster ist keinem oder dem falschen Workspace zugeordnet")
            }
            let originalTabCount = original.tabs.count
            originalWindow.makeKeyAndOrderFront(nil)
            pollForOriginalWindowActivation(
                original: original,
                originalWindow: originalWindow,
                originalTabCount: originalTabCount,
                newWorkspace: newWorkspace,
                newWindow: newWindow
            )
            return
        }

        if tick >= 100 {
            if !newWindow.isKeyWindow {
                finish(false, "⌘N-Fenster wurde nie Key-Window (Umgebungsproblem)")
            }
            finish(false, "⌘N-Fenster hat keinen fokussierten Editor "
                + "(Editor=\(editor != nil), FirstResponder="
                + "\(String(describing: newWindow.firstResponder)), "
                + "Selektionen=\(editor?.selectionManager.textSelections.map(\.range) ?? []))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollForNewWindowEditorFocus(
                original: original,
                originalWindow: originalWindow,
                marker: marker,
                newWorkspace: newWorkspace,
                newWindow: newWindow,
                tick: tick + 1
            )
        }
    }

    /// Fensterfokus ist unter macOS kooperativ: Ein im Hintergrund gestarteter
    /// Testprozess darf `makeKeyAndOrderFront` verweigert bekommen. Der Runner
    /// aktiviert die App deshalb von außen; hier warten wir auf den echten
    /// Key-Status und trennen Umgebungsausfall vom Routing-Fehler.
    private static func pollForOriginalWindowActivation(
        original: Workspace,
        originalWindow: NSWindow,
        originalTabCount: Int,
        newWorkspace: Workspace,
        newWindow: NSWindow,
        tick: Int = 0
    ) {
        if originalWindow.isKeyWindow {
            guard Workspace.shared === original else {
                finish(false, "Fokus zurück ins erste Fenster aktiviert falschen Workspace")
            }
            postCmd("t", keyCode: 17, windowNumber: originalWindow.windowNumber)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard original.tabs.count == originalTabCount + 1,
                      newWorkspace.tabs.count == 1 else {
                    finish(false, "⌘T nach Fensterwechsel landete im falschen Workspace")
                }
                newWindow.makeKeyAndOrderFront(nil)
                pollForNewWindowReactivation(
                    original: original,
                    originalWindow: originalWindow,
                    newWorkspace: newWorkspace,
                    newWindow: newWindow
                )
            }
            return
        }
        if tick >= 100 {
            finish(false, "erstes Fenster wurde nie Key-Window (Umgebungsproblem, kein Routing-Fehler)")
        }
        if tick % 10 == 9 {
            NSApp.activate(ignoringOtherApps: true)
            originalWindow.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollForOriginalWindowActivation(
                original: original,
                originalWindow: originalWindow,
                originalTabCount: originalTabCount,
                newWorkspace: newWorkspace,
                newWindow: newWindow,
                tick: tick + 1
            )
        }
    }

    private static func pollForNewWindowReactivation(
        original: Workspace,
        originalWindow: NSWindow,
        newWorkspace: Workspace,
        newWindow: NSWindow,
        tick: Int = 0
    ) {
        if newWindow.isKeyWindow {
            guard Workspace.shared === newWorkspace else {
                finish(false, "Fokus zurück ins zweite Fenster aktiviert falschen Workspace")
            }
            guard let activeID = newWorkspace.activeTabID,
                  let activeIndex = newWorkspace.tabs.firstIndex(where: { $0.id == activeID }) else {
                finish(false, "zweites Fenster hat vor dem ⌘W-Test keinen aktiven Tab")
            }
            // Den letzten Tab sauber/leergeleert machen: ⌘W muss nun ohne
            // Dialog das GESAMTE zweite Fenster schließen.
            newWorkspace.tabs[activeIndex].content = ""
            newWorkspace.tabs[activeIndex].isDirty = false
            postCmd("w", keyCode: 13, windowNumber: newWindow.windowNumber)
            pollForLastTabWindowClose(
                original: original,
                originalWindow: originalWindow,
                closedWorkspace: newWorkspace,
                closedWindow: newWindow
            )
            return
        }
        if tick >= 100 {
            finish(false, "zweites Fenster wurde nie wieder Key-Window (Umgebungsproblem, kein Routing-Fehler)")
        }
        if tick % 10 == 9 {
            newWindow.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollForNewWindowReactivation(
                original: original,
                originalWindow: originalWindow,
                newWorkspace: newWorkspace,
                newWindow: newWindow,
                tick: tick + 1
            )
        }
    }

    private static func pollForLastTabWindowClose(
        original: Workspace,
        originalWindow: NSWindow,
        closedWorkspace: Workspace,
        closedWindow: NSWindow,
        tick: Int = 0
    ) {
        if !closedWindow.isVisible {
            guard closedWorkspace.tabs.isEmpty else {
                finish(false, "Fenster schloss, aber der letzte Tab blieb im Workspace")
            }
            guard originalWindow.isVisible else {
                finish(false, "⌘W auf dem Zweitfenster schloss auch das erste Fenster")
            }
            if Workspace.shared === original {
                finish(true, "⌘N/Fokus/⌘T korrekt; ⌘W schließt letzten Tab samt Fenster")
            }
        }
        if tick >= 100 {
            finish(false, "⌘W ließ ein Fenster ohne Tabs zurück oder aktivierte den falschen Workspace")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollForLastTabWindowClose(
                original: original,
                originalWindow: originalWindow,
                closedWorkspace: closedWorkspace,
                closedWindow: closedWindow,
                tick: tick + 1
            )
        }
    }

    // MARK: - unabhängige Suchdialoge in mehreren Dokumentfenstern

    /// Reproduziert den gemeldeten Befund mit zwei Dokumentfenstern und je einer
    /// eigenen Suchmaske: Ein Trefferklick im zweiten Suchdialog darf weder
    /// Selektion noch Scrollziel des ersten Editors verändern.
    private static func runMultiWindowSearchJumpTest() {
        testLabel = "multisearch"
        guard let firstWorkspace = Workspace.shared,
              let firstWindow = NSApp.windows.first(where: {
                  !SearchWindow.isSearchWindow($0)
                      && WorkspaceWindowRegistry.workspace(for: $0) === firstWorkspace
                      && $0.isVisible
              }) else {
            finish(false, "kein erstes Dokumentfenster mit Workspace-Zuordnung")
        }

        // `waitForMainWindow` ruft uns über DispatchQueue.main auf. Diese
        // explizite Grenze macht die Main-Actor-Garantie auch dem Compiler
        // sichtbar, ohne den allgemeinen Selbsttest-Dispatcher umzubauen.
        let secondWorkspace = MainActor.assumeIsolated {
            DocumentWindowController.openNewDocument(defaults: workspaceDefaults())
        }
        guard let secondWindow = NSApp.windows.first(where: {
            !SearchWindow.isSearchWindow($0)
                && WorkspaceWindowRegistry.workspace(for: $0) === secondWorkspace
                && $0.isVisible
        }) else {
            finish(false, "kein zweites Dokumentfenster mit Workspace-Zuordnung")
        }

        waitForEditor(workspace: firstWorkspace, window: firstWindow) { _, _ in
            prepareMultiWindowSearchJumpTest(
                firstWorkspace: firstWorkspace,
                firstWindow: firstWindow,
                secondWorkspace: secondWorkspace,
                secondWindow: secondWindow
            )
        }
    }

    private static func prepareMultiWindowSearchJumpTest(
        firstWorkspace: Workspace,
        firstWindow: NSWindow,
        secondWorkspace: Workspace,
        secondWindow: NSWindow
    ) {
        let firstLines = (1...140).map { "Erstes Fenster, Zeile \($0): goal" }
        var secondLines = (1...140).map { "Zweites Fenster, Zeile \($0): leer" }
        secondLines[109] = "Zweites Fenster, Zeile 110: subagent"
        firstWorkspace.activeTabContent.wrappedValue = firstLines.joined(separator: "\n")
        secondWorkspace.activeTabContent.wrappedValue = secondLines.joined(separator: "\n")
        // CESE übernimmt programmatische Binding-Änderungen nicht live. Der
        // produktive Reload-Zähler remountet beide Editoren mit dem Testinhalt.
        firstWorkspace.editorReloadNonce += 1
        secondWorkspace.editorReloadNonce += 1

        firstWorkspace.findPattern = "goal"
        secondWorkspace.findPattern = "subagent"
        firstWorkspace.scope = .file
        secondWorkspace.scope = .file

        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            let firstPanel = SearchPanelController(workspace: firstWorkspace)
            let secondPanel = SearchPanelController(workspace: secondWorkspace)
            retainedSearchPanels = [firstPanel, secondPanel]
            firstPanel.show()
            secondPanel.show()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            pollMultiWindowSearchSetup(secondWorkspace: secondWorkspace,
                                       firstWindow: firstWindow,
                                       secondWindow: secondWindow)
        }
    }

    /// SwiftUI montiert die zweite ContentView und deren Editor asynchron.
    /// Wie die übrigen Fenster-Selbsttests warten wir auf den echten Zustand,
    /// statt mit einer geratenen festen Verzögerung zu messen.
    private static func pollMultiWindowSearchSetup(secondWorkspace: Workspace,
                                                   firstWindow: NSWindow,
                                                   secondWindow: NSWindow,
                                                   tick: Int = 0) {
        let searchWindows = NSApp.windows.filter {
            SearchWindow.isSearchWindow($0) && $0.isVisible
        }
        let firstTV = firstWindow.contentView.flatMap { editorTextView(in: $0) as? TextView }
        let secondTV = secondWindow.contentView.flatMap { editorTextView(in: $0) as? TextView }
        let secondSearchWindow = searchWindows.first {
            WorkspaceWindowRegistry.workspace(for: $0) === secondWorkspace
        }

        if searchWindows.count == 2,
           let firstTV, let secondTV, let secondSearchWindow {

            firstTV.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
            secondTV.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
            secondSearchWindow.makeKeyAndOrderFront(nil)

            let result = BufferSearch.find(
                in: secondWorkspace.activeTab?.content ?? "",
                options: SearchOptions(find: "subagent", replace: "",
                                       isRegex: false, caseSensitive: true)
            )
            guard let target = result.matches.first, target.line == 110 else {
                finish(false, "subagent-Testtreffer auf Zeile 110 fehlt")
            }
            NotificationCenter.default.postMatchJump(target, for: secondWorkspace)
            pollMultiWindowJump(firstTV: firstTV, secondTV: secondTV,
                                firstWindow: firstWindow, secondWindow: secondWindow,
                                secondSearchWindow: secondSearchWindow)
            return
        }
        if tick >= 100 {
            finish(false, "zwei Dokumentfenster wurden nicht samt zwei Suchdialogen und Editoren bereit "
                   + "(Suchdialoge=\(searchWindows.count), erster Editor=\(firstTV != nil), "
                   + "zweiter Editor=\(secondTV != nil), zweiter Suchdialog=\(secondSearchWindow != nil))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollMultiWindowSearchSetup(secondWorkspace: secondWorkspace,
                                       firstWindow: firstWindow,
                                       secondWindow: secondWindow,
                                       tick: tick + 1)
        }
    }

    private static func pollMultiWindowJump(firstTV: TextView, secondTV: TextView,
                                            firstWindow: NSWindow, secondWindow: NSWindow,
                                            secondSearchWindow: NSWindow,
                                            tick: Int = 0) {
        let secondRange = secondTV.selectedRange()
        if secondRange.location != NSNotFound,
           secondRange.length > 0,
           NSMaxRange(secondRange) <= (secondTV.string as NSString).length {
            let selected = (secondTV.string as NSString).substring(with: secondRange)
            guard selected == "subagent" else {
                finish(false, "zweiter Editor selektierte \"\(selected)\" statt subagent")
            }
            let firstRange = firstTV.selectedRange()
            guard firstRange.length == 0 else {
                finish(false, "Treffer-Sprung veränderte auch den ersten Editor: \(firstRange)")
            }
            guard firstWindow.isVisible else {
                finish(false, "erster Editor wurde beim Sprung ausgeblendet")
            }
            // Gefordert ist ein sichtbarer Treffer, keine bestimmte
            // Zentrierung. Die frühere ±8-Zeilen-Heuristik um die Viewport-
            // Mitte scheiterte bei einem korrekt sichtbaren Treffer am Rand.
            let targetOffset = max(secondRange.location, NSMaxRange(secondRange) - 1)
            let targetRect = secondTV.layoutManager.rectForOffset(targetOffset)
            let isVisiblyAtTarget = targetRect.map {
                secondTV.visibleRect.intersects($0)
            } ?? false
            if secondSearchWindow.isKeyWindow,
               !secondWindow.isKeyWindow,
               isVisiblyAtTarget {
                finish(true, "subagent wurde nur im zweiten Editor selektiert und sichtbar; "
                    + "zweite Suchmaske blieb Key, erster Editor unverändert")
            }
        }
        if tick >= 60 {
            let shownLine = secondTV.layoutManager
                .textLineForPosition(secondTV.visibleRect.midY)
                .map { $0.index + 1 }
            let targetOffset = secondRange.location == NSNotFound
                ? nil : max(secondRange.location, NSMaxRange(secondRange) - 1)
            let targetRect = targetOffset.flatMap {
                secondTV.layoutManager.rectForOffset($0)
            }
            finish(false, "zweiter Editor erreichte binnen 1,8 s nicht vollständig Auswahl und Sichtbarkeit "
                   + "bei sicherem Suchfenster-Fokus (selection=\(secondRange), "
                   + "searchKey=\(secondSearchWindow.isKeyWindow), documentKey=\(secondWindow.isKeyWindow), "
                   + "sichtbare Zeile=\(shownLine.map(String.init) ?? "nil"), "
                   + "Trefferrect=\(targetRect.map { String(describing: $0) } ?? "nil"), "
                   + "Viewport=\(secondTV.visibleRect))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollMultiWindowJump(firstTV: firstTV, secondTV: secondTV,
                                firstWindow: firstWindow, secondWindow: secondWindow,
                                secondSearchWindow: secondSearchWindow,
                                tick: tick + 1)
        }
    }

    /// Rekursive Suche, weil SwiftUI den Datei-Menüpunkt in interne Untermenüs
    /// einhängen kann. Modifiers werden bewusst geprüft, damit nicht ein
    /// zufälliger unmodifizierter „n"-Eintrag ausgelöst wird.
    private static func menuItem(forKeyEquivalent key: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.keyEquivalent.lowercased() == key,
               item.keyEquivalentModifierMask.contains(.command) {
                return item
            }
            if let submenu = item.submenu,
               let found = menuItem(forKeyEquivalent: key, in: submenu) {
                return found
            }
        }
        return nil
    }

    private static var testLabel = "findbar"

    private static func finish(_ ok: Bool, _ msg: String) -> Never {
        FileHandle.standardError.write(Data("SELFTEST \(testLabel): \(ok ? "PASS" : "FAIL") — \(msg)\n".utf8))
        exit(ok ? 0 : 1)
    }

    /// CMD+W bei vorderer Suchmaske → Maske schließt sich.
    ///
    /// War flaky: nach dem CMD+W-Post wurde der Fenster-Zustand EINMAL nach
    /// fixen 0,6 s geprüft. Schließt das Fenster minimal später (Release-
    /// Timing weicht von Debug ab), meldete der Test fälschlich FAIL, obwohl
    /// die Funktion intakt ist. Jetzt mit demselben Muster wie der Findbar-
    /// Test: App aktivieren, Fenster sicher nach vorn, setteln lassen, CMD+W
    /// posten und dann ENGMASCHIG POLLEN — PASS, sobald das Fenster
    /// unsichtbar wird; FAIL nur, wenn es das ganze Beobachtungsfenster über
    /// sichtbar bleibt.
    private static func runCmdWTest() {
        testLabel = "cmdw"
        guard let searchWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName == SearchWindow.frameAutosaveName
        }) else {
            finish(false, "Suchfenster nicht gefunden")
        }
        guard searchWindow.isVisible else {
            finish(false, "Suchfenster startet nicht sichtbar")
        }
        // App nach vorn holen UND Fenster key machen — CMD+W routet nur an
        // das vordere Key-Window. Ohne aktive App lief das Event früher
        // gelegentlich ins Leere (Mit-Ursache der Flakiness).
        NSApp.activate(ignoringOtherApps: true)
        searchWindow.makeKeyAndOrderFront(nil)

        // NICHT blind nach fixem Delay posten: Unter macOS 14 (kooperative
        // Aktivierung) kann `NSApp.activate` verweigert/verzögert werden —
        // besonders, wenn kurz vorher eine andere Fastra-Selbsttest-Instanz
        // lief (reproduziert 2026-06-11: 1 FAIL in 9 Läufen, nur direkt
        // nach einem vorherigen Selbsttest). Deshalb erst pollen, bis das
        // Fenster WIRKLICH key ist, und periodisch re-aktivieren. Klappt
        // die Aktivierung gar nicht, ist das ein Umgebungsproblem — der
        // FAIL-Text unterscheidet das klar vom echten Funktionsfehler.
        pollForKeyThenPost(searchWindow)
    }

    /// Pollt bis zu ~8 s darauf, dass die Suchmaske Key-Window ist (mit
    /// Re-Aktivierung alle ~0,3 s), und postet erst DANN CMD+W. So messen
    /// wir die Funktion (CMD+W schließt) getrennt von der Umgebung
    /// (App-Aktivierung wurde vom System verweigert).
    ///
    /// 8 s statt 1,5 s (2026-06-11): Unter macOS 26 verweigert die
    /// kooperative Aktivierung einem im Hintergrund gestarteten Prozess
    /// `NSApp.activate` KOMPLETT (isActive bleibt false). Der Test-Runner
    /// muss die App daher EXTERN nach vorn holen (System Events:
    /// `set frontmost of process "Fastra" to true`) — und das braucht
    /// Zeit, bis der Prozess für System Events sichtbar ist. Das lange
    /// Fenster gibt dem Runner die Chance; bei Erfolg endet das Polling
    /// sofort.
    private static func pollForKeyThenPost(_ window: NSWindow, tick: Int = 0) {
        let maxTicks = 270           // 270 × 30 ms ≈ 8 s
        if window.isKeyWindow {
            postCmd("w", keyCode: 13, windowNumber: window.windowNumber)
            pollForClose(window)
            return
        }
        if tick >= maxTicks {
            // Diagnose mitliefern: Ist die App überhaupt aktiv? Welches
            // Fenster IST stattdessen Key? Unterscheidet „System verweigert
            // Aktivierung" von „anderes Fenster klaut den Key-Status".
            let keyDesc = NSApp.keyWindow.map {
                "[\(type(of: $0))] \"\($0.title)\" autosave=\"\($0.frameAutosaveName)\""
            } ?? "keins"
            finish(false, "Aktivierung fehlgeschlagen — Suchmaske wurde nie Key-Window "
                + "(Umgebungsproblem, kein CMD+W-Funktionsfehler; "
                + "NSApp.isActive=\(NSApp.isActive), keyWindow=\(keyDesc), "
                + "panel: visible=\(window.isVisible) canBecomeKey=\(window.canBecomeKey))")
        }
        // Alle ~10 Ticks erneut um Aktivierung bitten — einzelne Aufrufe
        // verpuffen unter kooperativer Aktivierung gelegentlich.
        if tick % 10 == 9 {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollForKeyThenPost(window, tick: tick + 1)
        }
    }

    /// Pollt engmaschig, ob die Suchmaske nach CMD+W unsichtbar wird. Sobald
    /// sie verschwindet → PASS. Bleibt sie über das ganze Fenster sichtbar
    /// → FAIL. Ersetzt die frühere Einzel-Messung mit fixem Delay (flaky).
    private static func pollForClose(_ window: NSWindow, tick: Int = 0) {
        let maxTicks = 50            // 50 × 30 ms ≈ 1,5 s Beobachtungsfenster
        if !window.isVisible {
            finish(true, "Suchmaske nach CMD+W geschlossen (Tick \(tick))")
        }
        if tick >= maxTicks {
            finish(false, "Suchmaske nach CMD+W über \(maxTicks) Ticks noch sichtbar")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollForClose(window, tick: tick + 1)
        }
    }

    /// Postet ein echtes „CMD+<char>" (flagsChanged + keyDown) in die Queue.
    private static func postCmd(_ char: String, keyCode: UInt16, windowNumber: Int) {
        if let flags = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 55
        ) {
            NSApp.postEvent(flags, atStart: false)
        }
        if let key = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber, context: nil,
            characters: char, charactersIgnoringModifiers: char,
            isARepeat: false, keyCode: keyCode
        ) {
            NSApp.postEvent(key, atStart: false)
        }
    }

    /// Postet einen unmodifizierten Tastendruck an das angegebene Fenster.
    /// Damit prüft `navmatch` den echten SwiftUI-Fokus-/onKeyPress-Pfad der
    /// Trefferliste statt bloß die zugrunde liegende Notification aufzurufen.
    private static func postKey(_ char: String, keyCode: UInt16, windowNumber: Int) {
        guard let key = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber, context: nil,
            characters: char, charactersIgnoringModifiers: char,
            isARepeat: false, keyCode: keyCode
        ) else {
            finish(false, "konnte Key-Event (keyCode=\(keyCode)) nicht bauen")
        }
        NSApp.postEvent(key, atStart: false)
    }

    private static func runFindBarTest() {
        testLabel = "findbar"
        // Hauptfenster = sichtbares Fenster, das NICHT die Suchmaske ist.
        guard let workspace = Workspace.shared,
              let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }) else {
            finish(false, "kein Hauptfenster gefunden")
        }

        waitForEditor(workspace: workspace, window: mainWindow) { root, textView in
            prepareFindBarTest(mainWindow: mainWindow, root: root, textView: textView)
        }
    }

    private static func prepareFindBarTest(
        mainWindow: NSWindow,
        root: NSView,
        textView: TextView
    ) {
        // Voraussetzung, damit der Editor-eigene CMD+F-Monitor überhaupt
        // triggern WÜRDE: Hauptfenster Key + Editor ist First Responder.
        // (Genau die Situation, in der der Zombie früher auftrat.)
        mainWindow.makeKeyAndOrderFront(nil)
        _ = mainWindow.makeFirstResponder(textView)

        // Kurz warten: didBecomeKey installiert unseren Monitor neu (neuester).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let isFR = mainWindow.firstResponder === textView

            // Erst Command-Modifier (flagsChanged), dann F-keyDown — wie ein
            // echtes CMD+F. Der flagsChanged-Event löst den Reinstall unseres
            // keyDown-Monitors aus (siehe AppDelegate.installFlagsMonitor).
            if let flags = NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: mainWindow.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 55
            ) {
                NSApp.postEvent(flags, atStart: false)
            }
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: mainWindow.windowNumber, context: nil,
                characters: "f", charactersIgnoringModifiers: "f",
                isARepeat: false, keyCode: 3
            ) else {
                finish(false, "konnte CMD+F-Event nicht bauen")
            }
            // In die Queue posten → durchläuft die lokalen Monitore.
            NSApp.postEvent(event, atStart: false)

            // WICHTIG: NICHT nur den Endzustand prüfen. Der „Zombie" blitzt
            // kurz auf (showFindPanel animiert 0,15 s ein) und wird dann vom
            // Reconcile wieder geschlossen — bei einer Einzel-Messung nach
            // 0,6 s ist er längst weg und der Test wäre fälschlich grün.
            // Deshalb POLLEN wir über ~1,2 s engmaschig und schlagen an,
            // sobald das Panel AUCH NUR EINMAL sichtbar war.
            pollForFlash(in: root, firstResponder: isFR)
        }
    }

    /// Pollt engmaschig, ob das Editor-Find-Panel im Verlauf AUCH NUR
    /// KURZ sichtbar wird (Flash). Sobald es einmal auftaucht → FAIL.
    /// Nach Ablauf des Fensters ohne Sichtung → PASS.
    private static func pollForFlash(in root: NSView, firstResponder isFR: Bool, tick: Int = 0) {
        let maxTicks = 40            // 40 × 30 ms ≈ 1,2 s Beobachtungsfenster
        if findPanelVisible(in: root) {
            finish(false, "Editor-Find-Panel blitzte auf nach CMD+F (Tick \(tick), firstResponder=\(isFR))")
        }
        if tick >= maxTicks {
            finish(true, "kein Editor-Find-Panel über \(maxTicks) Ticks nach CMD+F (firstResponder=\(isFR))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollForFlash(in: root, firstResponder: isFR, tick: tick + 1)
        }
    }

    /// Prüft, ob Suchen- UND Ersetzen-Feld echte, editierbare Texteingaben
    /// sind. Beweist die gemeldeten Bugs (Find-Feld war statisches `Text`,
    /// Replace „nicht änderbar") deterministisch im echten App-Prozess.
    ///
    /// Vorgehen: Suchfenster nach vorn holen, alle editierbaren Text-Inputs
    /// im Fensterbaum einsammeln, jeweils zum First Responder machen und
    /// einen echten Tastendruck hineinposten — danach muss sich der Feld-
    /// Inhalt geändert haben. Findet der Test weniger als zwei editierbare
    /// Felder, fehlt eines (typisch: das Find-Feld) → FAIL.
    private static func runFieldsTest() {
        testLabel = "fields"
        guard let searchWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName == SearchWindow.frameAutosaveName
        }) else {
            finish(false, "Suchfenster nicht gefunden")
        }
        searchWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let root = searchWindow.contentView else {
                finish(false, "Suchfenster ohne contentView")
            }
            // Seit v0.7 sind Suchen- und Ersetzen-Feld KEINE SwiftUI-
            // TextFields (NSTextField) mehr, sondern NSTextView-basierte
            // RegexFieldTextViews (Inline-Token-Highlighting). Der Test
            // sammelt deshalb BEIDE Arten ein — fällt eine der beiden
            // Umstellungen je zurück, bleibt der Test trotzdem scharf.
            var fields: [NSView] = []
            collectTypeableFields(in: root, into: &fields)

            guard fields.count >= 2 else {
                finish(false, "nur \(fields.count) editierbares Texteingabe-Feld gefunden (erwartet ≥2: Suchen + Ersetzen)")
            }

            // Jedes Feld real betippen und Änderung verifizieren.
            for (idx, field) in fields.enumerated() {
                let before = readFieldText(field)
                guard searchWindow.makeFirstResponder(field) else {
                    finish(false, "Feld \(idx) (\(describeField(field))) konnte nicht fokussiert werden")
                }
                if let tf = field as? NSTextField {
                    // SwiftUI-TextField bridged auf NSTextField; direktes
                    // Einfügen über den Feld-Editor ist der zuverlässigste
                    // Weg, einen echten Tastendruck nachzubilden.
                    tf.currentEditor()?.insertText("Z")
                } else if let tv = field as? RegexFieldTextView {
                    // NSTextView nimmt insertText direkt — gleicher Pfad
                    // wie eine echte Tastatureingabe (inkl. Delegate).
                    tv.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                let after = readFieldText(field)
                if after == before {
                    finish(false, "Feld \(idx) (\(describeField(field))) nahm keine Eingabe an (Inhalt unverändert: \"\(before)\")")
                }
            }
            finish(true, "\(fields.count) editierbare Felder, alle nehmen Eingaben an")
        }
    }

    /// Prüft das zweizeilige Optionslayout im ECHTEN Suchfenster. Marker an
    /// den linken Toggle-Kanten messen die Ausrichtung unabhängig vom Modell;
    /// der zustandskodierte Marker belegt, dass „∗ wörtlich" sichtbar bleibt
    /// und nach Pattern-/RegEx-Wechseln im gerenderten Baum aktualisiert wird.
    private static func runSearchOptionsTest() {
        testLabel = "searchoptions"
        guard let ws = Workspace.shared,
              let searchWindow = NSApp.windows.first(where: {
                  $0.frameAutosaveName == SearchWindow.frameAutosaveName
              }),
              let root = searchWindow.contentView else {
            finish(false, "Workspace oder Suchfenster fehlt")
        }

        ws.scope = .file
        ws.useRegex = true
        ws.findPattern = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard searchWindow.contentMinSize.height >= 450 else {
                finish(false, "effektive Mindesthöhe \(searchWindow.contentMinSize.height), "
                    + "erwartet mindestens 450")
            }
            guard let first = markerView(id: "searchOptionFirst", in: root),
                  let second = markerView(id: "searchOptionSecond", in: root),
                  markerView(id: "wildcardLiteralOption-disabled-off", in: root) != nil else {
                finish(false, "Optionsmarker im sternlosen RegEx-Zustand unvollständig")
            }
            let firstPoint = first.convert(NSPoint.zero, to: root)
            let secondPoint = second.convert(NSPoint.zero, to: root)
            guard abs(firstPoint.x - secondPoint.x) <= 1,
                  abs(firstPoint.y - secondPoint.y) >= 5 else {
                finish(false, "Optionen nicht linksbündig zweizeilig: "
                    + "erste=\(firstPoint), zweite=\(secondPoint)")
            }

            ws.useRegex = false
            ws.findPattern = "a*b"
            pollSearchOptionsEnabled(ws, root: root)
        }
    }

    private static func pollSearchOptionsEnabled(_ ws: Workspace, root: NSView,
                                                 tick: Int = 0) {
        if markerView(id: "wildcardLiteralOption-enabled-off", in: root) != nil {
            ws.treatWildcardLiterally = true
            ws.findPattern = "ab"
            pollSearchOptionsReset(ws, root: root)
            return
        }
        if tick >= 40 {
            finish(false, "∗ wörtlich wurde mit Plain-Text-Stern nicht aktiv")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollSearchOptionsEnabled(ws, root: root, tick: tick + 1)
        }
    }

    private static func pollSearchOptionsReset(_ ws: Workspace, root: NSView,
                                               tick: Int = 0) {
        if markerView(id: "wildcardLiteralOption-disabled-off", in: root) != nil,
           !ws.treatWildcardLiterally {
            finish(true, "Mindesthöhe ≥450; Optionen zweizeilig/linksbündig; "
                + "∗ wörtlich dauerhaft sichtbar, zustandsabhängig aktiv und abgewählt")
        }
        if tick >= 40 {
            finish(false, "∗ wörtlich blieb nach Entfernen des Sterns aktiv/gewählt")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollSearchOptionsReset(ws, root: root, tick: tick + 1)
        }
    }

    /// Prüft den gemeldeten Alt-Treffer-Zustand am ECHTEN Projekt-Filterfeld:
    /// Ein AppKit-Einfügevorgang muss die gebundene Konfiguration ohne
    /// Debounce ändern. Noch im selben Main-Thread-Umlauf verschwinden die
    /// Treffer der vorherigen Semantik; Navigation, Vorschau und Apply bleiben
    /// bis zum neuen Ergebnis gesperrt. Die gemessene Dauer schützt außerdem
    /// davor, teure Projektarbeit versehentlich in den TextField-Setter zu
    /// verschieben.
    private static func runProjectInputTest() {
        testLabel = "projectinput"
        guard let ws = Workspace.shared,
              let searchWindow = NSApp.windows.first(where: {
                  $0.frameAutosaveName == SearchWindow.frameAutosaveName
              }),
              let root = searchWindow.contentView else {
            finish(false, "Workspace oder Suchfenster fehlt")
        }

        let fm = FileManager.default
        let projectRoot = fm.temporaryDirectory
            .appendingPathComponent("fastra-projectinput-\(UUID().uuidString)")
        let file = projectRoot.appendingPathComponent("alt.txt")
        do {
            try fm.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            try "ALTER_TREFFER".write(to: file, atomically: true, encoding: .utf8)
        } catch {
            try? fm.removeItem(at: projectRoot)
            finish(false, "Projekt-Fixture nicht schreibbar: \(error.localizedDescription)")
        }

        ws.openProject(at: projectRoot)
        ws.scope = .project
        ws.findPattern = "ALT"
        ws.useRegex = false
        searchWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Die Konfigurationsänderungen oben dürfen erst auslaufen; danach
        // injizieren wir bewusst eine vollständige alte Trefferbasis.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let field = editableTextField(
                id: "fastra.projectExclusions", in: root
            ) else {
                ws.closeProject()
                try? fm.removeItem(at: projectRoot)
                finish(false, "Projekt-Ausschlussfeld nicht im echten Fenster gefunden")
            }
            let options = SearchOptions(find: "ALT", replace: "", isRegex: false)
            let match = BufferSearch.Match(
                range: NSRange(location: 0, length: 3),
                line: 1, column: 1, matchText: "ALT", replacedText: ""
            )
            ws.folderResults = [FolderSearch.PerFileResult(
                url: file, matches: [match], totalMatches: 1,
                skipped: nil, snapshot: nil, searchOptions: options
            )]
            ws.folderTotalMatches = 1
            ws.folderSearching = false
            ws.folderNeedsSearch = false
            guard ws.navMatches.count == 1 else {
                ws.closeProject()
                try? fm.removeItem(at: projectRoot)
                finish(false, "Alt-Treffer war vor der Eingabe nicht navigierbar")
            }
            guard searchWindow.makeFirstResponder(field),
                  let editor = field.currentEditor() as? NSTextView else {
                ws.closeProject()
                try? fm.removeItem(at: projectRoot)
                finish(false, "Projekt-Ausschlussfeld wurde nicht First Responder")
            }

            let insertionRange = NSRange(
                location: field.stringValue.utf16.count, length: 0
            )
            let started = ProcessInfo.processInfo.systemUptime
            editor.insertText(", userPreferences.*" as NSString,
                              replacementRange: insertionRange)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let clearedSynchronously = ws.folderResults.isEmpty
                && ws.folderTotalMatches == 0
                && ws.navMatches.isEmpty
                && (ws.folderSearching || ws.folderNeedsSearch)
                && !ws.applyAllInFolder()
            let textArrived = field.stringValue.contains("userPreferences.*")
            let resultCount = ws.folderResults.count
            let navigationCount = ws.navMatches.count
            let searching = ws.folderSearching
            let needsSearch = ws.folderNeedsSearch

            ws.closeProject()
            try? fm.removeItem(at: projectRoot)
            guard textArrived, elapsed < 0.25, clearedSynchronously else {
                finish(false, String(
                    format: "Filtereingabe/Invalidierung fehlerhaft: Text=%@, %.3f s, "
                        + "Ergebnisse=%d, Navigation=%d, searching=%@, needs=%@",
                    textArrived ? "ok" : "fehlt", elapsed,
                    resultCount, navigationCount,
                    searching ? "ja" : "nein",
                    needsSearch ? "ja" : "nein"
                ))
            }
            finish(true, String(
                format: "echte Filtereingabe in %.3f s; Alt-Treffer, Navigation "
                    + "und Apply sofort invalidiert", elapsed
            ))
        }
    }

    private static func editableTextField(id: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField,
           field.isEditable, field.isEnabled,
           (field.accessibilityIdentifier() == id
            // SwiftUI hängt den Identifier je nach macOS-Version an seinen
            // Wrapper statt an das innere NSTextField. Der in Deutsch und
            // Englisch eindeutige Placeholder hält den End-to-End-Test dann
            // am selben produktiven Feld, ohne Feldreihenfolgen zu raten.
            || field.placeholderString?.contains("generated.swift") == true) {
            return field
        }
        for child in view.subviews {
            if let field = editableTextField(id: id, in: child) { return field }
        }
        return nil
    }

    /// Prüft, dass ein Tab-Wechsel (wie nach einem Datei-Drop) den Editor-
    /// Inhalt tatsächlich austauscht. Hintergrund: CodeEditSourceEditor setzt
    /// seinen Text NUR in `makeNSViewController` — Binding-Änderungen werden
    /// NICHT zurück in die TextView geschoben. Deshalb koppeln wir die View
    /// per `.id(activeTab.id)` an die Tab-ID, damit sie beim Tab-Wechsel neu
    /// erzeugt wird. Dieser Test belegt die Neuerzeugung über die Objekt-
    /// Identität der TextView (vorher ≠ nachher) und prüft, dass der aktive
    /// Tab den neuen Datei-Inhalt trägt. Genau der „Drop legt Tab an, zeigt
    /// aber keinen Inhalt"-Bug.
    private static func runTabSwitchTest() {
        testLabel = "tabswitch"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }) else {
            finish(false, "kein Hauptfenster gefunden")
        }

        waitForEditor(workspace: ws, window: mainWindow) { root, tv1 in
            prepareTabSwitchTest(ws: ws, root: root, tv1: tv1)
        }
    }

    private static func prepareTabSwitchTest(ws: Workspace, root: NSView, tv1: TextView) {
        let id1 = ObjectIdentifier(tv1)
        // Genau der manuell gefundene Fehler: Eine kurze Auswahl aus Datei A
        // durfte beim Öffnen von Datei B nicht auf deren erste Zeichen
        // übertragen werden.
        tv1.selectionManager.setSelectedRange(NSRange(location: 0, length: 5))

        // Temp-Datei mit eindeutigem Markerinhalt anlegen und laden →
        // neuer Tab, activeTabID wechselt. loadFile ist jetzt asynchron
        // (v0.9): Folge-Schritte in der Completion, damit der Inhalt beim
        // Prüfen wirklich im Tab steht.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-tabswitch-\(UUID().uuidString).txt")
        let marker = "TABSWITCH_MARKER_CONTENT"
        do { try marker.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        // Temp-Datei-Löschung in die Completion verschoben (war vorher sofort
        // nach loadFile — jetzt erst NACH dem Laden, damit der Hintergrund-Task
        // die Datei noch lesen kann).
        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else {
                finish(false, "loadFile schlug fehl (completion false)")
            }
            // SwiftUI Zeit geben, den Editor via `.id` neu zu erzeugen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let tv2 = editorTextView(in: root) as? TextView else {
                    finish(false, "keine Editor-TextView nach dem Tab-Wechsel")
                }
                let recreated = ObjectIdentifier(tv2) != id1
                let modelOK = ws.activeTab?.content == marker
                let resultingSelections = tv2.selectionManager.textSelections
                    .map(\.range)
                // CESE kann bis zum ersten Fokus entweder noch keine
                // TextSelection oder bereits den Einfügepunkt (0, 0)
                // besitzen. Beides ist korrekt; entscheidend ist, dass keine
                // nichtleere Auswahl aus dem vorigen Tab übrig bleibt.
                let selectionOK = resultingSelections.allSatisfy {
                    $0.length == 0
                }
                if !recreated {
                    finish(false, "Editor-TextView NICHT neu erzeugt — Inhalt bliebe stehen (genau der Drop-Bug)")
                } else if !modelOK {
                    finish(false, "Editor neu erzeugt, aber aktiver Tab trägt nicht den neuen Inhalt")
                } else if !selectionOK {
                    finish(false, "Auswahl aus dem vorigen Tab wurde übernommen: "
                        + "\(resultingSelections)")
                } else {
                    finish(true, "Editor neu erzeugt, neuer Inhalt und eigene Einfügemarke statt fremder Auswahl")
                }
            }
        }
    }

    // MARK: - -selftest tabclosehit / tabcompare

    /// Prüft die echte Klickfläche des kleinen Tab-X. Der Ziel-Tab ist
    /// absichtlich inaktiv: Trifft der synthetische Randklick fälschlich den
    /// Tab statt des Schließen-Buttons, wird er nur ausgewählt und der Test
    /// erkennt den Unterschied unabhängig am Workspace-Zustand.
    private static func runTabCloseHitTest() {
        testLabel = "tabclosehit"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks() else {
            finish(false, "Workspace oder Hauptfenster nicht erreichbar")
        }

        ws.openNewTab()
        guard let targetID = ws.activeTabID else {
            finish(false, "Ziel-Tab nicht erzeugbar")
        }
        ws.openNewTab()
        guard let keeperID = ws.activeTabID, keeperID != targetID else {
            finish(false, "aktiver Kontroll-Tab nicht erzeugbar")
        }

        pollTabCloseTarget(
            ws,
            window: window,
            targetID: targetID,
            keeperID: keeperID,
            tick: 0
        )
    }

    private static func pollTabCloseTarget(
        _ ws: Workspace,
        window: NSWindow,
        targetID: UUID,
        keeperID: UUID,
        tick: Int
    ) {
        guard let content = window.contentView,
              let marker = markerView(
                id: "tabClose-\(targetID.uuidString)",
                in: content
              ) else {
            guard tick < 40 else {
                finish(false, "AppKit-Marker des Tab-X fehlt")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pollTabCloseTarget(
                    ws,
                    window: window,
                    targetID: targetID,
                    keeperID: keeperID,
                    tick: tick + 1
                )
            }
            return
        }

        let minimumSide: CGFloat = 22
        guard marker.bounds.width >= minimumSide,
              marker.bounds.height >= minimumSide else {
            finish(
                false,
                "Tab-X-Hitbereich ist nur "
                    + "\(Int(marker.bounds.width))×\(Int(marker.bounds.height)) pt"
            )
        }

        // Einen Punkt innerhalb der rechten Kante klicken, nicht bloß das
        // Symbolzentrum. Genau dort fiel der kleine verschachtelte Button
        // bisher auf den umgebenden Tab zurück.
        let edge = NSPoint(x: marker.bounds.maxX - 1, y: marker.bounds.midY)
        let point = marker.convert(edge, to: nil)
        guard sendMouseClick(at: point, in: window, modifiers: []) else {
            finish(false, "Randklick auf das Tab-X nicht erzeugbar")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let closed = !ws.tabs.contains(where: { $0.id == targetID })
            let keeperStayedActive = ws.activeTabID == keeperID
            finish(
                closed && keeperStayedActive,
                closed && keeperStayedActive
                    ? "mindestens 22×22 pt; Randklick schließt nur den Ziel-Tab"
                    : "Randklick schloss den Ziel-Tab nicht eindeutig "
                        + "(geschlossen=\(closed), Kontroll-Tab aktiv=\(keeperStayedActive))"
            )
        }
    }

    /// Prüft den echten Shift-Klick auf einen zweiten Tab, die zwei sichtbar
    /// unterscheidbaren Auswahlrollen sowie den vorausgefüllten Vergleichs-
    /// dialog. Die Modelltests allein würden eine tote Modifier-Geste oder
    /// fehlende SwiftUI-Vorbelegung nicht erkennen.
    private static func runTabComparisonTest() {
        testLabel = "tabcompare"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks(),
              let content = window.contentView else {
            finish(false, "Workspace oder Hauptfenster nicht erreichbar")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-tabcompare-\(UUID().uuidString)")
        // Der lange Name schützt zugleich den realen Klickpfad eines in der
        // Mitte gekürzten Tabs vor Rückfällen zu fensterbreiten Tabs.
        let longName = String(repeating: "sehr-langer-dateiname-", count: 8)
            + "links.txt"
        let leftURL = directory.appendingPathComponent(longName)
        let rightURL = directory.appendingPathComponent("rechts.txt")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try "links\n".write(
                to: leftURL,
                atomically: true,
                encoding: .utf8
            )
            try "rechts\n".write(
                to: rightURL,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            finish(
                false,
                "Tabvergleich-Fixtures nicht anlegbar: \(error.localizedDescription)"
            )
        }

        ws.loadFile(at: leftURL) { leftOK in
            guard leftOK else {
                try? FileManager.default.removeItem(at: directory)
                finish(false, "linke Fixture nicht ladbar")
            }
            ws.loadFile(at: rightURL) { rightOK in
                guard rightOK else {
                    try? FileManager.default.removeItem(at: directory)
                    finish(false, "rechte Fixture nicht ladbar")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    guard let leftTab = ws.tabs.first(where: {
                        $0.url?.standardizedFileURL == leftURL.standardizedFileURL
                    }), let rightTab = ws.tabs.first(where: {
                        $0.url?.standardizedFileURL == rightURL.standardizedFileURL
                    }), ws.activeTabID == rightTab.id else {
                        try? FileManager.default.removeItem(at: directory)
                        finish(false, "Fixture-Tabs oder eindeutiger aktueller Tab fehlen")
                    }

                    let idleID = "documentTab-idle-\(leftTab.id.uuidString)"
                    guard let idleTab = markerView(id: idleID, in: content) else {
                        try? FileManager.default.removeItem(at: directory)
                        finish(false, "AppKit-Marker des zweiten Tabs fehlt")
                    }
                    guard sendTabClick(
                            on: idleTab,
                            in: window,
                            modifiers: .shift
                          ) else {
                        try? FileManager.default.removeItem(at: directory)
                        finish(false, "Shift-Mausereignis nicht erzeugbar")
                    }
                    pollShiftSelectedTabs(
                        ws,
                        window: window,
                        directory: directory,
                        leftID: leftTab.id,
                        rightID: rightTab.id,
                        tick: 0
                    )
                }
            }
        }
    }

    private static func sendTabClick(
        on view: NSView,
        in window: NSWindow,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let local = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let point = view.convert(local, to: nil)
        return sendMouseClick(at: point, in: window, modifiers: modifiers)
    }

    private static func sendMouseClick(
        at point: NSPoint,
        in window: NSWindow,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: modifiers,
            timestamp: time,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: modifiers,
            timestamp: time + 0.04,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ) else {
            return false
        }
        window.sendEvent(down)
        window.sendEvent(up)
        return true
    }

    private static func pollShiftSelectedTabs(
        _ ws: Workspace,
        window: NSWindow,
        directory: URL,
        leftID: UUID,
        rightID: UUID,
        tick: Int
    ) {
        let content = window.contentView
        let currentMarker = content.flatMap {
            markerView(
                id: "documentTab-current-\(rightID.uuidString)",
                in: $0
            )
        }
        let comparisonMarker = content.flatMap {
            markerView(
                id: "documentTab-comparison-\(leftID.uuidString)",
                in: $0
            )
        }
        if ws.activeTabID == rightID,
           ws.comparisonTabID == leftID,
           ws.selectedComparisonTabIDs == [leftID, rightID],
           currentMarker != nil,
           comparisonMarker != nil {
            guard ws.presentComparisonForSelectedTabs(contextTabID: leftID) else {
                try? FileManager.default.removeItem(at: directory)
                finish(false, "Kontextaktion akzeptiert den markierten Tab nicht")
            }
            pollPrefilledComparisonSheet(
                ws,
                window: window,
                directory: directory,
                leftID: leftID,
                rightID: rightID,
                tick: 0
            )
            return
        }
        guard tick < 30 else {
            try? FileManager.default.removeItem(at: directory)
            finish(
                false,
                "Shift-Klick: aktiv=\(ws.activeTabID?.uuidString ?? "nil"), "
                    + "Vergleich=\(ws.comparisonTabID?.uuidString ?? "nil"), "
                    + "Marker aktuell=\(currentMarker != nil), "
                    + "zweiter=\(comparisonMarker != nil)"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollShiftSelectedTabs(
                ws,
                window: window,
                directory: directory,
                leftID: leftID,
                rightID: rightID,
                tick: tick + 1
            )
        }
    }

    private static func pollPrefilledComparisonSheet(
        _ ws: Workspace,
        window: NSWindow,
        directory: URL,
        leftID: UUID,
        rightID: UUID,
        tick: Int
    ) {
        if let sheet = window.attachedSheet,
           let content = sheet.contentView {
            let leftReady = markerView(
                id: "compare-left-tab-\(leftID.uuidString)",
                in: content
            ) != nil
            let rightReady = markerView(
                id: "compare-right-tab-\(rightID.uuidString)",
                in: content
            ) != nil
            if leftReady, rightReady {
                ws.showCompareFilesDialog = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard let root = window.contentView,
                          let comparisonTab = markerView(
                            id: "documentTab-comparison-\(leftID.uuidString)",
                            in: root
                          ),
                          sendTabClick(
                            on: comparisonTab,
                            in: window,
                            modifiers: []
                          ) else {
                        try? FileManager.default.removeItem(at: directory)
                        finish(false, "normaler Folgeklick nicht ausführbar")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        let cleared = ws.activeTabID == leftID
                            && ws.comparisonTabID == nil
                        try? FileManager.default.removeItem(at: directory)
                        finish(
                            cleared,
                            cleared
                                ? "Shift-Klick behält Primärtab; zwei Markierungsrollen; "
                                    + "Dialog links/rechts vorgefüllt; Normalklick räumt auf"
                                : "Normalklick räumte die Zwei-Tab-Auswahl nicht auf"
                        )
                    }
                }
                return
            }
        }
        guard tick < 40 else {
            ws.showCompareFilesDialog = false
            try? FileManager.default.removeItem(at: directory)
            finish(
                false,
                "Vergleichs-Sheet nicht mit beiden markierten Tabs vorgefüllt"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollPrefilledComparisonSheet(
                ws,
                window: window,
                directory: directory,
                leftID: leftID,
                rightID: rightID,
                tick: tick + 1
            )
        }
    }

    // MARK: - -selftest softwrapprofiles

    /// Prüft die komplette Formatprofil-Kette im echten Editor:
    /// Markdown-Default an, 4D-Default aus, sofortiger CESE-Reconcile ohne
    /// Inhalts-/Selektions-/Dirty-/Undo-Änderung, Vererbung an einen neuen
    /// 4D-Tab und appweite Rückschaltung beider offenen 4D-Tabs. Zusätzlich
    /// muss der checkbare Hauptmenüpunkt jeden Zustand spiegeln.
    private static func runSoftWrapProfilesTest() {
        testLabel = "softwrapprofiles"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }) else {
            finish(false, "kein Hauptfenster gefunden")
        }

        waitForEditor(workspace: ws, window: mainWindow) { root, _ in
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("fastra-softwrap-\(UUID().uuidString)")
            let markdownURL = base.appendingPathComponent("notizen.md")
            let firstFourDURL = base.appendingPathComponent("erste.4dm")
            let secondFourDURL = base.appendingPathComponent("zweite.4dm")
            let longLine = String(repeating: "Soft-Wrap-Prüfung ", count: 40)
            do {
                try FileManager.default.createDirectory(
                    at: base, withIntermediateDirectories: true
                )
                try ("# Notizen\n\n\(longLine)\n")
                    .write(to: markdownURL, atomically: true, encoding: .utf8)
                try ("// Erste 4D-Methode\n\(longLine)\n")
                    .write(to: firstFourDURL, atomically: true, encoding: .utf8)
                try ("// Zweite 4D-Methode\n\(longLine)\n")
                    .write(to: secondFourDURL, atomically: true, encoding: .utf8)
            } catch {
                finish(false, "Fixtures nicht anlegbar: \(error.localizedDescription)")
            }

            ws.loadFile(at: markdownURL) { ok in
                guard ok else {
                    try? FileManager.default.removeItem(at: base)
                    finish(false, "Markdown-Fixture nicht ladbar")
                }
                pollSoftWrapState(
                    ws: ws, root: root, expectedFormat: .grammar(.markdown),
                    expectedWrap: true, label: "Markdown-Werkseinstellung",
                    tick: 0
                ) {
                    loadFirstFourDForSoftWrapTest(
                        ws: ws, root: root, base: base,
                        firstURL: firstFourDURL, secondURL: secondFourDURL
                    )
                }
            }
        }
    }

    private static func loadFirstFourDForSoftWrapTest(
        ws: Workspace, root: NSView, base: URL, firstURL: URL, secondURL: URL
    ) {
        ws.loadFile(at: firstURL) { ok in
            guard ok else {
                try? FileManager.default.removeItem(at: base)
                finish(false, "erste 4D-Fixture nicht ladbar")
            }
            pollSoftWrapState(
                ws: ws, root: root, expectedFormat: .fourD,
                expectedWrap: false, label: "4D-Werkseinstellung",
                tick: 0
            ) {
                guard let firstTabID = ws.activeTabID,
                      let textView = editorTextView(in: root) as? TextView else {
                    try? FileManager.default.removeItem(at: base)
                    finish(false, "erste 4D-TextView nicht erreichbar")
                }
                let viewID = ObjectIdentifier(textView)
                let selection = NSRange(location: 3, length: 5)
                textView.selectionManager.setSelectedRange(selection)
                let content = textView.string
                let dirty = ws.activeTab?.isDirty
                let canUndo = textView.undoManager?.canUndo

                guard let mainMenu = NSApp.mainMenu,
                      let menuItem = findMenuItem(titled: "Soft Wrap", in: mainMenu),
                      menuItem.isEnabled, menuItem.action != nil else {
                    try? FileManager.default.removeItem(at: base)
                    finish(false, "Hauptmenüpunkt „Soft Wrap“ nicht bedienbar")
                }
                // Nicht den Store direkt aufrufen: Dieser Klick belegt, dass
                // das bestehende Hauptmenü wirklich dieselbe Action schaltet.
                guard NSApp.sendAction(
                    menuItem.action!,
                    to: menuItem.target,
                    from: menuItem
                ) else {
                    try? FileManager.default.removeItem(at: base)
                    finish(false, "Hauptmenü-Action „Soft Wrap“ nicht ausführbar")
                }
                pollSoftWrapState(
                    ws: ws, root: root, expectedFormat: .fourD,
                    expectedWrap: true, label: "4D live eingeschaltet",
                    tick: 0
                ) {
                    guard let reconciled = editorTextView(in: root) as? TextView,
                          ObjectIdentifier(reconciled) == viewID,
                          reconciled.string == content,
                          reconciled.selectedRange() == selection,
                          ws.activeTab?.isDirty == dirty,
                          reconciled.undoManager?.canUndo == canUndo else {
                        try? FileManager.default.removeItem(at: base)
                        finish(false, "Soft-Wrap-Umschalten veränderte "
                            + "TextView-Identität, Inhalt, Auswahl, Dirty- oder Undo-Zustand")
                    }

                    ws.loadFile(at: secondURL) { ok in
                        guard ok else {
                            try? FileManager.default.removeItem(at: base)
                            finish(false, "zweite 4D-Fixture nicht ladbar")
                        }
                        pollSoftWrapState(
                            ws: ws, root: root, expectedFormat: .fourD,
                            expectedWrap: true, label: "neuer 4D-Tab übernimmt Profil",
                            tick: 0
                        ) {
                            guard let secondTabID = ws.activeTabID,
                                  secondTabID != firstTabID else {
                                try? FileManager.default.removeItem(at: base)
                                finish(false, "zweite 4D-Datei erzeugte keinen eigenen Tab")
                            }
                            ws.toggleSoftWrap()
                            pollSoftWrapState(
                                ws: ws, root: root, expectedFormat: .fourD,
                                expectedWrap: false, label: "zweiter 4D-Tab schaltet aus",
                                tick: 0
                            ) {
                                verifyBothFourDTabsAreUnwrapped(
                                    ws: ws, root: root, base: base,
                                    firstTabID: firstTabID,
                                    secondTabID: secondTabID
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private static func verifyBothFourDTabsAreUnwrapped(
        ws: Workspace, root: NSView, base: URL,
        firstTabID: UUID, secondTabID: UUID
    ) {
        ws.activeTabID = firstTabID
        pollSoftWrapState(
            ws: ws, root: root, expectedFormat: .fourD,
            expectedWrap: false, label: "erster offener 4D-Tab folgt global",
            tick: 0
        ) {
            ws.activeTabID = secondTabID
            pollSoftWrapState(
                ws: ws, root: root, expectedFormat: .fourD,
                expectedWrap: false, label: "zweiter offener 4D-Tab bleibt synchron",
                tick: 0
            ) {
                try? FileManager.default.removeItem(at: base)
                finish(true, "Markdown an; 4D aus; Live-Reconcile zustandstreu; "
                    + "neuer und beide offene 4D-Tabs samt Hauptmenü synchron")
            }
        }
    }

    private static func pollSoftWrapState(
        ws: Workspace, root: NSView,
        expectedFormat: DocumentFormatID, expectedWrap: Bool,
        label: String, tick: Int, completion: @escaping () -> Void
    ) {
        let textView = editorTextView(in: root) as? TextView
        // Entspricht dem Öffnen eines nativen Hauptmenüs: AppKit fragt die
        // SwiftUI-Command-Validierung ab, bevor der Haken sichtbar wird.
        NSApp.mainMenu?.update()
        let menuItem = findMenuItem(titled: "Soft Wrap", in: NSApp.mainMenu)
        let menuMatches = menuItem?.state == (expectedWrap ? .on : .off)
        if ws.activeDocumentFormat.id == expectedFormat,
           ws.softWrapEnabled == expectedWrap,
           textView?.wrapLines == expectedWrap,
           menuMatches {
            completion()
            return
        }
        if tick >= 80 {
            finish(false, "\(label) nicht binnen 8 s sichtbar: "
                + "format=\(ws.activeDocumentFormat.id.rawValue), "
                + "store=\(ws.softWrapEnabled), textView=\(String(describing: textView?.wrapLines)), "
                + "menu=\(String(describing: menuItem?.state.rawValue))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollSoftWrapState(
                ws: ws, root: root, expectedFormat: expectedFormat,
                expectedWrap: expectedWrap, label: label, tick: tick + 1,
                completion: completion
            )
        }
    }

    private static func findMenuItem(titled title: String, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.title == title { return item }
            if let found = findMenuItem(titled: title, in: item.submenu) {
                return found
            }
        }
        return nil
    }

    // MARK: - -selftest softwrapmodes

    /// Prüft die drei Umbruchziele am laufenden Editor. Der Test misst die
    /// echte CodeEdit-Layoutbreite, die Seitenlinienposition und die
    /// Fortschrittsgarantie der erzeugten Fragmente. Zielwechsel, Resize und
    /// Font-Zoom dürfen dabei weder Text noch Auswahl, Dirty- oder Undo-Zustand
    /// verändern.
    private static func runSoftWrapModesTest() {
        testLabel = "softwrapmodes"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }) else {
            finish(false, "kein Hauptfenster gefunden")
        }

        waitForEditor(workspace: ws, window: mainWindow) { root, _ in
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "fastra-softwrapmodes-\(UUID().uuidString).md"
                )
            let content = "Start\t"
                + String(repeating: "Wort ", count: 90)
                + String(repeating: "Langtoken", count: 80)
                + " 👨‍👩‍👧‍👦 Ende\n"
            do {
                try content.write(to: tmp, atomically: true, encoding: .utf8)
            } catch {
                finish(false, "Fixture nicht schreibbar: \(error.localizedDescription)")
            }

            ws.loadFile(at: tmp) { ok in
                try? FileManager.default.removeItem(at: tmp)
                guard ok else { finish(false, "Markdown-Fixture nicht ladbar") }
                pollForSoftWrapEditor(root: root, tick: 0) { textView, _ in
                    let selection = NSRange(location: 2, length: 7)
                    textView.selectionManager.setSelectedRange(selection)
                    let identity = ObjectIdentifier(textView)
                    let textBefore = textView.string
                    let dirtyBefore = ws.activeTab?.isDirty
                    let canUndoBefore = textView.undoManager?.canUndo

                    ws.setShowPageGuide(true)
                    ws.setPageGuideColumn(40)
                    ws.selectSoftWrapTarget(.window)
                    pollSoftWrapWindowGeometry(
                        ws: ws, root: root, guideColumn: 40, tick: 0
                    ) {
                        ws.setSoftWrapFixedColumn(40)
                        pollSoftWrapGeometry(
                            ws: ws, root: root, expectedTarget: .fixedColumn,
                            wrapColumn: 40, guideColumn: 40,
                            label: "feste Spalte", tick: 0
                        ) { _ in
                            ws.setPageGuideColumn(55)
                            ws.selectSoftWrapTarget(.pageGuide)
                            pollSoftWrapGeometry(
                                ws: ws, root: root, expectedTarget: .pageGuide,
                                wrapColumn: 55, guideColumn: 55,
                                label: "Seitenlinie", tick: 0
                            ) { pageGuideWidth in
                                var narrowFrame = mainWindow.frame
                                narrowFrame.size.width = 430
                                ws.setSoftWrapFixedColumn(120)
                                mainWindow.setFrame(narrowFrame, display: true)
                                pollSoftWrapGeometry(
                                    ws: ws, root: root,
                                    expectedTarget: .fixedColumn,
                                    wrapColumn: 120, guideColumn: 55,
                                    requireViewportClamp: true,
                                    label: "Viewport-Obergrenze", tick: 0
                                ) { _ in
                                    ws.setPageGuideColumn(55)
                                    ws.selectSoftWrapTarget(.pageGuide)
                                    mainWindow.setContentSize(
                                        NSSize(width: 900, height: 600)
                                    )
                                    // Das Resize erst vollständig durch SwiftUI
                                    // reconciliieren lassen. Würden wir die
                                    // Controller-Schrift vorher ändern, spielt das
                                    // anschließende View-Update absichtlich die
                                    // aktuelle App-Zoom-Konfiguration wieder ein.
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                        guard let zoomController =
                                            sourceEditorController(for: textView) else {
                                            finish(false, "Controller vor Font-Zoom verloren")
                                        }
                                        var zoomed = zoomController.configuration
                                        zoomed.appearance.font =
                                            .monospacedSystemFont(
                                                ofSize: 20, weight: .regular
                                            )
                                        zoomController.configuration = zoomed
                                        pollSoftWrapGeometry(
                                            ws: ws, root: root,
                                            expectedTarget: .pageGuide,
                                            wrapColumn: 55, guideColumn: 55,
                                            minimumConfiguredWidth: pageGuideWidth,
                                            label: "Font-Zoom", tick: 0
                                        ) { _ in
                                            guard let current =
                                                    editorTextView(in: root) as? TextView,
                                                  ObjectIdentifier(current) == identity,
                                                  current.string == textBefore,
                                                  current.selectedRange() == selection,
                                                  ws.activeTab?.content == textBefore,
                                                  ws.activeTab?.isDirty == dirtyBefore,
                                                  current.undoManager?.canUndo == canUndoBefore else {
                                                finish(
                                                    false,
                                                    "Zielwechsel/Resize/Zoom veränderten "
                                                        + "Editoridentität, Text, Auswahl, "
                                                        + "Dirty- oder Undo-Zustand"
                                                )
                                            }
                                            let fragments = Array(
                                                current.layoutManager.lineStorage
                                            ).flatMap {
                                                Array($0.data.lineFragments)
                                            }
                                            guard fragments.count > 1,
                                                  fragments.allSatisfy({
                                                      $0.range.length > 0
                                                  }) else {
                                                finish(
                                                    false,
                                                    "Wort-/Langtoken-/Unicode-Umbruch "
                                                        + "erzeugte leere Fragmente"
                                                )
                                            }
                                            finish(
                                                true,
                                                "Fenster, Seitenlinie und feste Spalte "
                                                    + "reagieren auf Resize/Zoom; Textzustand "
                                                    + "und Unicode-Fragmente bleiben intakt"
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - -selftest softwrapanchor

    /// Reproduziert den sichtbaren Sprung beim Ein-/Ausschalten von Soft Wrap.
    /// Entscheidend ist nicht der absolute Scrollwert: Bei langen Zeilen ändert
    /// sich die Dokumenthöhe stark. Unabhängig beobachtet wird deshalb die
    /// tatsächlich oberste logische Textzeile über `textLineForPosition`.
    private static func runSoftWrapAnchorTest() {
        testLabel = "softwrapanchor"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }

        let longTail = String(repeating: "Wortgruppe ", count: 32)
        let content = (1...2_400).map {
            "Ankerzeile \($0)\t\(longTail)Ende \($0)"
        }.joined(separator: "\n")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fastra-softwrapanchor-\(UUID().uuidString).txt"
            )
        do {
            try content.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            finish(false, "Fixture nicht schreibbar: \(error.localizedDescription)")
        }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "Text-Fixture nicht ladbar") }
            pollForSoftWrapEditor(root: root, tick: 0) { textView, _ in
                ws.setSoftWrapFixedColumn(40)
                pollSoftWrapState(
                    ws: ws, root: root, expectedFormat: .plainText,
                    expectedWrap: true, label: "Anker-Fixture umbrochen",
                    tick: 0
                ) {
                    let textBefore = textView.string
                    let selectionBefore = textView.selectedRange()
                    let dirtyBefore = ws.activeTab?.isDirty
                    let canUndoBefore = textView.undoManager?.canUndo
                    let targetTopLine = 1_799
                    convergeSoftWrapAnchor(
                        textView: textView, targetLine: targetTopLine,
                        tick: 0
                    ) { expectedTopLine in
                        ws.toggleSoftWrap()
                        observeSoftWrapAnchor(
                            ws: ws, textView: textView,
                            expectedWrap: false,
                            expectedTopLine: expectedTopLine,
                            tick: 0, observedLines: [],
                            maximumDrift: 0
                        ) {
                            ws.toggleSoftWrap()
                            observeSoftWrapAnchor(
                                ws: ws, textView: textView,
                                expectedWrap: true,
                                expectedTopLine: expectedTopLine,
                                tick: 0, observedLines: [],
                                maximumDrift: 0
                            ) {
                                guard textView.string == textBefore,
                                      textView.selectedRange() == selectionBefore,
                                      ws.activeTab?.content == textBefore,
                                      ws.activeTab?.isDirty == dirtyBefore,
                                      textView.undoManager?.canUndo == canUndoBefore else {
                                    finish(
                                        false,
                                        "Umschalten veränderte Text, Auswahl, "
                                            + "Dirty- oder Undo-Zustand"
                                    )
                                }
                                finish(
                                    true,
                                    "oberste Textzeile \(expectedTopLine + 1) "
                                        + "blieb bei Aus und Ein ohne "
                                        + "Zwischenabweichung identisch"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - -selftest selectionscroll

    /// Prüft im gepackten Editor den NSTextInputClient-Befehl, den AppKit für
    /// Shift+Pfeil nach unten aufruft. Die Messung verwendet bewusst die
    /// bewegte Range-Kante selbst und nicht CodeEdits Scroll-Hilfsfunktion.
    private static func runSelectionScrollTest() {
        testLabel = "selectionscroll"
        if let selectionScrollSetupError {
            finishSelectionScroll(
                false,
                "Kaltstart-Fixture nicht anlegbar: \(selectionScrollSetupError)"
            )
        }
        guard let ws = Workspace.shared else {
            finishSelectionScroll(
                false,
                "Workspace.shared ist nil (Test-Hook fehlt)"
            )
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finishSelectionScroll(false, "kein Hauptfenster gefunden")
        }
        pollForMarkdownSelectionScrollEditor(
            ws: ws, mainWindow: mainWindow, root: root, tick: 0
        )
    }

    /// Wartet ausdrücklich auf BEIDE Hälften des Markdown-Splits. So kann ein
    /// TextView-only-Test nicht erneut die entscheidende Produktansicht
    /// umgehen, in der der Nutzer den fehlenden Scroll beobachtet hat.
    private static func pollForMarkdownSelectionScrollEditor(
        ws: Workspace, mainWindow: NSWindow, root: NSView, tick: Int
    ) {
        let markdownReady = ws.activeTab?.isLoading == false
            && ws.activeTab?.url?.canonicalFileURL
                == selectionScrollFixtureURL?.canonicalFileURL
            && markdownWebView(in: root) != nil
        if markdownReady,
           let textView = editorTextView(in: root) as? TextView,
           sourceEditorController(for: textView) != nil {
            exerciseMarkdownSelectionScroll(
                textView: textView, mainWindow: mainWindow
            )
            return
        }
        if tick >= 100 {
            finishSelectionScroll(
                false,
                "Markdown-Split mit linkem Editor nicht binnen 10 s bereit"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollForMarkdownSelectionScrollEditor(
                ws: ws, mainWindow: mainWindow, root: root, tick: tick + 1
            )
        }
    }

    /// Sendet echte Shift+↓-Events an den fokussierten linken Editor. Zwischen
    /// den einzelnen Tastenläufen liegt jeweils ein Runloop-Durchlauf wie bei
    /// mehreren echten Tastendrücken; erst danach wird der Viewport gemessen.
    private static func exerciseMarkdownSelectionScroll(
        textView: TextView, mainWindow: NSWindow
    ) {
        guard let scrollView = textView.enclosingScrollView else {
            finishSelectionScroll(false, "Editor-ScrollView fehlt")
        }
        textView.layoutManager.layoutLines()
        let source = textView.string as NSString
        let middleOffset = source.range(of: "Auswahlzeile 1600").location
        guard middleOffset != NSNotFound,
              let middleRect = textView.layoutManager.rectForOffset(
                  middleOffset
              ) else {
            finishSelectionScroll(false, "mittlere Fixture-Zeile nicht layoutbar")
        }
        scrollView.contentView.scroll(
            to: CGPoint(x: 0, y: middleRect.minY)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.updatedViewport(scrollView.documentVisibleRect)
        let visibleBefore = scrollView.documentVisibleRect
        textView.layoutManager.layoutLines(in: visibleBefore)
        guard visibleBefore.minY > 0,
              let firstRect = textView.layoutManager.rectForOffset(0),
              let cursorOffset = textView.layoutManager.textOffsetAtPoint(
                  CGPoint(
                      x: visibleBefore.minX + 140,
                      y: visibleBefore.maxY - firstRect.height * 2
                  )
              ) else {
            finishSelectionScroll(
                false,
                "Startposition im mittleren Viewport nicht bestimmbar"
            )
        }
        textView.selectionManager.setSelectedRange(
            NSRange(location: cursorOffset, length: 0)
        )
        let initialTop = visibleBefore.minY

        guard mainWindow.makeFirstResponder(textView) else {
            finishSelectionScroll(
                false,
                "linker Markdown-Editor wurde nicht First Responder"
            )
        }
        if let flags = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero,
            modifierFlags: .shift,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: mainWindow.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 56
        ) {
            NSApp.postEvent(flags, atStart: false)
        }
        sendMarkdownSelectionScrollKey(
            textView: textView,
            scrollView: scrollView,
            mainWindow: mainWindow,
            initialTop: initialTop,
            step: 0
        )
    }

    private static func sendMarkdownSelectionScrollKey(
        textView: TextView,
        scrollView: NSScrollView,
        mainWindow: NSWindow,
        initialTop: CGFloat,
        step: Int
    ) {
        guard let key = NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: .shift,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: mainWindow.windowNumber, context: nil,
            characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125
        ) else {
            finishSelectionScroll(
                false,
                "konnte Shift+Pfeil-nach-unten nicht bauen"
            )
        }
        // Durch die NSApplication-Queue laufen lassen, damit dieselben lokalen
        // Event-Monitore wie bei der physischen Tastatur beteiligt sind.
        NSApp.postEvent(key, atStart: false)

        if step < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                sendMarkdownSelectionScrollKey(
                    textView: textView,
                    scrollView: scrollView,
                    mainWindow: mainWindow,
                    initialTop: initialTop,
                    step: step + 1
                )
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let range = textView.selectedRange()
                guard range.length > 0,
                      let activeRect = textView.layoutManager.rectForOffset(
                          NSMaxRange(range)
                      ) else {
                    finishSelectionScroll(
                        false,
                        "bewegte Auswahlkante nicht layoutbar"
                    )
                }
                let visibleRect = scrollView.documentVisibleRect
                guard visibleRect.minY > initialTop,
                      visibleRect.contains(activeRect) else {
                    finishSelectionScroll(
                        false,
                        "bewegte Kante außerhalb: Auswahl=\(range), "
                            + "Viewport=\(visibleRect), Kante=\(activeRect)"
                    )
                }
                finishSelectionScroll(
                    true,
                    "Shift-Auswahl scrollte von y=\(Int(initialTop)) auf "
                        + "y=\(Int(visibleRect.minY)); bewegte Kante sichtbar"
                )
            }
        }
    }

    private static func finishSelectionScroll(
        _ ok: Bool,
        _ message: String
    ) -> Never {
        if let directory = selectionScrollFixtureDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        selectionScrollFixtureDirectory = nil
        selectionScrollFixtureURL = nil
        finish(ok, message)
    }

    /// Scrollt iterativ, bis die Zielzeile wirklich oben liegt. Ein einmalig
    /// aus `rectForOffset` berechneter Wert wäre bei noch nicht ausgelegten
    /// langen Umbruchzeilen nur eine Schätzung und kein unabhängiger Repro.
    private static func convergeSoftWrapAnchor(
        textView: TextView, targetLine: Int, tick: Int,
        completion: @escaping (Int) -> Void
    ) {
        guard let scrollView = textView.enclosingScrollView,
              let line = textView.layoutManager.textLineForIndex(targetLine),
              let rect = textView.layoutManager.rectForOffset(
                line.range.location
              ) else {
            finish(false, "Ankerzeile nicht layoutbar")
        }
        let targetY = max(
            rect.minY - scrollView.contentInsets.top,
            0
        )
        scrollView.contentView.scroll(
            to: NSPoint(
                x: scrollView.contentView.bounds.origin.x,
                y: targetY
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.layoutManager.layoutLines()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let shown = textView.layoutManager.textLineForPosition(
                textView.visibleRect.minY
            )?.index
            if let shown, abs(shown - targetLine) <= 1 {
                completion(shown)
            } else if tick >= 30 {
                finish(
                    false,
                    "Ankerzeile \(targetLine + 1) nicht oben erreichbar; "
                        + "sichtbar=\(shown.map { String($0 + 1) } ?? "nil")"
                )
            } else {
                convergeSoftWrapAnchor(
                    textView: textView, targetLine: targetLine,
                    tick: tick + 1, completion: completion
                )
            }
        }
    }

    /// Beobachtet nicht nur den Endzustand: Jede sichtbare Zwischenposition
    /// zählt. So schützt der Test auch vor den früheren asynchronen
    /// Nachkorrekturen, die den Text fast eine Sekunde auf- und abbewegten.
    private static func observeSoftWrapAnchor(
        ws: Workspace, textView: TextView,
        expectedWrap: Bool, expectedTopLine: Int,
        tick: Int, observedLines: [Int],
        maximumDrift: CGFloat,
        completion: @escaping () -> Void
    ) {
        let wrapApplied = ws.softWrapEnabled == expectedWrap
            && textView.wrapLines == expectedWrap
        let shown = textView.layoutManager.textLineForPosition(
            textView.visibleRect.minY
        )?.index

        var nextObservedLines = observedLines
        var nextMaximumDrift = maximumDrift
        if wrapApplied, let shown {
            if nextObservedLines.last != shown {
                nextObservedLines.append(shown)
            }
            if let anchor = textView.layoutManager.textLineForIndex(
                expectedTopLine
            ), let rect = textView.layoutManager.rectForOffset(
                anchor.range.location
            ) {
                nextMaximumDrift = max(
                    nextMaximumDrift,
                    abs(rect.minY - textView.visibleRect.minY)
                )
            }
        }

        if tick >= 60 {
            guard wrapApplied,
                  shown == expectedTopLine,
                  !nextObservedLines.isEmpty,
                  nextObservedLines.allSatisfy({ $0 == expectedTopLine }),
                  nextMaximumDrift <= 2 else {
                finish(
                    false,
                    "Soft Wrap \(expectedWrap ? "Ein" : "Aus") zappelte: "
                        + "erwartet Zeile \(expectedTopLine + 1), "
                        + "Folge=\(nextObservedLines.map { $0 + 1 }), "
                        + "maximale Drift=\(Int(nextMaximumDrift)) pt"
                )
            }
            completion()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            observeSoftWrapAnchor(
                ws: ws, textView: textView,
                expectedWrap: expectedWrap,
                expectedTopLine: expectedTopLine,
                tick: tick + 1,
                observedLines: nextObservedLines,
                maximumDrift: nextMaximumDrift,
                completion: completion
            )
        }
    }

    /// Wartet nach einem Dateiwechel, bis TextView und der zugehörige
    /// CodeEdit-Controller gemeinsam in der Responderkette angekommen sind.
    private static func pollForSoftWrapEditor(
        root: NSView, tick: Int,
        completion: @escaping (TextView, TextViewController) -> Void
    ) {
        if let textView = editorTextView(in: root) as? TextView,
           let controller = sourceEditorController(for: textView) {
            completion(textView, controller)
            return
        }
        if tick >= 80 {
            finish(false, "TextViewController nicht binnen 8 s erreichbar")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollForSoftWrapEditor(
                root: root, tick: tick + 1, completion: completion
            )
        }
    }

    private static func pollSoftWrapWindowGeometry(
        ws: Workspace, root: NSView, guideColumn: Int, tick: Int,
        completion: @escaping () -> Void
    ) {
        if let textView = editorTextView(in: root) as? TextView,
           let controller = sourceEditorController(for: textView),
           let guide = findView(named: "ReformattingGuideView", in: root) {
            textView.layoutManager.layoutLines()
            let fontWidth = (" " as NSString).size(
                withAttributes: [.font: controller.font]
            ).width
            let characterWidth = max(fontWidth + textView.kern, 1)
            let expectedGuideWidth = CGFloat(guideColumn) * characterWidth
            let guideOffset = guide.frame.minX
                - textView.layoutManager.edgeInsets.left
            let fragments = Array(textView.layoutManager.lineStorage).flatMap {
                Array($0.data.lineFragments)
            }
            if ws.softWrapEnabled,
               ws.softWrapTarget == .window,
               ws.effectiveSoftWrapColumn == nil,
               ws.pageGuideColumn == guideColumn,
               ws.showPageGuide,
               textView.wrapLines,
               textView.layoutManager.maximumWrapWidth == nil,
               !guide.isHidden,
               abs(guideOffset - expectedGuideWidth) < 1.1,
               fragments.count > 1 {
                completion()
                return
            }
        }
        if tick >= 80 {
            finish(
                false,
                "Fensterbreite nicht binnen 8 s korrekt: "
                    + "target=\(ws.softWrapTarget.rawValue), "
                    + "column=\(String(describing: ws.effectiveSoftWrapColumn))"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollSoftWrapWindowGeometry(
                ws: ws, root: root, guideColumn: guideColumn,
                tick: tick + 1, completion: completion
            )
        }
    }

    private static func pollSoftWrapGeometry(
        ws: Workspace, root: NSView,
        expectedTarget: SoftWrapTarget,
        wrapColumn: Int, guideColumn: Int,
        requireViewportClamp: Bool = false,
        minimumConfiguredWidth: CGFloat? = nil,
        label: String, tick: Int,
        completion: @escaping (CGFloat) -> Void
    ) {
        if let textView = editorTextView(in: root) as? TextView,
           let controller = sourceEditorController(for: textView),
           let configuredWidth = textView.layoutManager.maximumWrapWidth,
           let guide = findView(named: "ReformattingGuideView", in: root) {
            textView.layoutManager.layoutLines()
            let fontWidth = (" " as NSString).size(
                withAttributes: [.font: controller.font]
            ).width
            let characterWidth = max(fontWidth + textView.kern, 1)
            let expectedWrapWidth = CGFloat(wrapColumn) * characterWidth
            let expectedGuideWidth = CGFloat(guideColumn) * characterWidth
            let guideOffset = guide.frame.minX
                - textView.layoutManager.edgeInsets.left
            let widthMatches = abs(configuredWidth - expectedWrapWidth) < 1
            let guideMatches = abs(guideOffset - expectedGuideWidth) < 1.1
            let clampMatches = !requireViewportClamp
                || textView.layoutManager.maxLineLayoutWidth < configuredWidth
            let zoomMatches = minimumConfiguredWidth.map {
                configuredWidth > $0
            } ?? true
            if ws.softWrapEnabled,
               ws.softWrapTarget == expectedTarget,
               ws.effectiveSoftWrapColumn == wrapColumn,
               ws.pageGuideColumn == guideColumn,
               ws.showPageGuide,
               textView.wrapLines,
               !guide.isHidden,
               widthMatches, guideMatches, clampMatches, zoomMatches {
                completion(configuredWidth)
                return
            }
        }
        if tick >= 80 {
            let textView = editorTextView(in: root) as? TextView
            finish(
                false,
                "\(label) nicht binnen 8 s korrekt: "
                    + "target=\(ws.softWrapTarget.rawValue), "
                    + "column=\(String(describing: ws.effectiveSoftWrapColumn)), "
                    + "configured=\(String(describing: textView?.layoutManager.maximumWrapWidth)), "
                    + "layout=\(String(describing: textView?.layoutManager.maxLineLayoutWidth))"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollSoftWrapGeometry(
                ws: ws, root: root, expectedTarget: expectedTarget,
                wrapColumn: wrapColumn, guideColumn: guideColumn,
                requireViewportClamp: requireViewportClamp,
                minimumConfiguredWidth: minimumConfiguredWidth,
                label: label, tick: tick + 1, completion: completion
            )
        }
    }

    private static func sourceEditorController(
        for textView: TextView
    ) -> TextViewController? {
        var responder: NSResponder? = textView
        var remaining = 50
        while let current = responder, remaining > 0 {
            if let controller = current as? TextViewController {
                return controller
            }
            responder = current.nextResponder
            remaining -= 1
        }
        return nil
    }

    /// Belegt END-TO-END, dass der Editor Syntax-Highlighting wirklich FÄRBT:
    /// eine Python-Datei mit Keyword/String/Kommentar wird in einen Tab
    /// geladen; danach müssen im ECHTEN Editor-TextStorage mehrere
    /// VERSCHIEDENE Vordergrundfarben stehen. Fängt die Bug-Klasse „Sprache
    /// erkannt, aber alles monochrom" (Daniel-Befund 2026-07-10) — Unit-Tests
    /// sehen die nicht, weil der Pfad CodeLanguage → TreeSitterClient →
    /// Query-Bundle → Attribut-Anwendung nur im echten App-Prozess läuft.
    /// Tree-sitter arbeitet asynchron → engmaschig pollen statt Einmal-Messung.
    private static func runHighlightTest() {
        testLabel = "highlight"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }
        _ = mainWindow

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-highlight-\(UUID().uuidString).py")
        let code = """
        # Kommentar in eigener Farbe
        def greet(name):
            count = 42
            return "Hallo " + name + str(count)
        """
        do { try code.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            guard ok else {
                try? FileManager.default.removeItem(at: tmp)
                finish(false, "loadFile schlug fehl (completion false)")
            }
            pollHighlightColors(root: root, url: tmp, tick: 0)
        }
    }

    /// Pollt (max. 10 s, 0,25-s-Takt), bis der Editor-TextStorage ≥ 2
    /// verschiedene Vordergrundfarben trägt. Timeout → FAIL inkl. Diagnose
    /// (erkannte Sprache, tree-sitter-Grammatik vorhanden?, Query-Pfad).
    private static func pollHighlightColors(root: NSView, url: URL, tick: Int) {
        let maxTicks = 40            // 40 × 0,25 s = 10 s
        let farben = distinctForegroundColors(in: root)
        if farben >= 2 {
            try? FileManager.default.removeItem(at: url)
            finish(true, "Editor färbt: \(farben) verschiedene Vordergrundfarben im TextStorage")
        }
        if tick >= maxTicks {
            let lang = CodeLanguage.detectLanguageFrom(url: url)
            let query = lang.queryURL
            let queryExists = query.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            try? FileManager.default.removeItem(at: url)
            finish(false, "monochrom nach 10 s (\(farben) Farbe(n)) — "
                + "Sprache=\(lang.id.rawValue), "
                + "tsLanguage=\(lang.language != nil ? "ok" : "NIL"), "
                + "queryURL=\(query?.path ?? "nil") existiert=\(queryExists)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollHighlightColors(root: root, url: url, tick: tick + 1)
        }
    }

    // MARK: - 4D-Vervollständigung (Etappe 6 Wunschpaket 2026-07c)

    /// Zustand für den mehrstufigen Completion-Selbsttest. Die Prüfschritte
    /// sammeln ihre Befunde, damit ein defektes Auto-Popup die unabhängige
    /// Prüfung von ⌃Leertaste, Pfeil und Maus nicht überspringt.
    private final class FourDCompletionTestState {
        let projectRoot: URL
        let fileURL: URL
        let initialText: String
        let componentMethod = "ZZF_ComponentShared"
        var failures: [String] = []

        init(projectRoot: URL, fileURL: URL, initialText: String) {
            self.projectRoot = projectRoot
            self.fileURL = fileURL
            self.initialText = initialText
        }
    }

    /// Reproduziert die 4D-Vervollständigung am LAUFENDEN
    /// CodeEditSourceEditor: Eine echte `.4dm` wird geladen, `A` und `L`
    /// gehen über die öffentliche TextView-Eingabe hinein, anschließend öffnet
    /// ⌃Leertaste die gleiche Liste. Gemessen wird nicht die Delegate-Logik, sondern das
    /// sichtbare CESE-Fenster mit seiner echten `NSTableView`.
    ///
    /// Danach muss ↓ die Auswahl bewegen, ein gezielter Mausklick die Auswahl
    /// ändern und ein Doppelklick die erste 4D-Vervollständigung übernehmen.
    /// Damit schützt der Test genau die Anbindung, die reine Unit-Tests nicht
    /// sehen: Text-Delegate, Event-Monitore, Fenster und Hit-Testing.
    private static func runFourDCompletionTest() {
        testLabel = "completion4d"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }

        // Echtes temporäres 4D-Projekt: Die geteilte Methode muss durch den
        // produktiven Komponentenindex in den produktiven Completion-Provider
        // gelangen. Das leere Aufruferdokument erzeugt danach nur die
        // ausdrücklich eingegebenen Präfixe.
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-completion4d-\(UUID().uuidString)")
        let methods = projectRoot.appendingPathComponent(
            "Project/Sources/Methods", isDirectory: true
        )
        let componentMethods = projectRoot.appendingPathComponent(
            "Components/FastraTools.4dbase/Project/Sources/Methods",
            isDirectory: true
        )
        let url = methods.appendingPathComponent("Aufrufer.4dm")
        // `Workspace.loadFile` kanonisiert `/var` zu `/private/var`. Der Test
        // muss dieselbe URL-Form speichern, sonst würde er einen korrekt
        // geladenen 4D-Tab fälschlich nie als aktiv erkennen.
        let fixtureText = "// Completion-Selbsttest\n"
        let state = FourDCompletionTestState(
            projectRoot: projectRoot.canonicalFileURL,
            fileURL: url.canonicalFileURL,
            initialText: fixtureText
        )
        do {
            try FileManager.default.createDirectory(
                at: methods, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: componentMethods, withIntermediateDirectories: true
            )
            try fixtureText.write(to: url, atomically: true, encoding: .utf8)
            try "//%attributes = {\"shared\":true}\n".write(
                to: componentMethods.appendingPathComponent("\(state.componentMethod).4dm"),
                atomically: true, encoding: .utf8
            )
        } catch {
            try? FileManager.default.removeItem(at: projectRoot)
            finish(false, "Completion-Fixture nicht schreibbar: \(error.localizedDescription)")
        }

        NSApp.appearance = NSAppearance(named: .aqua)
        ws.openProject(at: state.projectRoot)
        pollForFourDCompletionComponentIndex(
            ws: ws, mainWindow: mainWindow, root: root, state: state
        )
    }

    private static func pollForFourDCompletionComponentIndex(
        ws: Workspace,
        mainWindow: NSWindow,
        root: NSView,
        state: FourDCompletionTestState,
        tick: Int = 0
    ) {
        if ws.fourDComponentMethods[state.componentMethod.lowercased()] != nil {
            ws.loadFile(at: state.fileURL) { ok in
                guard ok else {
                    finishFourDCompletionTest(state, ok: false,
                                              message: "loadFile (.4dm) schlug fehl")
                }
                pollForFourDCompletionEditor(
                    ws: ws, mainWindow: mainWindow, root: root, state: state
                )
            }
            return
        }
        if tick >= 120 {
            finishFourDCompletionTest(
                state, ok: false,
                message: "Shared-Component-Methode nicht binnen 6 s indiziert"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollForFourDCompletionComponentIndex(
                ws: ws, mainWindow: mainWindow, root: root,
                state: state, tick: tick + 1
            )
        }
    }

    /// Wartet auf die neu gemountete TextView der `.4dm`-Datei. Ein
    /// gewöhnlicher Delay wäre hier unscharf: Der Tab-Wechsel erzeugt den
    /// SourceEditor neu, und erst diese Instanz trägt den 4D-Delegate.
    private static func pollForFourDCompletionEditor(
        ws: Workspace,
        mainWindow: NSWindow,
        root: NSView,
        state: FourDCompletionTestState,
        tick: Int = 0
    ) {
        // Die vom Workspace kanonisierte URL kann auf macOS einen anderen
        // Pfad-Alias tragen. Für diese Test-Fixture ist die aktive, geladene
        // `.4dm`-Endung die robuste und zugleich produktrelevante Bedingung.
        let isFourDTab = ws.activeTab?.isLoading == false
            && ws.activeTab?.url?.pathExtension.lowercased() == "4dm"
        if isFourDTab,
           let textView = completionEditorTextView(in: root, window: mainWindow,
                                                   expectedText: state.initialText) {
            // Der CESE-Monitor reagiert nur im Key-Window. Der Runner holt
            // die Test-App dafür nach vorn; verliert der Nutzer oder macOS
            // diesen Fokus, wäre ein fehlendes Popup kein Produktbefund.
            guard mainWindow.isKeyWindow else {
                if tick >= 120 {
                    finishFourDCompletionTest(state, ok: false,
                                              message: "Umgebungsproblem: 4D-Editor wurde nicht Key-Window")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    pollForFourDCompletionEditor(ws: ws, mainWindow: mainWindow,
                                                 root: root, state: state, tick: tick + 1)
                }
                return
            }
            guard mainWindow.makeFirstResponder(textView) else {
                finishFourDCompletionTest(state, ok: false,
                                          message: "4D-Editor wurde nicht First Responder")
            }
            // Zwei Einfügungen am laufenden TextView. Diese öffentliche
            // AppKit-Eingabemethode läuft durch dieselbe CESE-Textmutation und
            // deren Delegate wie eine getippte Taste; ein Queue-`keyDown` kann
            // in der bewusst nicht aktivierten Selbsttest-App dagegen schon im
            // System-Input-Context enden, bevor die TextView ihn sieht.
            textView.selectionManager.setSelectedRange(
                NSRange(location: (textView.string as NSString).length, length: 0)
            )
            guard insertCompletionCharacter("A", into: textView) else {
                finishFourDCompletionTest(state, ok: false,
                                          message: "konnte A für 4D-Editor nicht einfügen")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard insertCompletionCharacter("L", into: textView) else {
                    finishFourDCompletionTest(state, ok: false,
                                              message: "konnte L für 4D-Editor nicht einfügen")
                }
                pollForAutomaticFourDCompletion(mainWindow: mainWindow,
                                                textView: textView, state: state)
            }
            return
        }
        if tick >= 120 {
            finishFourDCompletionTest(state, ok: false,
                                      message: "`.4dm`-Editor nicht binnen 6 s aktiv/montiert")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollForFourDCompletionEditor(ws: ws, mainWindow: mainWindow,
                                         root: root, state: state, tick: tick + 1)
        }
    }

    /// Beobachtet das automatisch geöffnete CESE-Fenster nach der produktiven
    /// TextView-Eingabe. Die Textprüfung verhindert, dass ein fehlendes Routing
    /// fälschlich als Completion-Fehler gezählt wird.
    private static func pollForAutomaticFourDCompletion(
        mainWindow: NSWindow,
        textView: TextView,
        state: FourDCompletionTestState,
        tick: Int = 0
    ) {
        if let popup = fourDCompletionWindow(attachedTo: mainWindow) {
            guard let table = completionTable(in: popup), table.numberOfRows > 1 else {
                state.failures.append("automatisches Popup hat keine auswertbare Vorschlagsliste")
                closeAutomaticCompletionThenStartManual(mainWindow: mainWindow,
                                                         textView: textView, state: state)
                return
            }
            closeAutomaticCompletionThenStartManual(mainWindow: mainWindow,
                                                     textView: textView, state: state)
            return
        }
        if tick >= 80 {              // 80 × 50 ms = 4 s für CESE-Task + Layout
            let expectedText = state.initialText + "AL"
            if textView.string != expectedText {
                let selections = textView.selectionManager.textSelections.map(\.range)
                finishFourDCompletionTest(state, ok: false,
                                          message: "Testeingabe kam nicht im Editor an "
                                            + "(Text=\"\(textView.string)\", editable=\(textView.isEditable), "
                                            + "delegate=\(String(describing: textView.delegate)), "
                                            + "Selektionen=\(selections))")
            }
            state.failures.append("automatisches Popup blieb nach der Eingabe von „AL“ aus")
            startManualFourDCompletion(mainWindow: mainWindow, textView: textView, state: state)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollForAutomaticFourDCompletion(mainWindow: mainWindow,
                                            textView: textView, state: state, tick: tick + 1)
        }
    }

    /// Schließt ein vorhandenes Auto-Popup mit einem echten Escape-Event.
    /// Der Fallback räumt nur für den folgenden, unabhängigen ⌃Leertaste-Test
    /// auf; der Fehler bleibt vorher im Befund erhalten.
    private static func closeAutomaticCompletionThenStartManual(
        mainWindow: NSWindow,
        textView: TextView,
        state: FourDCompletionTestState,
        tick: Int = 0
    ) {
        if tick == 0 {
            postKey("\u{1b}", keyCode: 53, windowNumber: mainWindow.windowNumber)
        }
        if fourDCompletionWindow(attachedTo: mainWindow) == nil {
            startManualFourDCompletion(mainWindow: mainWindow, textView: textView, state: state)
            return
        }
        if tick >= 30 {
            state.failures.append("automatisches Popup ließ sich nicht mit Escape schließen")
            fourDCompletionWindow(attachedTo: mainWindow)?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                startManualFourDCompletion(mainWindow: mainWindow, textView: textView, state: state)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            closeAutomaticCompletionThenStartManual(mainWindow: mainWindow,
                                                     textView: textView, state: state, tick: tick + 1)
        }
    }

    /// Öffnet die Liste ausschließlich über den produktiven CESE-Shortcut
    /// ⌃Leertaste. Der Test ruft bewusst NICHT den Delegate oder Controller
    /// direkt auf, damit ein kaputtes Event-Routing sichtbar bleibt.
    private static func startManualFourDCompletion(
        mainWindow: NSWindow,
        textView: TextView,
        state: FourDCompletionTestState
    ) {
        guard mainWindow.isKeyWindow else {
            finishFourDCompletionTest(state, ok: false,
                                      message: "Umgebungsproblem: Fokus vor ⌃Leertaste verloren")
        }
        guard mainWindow.makeFirstResponder(textView) else {
            finishFourDCompletionTest(state, ok: false,
                                      message: "4D-Editor verlor vor ⌃Leertaste den First Responder")
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: mainWindow.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49
        ) else {
            finishFourDCompletionTest(state, ok: false,
                                      message: "konnte ⌃Leertaste-Event nicht bauen")
        }
        NSApp.postEvent(event, atStart: false)
        pollForManualFourDCompletion(mainWindow: mainWindow, textView: textView, state: state)
    }

    /// Wartet auf die über ⌃Leertaste geöffnete Liste und beginnt erst dann
    /// die Eingabeprüfung. Das trennt „Popup erscheint nicht“ sauber von
    /// „sichtbares Popup ist nicht bedienbar“.
    private static func pollForManualFourDCompletion(
        mainWindow: NSWindow,
        textView: TextView,
        state: FourDCompletionTestState,
        tick: Int = 0
    ) {
        guard mainWindow.isKeyWindow else {
            finishFourDCompletionTest(state, ok: false,
                                      message: "Umgebungsproblem: Fokus während ⌃Leertaste verloren")
        }
        if let popup = fourDCompletionWindow(attachedTo: mainWindow),
           let table = completionTable(in: popup), table.numberOfRows > 1 {
            // `items` wird in CESE über einen asynchronen Publisher in die
            // Tabelle geschrieben. Erst nach dessen letztem Reload ist die
            // Auswahl stabil; ein sofort geposteter Pfeil könnte sonst korrekt
            // wirken und gleich wieder auf Zeile 0 zurückgesetzt werden.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                testFourDCompletionArrow(mainWindow: mainWindow, popup: popup,
                                         textView: textView, table: table, state: state)
            }
            return
        }
        if tick >= 80 {
            state.failures.append("mit ⌃Leertaste geöffnetes Popup erschien nicht")
            finishFourDCompletionTest(state, ok: false,
                                      message: state.failures.joined(separator: "; "))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollForManualFourDCompletion(mainWindow: mainWindow, textView: textView,
                                         state: state, tick: tick + 1)
        }
    }

    /// Ein Pfeil-Event muss die SELEKTION der echten Vorschlagstabelle von
    /// Zeile 0 auf Zeile 1 verschieben. Das ist unabhängig davon beobachtbar,
    /// ob ein Fenster zufällig bloß gezeichnet wird.
    private static func testFourDCompletionArrow(
        mainWindow: NSWindow,
        popup: NSWindow,
        textView: TextView,
        table: NSTableView,
        state: FourDCompletionTestState
    ) {
        guard mainWindow.isKeyWindow else {
            finishFourDCompletionTest(state, ok: false,
                                      message: "Umgebungsproblem: Fokus vor Pfeiltaste verloren")
        }
        guard table.selectedRow == 0 else {
            state.failures.append("Vorschlagsliste startet nicht mit Zeile 0 (Ist: \(table.selectedRow))")
            testFourDCompletionClick(mainWindow: mainWindow, popup: popup,
                                     textView: textView, table: table, state: state)
            return
        }
        // NSDownArrowFunctionKey beschreibt das Event vollständig; CESE selbst
        // entscheidet aber bewusst über den Hardware-Keycode 125.
        postKey("\u{F701}", keyCode: 125, windowNumber: mainWindow.windowNumber)
        pollForFourDCompletionArrow(mainWindow: mainWindow, popup: popup,
                                    textView: textView, table: table, state: state)
    }

    private static func pollForFourDCompletionArrow(
        mainWindow: NSWindow,
        popup: NSWindow,
        textView: TextView,
        table: NSTableView,
        state: FourDCompletionTestState,
        tick: Int = 0
    ) {
        if table.selectedRow == 1 {
            testFourDCompletionClick(mainWindow: mainWindow, popup: popup,
                                     textView: textView, table: table, state: state)
            return
        }
        if tick >= 40 {
            state.failures.append("↓ bewegte die Vorschlagsauswahl nicht (Zeile blieb \(table.selectedRow))")
            testFourDCompletionClick(mainWindow: mainWindow, popup: popup,
                                     textView: textView, table: table, state: state)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollForFourDCompletionArrow(mainWindow: mainWindow, popup: popup,
                                        textView: textView, table: table,
                                        state: state, tick: tick + 1)
        }
    }

    /// Klickt gezielt in die jeweils ANDERE sichtbare Tabellenzeile. Damit
    /// kann der Test eine echte Mausreaktion auch dann beobachten, wenn die
    /// Pfeiltaste zuvor schon ausgefallen ist.
    private static func testFourDCompletionClick(
        mainWindow: NSWindow,
        popup: NSWindow,
        textView: TextView,
        table: NSTableView,
        state: FourDCompletionTestState
    ) {
        guard mainWindow.isKeyWindow else {
            finishFourDCompletionTest(state, ok: false,
                                      message: "Umgebungsproblem: Fokus vor Mausklick verloren")
        }
        let targetRow = table.selectedRow == 0 ? 1 : 0
        guard postCompletionMouseClick(in: table, row: targetRow, window: popup, clickCount: 1) else {
            finishFourDCompletionTest(state, ok: false,
                                      message: "konnte gezielten Klick in Vorschlagsliste nicht bauen")
        }
        pollForFourDCompletionClick(mainWindow: mainWindow, popup: popup,
                                    textView: textView, table: table, targetRow: targetRow,
                                    state: state)
    }

    private static func pollForFourDCompletionClick(
        mainWindow: NSWindow,
        popup: NSWindow,
        textView: TextView,
        table: NSTableView,
        targetRow: Int,
        state: FourDCompletionTestState,
        tick: Int = 0
    ) {
        if table.selectedRow == targetRow {
            // Der erste Treffer für „AL“ ist die generierte 4D-Anweisung
            // `ALERT`. Ein Doppelklick muss sie über den normalen CESE-Pfad
            // übernehmen — das beweist neben Hit-Testing auch die Aktivierung.
            guard postCompletionMouseClick(in: table, row: 0, window: popup, clickCount: 2) else {
                finishFourDCompletionTest(state, ok: false,
                                          message: "konnte Doppelklick in Vorschlagsliste nicht bauen")
            }
            pollForFourDCompletionApply(mainWindow: mainWindow, textView: textView, state: state)
            return
        }
        if tick >= 40 {
            state.failures.append("gezielter Klick änderte die Vorschlagsauswahl nicht (Zeile blieb \(table.selectedRow))")
            finishFourDCompletionTest(state, ok: false,
                                      message: state.failures.joined(separator: "; "))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollForFourDCompletionClick(mainWindow: mainWindow, popup: popup,
                                        textView: textView, table: table, targetRow: targetRow,
                                        state: state, tick: tick + 1)
        }
    }

    private static func pollForFourDCompletionApply(
        mainWindow: NSWindow,
        textView: TextView,
        state: FourDCompletionTestState,
        tick: Int = 0
    ) {
        if textView.string == state.initialText + "ALERT" {
            guard let root = mainWindow.contentView else {
                finishFourDCompletionTest(
                    state, ok: false, message: "Hauptfenster verlor contentView"
                )
            }
            startFourDComponentCompletion(
                mainWindow: mainWindow, root: root, textView: textView, state: state
            )
            return
        }
        if tick >= 40 {
            state.failures.append("Doppelklick übernahm den ersten Vorschlag nicht (Text=\"\(textView.string)\")")
            finishFourDCompletionTest(state, ok: false,
                                      message: state.failures.joined(separator: "; "))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollForFourDCompletionApply(mainWindow: mainWindow, textView: textView,
                                        state: state, tick: tick + 1)
        }
    }

    /// Zweite, problembezogene Phase: Eine eindeutig benannte geteilte
    /// Komponentenmethode wird real getippt, im echten Popup übernommen und
    /// danach unabhängig im TextStorage auf Farbe und Schrift geprüft.
    private static func startFourDComponentCompletion(
        mainWindow: NSWindow,
        root: NSView,
        textView: TextView,
        state: FourDCompletionTestState,
        tick: Int = 0
    ) {
        // Die erste Anwendung muss ihr Fenster vollständig geschlossen haben,
        // bevor der neue Präfix eingegeben wird.
        guard fourDCompletionWindow(attachedTo: mainWindow) == nil else {
            if tick >= 40 {
                finishFourDCompletionTest(
                    state, ok: false,
                    message: "ALERT-Popup blieb vor Component-Phase geöffnet"
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                startFourDComponentCompletion(
                    mainWindow: mainWindow, root: root, textView: textView,
                    state: state, tick: tick + 1
                )
            }
            return
        }
        guard mainWindow.isKeyWindow, mainWindow.makeFirstResponder(textView) else {
            finishFourDCompletionTest(
                state, ok: false,
                message: "Umgebungsproblem: Fokus vor Component-Typeahead verloren"
            )
        }
        textView.selectionManager.setSelectedRange(
            NSRange(location: (textView.string as NSString).length, length: 0)
        )
        guard insertCompletionCharacter("\nZ", into: textView) else {
            finishFourDCompletionTest(
                state, ok: false, message: "konnte ersten Component-Präfix nicht eingeben"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard insertCompletionCharacter("Z", into: textView) else {
                finishFourDCompletionTest(
                    state, ok: false, message: "konnte zweiten Component-Präfix nicht eingeben"
                )
            }
            pollForFourDComponentPopup(
                mainWindow: mainWindow, root: root, textView: textView, state: state
            )
        }
    }

    private static func pollForFourDComponentPopup(
        mainWindow: NSWindow,
        root: NSView,
        textView: TextView,
        state: FourDCompletionTestState,
        tick: Int = 0
    ) {
        if let popup = fourDCompletionWindow(attachedTo: mainWindow),
           let table = completionTable(in: popup), table.numberOfRows > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard postCompletionMouseClick(
                    in: table, row: 0, window: popup, clickCount: 2
                ) else {
                    finishFourDCompletionTest(
                        state, ok: false,
                        message: "konnte Component-Vorschlag nicht doppelklicken"
                    )
                }
                pollForFourDComponentApply(
                    mainWindow: mainWindow, root: root,
                    textView: textView, state: state
                )
            }
            return
        }
        if tick >= 80 {
            finishFourDCompletionTest(
                state, ok: false,
                message: "Component-Typeahead-Popup blieb nach „ZZ“ aus"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollForFourDComponentPopup(
                mainWindow: mainWindow, root: root, textView: textView,
                state: state, tick: tick + 1
            )
        }
    }

    private static func pollForFourDComponentApply(
        mainWindow: NSWindow,
        root: NSView,
        textView: TextView,
        state: FourDCompletionTestState,
        tick: Int = 0
    ) {
        let expected = state.initialText + "ALERT\n" + state.componentMethod
        if textView.string == expected {
            pollForAppliedFourDComponentStyle(
                root: root, state: state, tick: 0
            )
            return
        }
        if tick >= 60 {
            finishFourDCompletionTest(
                state, ok: false,
                message: "Component-Doppelklick übernahm nicht den erwarteten Namen "
                    + "(Text=\"\(textView.string)\")"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollForFourDComponentApply(
                mainWindow: mainWindow, root: root,
                textView: textView, state: state, tick: tick + 1
            )
        }
    }

    private static func pollForAppliedFourDComponentStyle(
        root: NSView,
        state: FourDCompletionTestState,
        tick: Int
    ) {
        let color = fourDComponentMethodExpectedColor(dark: false)
        let colored = storageSubstringHasColor(
            state.componentMethod, in: root,
            r: color.0, g: color.1, b: color.2
        )
        let styled = storageSubstringHasStyle(
            state.componentMethod, in: root, bold: true, italic: false
        )
        if colored && styled {
            finishFourDCompletionTest(
                state, ok: state.failures.isEmpty,
                message: state.failures.isEmpty
                    ? "Auto/⌃Leertaste/Pfeil/Maus funktionieren; Shared-Component "
                        + "real übernommen und danach orange/fett gerendert"
                    : state.failures.joined(separator: "; ")
            )
        }
        if tick >= 60 {
            finishFourDCompletionTest(
                state, ok: false,
                message: "übernommene Component-Methode falsch gerendert "
                    + "(Farbe=\(colored), fett/nicht-kursiv=\(styled))"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollForAppliedFourDComponentStyle(
                root: root, state: state, tick: tick + 1
            )
        }
    }

    /// Das CESE-Fenster ist intern; der Test beobachtet es deshalb über die
    /// öffentliche AppKit-Form: sichtbares Child-Window mit `NSTableView`.
    /// So bleibt der Wächter beim echten Fenster-/Hit-Test-Pfad statt an einer
    /// nur für Tests geöffneten Upstream-API hängen.
    private static func fourDCompletionWindow(attachedTo mainWindow: NSWindow) -> NSWindow? {
        (mainWindow.childWindows ?? []).first { candidate in
            candidate.isVisible && completionTable(in: candidate) != nil
        }
    }

    private static func completionTable(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        return completionTable(in: root)
    }

    private static func completionTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = completionTable(in: child) { return table }
        }
        return nil
    }

    /// Der SwiftUI-Remount kann auslaufende Editor-Views kurz im View-Baum
    /// lassen. Für einen Eingabetest zählt deshalb nur die editierbare View
    /// des aktuellen Hauptfensters mit dem geladenen Fixture-Text.
    private static func completionEditorTextView(
        in view: NSView,
        window: NSWindow,
        expectedText: String
    ) -> TextView? {
        if let textView = view as? TextView,
           textView.window === window,
           textView.isEditable,
           textView.string == expectedText,
           textView.frame.height > 50 {
            return textView
        }
        for child in view.subviews {
            if let found = completionEditorTextView(in: child, window: window,
                                                     expectedText: expectedText) {
                return found
            }
        }
        return nil
    }

    /// Erzeugt Down und Up mit derselben Fenster-Koordinate. Die Ereignisse
    /// gehen durch AppKit-Hit-Testing; ein direkter `tableView`-Methodenaufruf
    /// wäre hier wertlos, weil er den gemeldeten Fensterfehler umgehen würde.
    private static func postCompletionMouseClick(
        in table: NSTableView,
        row: Int,
        window: NSWindow,
        clickCount: Int
    ) -> Bool {
        guard row >= 0, row < table.numberOfRows else { return false }
        table.layoutSubtreeIfNeeded()
        let rowRect = table.rect(ofRow: row)
        guard !rowRect.isEmpty else { return false }
        let pointInTable = NSPoint(x: rowRect.midX, y: rowRect.midY)
        let pointInWindow = table.convert(pointInTable, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: pointInWindow, modifierFlags: [],
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: clickCount, pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: pointInWindow, modifierFlags: [],
            timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: clickCount, pressure: 0
        ) else {
            return false
        }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        return true
    }

    /// Fügt einen Buchstaben über die öffentliche Benutzer-Eingabe der
    /// produktiven TextView ein. Ein nicht aktiver Selbsttest-Prozess besitzt
    /// keinen System-Input-Context für `keyDown`; der explizite Range hält den
    /// gleichen CESE-Mutations-/Delegate-Pfad aber ohne dessen leere Cursor-
    /// Liste zuverlässig fest.
    private static func insertCompletionCharacter(
        _ character: String,
        into textView: TextView
    ) -> Bool {
        guard !character.isEmpty else { return false }
        let insertionPoint = (textView.string as NSString).length
        textView.insertText(character as NSString,
                            replacementRange: NSRange(location: insertionPoint, length: 0))
        return true
    }

    private static func finishFourDCompletionTest(
        _ state: FourDCompletionTestState,
        ok: Bool,
        message: String
    ) -> Never {
        Workspace.shared?.closeProject()
        NSApp.appearance = nil
        try? FileManager.default.removeItem(at: state.projectRoot)
        finish(ok, message)
    }

    // MARK: - 4D-Highlighting (Etappe 4 Wunschpaket 2026-07)

    /// Beobachtet die ECHTEN 4D-Vordergrundfarben im gepackten Bundle —
    /// erst im hellen, dann im dunklen Erscheinungsbild (die 4D-Themes sind
    /// pro Dokument aktiv und stammen aus light.json/dark.json). Prüft je
    /// Modus Befehl, Schlüsselwort, lokale und Prozessvariable, Tabelle,
    /// Feld, Kommentar sowie eine indizierte Projektmethode.
    private static func runFourDHighlightTest() {
        testLabel = "highlight4d"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }

        // Selbst geschriebene exportierte 4D-Fixture (nichts aus der
        // 4D-Doku). Der zweite Methodenname muss nur im Projektindex stehen,
        // damit der Test die Unterscheidung von Prozessvariablen beobachtet.
        let code = """
        // Prüfsumme neu berechnen
        If (True)
        \t$summe:=$summe+1
        \tAbr_init
        \tABR_LISTE_LB_AB:=1
        \tNachtrag
        \tComponent_Shared
        \tQUERY([Auftraege:1]; [Auftraege:1]Nummer=42)
        \tALERT("fertig")
        End if
        """
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-highlight4d-\(UUID().uuidString)")
        let methods = projectRoot.appendingPathComponent("Project/Sources/Methods",
                                                          isDirectory: true)
        let componentMethods = projectRoot.appendingPathComponent(
            "Components/FastraTools.4dbase/Project/Sources/Methods",
            isDirectory: true
        )
        let tmp = methods.appendingPathComponent("Highlight.4dm")
        do {
            try FileManager.default.createDirectory(at: methods, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: componentMethods, withIntermediateDirectories: true
            )
            try code.write(to: tmp, atomically: true, encoding: .utf8)
            try "// Projektindex-Fixture\n".write(
                to: methods.appendingPathComponent("Abr_init.4dm"), atomically: true,
                encoding: .utf8
            )
            try "//%attributes = {\"shared\":true}\n".write(
                to: componentMethods.appendingPathComponent("Component_Shared.4dm"),
                atomically: true, encoding: .utf8
            )
        } catch {
            try? FileManager.default.removeItem(at: projectRoot)
            finish(false, "4D-Projekt-Fixture nicht schreibbar: \(error.localizedDescription)")
        }

        // Erst hell erzwingen — der Test darf nicht vom System-Modus abhängen.
        NSApp.appearance = NSAppearance(named: .aqua)
        ws.openProject(at: projectRoot)
        pollFourDProjectMethodIndex(ws: ws, root: root, projectRoot: projectRoot,
                                    file: tmp, code: code, tick: 0)
    }

    private static func pollFourDProjectMethodIndex(ws: Workspace, root: NSView,
                                                    projectRoot: URL, file: URL,
                                                    code: String, tick: Int) {
        guard ws.fourDProjectMethodNames.contains("abr_init"),
              ws.fourDComponentMethods["component_shared"] != nil else {
            if tick >= 40 {
                ws.closeProject()
                try? FileManager.default.removeItem(at: projectRoot)
                finish(false, "4D-Indizes enthalten Abr_init/Component_Shared "
                    + "nach 10 s nicht")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                pollFourDProjectMethodIndex(ws: ws, root: root, projectRoot: projectRoot,
                                            file: file, code: code, tick: tick + 1)
            }
            return
        }
        ws.loadFile(at: file) { ok in
            guard ok else {
                ws.closeProject()
                try? FileManager.default.removeItem(at: projectRoot)
                finish(false, "loadFile (.4dm) schlug fehl")
            }
            pollFourDColors(
                root: root, url: file, dark: false,
                indexedMethod: "Abr_init", componentMethod: "Component_Shared", tick: 0
            ) {
                // Hell bestanden → dunkel umschalten und erneut beobachten.
                NSApp.appearance = NSAppearance(named: .darkAqua)
                pollFourDColors(
                    root: root, url: file, dark: true,
                    indexedMethod: "Abr_init", componentMethod: "Component_Shared", tick: 0
                ) {
                    runFourDDynamicProjectMethodIndexTest(
                        ws: ws, root: root, projectRoot: projectRoot, file: file, code: code
                    )
                }
            }
        }
    }

    /// Ergänzt nach dem tatsächlichen Öffnen nur die Indexdatei einer Methode.
    /// `Nachtrag` steht schon im sichtbaren Text: Er muss zuerst die Farbe
    /// einer Prozessvariablen haben und wechselt dann ohne Textmutation zur
    /// Projektmethodenfarbe. So prüft der Test ausschließlich den Index-
    /// Refresh und nicht eine nebenbei ausgelöste Editor-Neuerstellung.
    private static func runFourDDynamicProjectMethodIndexTest(
        ws: Workspace, root: NSView, projectRoot: URL, file: URL, code: String
    ) {
        pollFourDProcessVariableColor(root: root, url: file, dark: true,
                                      name: "Nachtrag", tick: 0) {
            beginFourDProjectMethodIndexRefresh(
                ws: ws, root: root, projectRoot: projectRoot, file: file, code: code
            )
        }
    }

    private static func beginFourDProjectMethodIndexRefresh(
        ws: Workspace, root: NSView, projectRoot: URL, file: URL, code: String
    ) {
        guard let textView = editorTextView(in: root) as? TextView else {
            ws.closeProject()
            try? FileManager.default.removeItem(at: projectRoot)
            finish(false, "4D-Index-Refresh ohne sichtbare TextView")
        }
        let identity = ObjectIdentifier(textView)
        let selection = textView.selectedRange()
        let visibleOrigin = textView.visibleRect.origin
        let addedMethod = projectRoot.appendingPathComponent("Project/Sources/Methods/Nachtrag.4dm")
        do {
            try "// nachträglich angelegte Projektmethode\n".write(
                to: addedMethod, atomically: true, encoding: .utf8
            )
        } catch {
            ws.closeProject()
            try? FileManager.default.removeItem(at: projectRoot)
            finish(false, "4D-Index-Fixture nicht ergänzbar: \(error.localizedDescription)")
        }
        pollFourDAddedMethod(
            ws: ws, root: root, projectRoot: projectRoot, file: file, code: code,
            textViewIdentity: identity, selection: selection, visibleOrigin: visibleOrigin, tick: 0
        )
    }

    private static func pollFourDAddedMethod(
        ws: Workspace, root: NSView, projectRoot: URL, file: URL, code: String,
        textViewIdentity: ObjectIdentifier, selection: NSRange, visibleOrigin: NSPoint, tick: Int
    ) {
        guard ws.fourDProjectMethodNames.contains("nachtrag") else {
            if tick >= 40 {
                ws.closeProject()
                try? FileManager.default.removeItem(at: projectRoot)
                finish(false, "4D-Index aktualisiert die nachträglich angelegte Methode nicht")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                pollFourDAddedMethod(
                    ws: ws, root: root, projectRoot: projectRoot, file: file, code: code,
                    textViewIdentity: textViewIdentity, selection: selection,
                    visibleOrigin: visibleOrigin, tick: tick + 1
                )
            }
            return
        }
        pollFourDColors(root: root, url: file, dark: true, indexedMethod: "Nachtrag", tick: 0) {
            guard let textView = editorTextView(in: root) as? TextView,
                  ObjectIdentifier(textView) == textViewIdentity,
                  textView.selectedRange() == selection,
                  abs(textView.visibleRect.origin.x - visibleOrigin.x) < 1,
                  abs(textView.visibleRect.origin.y - visibleOrigin.y) < 1 else {
                ws.closeProject()
                try? FileManager.default.removeItem(at: projectRoot)
                finish(false, "4D-Index-Refresh veränderte TextView, Selektion oder Scrollposition")
            }
            ws.closeProject()
            guard ws.projectURL == nil, ws.fourDProjectMethodNames.isEmpty else {
                try? FileManager.default.removeItem(at: projectRoot)
                finish(false, "4D-Methodenindex blieb nach Projekt-Schließen aktiv")
            }
            NSApp.appearance = NSAppearance(named: .aqua)
            try? FileManager.default.removeItem(at: projectRoot)
            // Etappe 3 Wunschpaket 2026-07b: 4D ist auch MANUELL
            // wählbar — an einer Nicht-.4dm-Datei prüfen.
            runFourDManualOverridePhase(ws: ws, root: root, code: code)
        }
    }

    /// Manueller 4D-Override end-to-end: eine .txt-Datei mit 4D-Inhalt zeigt
    /// zunächst KEINE 4D-Farben; nach `setCustomLanguageOverride(.fourD)`
    /// erscheinen sie; „Automatisch“ entfernt sie wieder. Beobachtet wird
    /// jeweils der echte Editor-TextStorage (wie in den Phasen davor).
    private static func runFourDManualOverridePhase(ws: Workspace, root: NSView,
                                                    code: String) {
        let txt = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-highlight4d-\(UUID().uuidString).txt")
        do { try code.write(to: txt, atomically: true, encoding: .utf8) }
        catch { finish(false, "(override) Temp-Datei nicht schreibbar") }
        ws.loadFile(at: txt) { ok in
            guard ok else {
                try? FileManager.default.removeItem(at: txt)
                finish(false, "(override) loadFile (.txt) schlug fehl")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                // Vorbedingung: als Plaintext KEINE 4D-Befehlsfarbe.
                let cmd = fourDExpectedColors(dark: false)[0]
                guard !storageContainsColor(in: root, r: cmd.1, g: cmd.2, b: cmd.3) else {
                    try? FileManager.default.removeItem(at: txt)
                    finish(false, "(override) .txt zeigt 4D-Farben schon OHNE Override")
                }
                ws.setCustomLanguageOverride(CustomLanguageRegistry.fourD)
                pollFourDColors(root: root, url: txt, dark: false, tick: 0) {
                    // Zurück auf Automatik → Farben müssen verschwinden.
                    ws.setLanguageOverride(nil)
                    pollFourDColorsGone(ws: ws, root: root, url: txt, tick: 0)
                }
            }
        }
    }

    private static func pollFourDColorsGone(ws: Workspace, root: NSView,
                                            url: URL, tick: Int) {
        let cmd = fourDExpectedColors(dark: false)[0]
        if !storageContainsColor(in: root, r: cmd.1, g: cmd.2, b: cmd.3) {
            NSApp.appearance = nil   // zurück zum Systemmodus
            try? FileManager.default.removeItem(at: url)
            finish(true, "4D-Farben hell + dunkel beobachtet; manueller Override "
                + "färbt .txt und „Automatisch“ räumt wieder")
        }
        if tick >= 40 {
            NSApp.appearance = nil
            try? FileManager.default.removeItem(at: url)
            finish(false, "(override) 4D-Farben bleiben nach Rückkehr zur Automatik")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollFourDColorsGone(ws: ws, root: root, url: url, tick: tick + 1)
        }
    }

    /// Erwartete 4D-Vordergrundfarben aus den öffentlichen Test-Fixtures.
    private static func fourDExpectedColors(dark: Bool) -> [(String, Int, Int, Int)] {
        dark
            ? [("Befehl", 0xB5, 0xD6, 0xDD), ("Keyword", 0xE1, 0xDC, 0x32),
               ("$lokal", 0x00, 0xF9, 0xCC), ("Prozessvariable", 0xD7, 0xF6, 0x92),
               ("Tabelle", 0xB7, 0x4D, 0x00), ("Feld", 0xBA, 0xD8, 0x0A),
               ("String", 0x94, 0xCE, 0x9F),
               ("Kommentar", 0x74, 0xC5, 0xEA)]
            : [("Befehl", 0x06, 0x8C, 0x00), ("Keyword", 0x03, 0x4D, 0x00),
               ("$lokal", 0x00, 0x70, 0xF5), ("Prozessvariable", 0x9E, 0x60, 0x00),
               ("Tabelle", 0x43, 0x99, 0xD0), ("Feld", 0x39, 0x80, 0xB2),
               ("String", 0x2F, 0x5D, 0x3A),
               ("Kommentar", 0x7F, 0x7E, 0x80)]
    }

    private static func fourDMethodExpectedColor(dark: Bool) -> (Int, Int, Int) {
        dark ? (0x0F, 0x93, 0x0A) : (0x00, 0x00, 0x88)
    }

    private static func fourDComponentMethodExpectedColor(dark: Bool) -> (Int, Int, Int) {
        dark ? (0xFF, 0x9D, 0x3F) : (0xB3, 0x47, 0x00)
    }

    private static func pollFourDColors(root: NSView, url: URL, dark: Bool,
                                        indexedMethod: String? = nil,
                                        componentMethod: String? = nil, tick: Int,
                                        then next: @escaping () -> Void) {
        let expected = fourDExpectedColors(dark: dark)
        // Jede Kategorie wird an ihrem eigenen 4D-Substring geprüft. Das ist
        // strenger als „irgendein Pixel hat diese Farbe“ und verhindert etwa,
        // dass eine Zeichenkette versehentlich durch eine andere Kategorie
        // als vorhanden gilt.
        let expectedSubstrings = [
            (expected[0], "QUERY"),
            (expected[1], "If"),
            (expected[2], "$summe"),
            (expected[3], "ABR_LISTE_LB_AB"),
            (expected[4], "[Auftraege:1]"),
            (expected[5], "Nummer"),
            (expected[6], "\"fertig\""),
            (expected[7], "// Prüfsumme neu berechnen"),
        ]
        var missing = expectedSubstrings.compactMap { expected, substring in
            storageSubstringHasColor(substring, in: root,
                                     r: expected.1, g: expected.2, b: expected.3)
                ? nil : expected
        }
        let methodColor = fourDMethodExpectedColor(dark: dark)
        if let indexedMethod, (!storageSubstringHasColor(
            indexedMethod, in: root, r: methodColor.0, g: methodColor.1, b: methodColor.2
        ) || !storageSubstringHasStyle(indexedMethod, in: root, bold: true, italic: true)) {
            missing.append(("Projektmethode \(indexedMethod)", methodColor.0,
                            methodColor.1, methodColor.2))
        }
        let componentColor = fourDComponentMethodExpectedColor(dark: dark)
        if let componentMethod, (!storageSubstringHasColor(
            componentMethod, in: root, r: componentColor.0,
            g: componentColor.1, b: componentColor.2
        ) || !storageSubstringHasStyle(
            componentMethod, in: root, bold: true, italic: false
        )) {
            missing.append(("Komponentenmethode \(componentMethod)", componentColor.0,
                            componentColor.1, componentColor.2))
        }
        if missing.isEmpty {
            next()
            return
        }
        if tick >= 40 {
            try? FileManager.default.removeItem(at: url)
            NSApp.appearance = nil
            finish(false, "\(dark ? "dunkel" : "hell"): Farben fehlen nach 10 s: "
                + missing.map(\.0).joined(separator: ", "))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollFourDColors(root: root, url: url, dark: dark,
                            indexedMethod: indexedMethod,
                            componentMethod: componentMethod,
                            tick: tick + 1, then: next)
        }
    }

    /// Wartet, bis der bereits sichtbare Name die Prozessvariablenfarbe hat.
    /// Erst danach wird die neue `.4dm`-Datei angelegt, damit der spätere
    /// Vergleich wirklich dieselbe Textstelle vor und nach dem Indexwechsel
    /// betrachtet.
    private static func pollFourDProcessVariableColor(
        root: NSView, url: URL, dark: Bool, name: String, tick: Int,
        then next: @escaping () -> Void
    ) {
        let expected = fourDExpectedColors(dark: dark)[3]
        if storageSubstringHasColor(name, in: root,
                                    r: expected.1, g: expected.2, b: expected.3) {
            next()
            return
        }
        if tick >= 40 {
            try? FileManager.default.removeItem(at: url)
            NSApp.appearance = nil
            finish(false, "Prozessvariable \(name) hat nach 10 s nicht die erwartete Farbe")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollFourDProcessVariableColor(root: root, url: url, dark: dark,
                                          name: name, tick: tick + 1, then: next)
        }
    }

    /// Prüft die Farbe genau am Namen der indizierten Projektmethode. Ein
    /// bloßes Vorkommen der Befehlsfarbe würde nicht beweisen, dass der
    /// Methodenindex die sonst gleichfarbige `ALERT`-Zeile verlassen hat.
    private static func storageSubstringHasColor(_ substring: String, in root: NSView,
                                                  r: Int, g: Int, b: Int) -> Bool {
        guard let textView = editorTextView(in: root) as? TextView,
              let storage = textView.textStorage,
              let range = textView.string.range(of: substring) else { return false }
        let nsRange = NSRange(range, in: textView.string)
        guard
              nsRange.location != NSNotFound,
              let color = storage.attribute(.foregroundColor, at: nsRange.location,
                                            effectiveRange: nil) as? NSColor,
              let srgb = color.usingColorSpace(.sRGB) else { return false }
        let tolerance = 1.5 / 255.0
        return abs(srgb.redComponent - Double(r) / 255) < tolerance
            && abs(srgb.greenComponent - Double(g) / 255) < tolerance
            && abs(srgb.blueComponent - Double(b) / 255) < tolerance
    }

    private static func storageSubstringHasStyle(_ substring: String, in root: NSView,
                                                 bold: Bool, italic: Bool) -> Bool {
        guard let textView = editorTextView(in: root) as? TextView,
              let storage = textView.textStorage,
              let range = textView.string.range(of: substring) else { return false }
        let nsRange = NSRange(range, in: textView.string)
        guard nsRange.location != NSNotFound,
              let font = storage.attribute(.font, at: nsRange.location,
                                           effectiveRange: nil) as? NSFont else { return false }
        let traits = NSFontManager.shared.traits(of: font)
        return traits.contains(.boldFontMask) == bold && traits.contains(.italicFontMask) == italic
    }

    /// Sucht eine konkrete sRGB-Farbe unter den `.foregroundColor`-Attributen
    /// des echten Editor-TextStorage (Toleranz ~1,5/255 je Kanal).
    private static func storageContainsColor(in root: NSView,
                                             r: Int, g: Int, b: Int) -> Bool {
        guard let tv = editorTextView(in: root) as? TextView,
              let storage = tv.textStorage, storage.length > 0 else { return false }
        var found = false
        storage.enumerateAttribute(.foregroundColor,
                                   in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return }
            let tolerance = 1.5 / 255.0
            if abs(color.redComponent - Double(r) / 255) < tolerance,
               abs(color.greenComponent - Double(g) / 255) < tolerance,
               abs(color.blueComponent - Double(b) / 255) < tolerance {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Zählt die verschiedenen `.foregroundColor`-Attribute im echten
    /// Editor-TextStorage (sRGB-normalisiert, damit gleiche Farben in
    /// unterschiedlichen Colorspaces nicht doppelt zählen).
    private static func distinctForegroundColors(in root: NSView) -> Int {
        guard let tv = editorTextView(in: root) as? TextView,
              let storage = tv.textStorage, storage.length > 0 else { return 0 }
        var seen = Set<String>()
        storage.enumerateAttribute(.foregroundColor,
                                   in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let color = value as? NSColor,
                  let srgb = color.usingColorSpace(.sRGB) else { return }
            seen.insert(String(format: "%.3f/%.3f/%.3f",
                               srgb.redComponent, srgb.greenComponent, srgb.blueComponent))
        }
        return seen.count
    }

    // MARK: - Leaks-Szenario (Wunschpaket 2026-07, Abschlussprüfung)

    /// Diagnose-Szenario für den `leaks`-Durchlauf: übt Bildvorschau, PDF-
    /// Vorschau, Hex-Ansicht und XPath-Leiste je einmal aus, schließt die
    /// Tabs wieder und meldet dann `LEAKSCENARIO READY <pid>` auf stderr.
    /// Danach bleibt der Prozess ~60 s am Leben, damit ein äußeres Skript
    /// `leaks <pid>` gegen die laufende App ausführen kann.
    private static func runLeakScenario() {
        testLabel = "leakscenario"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil")
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("fastra-leaks-\(UUID().uuidString)")
        let png = base.appendingPathComponent("bild.png")
        let pdf = base.appendingPathComponent("doku.pdf")
        let xml = base.appendingPathComponent("daten.xml")
        let txt = base.appendingPathComponent("hex.txt")
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            try writeSolidPNG(to: png, width: 640, height: 320)
            try writeSinglePagePDF(to: pdf)
            try "<lager><regal id=\"1\"><fach>Grüße</fach></regal></lager>"
                .write(to: xml, atomically: true, encoding: .utf8)
            try "Hexbeispiel 0123456789".write(to: txt, atomically: true,
                                               encoding: .utf8)
        } catch {
            finish(false, "Fixtures nicht schreibbar: \(error.localizedDescription)")
        }

        // Sequenz: PNG → PDF → TXT(Hex) → XML(XPath) → aufräumen → READY.
        ws.loadFile(at: png) { _ in
            ws.loadFile(at: pdf) { _ in
                ws.loadFile(at: txt) { _ in
                    ws.setViewMode(.hex)
                    ws.loadFile(at: xml) { _ in
                        NotificationCenter.default.post(name: .fastraShowXPathBar,
                                                        object: nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            MainActor.assumeIsolated {
                                XPathPanelController.lastShown?.model?.query = "//fach"
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                finishLeakScenario(ws: ws, base: base)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func finishLeakScenario(ws: Workspace, base: URL) {
        // Panel und Tabs schließen — Restbestände wären Leak-Kandidaten,
        // genau das soll `leaks` sehen können.
        MainActor.assumeIsolated { XPathPanelController.lastShown?.close() }
        if let keep = ws.tabs.first(where: { $0.url == nil })?.id ?? ws.tabs.first?.id {
            ws.closeOtherTabs(keeping: keep)
        }
        try? FileManager.default.removeItem(at: base)
        FileHandle.standardError.write(Data(
            "LEAKSCENARIO READY \(ProcessInfo.processInfo.processIdentifier)\n".utf8))
        // KEIN finish(): Der Prozess bleibt für den leaks-Angriff am Leben
        // und beendet sich nach 60 s selbst (SELFTEST-Zeile für den Runner).
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            finish(true, "Leak-Szenario ausgeübt (Bild/PDF/Hex/XPath)")
        }
    }

    // MARK: - XPath-Leiste (Etappe 5 Wunschpaket 2026-07)

    /// Öffnet die echte XPath-Leiste über die Menü-Notification und prüft,
    /// dass eine getippte Query den Editor WIRKLICH zur Fundstelle springen
    /// lässt (tatsächliche Selektion in der CodeEdit-TextView, nicht nur
    /// Modellzustand) — Panel-Öffnen + Springen End-to-End.
    private static func runXPathTest() {
        testLabel = "xpath"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }

        // Selbst geschriebene Fixture mit Multibyte-Inhalt VOR dem Ziel.
        //
        // Bewusst groß: Der XPath-Index entsteht asynchron. Bei einer winzigen
        // Datei ist er manchmal schon fertig, bevor der Test tippt — dann liefe
        // der Test am eigentlichen Risiko vorbei (Tippen VOR fertigem Index)
        // und wäre je nach Systemlast mal grün, mal rot. Die Füllelemente
        // machen den Bau lang genug, dass der Fall zuverlässig eintritt.
        var filler = ""
        for identifier in 100..<4100 {
            filler += "    <regal id=\"\(identifier)\">"
                + "<fach>Füllfach \(identifier)</fach></regal>\n"
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <lager ort="Köln 🙂">
            <regal id="1"><fach>Grüße</fach></regal>
        \(filler)    <regal id="42"><fach>Zielfach</fach></regal>
        </lager>
        """
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-xpath-\(UUID().uuidString).xml")
        do { try xml.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            guard ok else {
                try? FileManager.default.removeItem(at: tmp)
                finish(false, "loadFile (.xml) schlug fehl")
            }
            guard ws.activeTabSupportsXPath else {
                try? FileManager.default.removeItem(at: tmp)
                finish(false, "XPath für .xml nicht verfügbar (activeTabSupportsXPath=false)")
            }
            // Panel über den ECHTEN Menü-Pfad öffnen.
            NotificationCenter.default.post(name: .fastraShowXPathBar, object: nil)
            pollXPathPanel(ws: ws, root: root, xml: xml, tmp: tmp, tick: 0)
        }
    }

    private static func pollXPathPanel(ws: Workspace, root: NSView, xml: String,
                                       tmp: URL, tick: Int) {
        // Panel-Sichtbarkeit + Modell-Zugriff sind MainActor-isoliert; die
        // Selbsttests laufen auf dem Main-Thread → Isolierung übernehmen.
        let model: XPathBarModel? = MainActor.assumeIsolated {
            let visible = NSApp.windows.contains {
                $0.identifier == XPathPanelController.panelIdentifier && $0.isVisible
            }
            return visible ? XPathPanelController.lastShown?.model : nil
        }
        if let model {
            // Festhalten, ob der Index beim Tippen schon stand. Nur wenn NICHT,
            // prüft der Lauf den eigentlich riskanten Fall.
            let indexWasReady = MainActor.assumeIsolated { model.index != nil }
            // Query in das echte Modell tippen (Live-Springen).
            MainActor.assumeIsolated { model.query = "//regal[@id='42']/fach" }
            // Erwartete Fundstelle unabhängig berechnen: Name des
            // <fach>-Elements im Zielregal.
            let ns = xml as NSString
            let target = ns.range(of: "fach>Zielfach")
            let expected = NSRange(location: target.location, length: 4)
            pollXPathSelection(root: root, expected: expected, tmp: tmp,
                               tick: 0, indexWasReady: indexWasReady)
            return
        }
        if tick >= 40 {
            try? FileManager.default.removeItem(at: tmp)
            finish(false, "XPath-Panel erschien nicht binnen 10 s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollXPathPanel(ws: ws, root: root, xml: xml, tmp: tmp, tick: tick + 1)
        }
    }

    private static func pollXPathSelection(root: NSView, expected: NSRange,
                                           tmp: URL, tick: Int,
                                           indexWasReady: Bool) {
        if let tv = editorTextView(in: root) as? TextView,
           let selection = tv.selectionManager.textSelections.first?.range,
           selection.location == expected.location {
            // Panel wieder schließen (Aufräumen), Datei löschen.
            MainActor.assumeIsolated { XPathPanelController.lastShown?.close() }
            try? FileManager.default.removeItem(at: tmp)
            // Ehrlich ausweisen, welcher Fall geprüft wurde: Stand der Index
            // schon, lief der Test am eigentlichen Risiko vorbei.
            let scope = indexWasReady
                ? "Index war bereits fertig — verpasster Sprung NICHT geprüft"
                : "getippt vor fertigem Index (nachgeholter Sprung)"
            finish(true, "XPath-Panel öffnet und springt zur echten Fundstelle "
                + "(Selektion @\(selection.location); \(scope))")
        }
        if tick >= 40 {
            let actual = (editorTextView(in: root) as? TextView)?
                .selectionManager.textSelections.first?.range
            try? FileManager.default.removeItem(at: tmp)
            finish(false, "kein Sprung zur Fundstelle binnen 10 s "
                + "(erwartet \(expected), Selektion \(String(describing: actual)), "
                + "Index beim Tippen fertig: \(indexWasReady))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollXPathSelection(root: root, expected: expected, tmp: tmp,
                               tick: tick + 1, indexWasReady: indexWasReady)
        }
    }

    // MARK: - Ansichts-Umschalter + Vorschau (Etappe 2 Wunschpaket 2026-07)

    /// Prüft die Read-only-Vorschau mit ECHTER Beobachtung (Muster
    /// `highlight`): Ein rotes PNG muss als tatsächlich dekodiertes Bild in
    /// der View-Hierarchie ankommen (Pixelfarbe wird gesampelt, nicht nur
    /// Modellzustand), der Umschalter muss die Ansicht real wechseln, und
    /// ein generiertes PDF muss als PDFKit-Dokument mit einer Seite gerendert
    /// werden.
    private static func runPreviewRenderTest() {
        testLabel = "previewrender"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }

        // Rotes 64×32-PNG erzeugen (Rot ist als Sample-Farbe eindeutig).
        let png = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-previewrender-\(UUID().uuidString).png")
        do { try writeSolidPNG(to: png, width: 64, height: 32) }
        catch { finish(false, "PNG nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: png) { ok in
            guard ok else {
                try? FileManager.default.removeItem(at: png)
                finish(false, "loadFile (PNG) schlug fehl")
            }
            guard ws.activeViewMode == .preview else {
                try? FileManager.default.removeItem(at: png)
                finish(false, "PNG öffnet nicht in der Vorschau (Modus: \(ws.activeViewMode))")
            }
            pollImagePreview(root: root, ws: ws, png: png, tick: 0)
        }
    }

    /// Wartet, bis das dekodierte Bild wirklich in der View-Hierarchie hängt,
    /// und sampelt dann die Mittelpixel-Farbe.
    private static func pollImagePreview(root: NSView, ws: Workspace,
                                         png: URL, tick: Int) {
        if let imageView = previewImageView(in: root), let image = imageView.image {
            guard let color = centerColor(of: image) else {
                try? FileManager.default.removeItem(at: png)
                finish(false, "Vorschaubild nicht sampelbar")
            }
            guard color.redComponent > 0.8, color.greenComponent < 0.2,
                  color.blueComponent < 0.2 else {
                try? FileManager.default.removeItem(at: png)
                finish(false, "Vorschaubild hat falsche Farbe: \(color)")
            }
            // Umschalter real prüfen: Hex → Bildfläche verschwindet.
            ws.setViewMode(.hex)
            pollPreviewGone(root: root, ws: ws, png: png, tick: 0)
            return
        }
        if tick >= 40 {
            try? FileManager.default.removeItem(at: png)
            finish(false, "kein gerendertes Vorschaubild binnen 10 s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollImagePreview(root: root, ws: ws, png: png, tick: tick + 1)
        }
    }

    /// Nach dem Umschalten auf Hex darf keine Bildfläche mehr da sein.
    private static func pollPreviewGone(root: NSView, ws: Workspace,
                                        png: URL, tick: Int) {
        if previewImageView(in: root) == nil {
            try? FileManager.default.removeItem(at: png)
            runPDFPreviewPart(root: root, ws: ws)
            return
        }
        if tick >= 40 {
            try? FileManager.default.removeItem(at: png)
            finish(false, "Umschalter auf Hex entfernt die Bildvorschau nicht")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollPreviewGone(root: root, ws: ws, png: png, tick: tick + 1)
        }
    }

    /// PDF-Teil: einseitiges PDF erzeugen, laden, echtes PDFKit-Dokument
    /// in der Hierarchie beobachten.
    private static func runPDFPreviewPart(root: NSView, ws: Workspace) {
        let pdf = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-previewrender-\(UUID().uuidString).pdf")
        do { try writeSinglePagePDF(to: pdf) }
        catch { finish(false, "PDF nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: pdf) { ok in
            guard ok else {
                try? FileManager.default.removeItem(at: pdf)
                finish(false, "loadFile (PDF) schlug fehl")
            }
            guard ws.activeViewMode == .preview else {
                try? FileManager.default.removeItem(at: pdf)
                finish(false, "PDF öffnet nicht in der Vorschau (Modus: \(ws.activeViewMode))")
            }
            pollPDFPreview(root: root, pdf: pdf, tick: 0)
        }
    }

    private static func pollPDFPreview(root: NSView, pdf: URL, tick: Int) {
        if let pdfView = firstPDFView(in: root),
           let document = pdfView.document, document.pageCount == 1 {
            try? FileManager.default.removeItem(at: pdf)
            finish(true, "Bildvorschau rendert rot + Umschalter wirkt + PDF zeigt 1 Seite")
        }
        if tick >= 40 {
            try? FileManager.default.removeItem(at: pdf)
            finish(false, "kein gerendertes PDF binnen 10 s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollPDFPreview(root: root, pdf: pdf, tick: tick + 1)
        }
    }

    /// Sucht die Bildvorschau-Fläche über ihren Accessibility-Identifier.
    private static func previewImageView(in view: NSView) -> NSImageView? {
        if let imageView = view as? NSImageView,
           imageView.accessibilityIdentifier() == "imagePreviewSurface" {
            return imageView
        }
        for sub in view.subviews {
            if let found = previewImageView(in: sub) { return found }
        }
        return nil
    }

    private static func firstPDFView(in view: NSView) -> PDFView? {
        if let pdfView = view as? PDFView { return pdfView }
        for sub in view.subviews {
            if let found = firstPDFView(in: sub) { return found }
        }
        return nil
    }

    /// Mittelpixel-Farbe eines NSImage (sRGB) — echte Dekodier-Beobachtung.
    private static func centerColor(of image: NSImage) -> NSColor? {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
            .usingColorSpace(.sRGB)
    }

    /// Einfarbig rotes PNG über CoreGraphics schreiben.
    private static func writeSolidPNG(to url: URL, width: Int, height: Int) throws {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }

    /// Einseitiges PDF über CGContext schreiben.
    private static func writeSinglePagePDF(to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 100)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 160, height: 60))
        context.endPDFPage()
        context.closePDF()
    }

    /// Belegt den Offset-Fix beim Treffer-Sprung END-TO-END: ein Sprung zu
    /// einem Treffer auf einer SPÄTEN Zeile muss im Editor GENAU den Treffer-
    /// Text selektieren.
    ///
    /// Hintergrund: Der Sprung läuft über Zeile/Spalte (Start+Ende), NICHT
    /// über die absolute NSRange (siehe `NotificationCenter.postMatchJump`).
    /// Die absolute Range driftet, sobald frühere Zeilen im Editor-Storage
    /// anders lang sind als in der Such-Vorlage (Encoding/Line-Ending/BOM/
    /// CESE-interne Aufbereitung) — der Cursor landete dann daneben
    /// („Müller" statt „Daniel"). Reine Unit-Tests fangen das NICHT, weil sie
    /// CodeEditSourceEditors Zeile/Spalte→Selektion-Mapping nicht durchlaufen.
    ///
    /// Vorgehen: Inhalt mit unterschiedlich langen Vorzeilen (inkl. Umlauten
    /// und einem Emoji als UTF-16-Surrogatpaar — genau die Offset-Falle) in
    /// einen Tab laden, das eindeutige Zielwort auf der letzten Zeile per
    /// echter Such-Engine finden, exakt wie die GUI den Sprung posten und
    /// danach die TATSÄCHLICHE Editor-Selektion zurücklesen. Selektierter
    /// Text == Treffer-Text → der Sprung landete punktgenau.
    private static func runJumpTest() {
        testLabel = "jump"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }

        // App nach vorn + Hauptfenster key — wie im echten Bedienfall, wenn
        // der Nutzer einen Treffer anspringt. Ohne aktives Key-Window legt
        // CodeEditSourceEditor keine sichtbare Selektion an.
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)

        // Vorzeilen bewusst unterschiedlich lang + Umlaut/Emoji weit oben.
        // Zielwort eindeutig (taucht nur einmal auf) auf der letzten Zeile —
        // so ist ein Daneben-Landen am selektierten Text klar erkennbar.
        // ZWEI Fälle nacheinander: LF-Datei UND reine CR-Datei (klassisches
        // Mac / 4D-Log). Der CR-Fall ist die Regression aus Daniels Test —
        // der Klick auf einen Treffer sprang ins Leere, weil die Zeilen-
        // Zählung nur LF kannte. Gleiche Struktur, nur der Trenner wechselt.
        let baseLines = ["Müller wohnt in der Beispielstraße zwölf 😀", "x",
                         "mittellange dritte Zeile zum Variieren der Länge", "ZIELWORT"]
        let lfContent = baseLines.joined(separator: "\n")
        let crContent = baseLines.joined(separator: "\r")

        runJumpCase(ws: ws, mainWindow: mainWindow, root: root,
                    content: lfContent, label: "LF") {
            runJumpCase(ws: ws, mainWindow: mainWindow, root: root,
                        content: crContent, label: "CR") {
                finish(true, "Sprung selektierte exakt \"ZIELWORT\" in LF- UND CR-Datei "
                       + "(Zeilenzählung CR-bewusst — Klick-Sprung im 4D-Log-Fall belegt)")
            }
        }
    }

    /// Führt EINEN Jump-Fall aus (LF oder CR): Datei laden, ZIELWORT über die
    /// echte Such-Engine bestimmen, exakt wie die GUI über postMatchJump
    /// springen und die zurückgelesene Editor-Selektion prüfen. Bei Erfolg
    /// `onPass()`, bei Fehler sofortiger FAIL (mit Fall-Label).
    private static func runJumpCase(ws: Workspace, mainWindow: NSWindow, root: NSView,
                                    content: String, label: String,
                                    onPass: @escaping () -> Void) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-jump-\(label)-\(UUID().uuidString).txt")
        do { try content.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "(\(label)) Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        // loadFile ist asynchron (v0.9): Folge-Schritte + Datei-Löschung in
        // die Completion (Datei muss beim Hintergrund-Read noch existieren).
        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "(\(label)) loadFile schlug fehl (completion false)") }
            // Der Editor wird nach dem Dateiwechel neu eingehängt. Seine
            // Bereitschaft beobachten statt eine feste Renderdauer zu raten.
            pollForJumpEditor(
                root: root, expectedContent: content, label: label, tick: 0
            ) { tv in
                // Editor zum First Responder machen — sonst landet die Selektion
                // u.U. nicht im selectionManager (wie im Findbar-Test).
                _ = mainWindow.makeFirstResponder(tv)

                // Treffer über die ECHTE Such-Engine (gleicher Pfad wie die GUI-
                // Trefferliste), damit Zeile/Spalte konsistent sind.
                let opts = SearchOptions(find: "ZIELWORT", replace: "",
                                         isRegex: false, caseSensitive: true)
                let result = BufferSearch.find(in: ws.activeTab?.content ?? "", options: opts)
                guard let match = result.matches.first else {
                    finish(false, "(\(label)) Such-Engine fand ZIELWORT nicht (Inhalt nicht geladen?)")
                }

                // Sprung exakt wie GUI: Zeile/Spalte-Pfad über postMatchJump.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.postMatchJump(match, for: ws)
                    pollForSelection(tv, expected: match.matchText, line: match.line,
                                     column: match.column, label: label, onPass: onPass)
                }
            }
        }
    }

    private static func pollForJumpEditor(
        root: NSView, expectedContent: String, label: String, tick: Int,
        completion: @escaping (TextView) -> Void
    ) {
        if let textView = editorTextView(in: root) as? TextView,
           textView.string == expectedContent {
            completion(textView)
            return
        }
        if tick >= 40 {
            finish(
                false,
                "(\(label)) Editor-TextView mit geladenem Inhalt nicht binnen 4 s erreichbar"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollForJumpEditor(
                root: root, expectedContent: expectedContent,
                label: label, tick: tick + 1, completion: completion
            )
        }
    }

    // MARK: - -selftest ghosttext

    /// Sichert gegen den „Text-Geist" (Daniel-Befund 2026-07-12): Der
    /// CodeEditTextView-Typesetter verwendete den absoluten Endindex eines
    /// Zeilenumbruchs als `NSRange.length`. Ab dem zweiten Umbruchfragment
    /// überlappten die gezeichneten CoreText-Bereiche dadurch immer stärker →
    /// dasselbe Wort erschien mehrfach und Text lief rechts hinaus.
    ///
    /// CESE positioniert jedes Zeilenfragment als eigene `LineFragmentView`-
    /// Subview der `TextView`. Der Test lädt sehr lange Zeilen, erzwingt einen
    /// Breitenwechsel und prüft nach jedem Settle drei Invarianten:
    ///   (a) CoreText-Nutzlast und `documentRange` sind gleich lang,
    ///   (b) bei Umbruch AN ist keine Fragment-View breiter als die Grenze,
    ///   (c) keine zwei Live-Views belegen denselben Dokumentbereich.
    /// Genau diese Render-Fehlerklasse entgeht reinen Modell-Tests: Der
    /// gespeicherte Text war auch beim Geist jederzeit korrekt.
    private static func runGhostTextTest() {
        testLabel = "ghosttext"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)

        // Mehrere SEHR lange Zeilen (deutlich breiter als jedes Testfenster) —
        // so greift der Umbruch zwingend und ein zu breites Rest-Fragment fällt
        // sofort auf. Das Wort aus Daniels Screenshot bewusst wiederholt.
        let long = String(repeating: "Willkommensbildschirm ", count: 40)
        let content = (1...6).map { "Zeile \($0): \(long)" }.joined(separator: "\n")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-ghosttext-\(UUID().uuidString).txt")
        do { try content.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            // Breiten-Sequenz: jeder Schritt ändert die Umbruch-Breite und ist
            // damit eine Gelegenheit für einen stehenbleibenden Geist. Nach
            // jedem Settle wird die Invariante geprüft.
            // Realistischer Fall (wie Daniels Paste): frischer Editor, langer
            // Inhalt, nach dem Settle einmal prüfen. Danach ein Fenster-Resize
            // als zusätzlicher Auslöser (der Geist entsteht schon ohne).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let violation = ghostViolation(in: root) {
                    finish(false, "Text-Geist nach Laden: \(violation)")
                }
                var f = mainWindow.frame
                f.size.width = 700
                mainWindow.setFrame(f, display: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if let violation = ghostViolation(in: root) {
                        finish(false, "Text-Geist nach Resize: \(violation)")
                    }
                    finish(true, "kein Text-Geist nach Laden und Resize "
                           + "(keine überlappenden/überlaufenden Fragment-Views)")
                }
            }
        }
    }

    /// Prüft die aktuell im Editor gezeichneten Zeilenfragmente auf die zwei
    /// Geist-Signaturen. Gibt `nil` zurück, wenn alles sauber ist, sonst eine
    /// erklärende Meldung. Sammelt die `LineFragmentView`s rekursiv aus dem
    /// TextView-Teilbaum (robust, falls CESE sie je in einen Container legt).
    private static func ghostViolation(in root: NSView) -> String? {
        guard let tv = editorTextView(in: root) as? TextView else {
            // Kein Editor sichtbar (z.B. transienter Zustand) → nichts zu prüfen.
            return nil
        }
        var fragments: [LineFragmentView] = []
        func collect(_ view: NSView) {
            if let frag = view as? LineFragmentView { fragments.append(frag) }
            view.subviews.forEach(collect)
        }
        collect(tv)

        // Nur LIVE-Fragmente: geparkte Reuse-Views sind versteckt / auf .zero.
        let live = fragments.filter {
            !$0.isHidden && $0.frame != .zero && $0.lineFragment != nil
        }

        let wrapWidth = tv.layoutManager.maxLineLayoutWidth
        // (a) Direkter Wächter für den gefundenen Root Cause: Der Range des
        // gezeichneten CTLine-Inhalts darf nicht länger sein als der zugehörige
        // Dokumentbereich. Beim Bug war ab Fragment 2 `lineBreak` (Endindex)
        // statt `lineBreak - start` (Länge) an CoreText gegangen.
        for v in live {
            let fragment = v.lineFragment!
            let drawnLength = fragment.contents.reduce(0) { $0 + $1.length }
            if drawnLength != fragment.documentRange.length {
                return "CoreText-Nutzlast und Dokumentbereich sind verschieden lang "
                    + "(drawn=\(drawnLength), documentRange=\(fragment.documentRange)) — "
                    + "Umbruchfragmente überlappen intern"
            }
        }
        // (b) Überlauf: bei endlicher Umbruch-Breite (Umbruch AN) darf KEIN
        // sichtbares Fragment breiter als diese Breite sein. Ein zu breites
        // Fragment ist die überlaufende „Willkommensb"-Rest-View aus dem Screenshot.
        if wrapWidth.isFinite {
            for v in live where v.frame.width > wrapWidth + 2 {
                let r = v.lineFragment!.documentRange
                return "sichtbares Zeilenfragment breiter als die Umbruch-Breite "
                    + "(frameW=\(Int(v.frame.width)) > wrap=\(Int(wrapWidth)), documentRange=\(r), "
                    + "live-Fragmente=\(live.count)) — nicht umbrochene/überlaufende Geist-View"
            }
        }
        // (a) Überlappung: zwei sichtbare Fragmente, deren documentRange sich
        // schneidet → derselbe Text ist zweimal ausgelegt (Geist + korrekte
        // Umbruch-Version nebeneinander). Benachbarte Umbruch-Fragmente einer
        // Zeile haben lückenlose, NICHT überlappende Ranges → kein Fehlalarm.
        for i in 0..<live.count {
            let a = live[i].lineFragment!.documentRange
            guard a.location != NSNotFound else { continue }
            for j in (i + 1)..<live.count {
                let b = live[j].lineFragment!.documentRange
                guard b.location != NSNotFound else { continue }
                if NSIntersectionRange(a, b).length > 0 {
                    return "zwei sichtbare Fragmente mit überlappendem Text "
                        + "(documentRange a=\(a), b=\(b)) — Zeile doppelt ausgelegt"
                }
            }
        }
        return nil
    }

    // MARK: - -selftest wordclick

    /// Reproduziert den Doppelklick-Fehler aus einer langen Markdown-Zeile im
    /// echten Split-Editor: Wortanfang und Wortende müssen über ihre sichtbaren
    /// Trefferflächen jeweils zum ganzen Wort aufgelöst werden.
    private static func runWordDoubleClickTest() {
        testLabel = "wordclick"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks() else {
            finish(false, "Workspace oder Hauptfenster fehlt")
        }
        let fallbackText = wordClickFixtureContent()
        let text: String
        if let path = ProcessInfo.processInfo.environment["FASTRA_WORDCLICK_FIXTURE"],
           let fixture = try? String(contentsOfFile: path, encoding: .utf8) {
            // Lokale Realdatei für die Erstdiagnose; der normale Selbsttest
            // bleibt mit dem neutralen Größenabbild vollständig portabel.
            text = fixture
        } else {
            text = fallbackText
        }
        guard let target = wordClickTargetRange(in: text) else {
            finish(false, "Zielbereich fehlt im Doppelklick-Fixture")
        }
        let unrelated = NSRange(
            location: max(target.location - 12, 0), length: 10
        )
        let suffix = (text as NSString).substring(with: NSRange(
            location: target.location + 2, length: target.length - 2
        ))
        let initial = NSMutableString(string: text)
        initial.deleteCharacters(in: NSRange(
            location: target.location + 2,
            length: target.length - 2
        ))
        let initialText = initial as String
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-wordclick-\(UUID().uuidString).md")
        do { try Data(initialText.utf8).write(to: tmp) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        let environment = ProcessInfo.processInfo.environment
        let requestedWindowWidth = environment["FASTRA_WORDCLICK_WINDOW_WIDTH"]
            .flatMap(Double.init) ?? 1100
        let requestedSidebarWidth = environment["FASTRA_WORDCLICK_SIDEBAR_WIDTH"]
            .flatMap(Double.init) ?? 360.08984375
        let requestedPreviewWidth = environment["FASTRA_WORDCLICK_PREVIEW_WIDTH"]
            .flatMap(Double.init) ?? 422.6640625
        ws.sidebarWidth = requestedSidebarWidth
        ws.markdownPreviewWidth = requestedPreviewWidth
        // Diese Geometrie traf den gemeldeten Fragment-Grenzfall
        // deterministisch. Optionale Werte bleiben für die Erstdiagnose.
        window.setContentSize(NSSize(width: requestedWindowWidth, height: 800))
        workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "Markdown-Fixture lädt nicht") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let root = window.contentView,
                      let textView = editorTextView(in: root) as? TextView,
                      textView.string == initialText else {
                    finish(false, "Markdown-TextView mit Fixture fehlt")
                }
                window.makeFirstResponder(textView)
                prepareWordClickInitialLayout(
                    textView: textView, window: window,
                    expectedText: text, target: target,
                    unrelated: unrelated, suffix: suffix, tick: 0
                )
            }
        }
    }

    /// Erzeugt vor der Einfügung bewusst reale Fragmente für den nur zwei
    /// Zeichen langen Wortanfang. Ein bloßer Reload des fertigen Worts würde
    /// den gemeldeten stehengebliebenen Layoutzustand nicht reproduzieren.
    private static func prepareWordClickInitialLayout(
        textView: TextView, window: NSWindow, expectedText: String,
        target: NSRange, unrelated: NSRange, suffix: String, tick: Int
    ) {
        let initialTarget = NSRange(location: target.location, length: 2)
        textView.scrollToRange(initialTarget)
        textView.layoutManager.layoutLines()
        if let rect = textView.layoutManager.rectForOffset(target.location + 1),
           rect.width > 0, textView.visibleRect.intersects(rect) {
            textView.selectionManager.setSelectedRange(NSRange(
                location: target.location + 2, length: 0
            ))
            textView.insertText(
                suffix,
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            pollWordClickMutation(
                textView: textView, window: window, expectedText: expectedText,
                target: target, unrelated: unrelated, tick: 0
            )
            return
        }
        if tick >= 40 {
            finish(false, "kurzer Wortanfang wird binnen 4 s nicht real sichtbar")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            prepareWordClickInitialLayout(
                textView: textView, window: window,
                expectedText: expectedText, target: target,
                unrelated: unrelated, suffix: suffix, tick: tick + 1
            )
        }
    }

    /// Datenschutzneutrales Größenabbild des gemeldeten Markdown-Dokuments:
    /// Die ersten 132 UTF-16-Zeilenlängen und die Zielzeile entsprechen dem
    /// Repro, der Inhalt der Vorzeilen besteht ausschließlich aus Platzhaltern.
    private static func wordClickFixtureContent() -> String {
        let lineShapes = """
        1,6,1,9,5,6
        0
        11,20,9,5,7,1,7,8,3
        0
        11,10,1,7,4,5,5,3
        0
        11,2,4,12,1,1,4,6,11,3
        0
        9,6,6,3,3,4,10,4,4,4
        0
        2,3,3,5
        0
        1,1,1,6,2,7,7,8,6,3,3,5,1,12
        1,1,1,3,3,14,7,5,6,9,4,8,5,7
        1,1,1,9,6,8,3,7,8,7
        1,1,1,6,4,13,3,5,9,6,3,7
        1,1,1,3,18,7,3,9,5,9,10
        0
        2,10,6,5
        0
        3,1,15,6,2,1,9
        0
        1,4,3,6,6,3,9,4,4,7,6,9,8
        1,4,3,10,20,11,3,15
        1
        1,2,8,6,3,5,7,2,2,4,7,4,11,4
        1,14,3,4,4,3,3,10,11,5,4,3,2
        1,3,9,6,6,3,3,8,2,3,3,6,3,7
        0
        3,1,5,13,6,2,1,9
        0
        1,3,8,3,2,5,2,6,3,7,11,3,4,7,4
        1,6,8,8,3,3,5,7,7,9,7,5
        1,7,3,3,5
        1
        1,3,5,4,8,2,8,11,3,4,16,4
        1,3,3,4,4,13,3,5,3,5,5,12,8
        1,6,3,8
        1
        1,3,6,7,3,6,10,6,5,7,5,11
        1,4,6,4,11,4,8,3,4,4,5,11,4
        1,6,4,3,13,10,7,6,3,3,5,8
        1,3,3,4,11,3,3,9,8,6,12,3,6
        0
        3,1,4,6,6,6,2,1,9
        0
        1,7,3,3,7,14,3,9,7,13,6
        1,3,9,7,3,10,7,3,9,11
        1
        1,3,4,6,3,8,6,5,4,2,5,6,4,6
        1,5,4,6,4,3,3,9,11,4,4,4,5
        1,11,24
        1
        1,4,6,6,3,3,6,7,16,8,9
        1,15,13,4,8,3,13,3,11
        1,2,12,5,3,4,8,14,3,8,6
        1,9,8,12,4,6,12,4,10,6
        1,3,4,5,5,16,8,6,2,4,5,7,3,0
        1,3,6,8,6
        0
        3,1,10,3,3,8,5,6,2,1,9
        0
        1,4,11,9,6,3,9,5,3,12,3,3
        1,8,5,3,7,13,3,8,6,6,5,4
        1
        1,4,3,6,4,4,4,3,7,4,4,15,3,4
        1,4,13,8,7,4,3,5,4,10,2,3
        1,11,10,7,5,9,6,6,8
        1
        1,6,3,5,9,5,11,13,5,7
        1,9,3,4,24,3,13,6,3,5
        1,13,3,4,3,5,4,6,3,5,7,8
        0
        3,1,3,4,6,2,1,9
        0
        1,4,4,4,6,6,5,5,5,3,3,5,5,4,3
        1,6,3,7,25,15
        1
        1,4,4,5,10,3,3,4,5,4,8,3,2,3,8
        1,4,8,7,10,6,5,4,6,3,7,3,6
        1,10,2,7,9,6,2,3,8,4,2,7
        1
        1,3,6,6,4,2,4,5,5,2,3,7,10,4,0
        1,10,4,3,3,6,14,2,4,3,4,8
        0
        3,1,4,11,6,2,1,9
        0
        1,6,7,4,3,9,12,8,8,3,4,6
        1,3,4,12
        1
        1,2,6,6,17,7,3,5,7,4,7,3
        1,7,5,6,5,4,15,3,8,4,3,6
        1,6,7,3,3,11,3,11,6,7,13
        1,6,6,12,2,5,6,5,3,8,10,5
        1,2,3,8,7,6,6
        1
        1,3,6,2,6,5,5,6,16,3,11
        1,13,11,8,8,6,6,3,10,4
        1,12,10
        0
        3,1,10,3,10,7,6,2,1,9
        0
        1,4,6,4,12,9,5,2,12,3,6,6
        1,2,3,8,2,4,5,11,7,3,8,15
        1,6,7,9,5
        1
        1,2,5,11,8,9,3,3,9,4,7,4
        1,7,10,2,12,3,10,3,4,14,3
        1,3,4,7,6,3,4,7,6,5,2,5,2,7,3
        1,8,9,3,4,7,3,8,4,3,8,3,6
        1,6,6,9,2,3,7,5,6,2,8,3,10
        1,7,12,5,3,6,3,3,7,6,7,13
        1
        1,5,5,16,6,7,3,3,6,13,3
        1,10,7,4,7,8,3,3,9,4,5,3,5
        1,3,12,11,4,3,6,6,5,6,6,6
        1,4,4,7,5,3,7,3,3,4,10,3,3,9
        1,15
        0
        3,1,3,16,6,2,1,9
        0
        1,6,3,3,3,7,10,6,12
        1
        1,2,5,8,3,3,5,6,7,3,3,6,3,5
        1,9,4,7,12,3,8,8,3,5,4,5
        1,4,4,3,4,5,5,6,4,9,5
        1
        1,2,2,3,3,6,4,9,4,4,3,2,11,9,4
        1,4,11,7,4,5,6,7,12,4,3
        1,10,2,3,7,6,3,13,4,8,5,9
        1,4,7
        1
        """
        var lines = lineShapes.split(
            separator: "\n", omittingEmptySubsequences: false
        ).map { shape in
            shape.split(separator: ",").map {
                String(repeating: "x", count: Int($0) ?? 0)
            }.joined(separator: " ")
        }
        lines.append(
            "> xxxxx xxx-xxxxxxxxxxxx `xx_xxxx` xxx xxxxx xxxxxxxxxx "
                + "xxxxxx: xxxx xxxxxxxxxx, doppelklickbar"
        )
        lines.append(contentsOf: (134...174).map {
            "> Testzeile \($0): " + String(repeating: "x", count: $0 % 55 + 12)
        })
        return lines.joined(separator: "\n") + "\n"
    }

    /// Die gesicherte lokale Repro-Datei und das neutrale portable Abbild
    /// besitzen dieselbe Zielposition: Zeile 133, UTF-16-Spalte 82, 14 Units.
    /// So muss kein Inhalt aus dem Arbeitsdokument in den Quellcode wandern.
    private static func wordClickTargetRange(in text: String) -> NSRange? {
        let source = text as NSString
        var lineStart = 0
        for _ in 1..<133 {
            guard lineStart < source.length else { return nil }
            lineStart = NSMaxRange(source.lineRange(for: NSRange(
                location: lineStart, length: 0
            )))
        }
        let target = NSRange(location: lineStart + 81, length: 14)
        return target.max <= source.length ? target : nil
    }

    private static func pollWordClickMutation(
        textView: TextView, window: NSWindow, expectedText: String,
        target: NSRange, unrelated: NSRange, tick: Int
    ) {
        if textView.string == expectedText {
            centerWordClickTarget(textView: textView, target: target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pollWordClickReady(
                    textView: textView, window: window,
                    target: target, unrelated: unrelated, tick: 0
                )
            }
            return
        }
        if tick >= 40 {
            finish(false, "Eingabe stellt die lange Fixture-Zeile nicht wieder her")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollWordClickMutation(
                textView: textView, window: window, expectedText: expectedText,
                target: target, unrelated: unrelated, tick: tick + 1
            )
        }
    }

    /// `scrollToRange` laesst bereits knapp sichtbare Bereiche absichtlich
    /// stehen. Fuer echte Fensterereignisse muss das Ziel aber auch ausserhalb
    /// der Scrollleisten und Statusleisten liegen, nicht nur im Layout-Puffer.
    private static func centerWordClickTarget(
        textView: TextView, target: NSRange
    ) {
        guard let scrollView = textView.enclosingScrollView,
              let rect = textView.layoutManager.rectForOffset(target.location) else {
            textView.scrollToRange(target)
            return
        }
        let viewport = scrollView.documentVisibleRect
        scrollView.contentView.scroll(to: NSPoint(
            x: viewport.minX,
            y: max(rect.midY - viewport.height / 2, 0)
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.layoutManager.layoutLines()
    }

    /// `scrollToRange` arbeitet bei weit unten liegenden, langen Markdown-
    /// Dokumenten absichtlich mit faulem Layout. Erst klicken, wenn Anfang und
    /// nachträglich eingefügtes Ende echte Trefferflächen besitzen.
    private static func pollWordClickReady(
        textView: TextView, window: NSWindow,
        target: NSRange, unrelated: NSRange, tick: Int
    ) {
        guard window.makeFirstResponder(textView) else {
            finish(false, "Texteditor wird nicht First Responder")
        }
        textView.layoutManager.layoutLines()
        guard let content = window.contentView else {
            finish(false, "Fensterinhalt fehlt")
        }
        let clickOffsets = [target.location + 1, target.max - 2]
        let hitTestingIsReady = clickOffsets.allSatisfy { offset in
            guard let rect = textView.layoutManager.rectForOffset(offset),
                  rect.width > 0,
                  textView.visibleRect.intersects(rect),
                  let mapped = textView.layoutManager.textOffsetAtPoint(
                    NSPoint(x: rect.midX, y: rect.midY)
                  ) else {
                return false
            }
            let inWindow = textView.convert(
                NSPoint(x: rect.midX, y: rect.midY), to: nil
            )
            let inContent = content.convert(inWindow, from: nil)
            var hit = content.hitTest(inContent)
            while let view = hit {
                if view === textView {
                    return target.location...target.max ~= mapped
                }
                hit = view.superview
            }
            return false
        }
        if hitTestingIsReady {
            guard postWordDoubleClick(
                in: textView, window: window,
                offset: target.location + 1
            ) else {
                finish(false, "Doppelklick am Wortanfang nicht erzeugbar")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard textView.selectedRange() == target else {
                    finish(false, "Wortanfang markiert \(textView.selectedRange()) statt \(target)")
                }
                textView.selectionManager.setSelectedRange(unrelated)
                // Die programmatische Auswahländerung erst durch einen
                // Runloop-Takt abschließen lassen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard let rect = textView.layoutManager.rectForOffset(target.max - 2),
                          let mapped = textView.layoutManager.textOffsetAtPoint(
                            NSPoint(x: rect.midX, y: rect.midY)
                          ) else {
                        finish(false, "Wortende nicht auf Textposition abbildbar")
                    }
                    // Der Fenster-Hit-Test für genau diesen Punkt wurde oben
                    // bereits geprüft. Ab hier isolieren wir die Wortauswahl
                    // vom unzuverlässigen Hintergrund-Mausqueue-Timing.
                    textView.selectionManager.setSelectedRange(NSRange(
                        location: mapped, length: 0
                    ))
                    textView.selectWord(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        let selected = textView.selectedRange()
                        finish(selected == target,
                               selected == target
                               ? "Wortanfang und Wortende markieren dieselbe vollständige Auswahl"
                               : "Wortende reagiert nicht korrekt: Auswahl \(selected), erwartet \(target); "
                                 + wordClickDiagnostic(
                                    textView: textView, window: window,
                                    offset: target.max - 2
                                 ))
                    }
                }
            }
            return
        }
        if tick >= 40 {
            finish(false, "Zielwort wird binnen 4 s nicht real sichtbar")
        }
        textView.scrollToRange(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollWordClickReady(
                textView: textView, window: window,
                target: target, unrelated: unrelated, tick: tick + 1
            )
        }
    }

    /// Sendet die echte AppKit-Folge aus erstem und zweitem Klick an den
    /// produktiven Editor. Der Fenster-Hit-Test wurde unmittelbar davor für
    /// denselben Punkt geprüft; ein direkter Aufruf von `selectWord` würde den
    /// gemeldeten Zeichen-zu-Text-Pfad dagegen umgehen.
    private static func postWordDoubleClick(
        in textView: TextView, window: NSWindow, offset: Int
    ) -> Bool {
        guard let rect = textView.layoutManager.rectForOffset(offset) else {
            return false
        }
        let point = textView.convert(
            NSPoint(x: rect.midX, y: rect.midY), to: nil
        )
        let time = ProcessInfo.processInfo.systemUptime
        let firstEventNumber = Int(time * 1_000)
        var events: [NSEvent] = []
        for (index, eventDescription) in [
            (1, NSEvent.EventType.leftMouseDown, Float(1), 0.00),
            (1, .leftMouseUp, Float(0), 0.01),
            (2, .leftMouseDown, Float(1), 0.08),
            (2, .leftMouseUp, Float(0), 0.09),
        ].enumerated() {
            let (clickCount, type, pressure, delay) = eventDescription
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: time + delay, windowNumber: window.windowNumber,
                context: nil, eventNumber: firstEventNumber + index,
                clickCount: clickCount, pressure: pressure
            ) else { return false }
            events.append(event)
        }
        // Der Hintergrund-Runner besitzt absichtlich keinen Systemfokus. Die
        // App-Eventqueue darf solche synthetischen Klicks verwerfen; der echte
        // TextView-Ereignispfad selbst bleibt dagegen deterministisch prüfbar.
        textView.mouseDown(with: events[0])
        textView.mouseUp(with: events[1])
        textView.mouseDown(with: events[2])
        textView.mouseUp(with: events[3])
        return true
    }

    private static func wordClickDiagnostic(
        textView: TextView, window: NSWindow, offset: Int
    ) -> String {
        guard let rect = textView.layoutManager.rectForOffset(offset),
              let content = window.contentView else {
            return "kein Zeichenrechteck/ContentView"
        }
        let local = NSPoint(x: rect.midX, y: rect.midY)
        let inWindow = textView.convert(local, to: nil)
        let inContent = content.convert(inWindow, from: nil)
        var hierarchy: [String] = []
        var current = content.hitTest(inContent)
        while let view = current {
            hierarchy.append(String(describing: type(of: view)))
            current = view.superview
        }
        let mapped = textView.layoutManager.textOffsetAtPoint(local)
        let directHit = textView.hitTest(local)
            .map { String(describing: type(of: $0)) } ?? "nil"
        return "rect=\(rect), local=\(local), mapped=\(String(describing: mapped)), "
            + "textBounds=\(textView.bounds), visible=\(textView.visibleRect), "
            + "directHit=\(directHit), windowHit=\(hierarchy.joined(separator: "→"))"
    }

    // MARK: - -selftest rightedge

    /// Reproduziert die gemeldete Nutzergeometrie vom 2026-07-24: Markdown-
    /// Datei mit sehr langen Zeilen, integrierte Vorschau daneben, sichtbare
    /// Seitenleiste, System-Scrollbalken „immer einblenden“. Prüft, dass
    /// Klicks und Doppelklicks bis unmittelbar vor den vertikalen Scrollbalken
    /// den Cursor setzen bzw. das ganze Wort markieren.
    private static func runRightEdgeClickTest() {
        testLabel = "rightedge"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks() else {
            finish(false, "Workspace oder Hauptfenster fehlt")
        }
        // Exakte Geometrie aus dem Fehlerbericht (Defaults des Nutzers).
        ws.sidebarWidth = 216.13671875
        ws.markdownPreviewWidth = 332.3515625
        workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
        window.setContentSize(NSSize(width: 1100, height: 800))
        let text = rightEdgeFixtureContent()
        // Eigener leerer Ordner: Die Seitenleiste würde sonst den prall
        // gefüllten System-Temp-Ordner bei jedem SwiftUI-Durchlauf sortieren
        // und den Test massiv ausbremsen.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fastra-rightedge-\(UUID().uuidString)", isDirectory: true
            )
        let tmp = directory.appendingPathComponent("rechtsrand.md")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: tmp)
        }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }
        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: directory)
            guard ok else { finish(false, "Markdown-Fixture lädt nicht") }
            pollRightEdgeEditorReady(window: window, expectedText: text, tick: 0)
        }
    }

    /// Formabbild der Repro-Datei: elf logische Zeilen, die längste 646
    /// Zeichen. Wortlängen wechseln deterministisch, damit an vielen
    /// Umbruchkanten echte Wörter nahe am rechten Rand enden.
    private static func rightEdgeFixtureContent() -> String {
        let lineLengths = [646, 498, 406, 286, 187, 0, 120, 0, 80, 40, 18]
        let wordLengths = [4, 7, 3, 9, 5, 11, 6, 2, 8, 5]
        var lines: [String] = []
        for (lineIndex, targetLength) in lineLengths.enumerated() {
            if targetLength == 0 {
                lines.append("")
                continue
            }
            var line = ""
            var wordIndex = lineIndex
            while line.count < targetLength {
                let length = wordLengths[wordIndex % wordLengths.count]
                let letter = Character(
                    UnicodeScalar(UInt8(97 + (wordIndex % 26)))
                )
                if !line.isEmpty { line.append(" ") }
                line.append(String(repeating: letter, count: length))
                wordIndex += 1
            }
            lines.append(String(line.prefix(targetLength)))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func pollRightEdgeEditorReady(
        window: NSWindow, expectedText: String, tick: Int
    ) {
        if let root = window.contentView,
           markdownWebView(in: root) != nil,
           let textView = editorTextView(in: root) as? TextView,
           textView.string == expectedText,
           textView.enclosingScrollView != nil {
            window.makeFirstResponder(textView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                exerciseRightEdgeClicks(textView: textView, window: window)
            }
            return
        }
        if tick >= 100 {
            finish(false, "Markdown-Split mit Fixture nicht binnen 10 s bereit")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollRightEdgeEditorReady(
                window: window, expectedText: expectedText, tick: tick + 1
            )
        }
    }

    /// Misst die reale Geometrie und prüft ein Raster von Klickpunkten
    /// unmittelbar links vor dem vertikalen Scrollbalken.
    private static func exerciseRightEdgeClicks(
        textView: TextView, window: NSWindow
    ) {
        guard let scrollView = textView.enclosingScrollView,
              let content = window.contentView else {
            finish(false, "ScrollView oder ContentView fehlt")
        }
        textView.layoutManager.layoutLines()
        var diag: [String] = []
        diag.append("scrollerStyle=\(scrollView.scrollerStyle.rawValue) "
            + "(system=\(NSScroller.preferredScrollerStyle.rawValue))")
        diag.append("scrollView.frame=\(scrollView.frame) "
            + "contentSize=\(scrollView.contentSize)")
        diag.append("textView.frame=\(textView.frame) "
            + "visible=\(textView.visibleRect)")
        diag.append("edgeInsets=\(textView.layoutManager.edgeInsets) "
            + "wrapWidth=\(textView.layoutManager.wrapLinesWidth) "
            + "maxWrap=\(String(describing: textView.layoutManager.maximumWrapWidth))")
        var scrollerMinXInText: CGFloat = textView.visibleRect.maxX
        if let scroller = scrollView.verticalScroller, !scroller.isHidden {
            let inText = textView.convert(scroller.frame, from: scroller.superview)
            scrollerMinXInText = min(scrollerMinXInText, inText.minX)
            diag.append("verticalScroller in textView=\(inText)")
        }
        diag.append("klickbare rechte Kante x=\(scrollerMinXInText - 1)")
        // Alle MinimapViews im Fenster mit Sichtbarkeit und Lage vermerken.
        var minimapInfos: [String] = []
        func collectMinimaps(in view: NSView) {
            if String(describing: type(of: view)).contains("Minimap") {
                let inText = textView.convert(view.bounds, from: view)
                minimapInfos.append(
                    "\(type(of: view)) hidden=\(view.isHidden) "
                    + "hiddenOrAncestor=\(view.isHiddenOrHasHiddenAncestor) "
                    + "frame=\(view.frame) inTextView=\(inText)"
                )
            }
            for sub in view.subviews { collectMinimaps(in: sub) }
        }
        collectMinimaps(in: content)
        diag.append("Minimaps: " + minimapInfos.joined(separator: " ++ "))

        // Raster: erste 24 sichtbaren visuellen Zeilen, je vier x-Abstände
        // vor dem Scrollbalken. Für jeden Punkt: Fenster-Hit-Test und
        // Text-Offset-Auflösung.
        guard let firstRect = textView.layoutManager.rectForOffset(0) else {
            finish(false, "kein Zeichenrechteck für Offset 0")
        }
        let rowHeight = firstRect.height
        var deadPoints: [String] = []
        var checkedRows = 0
        for row in 0..<24 {
            let y = firstRect.minY + (CGFloat(row) + 0.5) * rowHeight
            guard y < textView.visibleRect.maxY else { break }
            // Nur Zeilen mit Text an der rechten Kante interessieren; ermittle
            // den rechtesten Zeichenpunkt der visuellen Zeile über eine Sonde
            // in der Zeilenmitte.
            guard let probeOffset = textView.layoutManager.textOffsetAtPoint(
                NSPoint(x: textView.layoutManager.edgeInsets.left + 4, y: y)
            ) else {
                deadPoints.append("Zeile \(row): Sonde am Zeilenanfang tot")
                continue
            }
            checkedRows += 1
            for dx in [1.0, 5.0, 15.0, 30.0] {
                let point = NSPoint(x: scrollerMinXInText - dx, y: y)
                let mapped = textView.layoutManager.textOffsetAtPoint(point)
                let inWindow = textView.convert(point, to: nil)
                let inContent = content.convert(inWindow, from: nil)
                var hitDescription = "nil"
                var hitsTextView = false
                var hit = content.hitTest(inContent)
                if let hitView = hit {
                    hitDescription = String(describing: type(of: hitView))
                }
                while let view = hit {
                    if view === textView { hitsTextView = true; break }
                    hit = view.superview
                }
                if mapped == nil || !hitsTextView {
                    deadPoints.append(
                        "Zeile \(row) dx=\(Int(dx)): mapped="
                        + "\(String(describing: mapped)) hit=\(hitDescription)"
                        + " (Sondenoffset \(probeOffset))"
                    )
                }
            }
        }
        guard checkedRows > 4 else {
            finish(false, "zu wenige messbare Zeilen — " + diag.joined(separator: " | "))
        }
        guard deadPoints.isEmpty else {
            finish(false, "tote Klickpunkte vor dem Scrollbalken: "
                + deadPoints.prefix(12).joined(separator: " ;; ")
                + " || Geometrie: " + diag.joined(separator: " | "))
        }
        exerciseRightEdgeDoubleClick(
            textView: textView, window: window,
            scrollerMinXInText: scrollerMinXInText, diag: diag
        )
    }

    /// Doppelklick auf das letzte Wort einer umbrochenen visuellen Zeile:
    /// Er muss genau dieses Wort markieren — wie am Wortanfang.
    private static func exerciseRightEdgeDoubleClick(
        textView: TextView, window: NSWindow,
        scrollerMinXInText: CGFloat, diag: [String]
    ) {
        // Rechtester Zeichenpunkt der zweiten visuellen Zeile (Zeile 0 der
        // 646er-Logikzeile ist sicher umbrochen, Zeile 1 beginnt mit Text).
        guard let firstRect = textView.layoutManager.rectForOffset(0) else {
            finish(false, "kein Zeichenrechteck für Offset 0")
        }
        let y = firstRect.minY + 1.5 * firstRect.height
        var rightmostOffset: Int?
        var rightmostRect: CGRect?
        var x = scrollerMinXInText - 1
        while x > textView.layoutManager.edgeInsets.left {
            if let offset = textView.layoutManager.textOffsetAtPoint(
                NSPoint(x: x, y: y)
            ), let rect = textView.layoutManager.rectForOffset(offset),
               rect.width >= 0 {
                rightmostOffset = offset
                rightmostRect = rect
                break
            }
            x -= 4
        }
        guard let clickOffset = rightmostOffset, rightmostRect != nil else {
            finish(false, "kein rechtester Zeichenpunkt bestimmbar — "
                + diag.joined(separator: " | "))
        }
        // Wortgrenzen des Zielworts aus dem Text ableiten.
        let source = textView.string as NSString
        var wordStart = clickOffset
        while wordStart > 0,
              !CharacterSet.whitespacesAndNewlines.contains(
                UnicodeScalar(source.character(at: wordStart - 1)) ?? " "
              ) {
            wordStart -= 1
        }
        var wordEnd = clickOffset
        while wordEnd < source.length,
              !CharacterSet.whitespacesAndNewlines.contains(
                UnicodeScalar(source.character(at: wordEnd)) ?? " "
              ) {
            wordEnd += 1
        }
        let expected = NSRange(location: wordStart, length: wordEnd - wordStart)
        guard expected.length > 0 else {
            finish(false, "Zielpunkt liegt auf Leerraum (Offset \(clickOffset))")
        }
        // Klick auf das letzte Zeichen des Worts, nicht auf die Wortmitte:
        // genau der gemeldete Fall.
        guard let lastCharRect = textView.layoutManager.rectForOffset(
            max(wordEnd - 1, wordStart)
        ) else {
            finish(false, "letztes Wortzeichen ohne Rechteck")
        }
        guard postWordDoubleClick(
            in: textView, window: window, offset: max(wordEnd - 1, wordStart)
        ) else {
            finish(false, "Doppelklick nicht erzeugbar")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let selected = textView.selectedRange()
            finish(selected == expected,
                   selected == expected
                   ? "alle Rasterpunkte klickbar; Doppelklick am rechten Rand "
                     + "markiert das ganze Wort \(expected)"
                   : "Doppelklick am rechten Rand: Auswahl \(selected), "
                     + "erwartet \(expected); Wortrechteck \(lastCharRect); "
                     + diag.joined(separator: " | "))
        }
    }

    // MARK: - -selftest selshort

    /// Variante des Auswahl-Scrolltests mit der kleinen Nutzerdatei: elf
    /// logische Zeilen, stark umbrochen, Markdown-Split. Shift+↓ bis ans
    /// Dateiende muss die bewegte Auswahlkante sichtbar halten.
    private static func runShortSelectionScrollTest() {
        testLabel = "selshort"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks() else {
            finish(false, "Workspace oder Hauptfenster fehlt")
        }
        ws.sidebarWidth = 216.13671875
        ws.markdownPreviewWidth = 332.3515625
        workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
        window.setContentSize(NSSize(width: 1100, height: 800))
        let text = rightEdgeFixtureContent()
        // Eigener leerer Ordner — siehe rightedge: verhindert, dass die
        // Seitenleiste den vollen System-Temp-Ordner dauernd sortiert.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fastra-selshort-\(UUID().uuidString)", isDirectory: true
            )
        let tmp = directory.appendingPathComponent("auswahl.md")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: tmp)
        }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }
        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: directory)
            guard ok else { finish(false, "Markdown-Fixture lädt nicht") }
            pollShortSelectionEditorReady(
                window: window, expectedText: text, tick: 0
            )
        }
    }

    private static func pollShortSelectionEditorReady(
        window: NSWindow, expectedText: String, tick: Int
    ) {
        if let root = window.contentView,
           markdownWebView(in: root) != nil,
           let textView = editorTextView(in: root) as? TextView,
           textView.string == expectedText,
           let scrollView = textView.enclosingScrollView {
            guard window.makeFirstResponder(textView) else {
                finish(false, "Editor wird nicht First Responder")
            }
            textView.layoutManager.layoutLines()
            textView.selectionManager.setSelectedRange(
                NSRange(location: 0, length: 0)
            )
            if let flags = NSEvent.keyEvent(
                with: .flagsChanged, location: .zero,
                modifierFlags: .shift,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 56
            ) {
                NSApp.postEvent(flags, atStart: false)
            }
            sendShortSelectionKey(
                textView: textView, scrollView: scrollView,
                window: window, step: 0
            )
            return
        }
        if tick >= 100 {
            finish(false, "Markdown-Split mit Fixture nicht binnen 10 s bereit")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollShortSelectionEditorReady(
                window: window, expectedText: expectedText, tick: tick + 1
            )
        }
    }

    /// 64 echte Shift+↓ — deutlich mehr als die Datei visuelle Zeilen hat,
    /// damit die Kante sicher bis ans Dateiende läuft. Nach JEDEM Tastendruck
    /// (plus Runloop-Takt) muss die bewegte Kante im Viewport liegen.
    private static func sendShortSelectionKey(
        textView: TextView, scrollView: NSScrollView,
        window: NSWindow, step: Int
    ) {
        guard let key = NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: .shift,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}",
            isARepeat: step > 0, keyCode: 125
        ) else {
            finish(false, "konnte Shift+Pfeil-nach-unten nicht bauen")
        }
        NSApp.postEvent(key, atStart: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            let range = textView.selectedRange()
            let visible = scrollView.documentVisibleRect
            if range.length > 0,
               let activeRect = textView.layoutManager.rectForOffset(
                   NSMaxRange(range)
               ),
               // Halbe Zeilenhöhe Toleranz: Der verzögerte Abgleich aus
               // Patch 4r darf einen Takt hinterherlaufen, aber nie eine
               // ganze Zeile verlieren.
               activeRect.minY > visible.maxY + activeRect.height / 2 {
                finish(false, "Schritt \(step): bewegte Kante \(activeRect) "
                    + "unterhalb des Viewports \(visible)")
            }
            if step < 63 {
                sendShortSelectionKey(
                    textView: textView, scrollView: scrollView,
                    window: window, step: step + 1
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let finalRange = textView.selectedRange()
                let finalVisible = scrollView.documentVisibleRect
                guard finalRange.length > 0,
                      NSMaxRange(finalRange)
                          == (textView.string as NSString).length,
                      let edge = textView.layoutManager.rectForOffset(
                          NSMaxRange(finalRange)
                      ) else {
                    finish(false, "Auswahl erreicht das Dateiende nicht: "
                        + "\(textView.selectedRange())")
                }
                guard finalVisible.maxY >= edge.maxY - 1 else {
                    finish(false, "Dateiende-Kante \(edge) liegt unter dem "
                        + "Viewport \(finalVisible)")
                }
                finish(true, "bewegte Kante blieb über 64 Shift+↓ sichtbar "
                    + "bis ans Dateiende (Viewport \(finalVisible))")
            }
        }
    }

    // MARK: - -selftest dragscroll

    /// Maus-Drag-Selektion über den unteren Fensterrand hinaus: Der Editor
    /// muss automatisch mitscrollen und die bewegte Kante sichtbar halten,
    /// statt die Auswahl unsichtbar unter dem Viewport weiterwachsen zu
    /// lassen.
    private static func runDragScrollTest() {
        testLabel = "dragscroll"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks() else {
            finish(false, "Workspace oder Hauptfenster fehlt")
        }
        ws.sidebarWidth = 216.13671875
        ws.markdownPreviewWidth = 332.3515625
        workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
        window.setContentSize(NSSize(width: 1100, height: 800))
        let text = rightEdgeFixtureContent()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fastra-dragscroll-\(UUID().uuidString)", isDirectory: true
            )
        let tmp = directory.appendingPathComponent("ziehen.md")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: tmp)
        }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }
        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: directory)
            guard ok else { finish(false, "Markdown-Fixture lädt nicht") }
            pollDragScrollEditorReady(window: window, expectedText: text, tick: 0)
        }
    }

    private static func pollDragScrollEditorReady(
        window: NSWindow, expectedText: String, tick: Int
    ) {
        if let root = window.contentView,
           markdownWebView(in: root) != nil,
           let textView = editorTextView(in: root) as? TextView,
           textView.string == expectedText,
           let scrollView = textView.enclosingScrollView {
            guard window.makeFirstResponder(textView) else {
                finish(false, "Editor wird nicht First Responder")
            }
            textView.layoutManager.layoutLines()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                beginDragScroll(
                    textView: textView, scrollView: scrollView, window: window
                )
            }
            return
        }
        if tick >= 100 {
            finish(false, "Markdown-Split mit Fixture nicht binnen 10 s bereit")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollDragScrollEditorReady(
                window: window, expectedText: expectedText, tick: tick + 1
            )
        }
    }

    /// Startet den Drag mit einem echten Maus-Down im Text und zieht dann
    /// unter den unteren Fensterrand. Die Folgeereignisse laufen über die
    /// App-Eventqueue, damit `window.currentEvent` und der produktive
    /// Autoscroll-Timer genauso arbeiten wie bei einer physischen Maus.
    private static func beginDragScroll(
        textView: TextView, scrollView: NSScrollView, window: NSWindow
    ) {
        guard let startRect = textView.layoutManager.rectForOffset(10) else {
            finish(false, "Startzeichen ohne Rechteck")
        }
        // Bewusst die linke Zeichenhälfte: Die Caret-Rundung ist an der
        // Zeichenmitte mehrdeutig, der Anker soll eindeutig bei Offset 10
        // liegen.
        let startInWindow = textView.convert(
            NSPoint(x: startRect.minX + 1, y: startRect.midY), to: nil
        )
        let initialTop = scrollView.documentVisibleRect.minY
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: startInWindow, modifierFlags: [],
            timestamp: time, windowNumber: window.windowNumber, context: nil,
            eventNumber: Int(time * 1_000), clickCount: 1, pressure: 1
        ) else {
            finish(false, "Maus-Down nicht erzeugbar")
        }
        textView.mouseDown(with: down)
        // Zielpunkt 40 Punkte UNTER dem Fenster (Fensterkoordinaten sind
        // unten-basiert, also negativ).
        let dragLocation = NSPoint(x: startInWindow.x, y: -40)
        continueDragScroll(
            textView: textView, scrollView: scrollView, window: window,
            dragLocation: dragLocation, initialTop: initialTop, step: 0
        )
    }

    private static func continueDragScroll(
        textView: TextView, scrollView: NSScrollView, window: NSWindow,
        dragLocation: NSPoint, initialTop: CGFloat, step: Int
    ) {
        let time = ProcessInfo.processInfo.systemUptime
        if let drag = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: dragLocation,
            modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: Int(time * 1_000) + step + 1, clickCount: 1,
            pressure: 1
        ) {
            NSApp.postEvent(drag, atStart: false)
        }
        if step < 45 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                continueDragScroll(
                    textView: textView, scrollView: scrollView, window: window,
                    dragLocation: dragLocation, initialTop: initialTop,
                    step: step + 1
                )
            }
            return
        }
        let upTime = ProcessInfo.processInfo.systemUptime
        if let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: dragLocation, modifierFlags: [],
            timestamp: upTime, windowNumber: window.windowNumber, context: nil,
            eventNumber: Int(upTime * 1_000) + 99, clickCount: 1, pressure: 0
        ) {
            NSApp.postEvent(up, atStart: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let range = textView.selectedRange()
            let visible = scrollView.documentVisibleRect
            guard range.length > 0 else {
                finish(false, "Drag erzeugte keine Auswahl")
            }
            // Der Anker muss am angeklickten Zeichen bleiben, auch wenn das
            // erste Drag-Ereignis bereits weit unterhalb des Fensters liegt.
            guard range.location == 10 else {
                finish(false, "Drag-Anker verrutscht: Auswahl beginnt bei "
                    + "\(range.location) statt am Klickpunkt 10")
            }
            guard visible.minY > initialTop else {
                finish(false, "Editor scrollte beim Drag über den unteren "
                    + "Rand nicht mit (Viewport weiter bei y=\(visible.minY), "
                    + "Auswahl \(range))")
            }
            guard let edge = textView.layoutManager.rectForOffset(
                NSMaxRange(range)
            ), edge.minY <= visible.maxY + edge.height / 2 else {
                finish(false, "Auswahlkante liegt nach dem Drag unter dem "
                    + "Viewport (Auswahl \(range), Viewport \(visible))")
            }
            finish(true, "Drag-Autoscroll folgt: Viewport von "
                + "y=\(Int(initialTop)) auf y=\(Int(visible.minY)), "
                + "Auswahl \(range) mit sichtbarer Kante")
        }
    }

    // MARK: - -selftest dirtyundo

    /// Punkt im Tab über den ECHTEN Editorpfad: Einfügen macht dirty,
    /// Rückgängig auf den exakten Ladezustand macht wieder sauber, Redo
    /// wieder dirty, und manuelles Löschen der Einfügung (ohne Undo) räumt
    /// den Punkt ebenfalls ab.
    private static func runDirtyUndoTest() {
        testLabel = "dirtyundo"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks(),
              let root = window.contentView else {
            finish(false, "Workspace oder Hauptfenster fehlt")
        }
        let content = "Zeile 1\nZeile 2\nZeile 3\n"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fastra-dirtyundo-\(UUID().uuidString)", isDirectory: true
            )
        let tmp = directory.appendingPathComponent("punkt.md")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: tmp)
        }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }
        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: directory)
            guard ok else { finish(false, "loadFile schlug fehl") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let tv = editorTextView(in: root) as? TextView,
                      tv.string == content else {
                    finish(false, "Editor-TextView mit Fixture fehlt")
                }
                guard ws.activeTab?.isDirty == false else {
                    finish(false, "Tab ist direkt nach dem Laden dirty")
                }
                // Wie im Fehlerbericht: zwei Leerzeilen ans Ende anhängen.
                tv.selectionManager.setSelectedRange(NSRange(
                    location: (content as NSString).length, length: 0
                ))
                tv.insertText(
                    "\n\n",
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard ws.activeTab?.isDirty == true else {
                        finish(false, "Einfügen setzte den Punkt nicht")
                    }
                    tv.undoManager?.undo()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard tv.string == content else {
                            finish(false, "Undo stellte den Ladezustand nicht her")
                        }
                        guard ws.activeTab?.isDirty == false else {
                            finish(false, "Punkt blieb trotz exakter Rücknahme "
                                + "per Undo bestehen")
                        }
                        tv.undoManager?.redo()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            guard ws.activeTab?.isDirty == true else {
                                finish(false, "Redo setzte den Punkt nicht erneut")
                            }
                            // Manuelles Löschen statt Undo: gleicher Inhalt,
                            // gleicher Anspruch.
                            let full = tv.string as NSString
                            tv.replaceCharacters(
                                in: NSRange(location: full.length - 2, length: 2),
                                with: ""
                            )
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                guard tv.string == content else {
                                    finish(false, "manuelles Löschen stellte den "
                                        + "Inhalt nicht wieder her")
                                }
                                finish(ws.activeTab?.isDirty == false,
                                       ws.activeTab?.isDirty == false
                                       ? "Punkt folgt Laden→Einfügen→Undo→Redo→"
                                         + "manuellem Löschen korrekt"
                                       : "Punkt blieb nach manuellem Löschen "
                                         + "der Einfügung bestehen")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - -selftest typescroll

    /// Tippen muss den Cursor IMMER in den Sichtbereich holen (Daniel-Befund
    /// 2026-07-25, BBEdit-Referenzverhalten): 1) Return am Dateiende scrollt
    /// zur neuen Zeile. 2) Auch wenn der Nutzer von Hand weggescrollt hat,
    /// holt das nächste getippte Zeichen die Cursorzeile zurück. 3) Ein per
    /// Palette eingefügtes Emoji ist sofort vollständig ausgelegt. 4) Shift+←
    /// erweitert die Auswahl über das Emoji.
    private static func runTypeScrollTest() {
        testLabel = "typescroll"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks(),
              let root = window.contentView else {
            finish(false, "Workspace oder Hauptfenster fehlt")
        }
        // Gleiche Konstellation wie Daniels Repro-Datei (2026-07-25): wenige,
        // sehr lange, weich umbrochene Markdown-Zeilen ohne End-Umbruch —
        // der umbrochene Inhalt ist höher als das Fenster. Seitenleiste und
        // integrierte Vorschau machen den Editor schmal (wie emojisplit).
        ws.sidebarWidth = 216.13671875
        ws.markdownPreviewWidth = 332.3515625
        workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
        window.setContentSize(NSSize(width: 1100, height: 500))
        // FASTRA_TYPESCROLL_FIXTURE erlaubt die Diagnose mit einer realen
        // Datei (Kopie!); der normale Lauf nutzt das neutrale Abbild.
        let text: String
        if let path = ProcessInfo.processInfo
            .environment["FASTRA_TYPESCROLL_FIXTURE"],
           let fixture = try? String(contentsOfFile: path, encoding: .utf8) {
            text = fixture
        } else {
            text = emojiSplitFixtureContent()
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-typescroll-\(UUID().uuidString).md")
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { finish(false, "Fixture nicht schreibbar: \(error.localizedDescription)") }
        ws.loadFile(at: url.canonicalFileURL) { ok in
            guard ok else {
                try? FileManager.default.removeItem(at: url)
                finish(false, "Fixture lädt nicht")
            }
            // Wie in Daniels realem Ablauf: Die Datei wird nach dem Öffnen
            // EXTERN geändert (v2-Kopie, andere Agenten) — der Editor lädt
            // still neu. Erst der Zustand NACH diesem Reload wird geprüft.
            typeScrollStageExternalChange(window: window, root: root,
                                          url: url, originalText: text)
        }
    }

    /// Ändert die geöffnete Datei auf der Platte und wartet auf den stillen
    /// Reload des sauberen Tabs. Danach laufen die Tipp-Stufen auf dem
    /// neu geladenen Editorzustand.
    private static func typeScrollStageExternalChange(
        window: NSWindow, root: NSView, url: URL, originalText: String
    ) {
        let changed = originalText + "\nextern ergänzte Zeile ohne Umbruch danach"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            do { try changed.write(to: url, atomically: true, encoding: .utf8) }
            catch {
                try? FileManager.default.removeItem(at: url)
                finish(false, "externe Änderung nicht schreibbar: \(error.localizedDescription)")
            }
            // Im echten Ablauf stößt die App-Aktivierung die Prüfung an; im
            // Selbsttest bleibt die App durchgehend aktiv → direkt aufrufen.
            Workspace.shared?.checkExternalChanges()
            pollTypeScrollReloaded(window: window, root: root, url: url,
                                   expectedText: changed, tick: 0)
        }
    }

    /// Bleibt bis zum Testende liegen: Die Zweitfenster-Stufe öffnet dieselbe
    /// Datei erneut (Daniels Repro-Ablauf 2026-07-24: ⌘N, dann ⌘O derselben
    /// Datei, während das erste Fenster sie im Hintergrund offen behält).
    private static var typeScrollFixtureURL: URL?

    private static func pollTypeScrollReloaded(
        window: NSWindow, root: NSView, url: URL, expectedText: String, tick: Int
    ) {
        if let textView = editorTextView(in: root) as? TextView,
           textView.string == expectedText {
            typeScrollFixtureURL = url
            pollTypeScrollEditorReady(window: window, root: root,
                                      expectedText: expectedText, tick: 0)
            return
        }
        if tick >= 100 {
            try? FileManager.default.removeItem(at: url)
            finish(false, "stiller Reload nach externer Änderung kam nicht binnen 10 s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollTypeScrollReloaded(window: window, root: root, url: url,
                                   expectedText: expectedText, tick: tick + 1)
        }
    }

    private static func pollTypeScrollEditorReady(
        window: NSWindow, root: NSView, expectedText: String, tick: Int
    ) {
        if let textView = editorTextView(in: root) as? TextView,
           textView.string == expectedText {
            window.makeFirstResponder(textView)
            // Ans Dateiende, Cursor hinter das letzte Zeichen.
            let length = (textView.string as NSString).length
            textView.selectionManager.setSelectedRange(
                NSRange(location: length, length: 0)
            )
            textView.scrollSelectionToVisible()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                typeScrollStageReturn(textView: textView) { failures in
                    typeScrollStageManualScroll(textView: textView,
                                                failures: failures)
                }
            }
            return
        }
        if tick >= 100 { finish(false, "Editor nicht binnen 10 s bereit") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollTypeScrollEditorReady(window: window, root: root,
                                      expectedText: expectedText, tick: tick + 1)
        }
    }

    /// Ist der Cursor (Kollaps-Selektion) im sichtbaren Bereich der TextView?
    private static func typeScrollCaretVisible(_ textView: TextView) -> Bool {
        guard let selection = textView.selectionManager.textSelections.first,
              let rect = textView.layoutManager.rectForOffset(selection.range.max)
        else { return false }
        return textView.visibleRect.intersects(rect)
    }

    /// Stufe 1: MEHRERE Returns am Dateiende — jede neue Zeile muss sichtbar
    /// bleiben. Ein einzelnes Return kann noch in den Sichtbereichs-Rest
    /// unterhalb des Cursors passen; erst die Wiederholung ist streng.
    /// `label` kennzeichnet Befunde der Zweitfenster-Wiederholung;
    /// `then` übernimmt die gesammelten Befunde.
    private static func typeScrollStageReturn(
        textView: TextView, iteration: Int = 0, failures: [String] = [],
        label: String = "", then: @escaping ([String]) -> Void
    ) {
        var failures = failures
        if iteration >= 6 {
            // Stufe 1b: Weitertippen auf der (womöglich unsichtbaren) Zeile
            // muss die Zeile ebenfalls sichtbar machen.
            textView.insertText("nachgetippt")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if !typeScrollCaretVisible(textView) {
                    failures.append(label + "Tippen auf unsichtbarer Zeile scrollt nicht nach")
                }
                then(failures)
            }
            return
        }
        // ECHTER Tastenpfad: keyDown-Event durchs Fenster (interpretKeyEvents,
        // Input-Context, TextFormation-Filter) — nicht der Direktselektor.
        // Fällt das Event-Bauen fehl, bleibt der Selektor das Fallback.
        if let window = textView.window,
           let event = NSEvent.keyEvent(
               with: .keyDown, location: .zero, modifierFlags: [],
               timestamp: ProcessInfo.processInfo.systemUptime,
               windowNumber: window.windowNumber, context: nil,
               characters: "\r", charactersIgnoringModifiers: "\r",
               isARepeat: false, keyCode: 36
           ) {
            window.sendEvent(event)
        } else {
            textView.insertNewline(nil)
        }
        // Unmittelbar nach dem Tastendruck ein unabhängiges SwiftUI-Update
        // erzwingen — wie es im echten Betrieb die Fußzeile (Zeile/Spalte)
        // auslöst. Genau dieses Update ließ den CESE-State-Reconcile mit
        // veralteter Scroll-Position den frischen Tipp-Scroll zurückdrehen
        // (Daniel-Repro 2026-07-24, Call-Stack via Scroll-Spy).
        Workspace.shared?.objectWillChange.send()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if !typeScrollCaretVisible(textView) {
                let visible = textView.visibleRect
                let caret = textView.selectionManager.textSelections.first
                    .flatMap { textView.layoutManager.rectForOffset($0.range.max) }
                failures.append(label + "Return \(iteration + 1) am Dateiende scrollt "
                    + "nicht zur neuen Zeile (sichtbar bis y=\(Int(visible.maxY)), "
                    + "Cursor bei y=\(caret.map { Int($0.minY) } ?? -1), "
                    + "Inhaltshöhe \(Int(textView.frame.height)))")
            }
            typeScrollStageReturn(textView: textView, iteration: iteration + 1,
                                  failures: failures, label: label, then: then)
        }
    }

    /// Stufe 2: Von Hand nach oben scrollen, dann ein Zeichen tippen — die
    /// Cursorzeile muss zurück in den Sichtbereich kommen (BBEdit-Verhalten).
    private static func typeScrollStageManualScroll(
        textView: TextView, failures: [String]
    ) {
        var failures = failures
        textView.enclosingScrollView?.contentView.scroll(to: .zero)
        textView.enclosingScrollView.map {
            $0.reflectScrolledClipView($0.contentView)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if typeScrollCaretVisible(textView) {
                failures.append("Umgebungsproblem: manuelles Wegscrollen wirkte nicht")
            }
            textView.insertText("x")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if !typeScrollCaretVisible(textView) {
                    failures.append("Tippen nach manuellem Wegscrollen holt die "
                        + "Cursorzeile nicht zurück")
                }
                typeScrollStageEmoji(textView: textView, failures: failures)
            }
        }
    }

    /// Stufe 3+4: Emoji wie über die macOS-Palette einfügen (insertText mit
    /// replacementRange) — Auslegung sofort vollständig; Shift+← erweitert
    /// die Auswahl um das komplette Emoji.
    private static func typeScrollStageEmoji(
        textView: TextView, failures: [String]
    ) {
        var failures = failures
        let ns = textView.string as NSString
        textView.selectionManager.setSelectedRange(
            NSRange(location: ns.length, length: 0)
        )
        textView.insertText("🤢", replacementRange: NSRange(location: NSNotFound, length: 0))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let after = textView.string as NSString
            if !(after as String).hasSuffix("🤢") {
                failures.append("Palette-Emoji fehlt im Text")
            }
            // Die Cursorzeile muss das Emoji vollständig ausgelegt haben:
            // Fragmente der Zeile decken die gesamte Zeilenlänge ab.
            if let line = textView.layoutManager.textLineForOffset(after.length - 1) {
                let covered = line.data.lineFragments.map(\.range.length)
                    .reduce(0, +)
                if covered < line.range.length - 1 {   // -1: Umbruchzeichen
                    failures.append("Emoji-Zeile unvollständig ausgelegt: "
                        + "\(covered) von \(line.range.length)")
                }
            }
            // Zweites Emoji wie im Repro, dann Shift+← zweimal.
            textView.insertText("🤮", replacementRange: NSRange(location: NSNotFound, length: 0))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                textView.moveLeftAndModifySelection(nil)
                let firstExtension = textView.selectionManager
                    .textSelections.first?.range.length ?? 0
                if firstExtension != 2 {
                    failures.append("Shift+← markiert hinter Emoji "
                        + "\(firstExtension) statt 2 UTF-16-Einheiten")
                }
                textView.moveLeftAndModifySelection(nil)
                let secondExtension = textView.selectionManager
                    .textSelections.first?.range.length ?? 0
                if secondExtension != 4 {
                    failures.append("Zweites Shift+← markiert "
                        + "\(secondExtension) statt 4 UTF-16-Einheiten")
                }
                typeScrollStagePixels(textView: textView, failures: failures)
            }
        }
    }

    /// Fensterinhalt als PNG aufnehmen. Bevorzugt `screencapture` (echte
    /// Bildschirm-Wahrheit); ohne Aufnahme-Berechtigung ersatzweise ein
    /// Render der aktuellen Layer-Backing-Stores — auch das zeigt veraltete
    /// Zeichnung, weil `CALayer.render(in:)` vorhandene Inhalte verwendet
    /// statt neu durch `draw(_:)` zu gehen.
    private static func typeScrollCapture(window: NSWindow) -> Data? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-typescroll-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-l\(window.windowNumber)", "-o", "-x", url.path]
        do {
            try capture.run()
            capture.waitUntilExit()
        } catch { return typeScrollLayerSnapshot(window: window) }
        guard capture.terminationStatus == 0,
              let data = try? Data(contentsOf: url) else {
            return typeScrollLayerSnapshot(window: window)
        }
        return data
    }

    /// Ersatz-Aufnahme aus den CALayer-Backing-Stores des Fensterinhalts.
    private static func typeScrollLayerSnapshot(window: NSWindow) -> Data? {
        guard let view = window.contentView, let layer = view.layer else {
            return nil
        }
        let scale = window.backingScaleFactor
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        context.cgContext.scaleBy(x: scale, y: scale)
        layer.render(in: context.cgContext)
        return rep.representation(using: .png, properties: [:])
    }

    /// Stufe 5 (Pixel-Wahrheit): Tippen muss den SICHTBAREN Fensterinhalt
    /// ändern. Layout-Rects können stimmen, während das Zeichnen veraltet —
    /// genau das ist die Klasse der Daniel-Befunde vom 2026-07-25.
    private static func typeScrollStagePixels(
        textView: TextView, failures: [String]
    ) {
        var failures = failures
        guard let window = textView.window,
              let before = typeScrollCapture(window: window) else {
            // Ohne Aufnahme keine Pixel-Aussage; die übrigen Stufen zählen.
            finishTypeScroll(failures: failures,
                             note: "; Pixel-Stufe übersprungen "
                               + "(Umgebungsproblem: keine Bildschirmaufnahme)")
            return
        }
        textView.insertText("PIXELPROBE", replacementRange: NSRange(location: NSNotFound, length: 0))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let after = typeScrollCapture(window: window) else {
                finishTypeScroll(failures: failures,
                                 note: "; Pixel-Stufe abgebrochen "
                                   + "(Umgebungsproblem: keine Bildschirmaufnahme)")
                return
            }
            if before == after {
                failures.append("Tippen änderte den sichtbaren Fensterinhalt "
                    + "NICHT (Pixel identisch — Zeichnung veraltet)")
            }
            typeScrollStageSecondWindow(failures: failures, note: "")
        }
    }

    /// Stufe 6 (Daniels Repro-Ablauf 2026-07-24): ⌘N öffnet ein ZWEITES
    /// Fenster, dort wird DIESELBE Datei erneut geladen, während das erste
    /// Fenster sie im Hintergrund offen behält. Die Return-Serie muss auch
    /// im Zweitfenster sichtbar scrollen.
    private static func typeScrollStageSecondWindow(
        failures: [String], note: String
    ) {
        guard let url = typeScrollFixtureURL,
              let firstWorkspace = Workspace.shared,
              let firstWindow = NSApp.windows.first(where: {
                  !SearchWindow.isSearchWindow($0) && $0.isVisible
                      && WorkspaceWindowRegistry.workspace(for: $0) != nil
              }) else {
            finishTypeScroll(failures: failures,
                             note: note + "; Zweitfenster-Stufe übersprungen "
                               + "(Ausgangszustand fehlt)")
            return
        }
        firstWindow.makeKeyAndOrderFront(nil)
        postCmd("n", keyCode: 45, windowNumber: firstWindow.windowNumber)
        pollTypeScrollSecondWindow(firstWorkspace: firstWorkspace,
                                   firstWindow: firstWindow, url: url,
                                   failures: failures, note: note, tick: 0)
    }

    private static func pollTypeScrollSecondWindow(
        firstWorkspace: Workspace, firstWindow: NSWindow, url: URL,
        failures: [String], note: String, tick: Int
    ) {
        // Das neue Fenster hat einen EIGENEN Workspace (Registry-Muster wie
        // im newwindow-Selbsttest).
        if let secondWindow = NSApp.windows.first(where: {
               !SearchWindow.isSearchWindow($0) && $0.isVisible
                   && $0 !== firstWindow
                   && WorkspaceWindowRegistry.workspace(for: $0) != nil
                   && WorkspaceWindowRegistry.workspace(for: $0) !== firstWorkspace
           }),
           let secondWorkspace = WorkspaceWindowRegistry.workspace(for: secondWindow),
           let secondRoot = secondWindow.contentView {
            secondWorkspace.loadFile(at: url.canonicalFileURL) { ok in
                guard ok else {
                    finishTypeScroll(failures: failures + ["Zweitfenster: Datei lädt nicht"],
                                     note: note)
                    return
                }
                pollTypeScrollSecondEditor(root: secondRoot, window: secondWindow,
                                           failures: failures, note: note, tick: 0)
            }
            return
        }
        if tick >= 100 {
            finishTypeScroll(failures: failures
                + ["Zweitfenster erschien nicht binnen 10 s nach ⌘N"], note: note)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollTypeScrollSecondWindow(firstWorkspace: firstWorkspace,
                                       firstWindow: firstWindow, url: url,
                                       failures: failures, note: note, tick: tick + 1)
        }
    }

    private static func pollTypeScrollSecondEditor(
        root: NSView, window: NSWindow, failures: [String], note: String, tick: Int
    ) {
        if let textView = editorTextView(in: root) as? TextView,
           !textView.string.isEmpty {
            window.makeFirstResponder(textView)
            let length = (textView.string as NSString).length
            textView.selectionManager.setSelectedRange(
                NSRange(location: length, length: 0)
            )
            textView.scrollSelectionToVisible()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                typeScrollStageReturn(textView: textView, label: "Zweitfenster: ") {
                    finishTypeScroll(failures: $0, note: note)
                }
            }
            return
        }
        if tick >= 100 {
            finishTypeScroll(failures: failures
                + ["Zweitfenster-Editor nicht binnen 10 s bereit"], note: note)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollTypeScrollSecondEditor(root: root, window: window,
                                       failures: failures, note: note, tick: tick + 1)
        }
    }

    private static func finishTypeScroll(failures: [String], note: String) {
        if let url = typeScrollFixtureURL {
            try? FileManager.default.removeItem(at: url)
            typeScrollFixtureURL = nil
        }
        finish(failures.isEmpty,
               failures.isEmpty
               ? "Tippen scrollt den Cursor sichtbar und zeichnet sichtbar; "
                 + "Emoji sofort ausgelegt; Shift+← erweitert über Emojis" + note
               : failures.joined(separator: " ;; ") + note)
    }

    // MARK: - -selftest emojisplit

    /// Emojis (UTF-16-Surrogatpaare) dürfen im Editor nie in zwei sichtbare
    /// Zeichen zerfallen: weder durch Attributläufe des Highlighters noch
    /// durch Umbruchfragmente oder die Glyphen des Typesetters.
    private static func runEmojiSplitTest() {
        testLabel = "emojisplit"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks() else {
            finish(false, "Workspace oder Hauptfenster fehlt")
        }
        ws.sidebarWidth = 216.13671875
        ws.markdownPreviewWidth = 332.3515625
        workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
        window.setContentSize(NSSize(width: 1100, height: 800))
        let text: String
        if let path = ProcessInfo.processInfo.environment["FASTRA_EMOJI_FIXTURE"],
           let fixture = try? String(contentsOfFile: path, encoding: .utf8) {
            // Reale Datei für die Erstdiagnose; der normale Lauf nutzt das
            // neutrale Abbild mit derselben Emoji-Konstellation.
            text = fixture
        } else {
            text = emojiSplitFixtureContent()
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fastra-emojisplit-\(UUID().uuidString)", isDirectory: true
            )
        let tmp = directory.appendingPathComponent("emoji.md")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: tmp)
        }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }
        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: directory)
            guard ok else { finish(false, "Markdown-Fixture lädt nicht") }
            pollEmojiSplitEditorReady(window: window, expectedText: text, tick: 0)
        }
    }

    /// Neutrales Abbild der Repro-Datei: mehrere lange Zeilen, am Ende eine
    /// Zeile mit drei Emojis in Anführungszeichen, ohne abschließenden
    /// Zeilenumbruch — exakt die gemeldete Konstellation.
    private static func emojiSplitFixtureContent() -> String {
        var lines = (1...9).map { index in
            "- " + String(
                repeating: "xxxx xxxxxxx xxx ",
                count: 8 + index % 4
            )
        }
        lines.append(
            "- Xxxx: Xxxx Xxxxx Xxxxx Xxxxxxx: xxxxxxxxx Xxxx "
            + "xxxxxxxxxxxxx: \"XXXX XXXXX: Xxxxxx Xxx xxxx xxxx "
            + "xxxxxxxx xxxx 🎶🤮🎶\" - xx xxxxxxx? "
        )
        return lines.joined(separator: "\n")
    }

    private static func pollEmojiSplitEditorReady(
        window: NSWindow, expectedText: String, tick: Int
    ) {
        if let root = window.contentView,
           markdownWebView(in: root) != nil,
           let textView = editorTextView(in: root) as? TextView,
           textView.string == expectedText {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                analyzeEmojiClusters(textView: textView)
            }
            return
        }
        if tick >= 100 {
            finish(false, "Markdown-Split mit Fixture nicht binnen 10 s bereit")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollEmojiSplitEditorReady(
                window: window, expectedText: expectedText, tick: tick + 1
            )
        }
    }

    /// Schiebt die Umbruchgrenze durch die Emoji-Zeile: Für jede Vorschau-
    /// Breite von 260 bis 500 Punkten in 2er-Schritten wird neu ausgelegt
    /// und erneut auf Surrogat-Zerfall geprüft.
    private static func sweepEmojiWidths(
        textView: TextView, width: Double, collected: [String]
    ) {
        guard width <= 500 else {
            finish(collected.isEmpty,
                   collected.isEmpty
                   ? "Emojis blieben über alle 121 Umbruchbreiten intakt"
                   : "Emoji zerfällt: "
                     + collected.prefix(8).joined(separator: " ;; ")
                     + " (insgesamt \(collected.count) Befunde)")
        }
        Workspace.shared?.markdownPreviewWidth = width
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            textView.layoutManager.layoutLines()
            let problems = emojiClusterProblems(textView: textView)
                .map { "Breite \(Int(width)): \($0)" }
            sweepEmojiWidths(
                textView: textView, width: width + 2,
                collected: collected + problems
            )
        }
    }

    /// Prüft jedes Emoji-Vorkommen auf drei Zerfallsarten: Attributlauf-
    /// Grenze im Surrogatpaar, Fragmentgrenze im Surrogatpaar und Glyphen,
    /// die auf dem Trailing-Surrogat beginnen.
    private static func analyzeEmojiClusters(textView: TextView) {
        // Ans Dateiende scrollen, damit die Zielzeile real ausgelegt ist —
        // und dem asynchronen, viewport-getriebenen Highlighter danach Zeit
        // geben, seine Attributläufe wirklich anzuwenden.
        let ns = textView.string as NSString
        textView.scrollToRange(NSRange(location: ns.length, length: 0))
        textView.layoutManager.layoutLines()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            analyzeEmojiClustersAfterHighlight(textView: textView)
        }
    }

    private static func analyzeEmojiClustersAfterHighlight(textView: TextView) {
        textView.layoutManager.layoutLines()
        let initialProblems = emojiClusterProblems(textView: textView)
            .map { "Nutzergeometrie: \($0)" }
        sweepEmojiWidths(
            textView: textView, width: 260, collected: initialProblems
        )
    }

    /// Liefert alle gefundenen Zerfallsarten für sämtliche Emoji-Vorkommen
    /// im aktuellen Layoutzustand.
    private static func emojiClusterProblems(textView: TextView) -> [String] {
        let ns = textView.string as NSString
        var clusters: [NSRange] = []
        for emoji in ["🎶", "🤮"] {
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let found = ns.range(of: emoji, options: [], range: search)
                guard found.location != NSNotFound else { break }
                clusters.append(found)
                let next = found.location + found.length
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        guard clusters.count >= 3 else {
            return ["Fixture enthält nicht die erwarteten Emojis"]
        }
        var problems: [String] = []
        for cluster in clusters.sorted(by: { $0.location < $1.location }) {
            // 1) Attributläufe des Storages dürfen das Paar nicht teilen.
            var runRanges: [NSRange] = []
            textView.textStorage.enumerateAttributes(
                in: cluster, options: []
            ) { _, range, _ in runRanges.append(range) }
            if runRanges.count > 1 {
                problems.append("Attributlauf-Grenze in \(cluster): \(runRanges)")
            }
            // 2) Umbruchfragmente dürfen das Paar nicht teilen; 3) keine
            // Glyphe darf auf dem Trailing-Surrogat beginnen.
            guard let linePosition = textView.layoutManager.textLineForOffset(
                cluster.location
            ) else {
                problems.append("keine Layoutzeile für \(cluster)")
                continue
            }
            let lineStart = linePosition.range.location
            for fragmentPosition in linePosition.data.lineFragments {
                let fragmentRange = NSRange(
                    location: lineStart + fragmentPosition.range.location,
                    length: fragmentPosition.range.length
                )
                for boundary in [fragmentRange.location, fragmentRange.max]
                where boundary > cluster.location && boundary < cluster.max {
                    problems.append("Fragmentgrenze bei \(boundary) "
                        + "im Emoji \(cluster)")
                }
                guard fragmentRange.intersection(cluster)?.length ?? 0 > 0
                else { continue }
                for content in fragmentPosition.data.contents {
                    guard case .text(let ctLine) = content.data else { continue }
                    // CTLine-Indizes sind je nach Erzeugung zeilen- oder
                    // fragmentrelativ; der Stringbereich der Linie verrät die
                    // Basis.
                    let ctRange = CTLineGetStringRange(ctLine)
                    let base = ctRange.location
                        >= fragmentPosition.range.location
                        ? lineStart
                        : fragmentRange.location
                    let runs = CTLineGetGlyphRuns(ctLine)
                        as? [CTRun] ?? []
                    for run in runs {
                        let glyphCount = CTRunGetGlyphCount(run)
                        guard glyphCount > 0 else { continue }
                        var indices = [CFIndex](repeating: 0, count: glyphCount)
                        CTRunGetStringIndices(
                            run, CFRange(location: 0, length: glyphCount),
                            &indices
                        )
                        for index in indices {
                            let absolute = base + index
                            if absolute > cluster.location
                                && absolute < cluster.max {
                                problems.append("Glyphe beginnt mitten im "
                                    + "Emoji \(cluster) (Offset \(absolute))")
                            }
                        }
                    }
                }
            }
        }
        return problems
    }

    // MARK: - -selftest emojipaste

    /// Ein per ⌘V eingefügtes Emoji mit Variantenselektor (⏸️ = U+23F8 U+FE0F)
    /// muss SOFORT als Farb-Emoji ausgelegt werden. Daniel-Befund 2026-07-27:
    /// direkt nach dem Einfügen erschien die schmale Textform (⏸), und erst
    /// ein Tab-Wechsel hin und zurück zeigte das richtige Symbol. Der Test
    /// prüft deshalb nicht den Speicherinhalt (der war immer korrekt), sondern
    /// die tatsächlich getypesetteten Glyphen der Zeile.
    private static func runEmojiPasteTest() {
        testLabel = "emojipaste"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks() else {
            finish(false, "Workspace oder Hauptfenster fehlt")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fastra-emojipaste-\(UUID().uuidString)", isDirectory: true
            )
        // Mit integrierter Vorschau prüfen — genau Daniels Arbeitsaufbau.
        workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
        window.setContentSize(NSSize(width: 1100, height: 800))
        let tmp = directory.appendingPathComponent("paste.md")
        // Lange Zeile: Bei aktivem Umbruch verschiebt jedes eingefügte Emoji
        // die Umbruchkante — genau die Konstellation, in der ein Cluster
        // zwischen zwei Umbruchfragmente geraten kann.
        let longLine = "Hier folgt das Symbol: "
            + String(repeating: "wort ", count: 40)
        let text = "Erste Zeile\n\(longLine)\nDritte Zeile\n"
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: tmp)
        }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: directory)
            guard ok else { finish(false, "Fixture lädt nicht") }
            if !ws.softWrapEnabled { ws.toggleSoftWrap() }
            waitForEditor(workspace: ws, window: window) { root, textView in
                guard textView.string == text else {
                    finish(false, "Editor zeigt den Fixture-Text nicht")
                }
                let start = (text as NSString).range(of: "Symbol: ").upperBound
                // Sweep über die zweite Zeile: Das Emoji wird nacheinander an
                // wachsenden Positionen eingefügt. Jedes bereits eingefügte
                // Emoji verschiebt die Umbruchkanten weiter — so wandert die
                // Kante durch die Einfügestellen.
                pasteEmojiStep(textView: textView, location: start, step: 0)
            }
        }
    }

    /// Ein Sweep-Schritt: Emoji per echtem Paste einfügen, auslegen lassen,
    /// Darstellung prüfen, dann weiter.
    private static func pasteEmojiStep(textView: TextView, location: Int, step: Int) {
        let maximumSteps = 12
        guard location <= (textView.string as NSString).length else {
            finish(false, "Einfügeposition liegt hinter dem Text")
        }
        textView.selectionManager.setSelectedRange(NSRange(location: location, length: 0))
        // Echter Paste-Weg über das Pasteboard; der vorherige Inhalt wird
        // danach wiederhergestellt.
        let pasteboard = NSPasteboard.general
        let backup = (pasteboard.types ?? []).compactMap { type in
            pasteboard.data(forType: type).map { (type, $0) }
        }
        pasteboard.clearContents()
        pasteboard.setString("\u{23F8}\u{FE0F}", forType: .string)
        textView.paste(textView)
        pasteboard.clearContents()
        if !backup.isEmpty {
            pasteboard.declareTypes(backup.map(\.0), owner: nil)
            for (type, data) in backup { pasteboard.setData(data, forType: type) }
        }

        // Highlighter und Auslegung einen Moment arbeiten lassen — genau in
        // diesem Fenster trat die falsche Darstellung auf.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let ns = textView.string as NSString
            let stored = NSRange(location: location, length: 2)
            guard stored.upperBound <= ns.length,
                  ns.substring(with: stored) == "\u{23F8}\u{FE0F}" else {
                finish(false, "Emoji-Sequenz U+23F8 U+FE0F steht nach dem Einfügen "
                    + "nicht an Position \(location) — Variantenselektor verloren")
            }
            textView.layoutManager.layoutLines()
            var problems = emojiPresentationProblems(textView: textView, range: stored)
            // Zusätzlich die tatsächlich gezeichneten Pixel: Ein Farb-Emoji ist
            // bunt, die schmale Textform einfarbig. Nur so fällt auch ein
            // Fehler auf, der erst beim Zeichnen entsteht.
            if problems.isEmpty, let colorProblem = emojiDrawingIsColorless(
                textView: textView, range: stored
            ) {
                problems.append(colorProblem)
            }
            guard problems.isEmpty else {
                finish(false, "Emoji an Position \(location) (Schritt \(step)) falsch "
                    + "ausgelegt: " + problems.joined(separator: "; "))
            }
            if step >= maximumSteps {
                checkEmojiInPreview(textView: textView, stepCount: maximumSteps + 1)
                return
            }
            // Nächste Stelle ein Stück weiter rechts in derselben Zeile.
            pasteEmojiStep(textView: textView, location: location + 9, step: step + 1)
        }
    }

    /// Rendert den Bereich des Emojis und meldet, wenn dort kein farbiges Pixel
    /// liegt. `nil` heißt „bunt genug" (oder nicht prüfbar).
    private static func emojiDrawingIsColorless(
        textView: TextView, range: NSRange
    ) -> String? {
        guard let rect = textView.layoutManager.rectForOffset(range.location) else {
            return nil
        }
        // Etwas Luft um die Glyphzelle, damit das Emoji sicher drin liegt.
        let area = rect.insetBy(dx: -2, dy: -2)
        guard area.width > 1, area.height > 1,
              let bitmap = textView.bitmapImageRepForCachingDisplay(in: area) else {
            return nil
        }
        textView.cacheDisplay(in: area, to: bitmap)
        var sawColor = false
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 1) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 1) {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.sRGB) else { continue }
                let red = color.redComponent, green = color.greenComponent
                let blue = color.blueComponent
                let spread = max(red, green, blue) - min(red, green, blue)
                // Grautöne (Text, Hintergrund) haben kaum Farbabstand.
                if spread > 0.15 && color.alphaComponent > 0.2 { sawColor = true }
            }
        }
        return sawColor ? nil : "gezeichneter Bereich \(area.integral) ist einfarbig — "
            + "es erscheint die schmale Textform statt des Farb-Emojis"
    }

    /// Zweiter Teil des Tests: Die integrierte Markdown-Vorschau aktualisiert
    /// sich live über `document.body.innerHTML` statt neu zu laden. Auch dieser
    /// Weg muss den Variantenselektor behalten — sonst zeigte die Vorschau die
    /// schmale Textform, bis ein Tab-Wechsel sie neu aufbaut.
    private static func checkEmojiInPreview(textView: TextView, stepCount: Int) {
        guard let window = mainWindowForAXChecks(),
              let root = window.contentView,
              let webView = markdownWebView(in: root) else {
            finish(true, "Eingefügtes ⏸️ wird an \(stepCount) Stellen (auch an "
                + "Umbruchkanten) sofort als ein Farb-Emoji-Glyph ausgelegt "
                + "(Vorschau nicht offen, deshalb ungeprüft)")
        }
        // Der Vorschau Zeit für das Live-Update lassen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            webView.evaluateJavaScript("document.body.innerText") { value, error in
                guard let shown = value as? String else {
                    finish(false, "Vorschau-Text nicht lesbar: "
                        + (error?.localizedDescription ?? "kein Wert"))
                }
                // Über die Skalare zählen: Swifts String-Suche vergleicht
                // Graphem-Cluster, ein nacktes U+23F8 würde in "⏸️" gar nicht
                // gefunden — genau der Unterschied, um den es hier geht.
                let scalars = Array(shown.unicodeScalars)
                var bare = 0
                var full = 0
                for (index, scalar) in scalars.enumerated() where scalar.value == 0x23F8 {
                    bare += 1
                    if index + 1 < scalars.count, scalars[index + 1].value == 0xFE0F {
                        full += 1
                    }
                }
                if bare == 0 {
                    finish(false, "Vorschau zeigt das eingefügte Symbol gar nicht")
                } else if full < bare {
                    finish(false, "Vorschau verliert den Variantenselektor: "
                        + "\(bare) Basiszeichen, davon nur \(full) mit U+FE0F")
                } else {
                    finish(true, "Eingefügtes ⏸️ bleibt in Editor (\(stepCount) Stellen, "
                        + "auch an Umbruchkanten) und in der Live-Vorschau (\(full)×) "
                        + "vollständig")
                }
            }
        }
    }

    /// Meldet, wenn die Emoji-Sequenz nicht als EIN Glyph aus einer Emoji-
    /// Schrift gesetzt wird. Genau daran unterscheidet sich die schmale
    /// Textform (zwei Runs bzw. Monospace-Schrift) vom Farb-Emoji.
    private static func emojiPresentationProblems(
        textView: TextView, range: NSRange
    ) -> [String] {
        guard let line = textView.layoutManager.textLineForOffset(range.location) else {
            return ["Zeile zur Emoji-Position nicht auffindbar"]
        }
        var problems: [String] = []
        var covered = false
        for fragment in line.data.lineFragments {
            for content in fragment.data.contents {
                guard case .text(let ctLine) = content.data else { continue }
                // CTLine und CTRun zählen beide relativ zum Zeilen-Text (der
                // Typesetter wird pro logischer Zeile erzeugt) — deshalb nur
                // den Zeilenanfang addieren, nicht zusätzlich den Fragment-
                // Anfang.
                let lineStart = line.range.location
                for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? [] {
                    let runRange = CTRunGetStringRange(run)
                    let absolute = NSRange(
                        location: lineStart + runRange.location,
                        length: runRange.length
                    )
                    guard absolute.intersection(range) != nil else { continue }
                    covered = true
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    var fontName = "—"
                    if let raw = attributes[kCTFontAttributeName as String] {
                        fontName = CTFontCopyPostScriptName(raw as! CTFont) as String
                    }
                    let glyphs = CTRunGetGlyphCount(run)
                    if !fontName.contains("Emoji") {
                        problems.append(
                            "Run \(absolute) nutzt \(fontName) statt einer Emoji-Schrift"
                        )
                    } else if absolute.length == range.length && glyphs != 1 {
                        problems.append(
                            "Run \(absolute) liefert \(glyphs) Glyphen statt einem"
                        )
                    }
                }
            }
        }
        if !covered {
            problems.append("kein Glyph-Run deckt die Emoji-Position ab")
        }
        return problems
    }

    // MARK: - -selftest emojipreview

    /// Hält die gemessene Grenze zwischen Editor und Vorschau fest.
    ///
    /// Daniel-Befund 2026-07-27: Ein Sprechskript enthielt 61-mal das nackte
    /// `⏸` (U+23F8 OHNE Variantenselektor, so in der Datei und über die ganze
    /// Git-Historie). Der Editor zeigt dafür ein Farb-Emoji, weil CoreText das
    /// Zeichen in keiner Textschrift findet und auf Apple Color Emoji
    /// zurückfällt. WebKit entscheidet die Präsentation VOR der Schriftwahl und
    /// zeigt darum die Textform — wie Browser, GitHub und Keynote es auch tun.
    /// Fastra wandelt dabei nichts um; erst der Variantenselektor macht aus dem
    /// Zeichen überall ein Emoji.
    ///
    /// Der Test fotografiert vier Fälle in der WebView (nackt/vollständig,
    /// Inline-Code/Fließtext) und prüft die Farbe der Pixel: Eine
    /// Emoji-Schrift in der CSS-Kaskade ändert daran nachweislich nichts, und
    /// ein global erzwungenes `font-variant-emoji` würde auch Pfeile und
    /// Häkchen kippen. Beide Abweichungen schlagen hier an.
    private static func runEmojiPreviewTest() {
        testLabel = "emojipreview"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks() else {
            finish(false, "Workspace oder Hauptfenster fehlt")
        }
        workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
        window.setContentSize(NSSize(width: 1100, height: 800))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fastra-emojipreview-\(UUID().uuidString)", isDirectory: true
            )
        let tmp = directory.appendingPathComponent("preview.md")
        // Erste Zeile: nacktes Basiszeichen als Inline-Code — genau die Form aus
        // Daniels Skript. Zweite Zeile: vollständige Emoji-Sequenz als
        // Kontrollfall.
        let text = "Code nackt `\u{23F8}` Ende\n\nCode voll `\u{23F8}\u{FE0F}` Ende\n\n"
            + "Fließtext nackt **\u{23F8}** Ende\n\nFließtext voll *\u{23F8}\u{FE0F}* Ende\n"
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: tmp)
        }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: directory)
            guard ok else { finish(false, "Fixture lädt nicht") }
            pollEmojiPreviewReady(window: window, tick: 0)
        }
    }

    private static func pollEmojiPreviewReady(window: NSWindow, tick: Int) {
        if let root = window.contentView,
           let webView = markdownWebView(in: root) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                measureEmojiPreviewColors(
                    webView: webView,
                    pending: [
                        ("code-nackt", "document.querySelectorAll('code')[0]"),
                        ("code-voll", "document.querySelectorAll('code')[1]"),
                        ("text-nackt", "document.querySelector('strong')"),
                        ("text-voll", "document.querySelector('em')")
                    ],
                    results: []
                )
            }
            return
        }
        if tick >= 100 { finish(false, "Vorschau nicht binnen 10 s bereit") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollEmojiPreviewReady(window: window, tick: tick + 1)
        }
    }

    /// Fotografiert je Fall das Element und meldet, ob es farbig ist.
    private static func measureEmojiPreviewColors(
        webView: WKWebView, pending: [(String, String)],
        results: [(label: String, coloredPixels: Int)]
    ) {
        guard let (label, expression) = pending.first else {
            let details = results.map {
                "\($0.label): \($0.coloredPixels > 0 ? "farbig (\($0.coloredPixels) Pixel)" : "einfarbig")"
            }.joined(separator: "; ")
            let full = results.filter { $0.label.hasSuffix("voll") }
            let bare = results.filter { $0.label.hasSuffix("nackt") }
            // Mit Variantenselektor MUSS die Vorschau farbig zeichnen.
            if full.contains(where: { $0.coloredPixels == 0 }) {
                finish(false, "⏸️ mit U+FE0F wird in der Vorschau nicht farbig "
                    + "gezeichnet: \(details)")
            } else if bare.contains(where: { $0.coloredPixels > 0 }) {
                // Gegenrichtung: Würde die Vorschau auch das nackte Zeichen
                // farbig zeichnen (etwa durch ein global gesetztes
                // `font-variant-emoji: emoji`), kippten auch Pfeile und Häkchen
                // in Emoji-Form. Das wäre eine Produktentscheidung, keine
                // Nebenwirkung — deshalb schlägt der Wächter hier bewusst an.
                finish(false, "Vorschau zeichnet auch das NACKTE ⏸ farbig — "
                    + "Emoji-Präsentation wurde erzwungen: \(details)")
            } else {
                finish(true, "Vorschau folgt Unicode: ⏸️ (mit U+FE0F) farbig, "
                    + "nacktes ⏸ als Textform — anders als der Editor daneben, "
                    + "der über CoreTexts Schriftrückfall ein Farb-Emoji zeigt: "
                    + "\(details)")
            }
        }
        let script = """
        (function(){
          const el = \(expression);
          if (!el) return null;
          const r = el.getBoundingClientRect();
          return [r.left + window.scrollX, r.top + window.scrollY, r.width, r.height];
        })()
        """
        webView.evaluateJavaScript(script) { value, _ in
            guard let numbers = value as? [Double], numbers.count == 4 else {
                finish(false, "Element \(label) in der Vorschau nicht gefunden")
            }
            let rect = CGRect(x: numbers[0], y: numbers[1],
                              width: max(numbers[2], 1), height: max(numbers[3], 1))
            let configuration = WKSnapshotConfiguration()
            configuration.rect = rect
            webView.takeSnapshot(with: configuration) { image, error in
                guard let image, let bitmap = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else {
                    finish(false, "Snapshot für \(label) fehlgeschlagen: "
                        + (error?.localizedDescription ?? "kein Bild"))
                }
                var colored = 0
                for x in 0..<bitmap.pixelsWide {
                    for y in 0..<bitmap.pixelsHigh {
                        guard let color = bitmap.colorAt(x: x, y: y)?
                            .usingColorSpace(.sRGB) else { continue }
                        let spread = max(color.redComponent, color.greenComponent,
                                         color.blueComponent)
                            - min(color.redComponent, color.greenComponent,
                                  color.blueComponent)
                        if spread > 0.15 { colored += 1 }
                    }
                }
                measureEmojiPreviewColors(
                    webView: webView,
                    pending: Array(pending.dropFirst()),
                    results: results + [(label: label, coloredPixels: colored)]
                )
            }
        }
    }

    // MARK: - -selftest tabscroll

    /// Der sichtbare Ausschnitt eines Tabs muss den Tab-Wechsel überleben.
    /// Daniel-Befund 2026-07-27: Nach Wechsel und Rückwechsel stand die
    /// Cursorzeile plötzlich in der obersten Bildschirmzeile, weil der neu
    /// erzeugte Editor am Dateianfang startet und CESE nur die Einfügemarke
    /// sichtbar macht.
    private static func runTabScrollTest() {
        testLabel = "tabscroll"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks() else {
            finish(false, "Workspace oder Hauptfenster fehlt")
        }
        window.setContentSize(NSSize(width: 1000, height: 600))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fastra-tabscroll-\(UUID().uuidString)", isDirectory: true
            )
        let longFile = directory.appendingPathComponent("lang.txt")
        let shortFile = directory.appendingPathComponent("kurz.txt")
        let longText = (1...600).map { "Zeile \($0) mit etwas Text" }
            .joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Data(longText.utf8).write(to: longFile)
            try Data("Kurze Datei\n".utf8).write(to: shortFile)
        }
        catch { finish(false, "Temp-Dateien nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: longFile) { ok in
            guard ok else {
                try? FileManager.default.removeItem(at: directory)
                finish(false, "lange Datei lädt nicht")
            }
            guard let longTabID = ws.activeTabID else {
                try? FileManager.default.removeItem(at: directory)
                finish(false, "kein aktiver Tab für die lange Datei")
            }
            waitForEditor(workspace: ws, window: window) { root, textView in
                // Cursor in die Mitte des Dokuments und dorthin scrollen.
                let middle = (textView.string as NSString).range(of: "Zeile 300 ")
                textView.selectionManager.setSelectedRange(
                    NSRange(location: middle.location, length: 0)
                )
                textView.scrollToRange(NSRange(location: middle.location, length: 0))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let clipView = textView.enclosingScrollView?.contentView else {
                        try? FileManager.default.removeItem(at: directory)
                        finish(false, "keine ScrollView am Editor")
                    }
                    let expected = clipView.bounds.origin.y
                    guard expected > 100 else {
                        try? FileManager.default.removeItem(at: directory)
                        finish(false, "Ausgangsposition nicht gescrollt (y=\(expected))")
                    }
                    // Zweite Datei öffnen (wechselt den Tab) …
                    ws.loadFile(at: shortFile) { ok2 in
                        try? FileManager.default.removeItem(at: directory)
                        guard ok2 else { finish(false, "kurze Datei lädt nicht") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            // … und zurückwechseln.
                            ws.selectTab(id: longTabID)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                guard let tv = editorTextView(in: root) as? TextView,
                                      let clip = tv.enclosingScrollView?.contentView else {
                                    finish(false, "Editor nach dem Rückwechsel nicht auffindbar")
                                }
                                let actual = clip.bounds.origin.y
                                let delta = abs(actual - expected)
                                if delta <= 4 {
                                    finish(true, "Ausschnitt überlebt den Tab-Wechsel "
                                        + "(y=\(Int(actual)) statt Sprung auf die Cursorzeile)")
                                } else {
                                    finish(false, "Scrollposition geändert: erwartet y≈"
                                        + "\(Int(expected)), tatsächlich \(Int(actual))")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - -selftest emojishot

    /// Diagnose: öffnet die per `FASTRA_EMOJI_FIXTURE` angegebene (oder die
    /// neutrale) Emoji-Datei im Markdown-Split, scrollt ans Dateiende und
    /// gibt die Fenster-Nummer fürs Capture aus.
    private static func runEmojiShot() {
        testLabel = "emojishot"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks() else {
            finish(false, "Workspace oder Hauptfenster fehlt")
        }
        ws.sidebarWidth = 216.13671875
        ws.markdownPreviewWidth = 332.3515625
        workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
        window.setContentSize(NSSize(width: 1100, height: 800))
        let text: String
        if let path = ProcessInfo.processInfo.environment["FASTRA_EMOJI_FIXTURE"],
           let fixture = try? String(contentsOfFile: path, encoding: .utf8) {
            text = fixture
        } else {
            text = emojiSplitFixtureContent()
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fastra-emojishot-\(UUID().uuidString)", isDirectory: true
            )
        let tmp = directory.appendingPathComponent("emoji.md")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: tmp)
        }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }
        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: directory)
            guard ok else { finish(false, "Fixture lädt nicht") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let root = window.contentView,
                      let textView = editorTextView(in: root) as? TextView else {
                    finish(false, "Editor fehlt")
                }
                let ns = textView.string as NSString
                textView.scrollToRange(NSRange(location: ns.length, length: 0))
                textView.layoutManager.layoutLines()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    dumpMainWindowThenExit(prefix: "EMOJISHOT-WINDOW")
                }
            }
        }
    }

    // MARK: - -selftest comment4d

    /// Ein Edit innerhalb eines langen `/* … */`-Blocks darf die
    /// Kommentarfarbe hinter der Editposition nicht löschen. CESE färbt nach
    /// einem Edit chunkweise ab der Editposition neu; der 4D-Provider muss
    /// seine Token deshalb auf den angefragten Chunk zuschneiden.
    private static func runFourDCommentEditTest() {
        testLabel = "comment4d"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks(),
              let root = window.contentView else {
            finish(false, "Workspace oder Hauptfenster fehlt")
        }
        var lines = ["// Kopfzeile", "/* Modernisierung"]
        lines.append("- Ankerzeile für den Edit xx")
        lines.append(contentsOf: (1...24).map {
            "- Punkt \($0): " + String(repeating: "x", count: 40 + $0 % 7)
        })
        lines.append("- Schlusszeile QQZWEIQQ")
        lines.append("*/")
        lines.append("ALERT(\"ok\")")
        let code = lines.joined(separator: "\n")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fastra-comment4d-\(UUID().uuidString)", isDirectory: true
            )
        let tmp = directory.appendingPathComponent("Kommentar.4dm")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Data(code.utf8).write(to: tmp)
        }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }
        // Fester Hellmodus wie im highlight4d-Test: erwartete Farben sind
        // Fixture-Werte, kein Systemzustand.
        NSApp.appearance = NSAppearance(named: .aqua)
        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: directory)
            guard ok else { finish(false, "loadFile (.4dm) schlug fehl") }
            pollFourDCommentInitialColor(root: root, code: code, tick: 0)
        }
    }

    private static func pollFourDCommentInitialColor(
        root: NSView, code: String, tick: Int
    ) {
        let comment = fourDExpectedColors(dark: false)[7]
        if let textView = editorTextView(in: root) as? TextView,
           textView.string == code {
            let ns = code as NSString
            let closing = ns.range(of: "QQZWEIQQ")
            if storageSubstringHasColor("QQZWEIQQ", in: root,
                                        r: comment.1, g: comment.2, b: comment.3) {
                // Edit am Ende der Ankerzeile mitten im Kommentarblock.
                let anchor = ns.range(of: "- Ankerzeile für den Edit xx")
                textView.selectionManager.setSelectedRange(
                    NSRange(location: anchor.max, length: 0)
                )
                textView.insertText(
                    "yy", replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    pollFourDCommentColorAfterEdit(root: root, tick: 0)
                }
                return
            }

            // CESE hebt abschnittsweise den sichtbaren Bereich hervor. Die
            // geprüfte Schlusszeile deshalb zuerst wirklich sichtbar machen;
            // eine bestimmte gespeicherte Fensterhöhe darf den Test nicht
            // entscheiden. Nach dem Edit weiter oben muss ihre Farbe bleiben.
            textView.scrollToRange(closing)
            textView.layoutManager.layoutLines()
        }
        if tick >= 60 {
            NSApp.appearance = nil
            finish(false, "Kommentarfarbe erscheint initial nicht binnen 15 s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollFourDCommentInitialColor(root: root, code: code, tick: tick + 1)
        }
    }

    private static func pollFourDCommentColorAfterEdit(root: NSView, tick: Int) {
        let comment = fourDExpectedColors(dark: false)[7]
        let commandColor = fourDExpectedColors(dark: false)[0]
        let closingKept = storageSubstringHasColor(
            "QQZWEIQQ", in: root, r: comment.1, g: comment.2, b: comment.3
        )
        let commandKept = storageSubstringHasColor(
            "ALERT", in: root,
            r: commandColor.1, g: commandColor.2, b: commandColor.3
        )
        if closingKept && commandKept {
            NSApp.appearance = nil
            finish(true, "Kommentarfarbe bleibt nach Edit im Block bis zum "
                + "Blockende erhalten")
        }
        if tick >= 40 {
            NSApp.appearance = nil
            finish(false, "nach dem Edit im Kommentarblock: Schlusszeile "
                + "kommentarfarben=\(closingKept), ALERT befehlsfarben=\(commandKept)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollFourDCommentColorAfterEdit(root: root, tick: tick + 1)
        }
    }

    // MARK: - -selftest sighelp4d

    /// End-to-End-Prüfung der 4D-Parameterhilfe: Cursor in die Klammern eines
    /// Projektmethoden-Aufrufs setzen → Panel mit Signatur und Kommentarkopf
    /// erscheint; Cursor an den Zeilenanfang → Panel verschwindet.
    private static func runFourDSignatureHelpTest() {
        testLabel = "sighelp4d"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks(),
              let root = window.contentView else {
            finish(false, "Workspace oder Hauptfenster fehlt")
        }
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-sighelp4d-\(UUID().uuidString)")
        let methods = projectRoot.appendingPathComponent(
            "Project/Sources/Methods", isDirectory: true
        )
        let target = methods.appendingPathComponent("Begruessung.4dm")
        let outer = methods.appendingPathComponent("Verpacke.4dm")
        let caller = methods.appendingPathComponent("Aufrufer.4dm")
        let targetSource = """
        //%attributes = {}
        // Baut die Grußformel.
        // Zweite Kopfzeile mit Details.
        #DECLARE($name_t : Text; $anzahl_i : Integer)->$gruss_t : Text
        $gruss_t:="Hallo "+$name_t
        """
        let outerSource = """
        //%attributes = {}
        // Verpackt einen Text.
        #DECLARE($inhalt_t : Text; $breite_i : Integer)->$paket_t : Text
        $paket_t:="["+$inhalt_t+"]"
        """
        // Geteilte Methode einer entpackten Komponente — sie muss in der
        // Parameterhilfe genauso funktionieren wie eine Projektmethode.
        let componentMethods = projectRoot.appendingPathComponent(
            "Components/Werkzeug.4dbase/Project/Sources/Methods", isDirectory: true
        )
        let componentTarget = componentMethods.appendingPathComponent("Werkzeug_Miss.4dm")
        let componentSource = """
        //%attributes = {"shared":true}
        // Misst einen Text.
        #DECLARE($text_t : Text)->$laenge_i : Integer
        $laenge_i:=Length($text_t)
        """
        // Zeile 2: einfacher Aufruf. Zeile 3: verschachtelter Aufruf — die
        // innere Methode ist Argument der äußeren. Zeile 4: Komponente.
        let callerSource = """
        // Aufrufer
        Begruessung("Welt";2)
        Verpacke(Begruessung("Du";1);80)
        Werkzeug_Miss("Probe")
        """
        do {
            try FileManager.default.createDirectory(
                at: methods, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: componentMethods, withIntermediateDirectories: true
            )
            try targetSource.write(to: target, atomically: true, encoding: .utf8)
            try outerSource.write(to: outer, atomically: true, encoding: .utf8)
            try componentSource.write(to: componentTarget, atomically: true,
                                      encoding: .utf8)
            try callerSource.write(to: caller, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: projectRoot)
            finish(false, "4D-Fixture nicht schreibbar: \(error.localizedDescription)")
        }
        ws.openProject(at: projectRoot)
        pollFourDSignatureIndexReady(
            ws: ws, root: root, window: window,
            projectRoot: projectRoot, caller: caller, tick: 0
        )
    }

    private static func pollFourDSignatureIndexReady(
        ws: Workspace, root: NSView, window: NSWindow,
        projectRoot: URL, caller: URL, tick: Int
    ) {
        guard ws.fourDProjectMethodNames.contains("begruessung"),
              ws.fourDProjectMethodNames.contains("verpacke"),
              ws.fourDComponentMethods["werkzeug_miss"] != nil else {
            if tick >= 40 {
                ws.closeProject()
                try? FileManager.default.removeItem(at: projectRoot)
                finish(false, "Projekt-/Komponentenindex ist nach 10 s unvollständig")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                pollFourDSignatureIndexReady(
                    ws: ws, root: root, window: window,
                    projectRoot: projectRoot, caller: caller, tick: tick + 1
                )
            }
            return
        }
        ws.loadFile(at: caller) { ok in
            guard ok else {
                ws.closeProject()
                try? FileManager.default.removeItem(at: projectRoot)
                finish(false, "Aufrufer.4dm lädt nicht")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let textView = editorTextView(in: root) as? TextView else {
                    ws.closeProject()
                    try? FileManager.default.removeItem(at: projectRoot)
                    finish(false, "Editor-TextView fehlt")
                }
                window.makeFirstResponder(textView)
                // Cursor hinter das erste Argument: innerhalb der Klammern.
                let ns = textView.string as NSString
                let anchor = ns.range(of: "\"Welt\"")
                guard anchor.location != NSNotFound else {
                    ws.closeProject()
                    try? FileManager.default.removeItem(at: projectRoot)
                    finish(false, "Aufrufzeile fehlt im Editor")
                }
                textView.selectionManager.setSelectedRange(
                    NSRange(location: anchor.max, length: 0)
                )
                pollFourDSignaturePanelVisible(
                    ws: ws, window: window, textView: textView,
                    projectRoot: projectRoot, tick: 0
                )
            }
        }
    }

    private static func fourDSignaturePanelText(window: NSWindow) -> String? {
        for child in window.childWindows ?? [] {
            guard child.styleMask.contains(.borderless),
                  let content = child.contentView else { continue }
            for view in content.subviews {
                if let label = view as? NSTextField {
                    return label.attributedStringValue.string
                }
            }
        }
        return nil
    }

    private static func pollFourDSignaturePanelVisible(
        ws: Workspace, window: NSWindow, textView: TextView,
        projectRoot: URL, tick: Int
    ) {
        if let text = fourDSignaturePanelText(window: window),
           text.contains("Begruessung"),
           text.contains("$name_t : Text"),
           text.contains("$anzahl_i : Integer"),
           text.contains("$gruss_t : Text"),
           text.contains("Baut die Grußformel."),
           text.contains("Zweite Kopfzeile mit Details.") {
            // Verschachtelter Aufruf: Cursor in die Klammern der INNEREN
            // Methode, die selbst Argument der äußeren ist.
            let ns = textView.string as NSString
            let inner = ns.range(of: "\"Du\"")
            guard inner.location != NSNotFound else {
                ws.closeProject()
                try? FileManager.default.removeItem(at: projectRoot)
                finish(false, "verschachtelte Aufrufzeile fehlt")
            }
            textView.selectionManager.setSelectedRange(
                NSRange(location: inner.max, length: 0)
            )
            pollFourDSignatureNestedInner(
                ws: ws, window: window, textView: textView,
                projectRoot: projectRoot, tick: 0
            )
            return
        }
        if tick >= 40 {
            let seen = fourDSignaturePanelText(window: window) ?? "(kein Panel)"
            ws.closeProject()
            try? FileManager.default.removeItem(at: projectRoot)
            finish(false, "Parameterhilfe erscheint nicht korrekt binnen 10 s; "
                + "gesehen: \(seen.prefix(300))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollFourDSignaturePanelVisible(
                ws: ws, window: window, textView: textView,
                projectRoot: projectRoot, tick: tick + 1
            )
        }
    }

    /// Im verschachtelten Aufruf muss die INNERE Methode angezeigt werden.
    private static func pollFourDSignatureNestedInner(
        ws: Workspace, window: NSWindow, textView: TextView,
        projectRoot: URL, tick: Int
    ) {
        if let text = fourDSignaturePanelText(window: window),
           text.contains("Begruessung"),
           text.contains("$name_t : Text"),
           !text.contains("Verpacke") {
            // Cursor HINTER die innere schließende Klammer (vor `;80`):
            // jetzt gilt wieder der äußere Aufruf, aktiver Parameter 0.
            let ns = textView.string as NSString
            let closing = ns.range(of: "\"Du\";1)")
            guard closing.location != NSNotFound else {
                ws.closeProject()
                try? FileManager.default.removeItem(at: projectRoot)
                finish(false, "innere schließende Klammer fehlt")
            }
            textView.selectionManager.setSelectedRange(
                NSRange(location: closing.max, length: 0)
            )
            pollFourDSignatureNestedOuter(
                ws: ws, window: window, textView: textView,
                projectRoot: projectRoot, tick: 0
            )
            return
        }
        if tick >= 40 {
            let seen = fourDSignaturePanelText(window: window) ?? "(kein Panel)"
            ws.closeProject()
            try? FileManager.default.removeItem(at: projectRoot)
            finish(false, "verschachtelt: innere Methode erscheint nicht; "
                + "gesehen: \(seen.prefix(300))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollFourDSignatureNestedInner(
                ws: ws, window: window, textView: textView,
                projectRoot: projectRoot, tick: tick + 1
            )
        }
    }

    /// Hinter der inneren Klammer zeigt das Panel wieder die äußere Methode.
    private static func pollFourDSignatureNestedOuter(
        ws: Workspace, window: NSWindow, textView: TextView,
        projectRoot: URL, tick: Int
    ) {
        if let text = fourDSignaturePanelText(window: window),
           text.contains("Verpacke"),
           text.contains("$inhalt_t : Text"),
           text.contains("Verpackt einen Text."),
           !text.contains("$name_t") {
            // Cursor in den Aufruf der Komponentenmethode.
            let ns = textView.string as NSString
            let componentCall = ns.range(of: "\"Probe\"")
            guard componentCall.location != NSNotFound else {
                ws.closeProject()
                try? FileManager.default.removeItem(at: projectRoot)
                finish(false, "Komponenten-Aufrufzeile fehlt")
            }
            textView.selectionManager.setSelectedRange(
                NSRange(location: componentCall.max, length: 0)
            )
            pollFourDSignatureComponent(
                ws: ws, window: window, textView: textView,
                projectRoot: projectRoot, tick: 0
            )
            return
        }
        if tick >= 40 {
            let seen = fourDSignaturePanelText(window: window) ?? "(kein Panel)"
            ws.closeProject()
            try? FileManager.default.removeItem(at: projectRoot)
            finish(false, "verschachtelt: äußere Methode erscheint hinter der "
                + "inneren Klammer nicht; gesehen: \(seen.prefix(300))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollFourDSignatureNestedOuter(
                ws: ws, window: window, textView: textView,
                projectRoot: projectRoot, tick: tick + 1
            )
        }
    }

    /// Die geteilte Komponentenmethode zeigt Signatur und Kommentarkopf wie
    /// eine Projektmethode (Komponentenmethoden-Auftrag 2026-07-24).
    private static func pollFourDSignatureComponent(
        ws: Workspace, window: NSWindow, textView: TextView,
        projectRoot: URL, tick: Int
    ) {
        if let text = fourDSignaturePanelText(window: window),
           text.contains("Werkzeug_Miss"),
           text.contains("$text_t : Text"),
           text.contains("$laenge_i : Integer"),
           text.contains("Misst einen Text.") {
            // Cursor an den Zeilenanfang → Panel muss verschwinden.
            textView.selectionManager.setSelectedRange(
                NSRange(location: 0, length: 0)
            )
            pollFourDSignaturePanelGone(
                ws: ws, window: window, projectRoot: projectRoot, tick: 0
            )
            return
        }
        if tick >= 40 {
            let seen = fourDSignaturePanelText(window: window) ?? "(kein Panel)"
            ws.closeProject()
            try? FileManager.default.removeItem(at: projectRoot)
            finish(false, "Komponentenmethode erscheint nicht in der "
                + "Parameterhilfe; gesehen: \(seen.prefix(300))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollFourDSignatureComponent(
                ws: ws, window: window, textView: textView,
                projectRoot: projectRoot, tick: tick + 1
            )
        }
    }

    private static func pollFourDSignaturePanelGone(
        ws: Workspace, window: NSWindow, projectRoot: URL, tick: Int
    ) {
        if fourDSignaturePanelText(window: window) == nil {
            ws.closeProject()
            try? FileManager.default.removeItem(at: projectRoot)
            finish(true, "Parameterhilfe zeigt Signatur samt Kommentarkopf, "
                + "wechselt verschachtelt zwischen innerer und äußerer "
                + "Methode, kennt geteilte Komponentenmethoden und "
                + "verschwindet außerhalb der Klammern")
        }
        if tick >= 40 {
            ws.closeProject()
            try? FileManager.default.removeItem(at: projectRoot)
            finish(false, "Parameterhilfe bleibt außerhalb der Klammern sichtbar")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollFourDSignaturePanelGone(
                ws: ws, window: window, projectRoot: projectRoot, tick: tick + 1
            )
        }
    }

    // MARK: - -selftest sighelpshot

    /// Diagnose: baut dieselbe Szene wie `sighelp4d` auf, lässt das Panel
    /// stehen und gibt Fenster-Nummern von Hauptfenster und Panel fürs
    /// Capture aus.
    private static func runFourDSignatureHelpShot() {
        testLabel = "sighelpshot"
        guard let ws = Workspace.shared,
              let window = mainWindowForAXChecks(),
              let root = window.contentView else {
            finish(false, "Workspace oder Hauptfenster fehlt")
        }
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-sighelpshot-\(UUID().uuidString)")
        let methods = projectRoot.appendingPathComponent(
            "Project/Sources/Methods", isDirectory: true
        )
        let target = methods.appendingPathComponent("Begruessung.4dm")
        let caller = methods.appendingPathComponent("Aufrufer.4dm")
        let targetSource = """
        //%attributes = {}
        // Baut die Grußformel für die Startseite.
        // Ruft niemand nachts an, bleibt der Gruß freundlich.
        #DECLARE($name_t : Text; $anzahl_i : Integer)->$gruss_t : Text
        $gruss_t:="Hallo "+$name_t
        """
        let callerSource = """
        // Aufrufer
        Begruessung("Welt";2)
        """
        do {
            try FileManager.default.createDirectory(
                at: methods, withIntermediateDirectories: true
            )
            try targetSource.write(to: target, atomically: true, encoding: .utf8)
            try callerSource.write(to: caller, atomically: true, encoding: .utf8)
        } catch {
            finish(false, "Fixture nicht schreibbar: \(error.localizedDescription)")
        }
        ws.openProject(at: projectRoot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            ws.loadFile(at: caller) { ok in
                guard ok else { finish(false, "Aufrufer lädt nicht") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard let textView = editorTextView(in: root) as? TextView
                    else { finish(false, "TextView fehlt") }
                    window.makeFirstResponder(textView)
                    let ns = textView.string as NSString
                    let anchor = ns.range(of: "\"Welt\"")
                    textView.selectionManager.setSelectedRange(
                        NSRange(location: anchor.max, length: 0)
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        window.orderFront(nil)
                        let panelNumber = (window.childWindows ?? [])
                            .first { $0.styleMask.contains(.borderless) }?
                            .windowNumber ?? -1
                        let line = "SIGHELPSHOT-WINDOW \(window.windowNumber) "
                            + "PANEL \(panelNumber)\n"
                        FileHandle.standardError.write(Data(line.utf8))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                            exit(0)
                        }
                    }
                }
            }
        }
    }

    // MARK: - -selftest replaceall

    /// Sichert die Regression aus dem Präsentations-Build (2026-06-24):
    /// „Alle ersetzen" ließ den SICHTBAREN Editor-Text unverändert, obwohl das
    /// Modell korrekt ersetzt wurde — CodeEditSourceEditor übernimmt
    /// Binding-Änderungen nicht von selbst (Text fließt nur TextView → Binding).
    /// `applyAllInActiveBuffer` zählt deshalb `editorReloadNonce` hoch und
    /// erzwingt eine Editor-Neuerzeugung. Dieser Test liest den ECHTEN
    /// Editor-`.string` zurück und belegt, dass er nach dem Replace den
    /// ersetzten Text zeigt — nicht mehr den Vor-Replace-Text.
    ///
    /// Genau die Bug-Klasse, die reine Unit-Tests NICHT fangen: das Modell war
    /// korrekt, nur die View hing hinterher.
    private static func runReplaceAllTest() {
        testLabel = "replaceall"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)

        // Exakt der Präsentations-Demo-Inhalt („Nachname, Vorname" je Zeile),
        // 9 Treffer für `(\w+), (\w+)` (Leerzeile + Listen zählen nicht doppelt).
        let content = ["Mustermann, Max", "Mustermann, Erika", "Lovelace, Ada",
                       "Turing, Alan", "Hopper, Grace", "Karpathy, Andrej", "",
                       "ring, The", "Matrix, The", "Empire Strikes Back, The"]
            .joined(separator: "\n")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-replaceall-\(UUID().uuidString).txt")
        do { try content.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            // SwiftUI/CESE Zeit geben, den Editor mit dem Inhalt zu erzeugen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let tvView = editorTextView(in: root), let tv = tvView as? TextView else {
                    finish(false, "Editor-TextView nicht erreichbar")
                }
                // Vorbedingung: Editor zeigt VOR dem Replace den Original-Text.
                guard (tv.string as NSString).contains("Mustermann, Max") else {
                    finish(false, "Editor zeigt vor dem Replace nicht den Original-Text "
                        + "(string-Anfang: \(String(tv.string.prefix(40))))")
                }
                ws.scope = .file
                ws.useRegex = true
                ws.caseSensitive = false
                ws.replacePattern = "$2 $1"
                ws.findPattern = #"(\w+), (\w+)"#
                pollReplaceAllReady(ws, root: root)
            }
        }
    }

    /// Wartet, bis die (async) Suche die 9 Demo-Treffer geliefert hat, ruft
    /// dann `applyAllInActiveBuffer()` (exakt der „Alle ersetzen"-Pfad) und
    /// pollt anschließend den echten Editor-Text.
    private static func pollReplaceAllReady(_ ws: Workspace, root: NSView, tick: Int = 0) {
        let maxTicks = 100   // ~3 s
        if !ws.bufferSearching && ws.bufferTotalMatches == 9 {
            ws.applyAllInActiveBuffer()
            // Modell-Soll: das, was die Engine produziert. Erst das Modell prüfen
            // (muss korrekt ersetzt sein), dann die View dagegen abgleichen.
            let expected = ws.activeTab?.content ?? ""
            guard expected.contains("Max Mustermann"),
                  !expected.contains("Mustermann, Max") else {
                finish(false, "Modell-Replace selbst falsch: content=\(String(expected.prefix(60)))")
            }
            pollReplaceAllVisible(ws, root: root, expected: expected)
            return
        }
        if tick >= maxTicks {
            finish(false, "(replaceall) Suche lieferte nicht 9 Treffer "
                + "(total=\(ws.bufferTotalMatches), searching=\(ws.bufferSearching), "
                + "error=\(ws.searchError ?? "nil"))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollReplaceAllReady(ws, root: root, tick: tick + 1)
        }
    }

    /// Pollt den ECHTEN Editor-`.string` (jedes Mal frisch aus der View-
    /// Hierarchie geholt, weil der Editor neu erzeugt wird), bis er den
    /// ersetzten Text zeigt. PASS, sobald „Max Mustermann" sichtbar ist und
    /// „Mustermann, Max" verschwunden — das ist die eigentliche Regression.
    private static func pollReplaceAllVisible(_ ws: Workspace, root: NSView,
                                              expected: String, tick: Int = 0) {
        let maxTicks = 100   // ~3 s
        if let tvView = editorTextView(in: root), let tv = tvView as? TextView {
            let shown = tv.string
            let displaysReplaced = shown.contains("Max Mustermann")
                && !shown.contains("Mustermann, Max")
            if shown == expected || displaysReplaced {
                finish(true, "Editor zeigt nach Alle-ersetzen den ersetzten Text "
                    + "(Max Mustermann sichtbar, 'Mustermann, Max' weg) — "
                    + "Neuerzeugung via editorReloadNonce greift"
                    + (shown == expected ? "; exakt == Modell-Inhalt" : ""))
            }
        }
        if tick >= maxTicks {
            let now = (editorTextView(in: root) as? TextView)?.string ?? "<kein Editor>"
            finish(false, "(replaceall) Editor zeigt nach dem Replace weiter den ALTEN Text — "
                + "Neuerzeugung wirkte nicht. string-Anfang: \(String(now.prefix(60)))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollReplaceAllVisible(ws, root: root, expected: expected, tick: tick + 1)
        }
    }

    // MARK: - -selftest pilldrop

    /// Belegt headless, dass das Ersetzen-Feld einen gedraggten Gruppen-String
    /// AUCH dann annimmt, wenn es bereits den Fokus hat (Daniel-Befund
    /// 2026-06-24: vorher musste man erst ein anderes Feld anklicken, sonst
    /// verpuffte der Drop). Echtes Maus-Dragging ist nicht automatisierbar —
    /// wir treiben stattdessen die Drag-Destination-Methoden des ÄUSSEREN
    /// `RegexFieldScrollView` nahe seinem unteren Rand mit einem
    /// `NSDraggingInfo`-Mock, der „$1" trägt. So deckt derselbe Test sowohl den
    /// Fokus-Bug als auch Daniels Befund vom 2026-07-10 ab, dass nur der obere
    /// Teil der sichtbaren Zeile zuverlässig als Drop-Ziel reagierte.
    private static func runPillDropTest() {
        testLabel = "pilldrop"
        guard let searchWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName == SearchWindow.frameAutosaveName
        }) else { finish(false, "Suchfenster nicht gefunden") }
        searchWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let root = searchWindow.contentView else {
                finish(false, "Suchfenster ohne contentView")
            }
            guard let replaceField = findReplaceField(in: root) else {
                finish(false, "Ersetzen-Feld (fastra.replaceField) nicht gefunden")
            }
            // Feld leeren + FOKUSSIEREN — genau die Bug-Bedingung (fokussiertes Feld).
            replaceField.string = ""
            guard searchWindow.makeFirstResponder(replaceField),
                  replaceField.window?.firstResponder === replaceField else {
                finish(false, "Ersetzen-Feld konnte nicht fokussiert werden (kein First Responder)")
            }
            guard let dropSurface = replaceField.enclosingScrollView
                    as? RegexFieldScrollView else {
                finish(false, "Ersetzen-Feld besitzt kein vollflächiges Drop-Ziel")
            }

            // NSDraggingInfo liefert Fensterkoordinaten. Wir zielen bewusst nur
            // einen Punkt oberhalb des unteren sichtbaren ScrollView-Rands.
            let lowerEdge = NSPoint(x: dropSurface.bounds.minX + 8,
                                    y: dropSurface.bounds.minY + 1)
            let windowPoint = dropSurface.convert(lowerEdge, to: nil)
            let mock = MockDraggingInfo(string: "$1", location: windowPoint)
            // 1) Annahme am unteren Rand: muss .copy liefern.
            let op = dropSurface.draggingEntered(mock)
            guard op.contains(.copy) else {
                finish(false, "(unterer Rand, fokussiert) draggingEntered lieferte "
                    + "rawValue=\(op.rawValue), erwartet .copy")
            }
            // 2) Drop ausführen: Feldinhalt muss danach $1 enthalten.
            let accepted = dropSurface.performDragOperation(mock)
            let shown = replaceField.string
            if accepted && shown.contains("$1") {
                finish(true, "Komplette Feldhöhe nimmt Pillen-Drop bei Fokus an: "
                    + "unterer Rand=.copy, performDrag fügte $1 ein (Inhalt: \(shown))")
            } else {
                finish(false, "(unterer Rand, fokussiert) performDragOperation=\(accepted), "
                    + "Feld-Inhalt \(shown) enthält kein $1")
            }
        }
    }

    /// Findet die `RegexFieldTextView` des Ersetzen-Feldes über ihren
    /// Accessibility-Identifier (in `RegexFieldView.makeNSView` gesetzt).
    private static func findReplaceField(in view: NSView) -> RegexFieldTextView? {
        if let tv = view as? RegexFieldTextView,
           tv.accessibilityIdentifier() == "fastra.replaceField" {
            return tv
        }
        for sub in view.subviews {
            if let f = findReplaceField(in: sub) { return f }
        }
        return nil
    }

    /// Minimaler `NSDraggingInfo`-Mock für `pilldrop`: trägt einen String auf
    /// einer eigenen Pasteboard, alle übrigen Protokoll-Member sind triviale
    /// Stubs. Reicht, um die Drag-Destination-Overrides headless zu prüfen —
    /// echtes Maus-Dragging lässt sich nicht automatisieren.
    private final class MockDraggingInfo: NSObject, NSDraggingInfo {
        private let pasteboard: NSPasteboard
        var draggingLocation: NSPoint

        init(string: String, location: NSPoint) {
            self.pasteboard = NSPasteboard(name: NSPasteboard.Name("fastra.test.pilldrop"))
            self.pasteboard.clearContents()
            self.pasteboard.setString(string, forType: .string)
            self.draggingLocation = location
            super.init()
        }

        var draggingPasteboard: NSPasteboard { pasteboard }
        // Externer Drag (nicht das Feld selbst) → die Overrides greifen.
        var draggingSource: Any? { nil }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        var draggingSequenceNumber: Int { 0 }
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination: Bool = false
        var numberOfValidItemsForDrop: Int = 1
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
        func slideDraggedImage(to screenPoint: NSPoint) {}
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions,
                                    for view: NSView?,
                                    classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    }

    // MARK: - -selftest navmatch

    /// Reproduziert den REALEN Bedienfall, den `jump` bisher umging: die
    /// schwebende Suchmaske ist Key-Window (der Nutzer klickt dort einen
    /// Treffer / drückt CMD+G), und der Sprung MUSS trotzdem im Editor sichtbar
    /// ankommen. `jump` machte künstlich das Hauptfenster Key+FirstResponder —
    /// dadurch fiel nicht auf, dass Treffer-Navigation aus der Maske heraus
    /// nichts bewirkt (Daniel-Befund 2026-06-13: Liste „nicht klickbar", CMD+G tot).
    private static func runNavMatchTest() {
        testLabel = "navmatch"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }
        // 3 Treffer „TREFFER" auf Zeile 2/4/6.
        let content = ["zeile eins ohne", "TREFFER zwei hier", "zeile drei nix",
                       "TREFFER vier da", "zeile fuenf nix", "TREFFER sechs"].joined(separator: "\n")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-navmatch-\(UUID().uuidString).txt")
        do { try content.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let tvView = editorTextView(in: root), let tv = tvView as? TextView else {
                    finish(false, "Editor-TextView nicht erreichbar")
                }
                // REALISTISCH: die Suchmaske nach vorn holen + zum Key-Window
                // machen — so wie es ist, wenn der Nutzer dort einen Treffer
                // anklickt. NICHT das Hauptfenster aktivieren (das war der
                // unrealistische Trick des jump-Tests).
                guard let searchWin = NSApp.windows.first(where: {
                    $0.frameAutosaveName == SearchWindow.frameAutosaveName && $0.isVisible
                }) else { finish(false, "keine sichtbare Suchmaske") }
                NSApp.activate(ignoringOtherApps: true)
                searchWin.makeKeyAndOrderFront(nil)

                ws.scope = .file
                ws.useRegex = false
                ws.caseSensitive = true
                ws.findPattern = "TREFFER"
                pollNavReady(ws, tv: tv, searchWindow: searchWin, originalText: content)
            }
        }
    }

    /// Wartet auf drei Treffer und drückt Return im echten Suchfeld. Das muss
    /// Treffer 0 aktivieren und den Fokus an die Trefferliste weitergeben.
    private static func pollNavReady(_ ws: Workspace, tv: TextView,
                                     searchWindow: NSWindow, originalText: String,
                                     tick: Int = 0) {
        let maxTicks = 100   // ~3 s
        if !ws.bufferSearching && ws.bufferMatches.count == 3 {
            guard let root = searchWindow.contentView else {
                finish(false, "(navmatch) Suchmaske ohne contentView")
            }
            var fields: [NSView] = []
            collectTypeableFields(in: root, into: &fields)
            guard let findField = fields.compactMap({ $0 as? RegexFieldTextView }).first(where: {
                $0.accessibilityIdentifier() == "fastra.findField"
            }), searchWindow.makeFirstResponder(findField) else {
                finish(false, "(navmatch) Suchfeld nicht gefunden/fokussierbar")
            }
            // Derselbe AppKit-onSubmit-Pfad wie eine physische Return-Taste.
            findField.insertNewline(nil)
            pollNavSelection(ws, tv: tv, searchWindow: searchWindow,
                             originalText: originalText, expectedIndex: 0,
                             thenPressReturnInList: true)
            return
        }
        if tick >= maxTicks {
            finish(false, "(navmatch) Suche lieferte nicht 3 Treffer "
                + "(count=\(ws.bufferMatches.count), searching=\(ws.bufferSearching), "
                + "error=\(ws.searchError ?? "nil"))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollNavReady(ws, tv: tv, searchWindow: searchWindow,
                         originalText: originalText, tick: tick + 1)
        }
    }

    /// Prüft unabhängig beobachtbar: richtige Selektion, Suchfenster bleibt
    /// Key, Editor bleibt ohne First-Responder und sein Text unverändert.
    private static func pollNavSelection(_ ws: Workspace, tv: TextView,
                                         searchWindow: NSWindow, originalText: String,
                                         expectedIndex: Int, thenPressReturnInList: Bool,
                                         tick: Int = 0) {
        let maxTicks = 60   // ~1,8 s
        let editorText = tv.string as NSString
        let sel = tv.selectedRange()
        if ws.activeMatchIndex == expectedIndex,
           sel.location != NSNotFound, sel.length > 0, NSMaxRange(sel) <= editorText.length {
            let selectedText = editorText.substring(with: sel)
            if selectedText != "TREFFER" {
                finish(false, "(navmatch) Sprung selektierte \"\(selectedText)\", erwartet \"TREFFER\"")
            }
            guard searchWindow.isKeyWindow else {
                finish(false, "(navmatch) Suchmaske verlor nach Treffer \(expectedIndex) den Key-Status")
            }
            if tv.window?.firstResponder === tv {
                finish(false, "(navmatch) Editor wurde nach Treffer \(expectedIndex) First Responder")
            }
            guard tv.string == originalText else {
                finish(false, "(navmatch) Dokumenttext wurde durch Return verändert")
            }
            if thenPressReturnInList {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    postKey("\r", keyCode: 36, windowNumber: searchWindow.windowNumber)
                    pollNavSelection(ws, tv: tv, searchWindow: searchWindow,
                                     originalText: originalText, expectedIndex: 1,
                                     thenPressReturnInList: false)
                }
                return
            }
            finish(true, "Return im Suchfeld fokussiert Treffer 1; zweites Return "
                + "springt zu Treffer 2; Suchmaske bleibt Key, Editor unverändert")
        }
        if tick >= maxTicks {
            finish(false, "(navmatch) \"nächster Treffer\" erzeugte über \(maxTicks) Ticks KEINE "
                + "Editor-Selektion (selectedRange=\(sel)) — Navigation aus der Suchmaske wirkungslos")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollNavSelection(ws, tv: tv, searchWindow: searchWindow,
                             originalText: originalText, expectedIndex: expectedIndex,
                             thenPressReturnInList: thenPressReturnInList, tick: tick + 1)
        }
    }

    /// Pollt engmaschig, bis der Editor eine Selektion hat, und prüft dann,
    /// ob ihr Text exakt dem erwarteten Treffer entspricht. Sobald eine
    /// gültige Selektion da ist → `onPass()` bei Gleichheit, sonst FAIL mit
    /// dem daneben-selektierten Text. Bleibt über das ganze Beobachtungs-
    /// fenster GAR keine Selektion → FAIL (Sprung wirkte nicht).
    private static func pollForSelection(_ tv: TextView, expected: String,
                                         line: Int, column: Int, label: String,
                                         onPass: @escaping () -> Void, tick: Int = 0) {
        let maxTicks = 50            // 50 × 30 ms ≈ 1,5 s Beobachtungsfenster
        let editorText = tv.string as NSString
        let sel = tv.selectedRange()
        if sel.location != NSNotFound, sel.length > 0, NSMaxRange(sel) <= editorText.length {
            let selectedText = editorText.substring(with: sel)
            if selectedText == expected {
                onPass()
            } else {
                finish(false, "(\(label)) Sprung daneben: selektiert \"\(selectedText)\", "
                       + "erwartet \"\(expected)\" — genau der Offset-Drift")
            }
            return
        }
        if tick >= maxTicks {
            finish(false, "(\(label)) Sprung setzte über \(maxTicks) Ticks keine Selektion (selectedRange=\(sel))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollForSelection(tv, expected: expected, line: line, column: column,
                             label: label, onPass: onPass, tick: tick + 1)
        }
    }

    // MARK: - -selftest scrolljump

    /// Sichert den Treffer-SPRUNG-SCROLL bei GROSSEN Dokumenten ab (Daniel-
    /// Befund 2026-06-22: Treffer wurde markiert, aber das Dokument scrollte in
    /// einer 41k-Zeilen-Datei NICHT hin — und mein erster Fix-Versuch scrollte
    /// sogar an den Datei-Anfang, weil er die Selektion zu früh zurücklas).
    /// Zugleich Daten-Reihenfolge-Wächter für die Trefferliste (Befund: Liste
    /// schien verkehrt herum sortiert).
    ///
    /// Vorgehen: großes Dokument (2500 Zeilen) laden, mit der ECHTEN Such-
    /// Engine alle Treffer finden, prüfen dass `bufferMatches` AUFSTEIGEND nach
    /// Zeile sortiert ist, dann zu einem Treffer WEIT UNTEN (ab Zeile 1900)
    /// springen und über `rectForOffset` + `visibleRect` belegen, dass der
    /// Treffer wirklich in den sichtbaren Bereich gescrollt wurde (nicht an den
    /// Datei-Anfang). Reine Unit-Tests fangen das nicht — die CESE-Layout-/
    /// Scroll-Mechanik wird nur im laufenden Editor durchlaufen.
    private static func runScrollJumpTest() {
        testLabel = "scrolljump"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)

        // 2500 Zeilen, jede mit einem eindeutigen „ende"-Treffer.
        var lines: [String] = []
        lines.reserveCapacity(2500)
        for i in 1...2500 { lines.append("Zeile \(i): wert ende") }
        let content = lines.joined(separator: "\n")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-scroll-\(UUID().uuidString).txt")
        do { try content.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let tvView = editorTextView(in: root), let tv = tvView as? TextView else {
                    finish(false, "Editor-TextView nicht als CodeEditTextView.TextView erreichbar")
                }
                _ = mainWindow.makeFirstResponder(tv)

                let opts = SearchOptions(find: "ende", replace: "",
                                         isRegex: false, caseSensitive: true)
                let result = BufferSearch.find(in: ws.activeTab?.content ?? "", options: opts)
                let lineSeq = result.matches.map(\.line)
                guard !lineSeq.isEmpty else {
                    finish(false, "keine Treffer gefunden (Inhalt nicht geladen?)")
                }
                // Befund #2: Reihenfolge der Treffer-Daten MUSS aufsteigend sein.
                if lineSeq != lineSeq.sorted() {
                    finish(false, "bufferMatches NICHT aufsteigend nach Zeile — erste: \(lineSeq.prefix(8))")
                }
                // Sprung-Ziel weit unten (innerhalb des 2000er-Materialisierungs-Caps).
                guard let target = result.matches.first(where: { $0.line >= 1900 }) else {
                    finish(false, "kein Treffer ab Zeile 1900 — max gelistete Zeile \(lineSeq.max() ?? 0)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.postMatchJump(target, for: ws)
                    pollForScrollVisible(tv, matchLocation: target.range.location,
                                         line: target.line, tick: 0)
                }
            }
        }
    }

    /// Pollt, bis der Treffer-Rect (via `rectForOffset`) den sichtbaren Bereich
    /// des Editors schneidet — belegt, dass der Sprung wirklich dorthin
    /// gescrollt hat. FAIL, wenn der Treffer nach ~2 s nicht in Sicht ist
    /// (z.B. weil fälschlich an den Datei-Anfang gescrollt wurde).
    private static func pollForScrollVisible(_ tv: TextView, matchLocation: Int,
                                             line: Int, tick: Int) {
        let maxTicks = 40            // 40 × 50 ms = 2 s
        if let rect = tv.layoutManager.rectForOffset(matchLocation) {
            let visible = tv.visibleRect
            if visible.intersects(rect) {
                finish(true, "Sprung scrollte Zeile \(line) in Sicht "
                       + "(matchY=\(Int(rect.midY)), sichtbar \(Int(visible.minY))–\(Int(visible.maxY)))")
            }
            if tick >= maxTicks {
                finish(false, "Treffer NICHT in Sicht: Zeile \(line) liegt bei matchY=\(Int(rect.midY)), "
                       + "sichtbar nur \(Int(visible.minY))–\(Int(visible.maxY)) (scrollte an den Anfang?)")
            }
        } else if tick >= maxTicks {
            finish(false, "rectForOffset lieferte nil für Zeile \(line)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollForScrollVisible(tv, matchLocation: matchLocation, line: line, tick: tick + 1)
        }
    }

    /// Sammelt alle editierbaren `NSTextField` (SwiftUI-`TextField` bridged
    /// darauf) rekursiv ein. Nicht-editierbare Labels (SwiftUI-`Text` →
    /// `NSTextField` mit `isEditable == false`) werden ausgeschlossen.
    private static func collectEditableFields(in view: NSView, into out: inout [NSTextField]) {
        if let tf = view as? NSTextField, tf.isEditable, tf.isEnabled {
            out.append(tf)
        }
        for sub in view.subviews { collectEditableFields(in: sub, into: &out) }
    }

    /// Sammelt beide Arten betippbarer Eingabefelder ein: klassische
    /// editierbare `NSTextField` UND die `RegexFieldTextView`s der
    /// Suchmaske (NSTextView-Subklasse, seit v0.7 — Token-Highlighting).
    private static func collectTypeableFields(in view: NSView, into out: inout [NSView]) {
        if let tf = view as? NSTextField, tf.isEditable, tf.isEnabled {
            out.append(tf)
        } else if let tv = view as? RegexFieldTextView, tv.isEditable {
            out.append(tv)
        }
        for sub in view.subviews { collectTypeableFields(in: sub, into: &out) }
    }

    /// Aktueller Text eines betippbaren Felds (beide Arten).
    private static func readFieldText(_ field: NSView) -> String {
        if let tf = field as? NSTextField { return tf.stringValue }
        if let tv = field as? RegexFieldTextView { return tv.string }
        return ""
    }

    private static func describe(_ field: NSTextField) -> String {
        "\(type(of: field)) ph=\"\(field.placeholderString ?? "")\""
    }

    /// Beschreibung für Fehlermeldungen — beide Feld-Arten.
    private static func describeField(_ field: NSView) -> String {
        if let tf = field as? NSTextField { return describe(tf) }
        if let tv = field as? RegexFieldTextView {
            return "RegexFieldTextView ph=\"\(tv.placeholder)\""
        }
        return String(describing: type(of: field))
    }

    // MARK: - -selftest hscroll

    /// Diagnose + Wächter für den horizontalen Scrollbalken bei „Umbruch aus"
    /// (Daniel-Befund 2026-06-23: ohne Umbruch war langer Text unerreichbar —
    /// KEIN H-Scrollbalken; ein statischer Screenshot kann das nicht beweisen).
    /// Lädt sehr lange Zeilen und liest die ECHTEN ScrollView-Maße aus dem
    /// laufenden Editor: ist `documentView` breiter als der sichtbare Bereich
    /// UND `hasHorizontalScroller` gesetzt → horizontal scrollbar. Dumpt die
    /// Werte IMMER (auch bei PASS), damit die Ursache sichtbar ist. Nur bei
    /// Der Test schaltet das Plain-Text-Profil selbst aus, damit er unabhängig
    /// von echten Nutzer-Defaults und dem migrierten Altschlüssel bleibt.
    private static func runHScrollTest() {
        testLabel = "hscroll"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)
        ws.setSoftWrapEnabled(false)

        // 40 sehr lange Zeilen (~430 Zeichen) → weit breiter als jedes Fenster.
        let longTail = String(repeating: "lang_", count: 80)
        var lines: [String] = []
        for i in 1...40 { lines.append("Zeile \(i) \(longTail) ENDE\(i)") }
        let content = lines.joined(separator: "\n")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-hscroll-\(UUID().uuidString).txt")
        do { try content.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                guard let tvView = editorTextView(in: root), let tv = tvView as? TextView else {
                    finish(false, "Editor-TextView nicht als CodeEditTextView.TextView erreichbar")
                }
                guard let sv = tv.enclosingScrollView else {
                    finish(false, "kein enclosingScrollView am Editor-TextView")
                }
                let clipW = sv.contentView.bounds.width
                let wrap = tv.wrapLines
                let estBefore = tv.layoutManager.estimatedWidth()
                let docBefore = sv.documentView?.frame.width ?? 0
                // Erzwungenen Layout-/Frame-Pass auslösen und neu messen — zeigt,
                // ob das Problem ein fehlender Trigger ist (dann wächst es jetzt)
                // oder die Breite gar nicht gemessen wird (dann bleibt est klein).
                tv.needsLayout = true
                tv.layoutSubtreeIfNeeded()
                tv.updateFrameIfNeeded()
                let estAfter = tv.layoutManager.estimatedWidth()
                let docAfter = sv.documentView?.frame.width ?? 0
                let hasH = sv.hasHorizontalScroller
                let style = sv.scrollerStyle == .overlay ? "overlay" : "legacy"
                let info = "wrap=\(wrap) clipW=\(Int(clipW)) hasH=\(hasH) style=\(style) "
                    + "est=\(Int(estBefore))->\(Int(estAfter)) docW=\(Int(docBefore))->\(Int(docAfter))"
                if wrap {
                    finish(true, "(Umbruch AN — nur Diagnose) \(info)")
                } else {
                    let scrollable = docAfter > clipW + 1 && hasH
                    finish(scrollable,
                           (scrollable ? "horizontal scrollbar OK: " : "NICHT horizontal scrollbar: ") + info)
                }
            }
        }
    }

    // MARK: - -selftest crjump

    /// Reproduziert + diagnostiziert den Tief-Zeilen-Sprung-Scroll-Bug bei
    /// REINEN CR-Zeilenenden (Daniel-Befund 2026-06-23: Klick auf Treffer in
    /// hoher Zeile scrollt im Hauptfenster falsch, Fehler wächst mit der Tiefe;
    /// Datei ist eine 4D-Log mit CR-Zeilenenden). UNABHÄNGIGER Check: nach dem
    /// Sprung wird über `textLineForPosition(visibleRect.midY)` ausgelesen,
    /// welche Zeile TATSÄCHLICH sichtbar ist — NICHT über `rectForOffset`, das
    /// derselbe (evtl. fehlerhafte) Schätz-Mechanismus ist wie der Sprung selbst
    /// (deshalb sah `scrolljump` mit LF nichts). Dumpt alle Indizes, damit die
    /// Ursache (Zeilenindex-Divergenz vs. Höhen-Schätzung) sichtbar wird.
    private static func runCRJumpTest() {
        testLabel = "crjump"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)

        // 41000 SEHR LANGE Zeilen (~280 Zeichen, wie Daniels echte 4D-Log mit
        // ~41k Zeilen), REINE CR-Zeilenenden (\r), Marke TIEF auf Zeile 40000.
        // Lange Zeilen, weil der Bug mit kurzen Zeilen NICHT reproduzierte
        // (bei Umbruch an wrappen sie auf mehrere Zeilen → variable Höhen →
        // Schätzfehler). Die große Tiefe ist Absicht: der Sprung-Fehler wuchs
        // PROPORTIONAL zur Zeilen-Tiefe (1256→485), erst die echte 41k-Tiefe
        // belegt, dass `convergeScroll` auch ganz unten konvergiert.
        let tail = String(repeating: "gg.4DProject.M[2568][Web021] WebDebugLog SendFile ", count: 5)
        var lines: [String] = []
        for i in 1...41000 { lines.append("Zeile \(i) \(tail) \(i == 40000 ? "ZIELMARKE" : "ende")") }
        let content = lines.joined(separator: "\r")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-crjump-\(UUID().uuidString).txt")
        do { try content.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            // 41k lange Zeilen → CESE-Editor-Mount braucht spürbar länger als bei
            // 3000 (Mount blockiert proportional, vgl. loadperf). Mehr Settle-Zeit,
            // sonst misst der Test, bevor das Layout steht.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let tvView = editorTextView(in: root), let tv = tvView as? TextView else {
                    finish(false, "Editor-TextView nicht als CodeEditTextView.TextView erreichbar")
                }
                _ = mainWindow.makeFirstResponder(tv)
                let opts = SearchOptions(find: "ZIELMARKE", replace: "", isRegex: false, caseSensitive: true)
                let result = BufferSearch.find(in: ws.activeTab?.content ?? "", options: opts)
                guard let match = result.matches.first else {
                    finish(false, "ZIELMARKE nicht gefunden (Inhalt/CR nicht geladen?)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.postMatchJump(match, for: ws)
                    // Settle lassen, dann UNABHÄNGIG prüfen, welche Zeile sichtbar ist.
                    // 2,0 s statt 1,3 s — convergeScroll iteriert bei Tiefe 40000
                    // länger bis zur Konvergenz.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        let vis = tv.visibleRect
                        let shownMid = tv.layoutManager.textLineForPosition(vis.midY)?.index
                        let shownTop = tv.layoutManager.textLineForPosition(vis.minY)?.index
                        let byIndex = tv.layoutManager.textLineForIndex(match.line - 1)?.index
                        let byOffset = tv.layoutManager.textLineForOffset(match.range.location)?.index
                        let info = "matchLine=\(match.line) loc=\(match.range.location) "
                            + "textLineForIndex=\(byIndex.map(String.init) ?? "nil") "
                            + "textLineForOffset=\(byOffset.map(String.init) ?? "nil") "
                            + "sichtbarMitte(1-based)=\(shownMid.map { String($0 + 1) } ?? "nil") "
                            + "sichtbarOben(1-based)=\(shownTop.map { String($0 + 1) } ?? "nil") "
                            + "visY=\(Int(vis.minY))-\(Int(vis.maxY))"
                        if let s = shownMid, abs((s + 1) - match.line) <= 15 {
                            finish(true, "CR-Sprung korrekt: \(info)")
                        } else {
                            finish(false, "CR-Sprung FALSCH (Ziel nicht sichtbar): \(info)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - -selftest textop

    /// Verifiziert den MENÜLEISTEN-Pfad der BBEdit-„Text"-Operationen
    /// end-to-end: Buffer laden, `.fastraTextOp` (uppercase) und danach beide
    /// `.fastraSortLines`-Richtungen posten — exakt wie es das „Text"-Menü tut.
    /// Geprüft wird jeweils der ECHTE Editor-Inhalt. Deckt Observer
    /// (AppDelegate) → EditorContextMenu → native TextView → Undo-fähige
    /// Ersetzung ab.
    private static func runTextOpTest() {
        testLabel = "textop"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-textop-\(UUID().uuidString).txt")
        do {
            try "beta\nalpha\ngamma\n".write(
                to: tmp, atomically: true, encoding: .utf8
            )
        }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                guard let tv = editorTextView(in: root) as? TextView else {
                    finish(false, "Editor-TextView nicht erreichbar")
                }
                _ = mainWindow.makeFirstResponder(tv)
                // Keine Selektion → ganze Datei. Posten wie das „Text"-Menü.
                NotificationCenter.default.post(name: .fastraTextOp,
                                                object: TextOpKind.uppercase.rawValue)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard tv.string == "BETA\nALPHA\nGAMMA\n" else {
                        finish(false, "Großschreibung erreichte den echten Editor nicht")
                    }
                    NotificationCenter.default.post(
                        name: .fastraSortLines,
                        object: LineOperations.SortDirection.ascending.rawValue
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard tv.string == "ALPHA\nBETA\nGAMMA\n" else {
                            finish(false, "aufsteigende Sortierung: \(tv.string.debugDescription)")
                        }
                        NotificationCenter.default.post(
                            name: .fastraSortLines,
                            object: LineOperations.SortDirection.descending.rawValue
                        )
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            let expected = "GAMMA\nBETA\nALPHA\n"
                            guard tv.string == expected else {
                                finish(false, "absteigende Sortierung: "
                                    + "\(tv.string.debugDescription)")
                            }
                            checkEmojiPresentationTextOp(tv: tv)
                        }
                    }
                }
            }
        }
    }

    /// Letzter Schritt von `textop`: Die neue Unicode-Operation
    /// „Emoji-Darstellung erzwingen" muss über denselben Menüweg im echten
    /// Editor ankommen — und ihr Rückweg auch. Geprüft wird an Daniels Fall
    /// (nacktes `⏸`) samt einem Zeichen, das unangetastet bleiben muss.
    private static func checkEmojiPresentationTextOp(tv: TextView) {
        let source = "Pause \u{23F8} und \u{00A9} 2026\n"
        tv.selectionManager.setSelectedRange(
            NSRange(location: 0, length: (tv.string as NSString).length)
        )
        tv.insertText(source, replacementRange: NSRange(location: NSNotFound, length: 0))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            tv.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
            NotificationCenter.default.post(
                name: .fastraTextOp,
                object: TextOpKind.addEmojiPresentation.rawValue
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let expected = "Pause \u{23F8}\u{FE0F} und \u{00A9} 2026\n"
                guard tv.string == expected else {
                    finish(false, "Emoji-Darstellung erzwingen erreichte den "
                        + "Editor nicht: \(tv.string.debugDescription)")
                }
                NotificationCenter.default.post(
                    name: .fastraTextOp,
                    object: TextOpKind.removeEmojiPresentation.rawValue
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    finish(tv.string == source,
                           "Text-Op, beide Sortierrichtungen und die "
                            + "Emoji-Darstellung (hin und zurück) im echten Editor")
                }
            }
        }
    }

    // MARK: - -selftest joinundo

    /// Regression für den konkret gemeldeten Fall: Eine per Cmd+A vollständig
    /// ausgewählte CSS-Datei wird ohne Soft Wrap verbunden. Die Vollauswahl
    /// darf danach weder den Editor leerräumen noch nach Undo einen leeren
    /// Bildschirm oberhalb von Zeile 1 hinterlassen. Der Modelltext allein
    /// reicht als Prüfung nicht, weil er beim ursprünglichen Fehler jederzeit
    /// vollständig war.
    private static func runJoinUndoTest() {
        testLabel = "joinundo"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }

        var lines = (1...12).flatMap { index in
            [
                ".c\(index) {",
                "  color: #123456;",
                "  margin: \(index)px;",
                "}",
                ""
            ]
        }
        lines.append("/* Ende */")
        let content = lines.joined(separator: "\n")
        let fullSelection = NSRange(
            location: 0,
            length: (content as NSString).length
        )
        let joined = TextOperations.joinLines(
            in: content,
            selection: fullSelection
        )?.newText
        guard let joined else {
            finish(false, "Join-Lines-Fixture lieferte kein Ergebnis")
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-joinundo-\(UUID().uuidString).css")
        do { try content.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let tv = editorTextView(in: root) as? TextView else {
                    finish(false, "Editor-TextView nicht erreichbar")
                }
                tv.layoutManager.wrapLines = false
                tv.selectAll(nil)
                tv.layoutManager.layoutLines()
                NotificationCenter.default.post(
                    name: .fastraTextOp,
                    object: TextOpKind.joinLines.rawValue
                )

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let joinedVisible = visibleTextFragmentCount(in: tv)
                    let joinedSelection = tv.selectedRange()
                    let joinedTextCorrect = tv.string == joined

                    tv.undoManager?.undo()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        let undoVisible = visibleTextFragmentCount(in: tv)
                        let undoSelection = tv.selectedRange()
                        let undoTextCorrect = tv.string == content
                        tv.undoManager?.redo()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            let redoVisible = visibleTextFragmentCount(in: tv)
                            let redoSelection = tv.selectedRange()
                            let redoTextCorrect = tv.string == joined
                            let ok = joinedTextCorrect
                                && joinedVisible > 0
                                && joinedSelection == NSRange(location: 0, length: 0)
                                && undoTextCorrect
                                && undoVisible > 0
                                && undoSelection == NSRange(location: 0, length: 0)
                                && redoTextCorrect
                                && redoVisible > 0
                                && redoSelection == NSRange(location: 0, length: 0)
                            finish(
                                ok,
                                "Join: Text=\(joinedTextCorrect), sichtbare Fragmente="
                                    + "\(joinedVisible), Auswahl=\(joinedSelection), Zeichen="
                                    + "\((content as NSString).length); "
                                    + "Undo: Text=\(undoTextCorrect), sichtbare Fragmente="
                                    + "\(undoVisible), Auswahl=\(undoSelection); "
                                    + "Redo: Text=\(redoTextCorrect), sichtbare Fragmente="
                                    + "\(redoVisible), Auswahl=\(redoSelection)"
                            )
                        }
                    }
                }
            }
        }
    }

    /// Zählt echte, nicht geparkte Text-Views im sichtbaren Editorbereich.
    /// Das ist unabhängig von `rectForOffset`: genau die war bei früheren
    /// Layoutfehlern trotz leerer Darstellung scheinbar plausibel.
    private static func visibleTextFragmentCount(in textView: TextView) -> Int {
        var fragments: [LineFragmentView] = []
        func collect(_ view: NSView) {
            if let fragment = view as? LineFragmentView {
                fragments.append(fragment)
            }
            view.subviews.forEach(collect)
        }
        collect(textView)
        return fragments.filter {
            !$0.isHidden
                && $0.frame != .zero
                && ($0.lineFragment?.documentRange.length ?? 0) > 0
                && ($0.lineFragment?.contents.reduce(0) {
                    $0 + $1.length
                } ?? 0) > 0
                && $0.frame.intersects(textView.visibleRect)
        }.count
    }

    // MARK: - -selftest colsel

    /// Verifiziert den öffentlichen Option-Drag-Pfad ohne Soft Wrap. Die
    /// Punkt-API ist exakt dieselbe, die `mouseDragged` verwendet; geprüft
    /// werden nicht nur mehrere Cursor, sondern die exakten Teilbereiche.
    private static func runColumnSelectionTest() {
        testLabel = "colsel"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)

        // Gleich lange Zeilen (Monospace) → saubere Spalten.
        let content = "ABCDEFGH\nABCDEFGH\nABCDEFGH\nABCDEFGH"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-colsel-\(UUID().uuidString).txt")
        do { try content.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                guard let tv = editorTextView(in: root) as? TextView else {
                    finish(false, "Editor-TextView nicht erreichbar")
                }
                tv.layoutManager.wrapLines = false
                tv.layoutSubtreeIfNeeded()
                // Offset 2 = Zeile 0, Spalte 2. Offset 32 = Zeile 3, Spalte 5
                // (je Zeile 8 Zeichen + \n = 9; 3*9 + 5 = 32).
                guard let rA = tv.layoutManager.rectForOffset(2),
                      let rB = tv.layoutManager.rectForOffset(32) else {
                    finish(false, "rectForOffset nil (Layout noch nicht bereit?)")
                }
                let pA = CGPoint(x: rA.minX, y: rA.midY)
                let pB = CGPoint(x: rB.minX, y: rB.midY)
                tv.selectColumns(betweenPointA: pA, pointB: pB)
                let snapshot = tv.fastraColumnSelectionSnapshot
                let values = snapshot?.ranges.map {
                    (tv.string as NSString).substring(with: $0)
                }
                let ok = snapshot?.lineIndices == [0, 1, 2, 3]
                    && snapshot?.lowerColumn == 2
                    && snapshot?.upperColumn == 5
                    && values == ["CDE", "CDE", "CDE", "CDE"]
                finish(ok,
                       "Option-Drag: Zeilen=\(snapshot?.lineIndices ?? []), "
                       + "Spalten=\(snapshot?.lowerColumn ?? -1)…"
                       + "\(snapshot?.upperColumn ?? -1), Werte=\(values ?? [])")
            }
        }
    }

    // MARK: - -selftest colselwrap

    /// Soft Wrap darf keine zusätzliche Rechteckzeile erzeugen. Der Test
    /// umfasst kurze/leere Zeilen, Tabs, CRLF und zusammengesetzte Grapheme;
    /// Vorwärts- und Rückwärtsauswahl müssen dieselben logischen Zeilen treffen.
    private static func runWrappedColumnSelectionTest() {
        testLabel = "colselwrap"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }

        let lines = [
            "abCDE" + String(repeating: " langeZeile", count: 12),
            "xy",
            "",
            "\tABCD",
            "ab👩‍💻e\u{301}Z",
        ]
        let content = lines.joined(separator: "\r\n")
        var starts: [Int] = []
        var offset = 0
        for (index, line) in lines.enumerated() {
            starts.append(offset)
            offset += (line as NSString).length
            if index < lines.count - 1 { offset += 2 }
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-colselwrap-\(UUID().uuidString).txt")
        do { try content.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                guard let tv = editorTextView(in: root) as? TextView else {
                    finish(false, "Editor-TextView nicht erreichbar")
                }
                let charWidth = max(
                    (" " as NSString).size(withAttributes: [
                        .font: tv.font,
                        .kern: tv.kern,
                    ]).width,
                    1
                )
                tv.layoutManager.wrapLines = true
                tv.layoutManager.maximumWrapWidth = charWidth * 9
                tv.layoutManager.layoutLines()

                let firstFragments = Array(tv.layoutManager.lineStorage)
                    .first.map { Array($0.data.lineFragments).count } ?? 0
                tv.selectionManager.setSelectedRange(
                    NSRange(location: starts[0] + 2, length: 3)
                )
                for _ in 1..<lines.count {
                    guard tv.fastraSelectColumn(upwards: false) else {
                        finish(false, "Select Down endete vor der letzten logischen Zeile")
                    }
                }
                guard let forward = tv.fastraColumnSelectionSnapshot else {
                    finish(false, "Vorwärtsauswahl lieferte keinen Rechteckzustand")
                }
                let values = forward.ranges.map {
                    (tv.string as NSString).substring(with: $0)
                }
                let expectedValues = ["CDE", "", "", "\tA", "👩‍💻e\u{301}Z"]
                let textBefore = tv.string
                let rangesBefore = forward.ranges

                // Dieselbe Geometrie rückwärts aufbauen. Der letzte echte
                // Teilbereich ist graphem-sicher und bestimmt wieder Spalte 2…5.
                tv.selectionManager.setSelectedRange(forward.ranges[4])
                for _ in 1..<lines.count {
                    guard tv.fastraSelectColumn(upwards: true) else {
                        finish(false, "Select Up endete vor der ersten logischen Zeile")
                    }
                }
                guard let reverse = tv.fastraColumnSelectionSnapshot else {
                    finish(false, "Rückwärtsauswahl lieferte keinen Rechteckzustand")
                }

                // Wrap-Ziel ändern und Wrap kurz aus-/einschalten: weder Text
                // noch echte UTF-16-Bereiche dürfen sich dadurch verändern.
                tv.layoutManager.maximumWrapWidth = charWidth * 14
                tv.layoutManager.wrapLines = false
                tv.layoutManager.layoutLines()
                tv.layoutManager.wrapLines = true
                tv.layoutManager.layoutLines()
                let afterToggle = tv.fastraColumnSelectionSnapshot

                let ok = firstFragments > 1
                    && forward.lineIndices == [0, 1, 2, 3, 4]
                    && forward.lowerColumn == 2
                    && forward.upperColumn == 5
                    && values == expectedValues
                    && reverse.lineIndices == forward.lineIndices
                    && reverse.ranges == rangesBefore
                    && afterToggle?.ranges == rangesBefore
                    && tv.string == textBefore
                finish(
                    ok,
                    "Fragmente Zeile 1=\(firstFragments), logische Zeilen="
                        + "\(forward.lineIndices), Werte=\(values), "
                        + "rückwärts=\(reverse.ranges == rangesBefore), "
                        + "Wrap-Umschaltung=\(afterToggle?.ranges == rangesBefore)"
                )
            }
        }
    }

    // MARK: - -selftest colpaste

    /// Copy/Paste, Tippen, Löschen, Cut, Paste Column und eine Zeichen-
    /// Transformation müssen alle Rechteckteile bearbeiten und je genau eine
    /// Undo-Gruppe erzeugen.
    private static func runColumnPasteTest() {
        testLabel = "colpaste"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-colpaste-\(UUID().uuidString).txt")
        do {
            try "abCDef\nabXYef\nab12ef".write(
                to: tmp, atomically: true, encoding: .utf8
            )
        } catch {
            finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)")
        }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                guard let tv = editorTextView(in: root) as? TextView else {
                    finish(false, "Editor-TextView nicht erreichbar")
                }
                var failures: [String] = []
                func check(_ condition: @autoclosure () -> Bool, _ label: String) {
                    if !condition() { failures.append(label) }
                }
                func selectThree(
                    _ text: String,
                    start: Int = 2,
                    length: Int = 2
                ) -> Int {
                    tv.setText(text)
                    tv._undoManager?.clearStack()
                    tv.selectionManager.setSelectedRange(
                        NSRange(location: start, length: length)
                    )
                    check(tv.fastraSelectColumn(upwards: false), "Select Down 1")
                    check(tv.fastraSelectColumn(upwards: false), "Select Down 2")
                    return tv._undoManager?.undoCount ?? -1
                }
                func checkOneUndo(_ before: Int, _ label: String) {
                    check(
                        tv._undoManager?.undoCount == before + 1,
                        "\(label): nicht genau eine Undo-Gruppe"
                    )
                }

                NSApp.mainMenu?.update()
                let pasteColumnItem = findMenuItem(
                    titled: L10n.string("Spalte einfügen"),
                    in: NSApp.mainMenu
                )
                let selectUpItem = findMenuItem(
                    titled: L10n.string("Rechteckauswahl nach oben"),
                    in: NSApp.mainMenu
                )
                let selectDownItem = findMenuItem(
                    titled: L10n.string("Rechteckauswahl nach unten"),
                    in: NSApp.mainMenu
                )
                let upArrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
                let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
                check(
                    pasteColumnItem?.keyEquivalent.lowercased() == "v"
                        && pasteColumnItem?.keyEquivalentModifierMask
                            == [.command, .control],
                    "Menü/Kürzel für Paste Column fehlt"
                )
                check(
                    selectUpItem?.keyEquivalent == upArrow
                        && selectUpItem?.keyEquivalentModifierMask
                            == [.control, .shift],
                    "Menü/Kürzel für Select Up fehlt"
                )
                check(
                    selectDownItem?.keyEquivalent == downArrow
                        && selectDownItem?.keyEquivalentModifierMask
                            == [.control, .shift],
                    "Menü/Kürzel für Select Down fehlt"
                )

                let base = "abCDef\nabXYef\nab12ef"

                _ = selectThree(base)
                tv.copy(tv)
                check(
                    NSPasteboard.general.string(forType: .string)
                        == "CD\nXY\n12\n",
                    "Rechteck-Copy falsch"
                )

                var undoBefore = selectThree(base)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("Q", forType: .string)
                tv.paste(tv)
                check(tv.string == "abQef\nabQef\nabQef", "Fill-down Paste falsch")
                checkOneUndo(undoBefore, "Fill-down Paste")
                tv._undoManager?.undo()
                check(tv.string == base, "Fill-down Undo falsch")
                tv._undoManager?.redo()
                check(tv.string == "abQef\nabQef\nabQef", "Fill-down Redo falsch")

                undoBefore = selectThree(base)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("1\n22", forType: .string)
                tv.paste(tv)
                check(
                    tv.string == "ab1ef\nab22ef\nabef",
                    "Mismatch-Regel (fehlende Clipboard-Zeile leert Rest) falsch"
                )
                checkOneUndo(undoBefore, "Mehrzeiliges Paste")

                undoBefore = selectThree(base)
                tv.insertText(
                    "T" as NSString,
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                check(tv.string == "abTef\nabTef\nabTef", "Tippen auf Rechteck falsch")
                checkOneUndo(undoBefore, "Tippen")

                undoBefore = selectThree(base)
                tv.deleteBackward(nil)
                check(tv.string == "abef\nabef\nabef", "Backspace auf Rechteck falsch")
                checkOneUndo(undoBefore, "Backspace")

                let shortRows = "abcdef\nab\nabc"
                undoBefore = selectThree(shortRows, start: 4, length: 1)
                tv.deleteBackward(nil)
                check(
                    tv.string == "abcdf\nab\nabc",
                    "Backspace löschte außerhalb kurzer Rechteckzeilen"
                )
                checkOneUndo(undoBefore, "Backspace mit kurzen Zeilen")

                undoBefore = selectThree(shortRows, start: 4, length: 1)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("Q", forType: .string)
                tv.paste(tv)
                check(
                    tv.string == "abcdQf\nabQ\nabcQ",
                    "Normales Paste polsterte kurze Zeilen unerwartet"
                )
                checkOneUndo(undoBefore, "Paste mit kurzen Zeilen")

                undoBefore = selectThree(base)
                tv.cut(tv)
                check(tv.string == "abef\nabef\nabef", "Cut auf Rechteck falsch")
                check(
                    NSPasteboard.general.string(forType: .string)
                        == "CD\nXY\n12\n",
                    "Cut-Clipboard falsch"
                )
                checkOneUndo(undoBefore, "Cut")

                // Paste Column an Spalte 4: kurze Zeilen werden mit Tabs
                // aufgefüllt, weil das aktive Einrückungsprofil Tabs nutzt.
                let padded = "abcdef\nab\nabc"
                undoBefore = selectThree(padded, start: 4, length: 1)
                tv.fastraColumnIndentationUnit = "\t"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("X\nY\nZ", forType: .string)
                NotificationCenter.default.post(
                    name: .fastraPasteColumn,
                    object: nil
                )
                check(
                    tv.string == "abcdXf\nab\tY\nabc\tZ",
                    "Paste Column/Tab-Padding falsch: \(tv.string.debugDescription)"
                )
                checkOneUndo(undoBefore, "Paste Column")
                tv.fastraColumnIndentationUnit = "    "

                // Unterschiedliche Ergebnislängen (ß → SS) prüfen zugleich
                // Transformationsrouting und Range-Neuberechnung.
                let transformBase = "abßz\nabxy\nabéz"
                undoBefore = selectThree(transformBase, start: 2, length: 1)
                NotificationCenter.default.post(
                    name: .fastraTextOp,
                    object: TextOpKind.uppercase.rawValue
                )
                check(
                    tv.string == "abSSz\nabXy\nabÉz",
                    "Rechteck-Transformation falsch: \(tv.string.debugDescription)"
                )
                checkOneUndo(undoBefore, "Rechteck-Transformation")
                tv._undoManager?.undo()
                check(tv.string == transformBase, "Transformations-Undo falsch")

                // Nullbereiche kurzer Zeilen dürfen keinesfalls als
                // „keine Auswahl = ganzes Dokument" transformiert werden.
                let shortTransform = "abcdez\nab\nabc"
                undoBefore = selectThree(shortTransform, start: 4, length: 1)
                NotificationCenter.default.post(
                    name: .fastraTextOp,
                    object: TextOpKind.uppercase.rawValue
                )
                check(
                    tv.string == "abcdEz\nab\nabc",
                    "Transformation verließ kurze Rechteckzeilen"
                )
                checkOneUndo(undoBefore, "Transformation mit kurzen Zeilen")

                finish(
                    failures.isEmpty,
                    failures.isEmpty
                        ? "Copy/Paste/Tippen/Backspace/Cut/Paste Column/"
                            + "Transformation jeweils über drei logische Zeilen "
                            + "und eine Undo-Gruppe"
                        : failures.joined(separator: "; ")
                )
            }
        }
    }

    private static func runGutterDimmingTest() {
        testLabel = "gutterdim"
        guard let workspace = Workspace.shared,
              let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }) else {
            finish(false, "kein Hauptfenster gefunden")
        }

        waitForEditor(workspace: workspace, window: mainWindow) { root, _ in
            checkGutterDimming(in: root)
        }
    }

    private static func checkGutterDimming(in root: NSView) {
        guard let gutter = findView(named: "GutterView", in: root) else {
            finish(false, "echter CodeEditSourceEditor-Gutter nicht gefunden")
        }
        GutterDimming.apply(in: root, windowIsKey: false)
        let dimmed = gutter.alphaValue
        GutterDimming.apply(in: root, windowIsKey: true)
        let active = gutter.alphaValue
        finish(dimmed < 0.5 && active == 1,
               "echter Gutter alpha hinten=\(dimmed), vorn=\(active)")
    }

    // MARK: - -selftest filemodes

    private static func runFileModesTest() {
        testLabel = "filemodes"
        guard let ws = Workspace.shared else { finish(false, "Workspace.shared ist nil") }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            "fastra-filemodes-\(UUID().uuidString)", isDirectory: true
        )
        let binary = base.appendingPathComponent("binary.dat")
        let large = base.appendingPathComponent("large.log")
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            try Data([0x46, 0x41, 0x53, 0x54, 0, 0x52, 0x41]).write(to: binary)
            _ = FileManager.default.createFile(atPath: large.path, contents: nil)
            let handle = try FileHandle(forWritingTo: large)
            let chunk = Data(repeating: 0x41, count: 1024 * 1024)
            var remaining = FileLoader.largeFileThreshold + 101
            while remaining > 0 {
                let count = min(UInt64(chunk.count), remaining)
                try handle.write(contentsOf: chunk.prefix(Int(count)))
                remaining -= count
            }
            try handle.close()
        } catch {
            try? fm.removeItem(at: base)
            finish(false, "Setup fehlgeschlagen: \(error.localizedDescription)")
        }

        ws.loadFile(at: binary) { binaryOK in
            guard binaryOK, ws.activeTab?.displayMode == .hex,
                  ws.activeTab?.content.isEmpty == true else {
                try? fm.removeItem(at: base)
                finish(false, "Binärdatei wurde nicht als Hex geroutet")
            }
            ws.loadFile(at: large) { largeOK in
                let tab = ws.activeTab
                let ok = largeOK && tab?.displayMode == .chunkedText
                    && tab?.content.isEmpty == true
                    && (tab?.fileSize ?? 0) > FileLoader.largeFileThreshold
                try? fm.removeItem(at: base)
                finish(ok, ok
                       ? "Null-Byte → Hex; >32 MiB Text → Abschnittsansicht ohne Voll-Buffer"
                       : "Großdatei wurde nicht abschnittsweise geroutet: \(String(describing: tab))")
            }
        }
    }

    /// Findet die Haupt-Textfläche des Editors. CodeEditSourceEditor nutzt
    /// keine `NSTextView`, sondern eine eigene `TextView: NSView` (Modul
    /// CodeEditTextView) — daher Suche über den Klassennamen.
    private static func editorTextView(in view: NSView) -> NSView? {
        let name = String(describing: type(of: view))
        if name.contains("TextView"), view.acceptsFirstResponder, view.frame.height > 50 {
            return view
        }
        for sub in view.subviews {
            if let tv = editorTextView(in: sub) { return tv }
        }
        return nil
    }

    private static func findView(named className: String, in view: NSView) -> NSView? {
        let name = String(describing: type(of: view))
        if name == className || name.hasSuffix(".\(className)") { return view }
        for child in view.subviews {
            if let found = findView(named: className, in: child) { return found }
        }
        return nil
    }

    /// `true`, wenn irgendwo ein sichtbares CodeEditSourceEditor-Find-Panel
    /// hängt (Klassenname enthält „FindPanel", nicht versteckt, sichtbare Höhe).
    private static func findPanelVisible(in view: NSView) -> Bool {
        let name = String(describing: type(of: view))
        if name.contains("FindPanel"), !view.isHidden, view.frame.height > 1,
           view.window != nil {
            return true
        }
        return view.subviews.contains { findPanelVisible(in: $0) }
    }

    // MARK: - Selbsttest search

    /// Treibt Workspace + SearchRunner END-TO-END in drei Teilprüfungen:
    ///
    /// a) Buffer-Scope: Bekannten Text laden, Pattern mit exakt N Treffern
    ///    setzen, aufs Debounce pollen (120 ms Buffer-Debounce), prüfen, dass
    ///    `bufferMatches.count == N` und Zeile/Spalte des ersten Treffers stimmen.
    ///
    /// b) Live-Ordner-Scope: Temp-Ordner mit 2 Textdateien anlegen, Scope auf
    ///    `.folder` wechseln, Pattern ≥ 3 Zeichen (Live-Schwelle) setzen, den
    ///    Temp-Ordner als einzigen aktivierten Ordner eintragen, auf das Folder-
    ///    Debounce pollen (~0,42 s + async), prüfen, dass `folderTotalMatches`
    ///    gleich der erwarteten Summe ist. Danach Temp-Ordner aufräumen.
    ///
    /// c) Negativ-Pfad (Buffer-Scope): Pattern das nichts matcht → 0 Treffer
    ///    nach Debounce-Wartezeit.
    ///
    /// PASS nur wenn alle drei Teilprüfungen bestehen. FAIL benennt den
    /// konkreten Teilschritt und gibt Soll- vs. Ist-Wert aus.
    /// Fensterloser End-to-End-Test des Geöffnet-Scopes (BBEdit „Open text
    /// documents"): drei In-Memory-Tabs, Live-Suche über den ECHTEN
    /// SearchRunner-Pfad (Combine-Trigger + Task.detached), dann
    /// „Alle ersetzen" über alle Tabs. Prüft genau die Verdrahtung, die
    /// die reinen Unit-Tests umgehen (Runner-Async-Pfad).
    private static func runOpenScopeTest() {
        testLabel = "openscope"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        // Tabs direkt setzen — der Geöffnet-Scope sucht Tab-INHALTE
        // (auch ungespeicherte), keine Dateien. Genau das testen wir.
        ws.tabs = [
            EditorTab(title: "open-a.txt", path: "—",
                      content: "eins MARKER\nzwei\nMARKER drei"),
            EditorTab(title: "open-b.txt", path: "—", content: "MARKER"),
            EditorTab(title: "open-c.txt", path: "—", content: "ohne Treffer"),
        ]
        ws.activeTabID = ws.tabs[0].id
        ws.scope = .open
        ws.useRegex = false
        ws.caseSensitive = true
        ws.findPattern = "MARKER"
        ws.replacePattern = "ERSETZT"
        pollOpenResults(ws)
    }

    /// Pollt auf das erwartete Geöffnet-Ergebnis (3 Treffer in 2 Tabs),
    /// dann Teil b: Alle ersetzen. Max. ~2 s (Debounce 120 ms + Async-Lauf).
    private static func pollOpenResults(_ ws: Workspace, tick: Int = 0) {
        let maxTicks = 67
        if ws.openTotalMatches == 3 && ws.openResults.count == 2 {
            // Gruppen-Reihenfolge = Tab-Reihenfolge; Zeile/Spalte tab-lokal.
            guard ws.openResults[0].title == "open-a.txt",
                  ws.openResults[0].matches.count == 2,
                  ws.openResults[0].matches[1].line == 3,
                  ws.openResults[1].title == "open-b.txt" else {
                finish(false, "(a) Gruppen falsch: \(ws.openResults.map { "\($0.title):\($0.matches.count)" })")
            }
            // ── Teil b: Alle ersetzen über alle Tabs ────────────────────
            let changed = ws.applyAllInOpenTabs()
            guard changed == 2 else {
                finish(false, "(b) applyAllInOpenTabs änderte \(changed) statt 2 Tabs")
            }
            guard ws.tabs[0].content == "eins ERSETZT\nzwei\nERSETZT drei",
                  ws.tabs[0].isDirty,
                  ws.tabs[1].content == "ERSETZT", ws.tabs[1].isDirty,
                  ws.tabs[2].content == "ohne Treffer", !ws.tabs[2].isDirty else {
                finish(false, "(b) Tab-Inhalte nach Ersetzen falsch: \(ws.tabs.map(\.content))")
            }
            finish(true, "Geöffnet-Scope: 3 Treffer in 2 Tabs, Alle-ersetzen änderte genau 2 Tabs")
        }
        if tick >= maxTicks {
            finish(false, "(a) Timeout: openTotalMatches=\(ws.openTotalMatches), Gruppen=\(ws.openResults.count)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollOpenResults(ws, tick: tick + 1)
        }
    }

    /// Fensterlos — Projekt- & Git-Ausbau Etappe 1 end-to-end über den echten
    /// Workspace: Willkommens-Bedingung, Projekt öffnen (Dateibaum-Wurzel,
    /// Zuletzt-benutzt-Liste), Datei aus dem Baum laden, automatische
    /// Repo-Erkennung ohne Duplikat und Projekt-Datei-Set samt Ausschluss.
    // MARK: - Selbsttest mdassist (Etappe 5 Wunschpaket 2026-07b)

    /// End-to-End-Prüfung des assistierten Markdown-Schreibens:
    /// (a) Markdown-Toolbar ist für den Markdown-Tab real layoutet.
    /// (b) ⌘V-Pfad mit programmatisch befülltem Pasteboard (PNG): Datei
    ///     entsteht neben dem Dokument, relativer Link steht im Editor,
    ///     die Vorschau rendert das Bild UND scrollt zur Einfügestelle.
    /// (c) Drop-Abgrenzung: Bilddatei wird eingefügt, Textdatei geöffnet.
    private static func runMarkdownAssistTest() {
        testLabel = "mdassist"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("fastra-mdassist-\(UUID().uuidString)")
        let doc = base.appendingPathComponent("Notizen.md")
        // WIRKLICH außerhalb des Dokumentordners — sonst greift die
        // „schon im Dokumentbaum → nur verlinken“-Regel statt der Kopie.
        let outside = fm.temporaryDirectory
            .appendingPathComponent("fastra-mdassist-src-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            // Langes Dokument: Die Einfügestelle liegt am Ende, damit der
            // Vorschau-Scroll real beobachtbar ist (scrollY > 0).
            let filler = (1...60).map { "Absatz \($0) mit etwas Text." }
                .joined(separator: "\n\n")
            try ("# Notizen\n\n" + filler + "\n\n")
                .write(to: doc, atomically: true, encoding: .utf8)
            try writeSolidPNG(to: outside.appendingPathComponent("quelle.png"),
                              width: 8, height: 8)
            try "Begleittext".write(to: outside.appendingPathComponent("begleit.txt"),
                                    atomically: true, encoding: .utf8)
        } catch {
            finish(false, "(setup) Fixtures nicht schreibbar: \(error.localizedDescription)")
        }

        ws.loadFile(at: doc) { ok in
            guard ok else { finish(false, "(setup) Notizen.md lädt nicht") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let tvView = editorTextView(in: root), let tv = tvView as? TextView else {
                    finish(false, "Editor-TextView nicht erreichbar")
                }
                // (a) Toolbar real im Layout?
                guard markerViewExists(id: "markdownToolbar", in: root) else {
                    finish(false, "(a) Markdown-Toolbar fehlt für den Markdown-Tab")
                }
                // (b) Paste-Pfad: Fenster + Editor fokussieren, PNG ins
                // Pasteboard, dann der ECHTE ⌘V-Interceptions-Pfad. Der
                // Key-Status kommt asynchron — deshalb mit Wiederholungen.
                tv.selectionManager.setSelectedRange(
                    NSRange(location: (tv.string as NSString).length, length: 0))
                let png = (try? Data(contentsOf: outside.appendingPathComponent("quelle.png"))) ?? Data()
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(png, forType: NSPasteboard.PasteboardType("public.png"))
                attemptMarkdownPaste(ws, tv: tv, root: root, base: base,
                                     outside: outside, window: mainWindow, tick: 0)
            }
        }
    }

    /// Fokus + ⌘V-Pfad mit Wiederholungen: `NSApp.activate` und der
    /// Key-Status greifen erst nach ein paar Runloop-Ticks zuverlässig —
    /// besonders wenn der Desktop gerade aktiv benutzt wird.
    private static func attemptMarkdownPaste(_ ws: Workspace, tv: TextView,
                                             root: NSView, base: URL, outside: URL,
                                             window: NSWindow, tick: Int) {
        let maxTicks = 40    // 10 s
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tv)
        if MainActor.assumeIsolated({ MarkdownAssist.handlePasteCommand() }) {
            pollMarkdownPaste(ws, tv: tv, root: root, base: base,
                              outside: outside, tick: 0)
            return
        }
        if tick >= maxTicks {
            let responder = String(describing: type(of: window.firstResponder as Any))
            finish(false, "(b) handlePasteCommand übernimmt nicht "
                + "(keyWindow=\(NSApp.keyWindow != nil), isKey=\(window.isKeyWindow), "
                + "responder=\(responder))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            attemptMarkdownPaste(ws, tv: tv, root: root, base: base,
                                 outside: outside, window: window, tick: tick + 1)
        }
    }

    private static func pollMarkdownPaste(_ ws: Workspace, tv: TextView, root: NSView,
                                          base: URL, outside: URL, tick: Int) {
        let maxTicks = 40    // 10 s
        let files = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        let imageFile = files.first { $0.hasPrefix("Notizen-") && $0.hasSuffix(".png") }
        let linkInEditor = tv.string.contains("![Notizen-")
        if let imageFile, linkInEditor {
            // Vorschau: Bild gerendert + zur Einfügestelle gescrollt.
            guard let webView = firstWebView(in: root) else {
                finish(false, "(b) keine Markdown-Vorschau-WebView gefunden")
            }
            webView.evaluateJavaScript(
                "[document.images.length, window.scrollY]"
            ) { value, _ in
                let pair = value as? [Any]
                let images = pair?.first as? Int ?? 0
                let scrollY = (pair?.last as? Double) ?? Double(pair?.last as? Int ?? 0)
                if images >= 1, scrollY > 50 {
                    runMarkdownDropPhase(ws, tv: tv, base: base, outside: outside,
                                         storedImage: imageFile)
                    return
                }
                if tick >= maxTicks {
                    finish(false, "(b) Vorschau: images=\(images), scrollY=\(scrollY) nach 10 s")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    pollMarkdownPaste(ws, tv: tv, root: root, base: base,
                                      outside: outside, tick: tick + 1)
                }
            }
            return
        }
        if tick >= maxTicks {
            finish(false, "(b) nach 10 s: Datei=\(String(describing: imageFile)), "
                + "Link=\(linkInEditor)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollMarkdownPaste(ws, tv: tv, root: root, base: base,
                              outside: outside, tick: tick + 1)
        }
    }

    /// (c) Drop-Abgrenzung: eine Bilddatei + eine Textdatei „fallen" auf den
    /// Markdown-Editor — das Bild wird kopiert + verlinkt, der Text geöffnet.
    private static func runMarkdownDropPhase(_ ws: Workspace, tv: TextView,
                                             base: URL, outside: URL,
                                             storedImage: String) {
        let tabsBefore = ws.tabs.count
        MainActor.assumeIsolated {
            MarkdownAssist.handleDroppedFileURLs([
                outside.appendingPathComponent("quelle.png"),
                outside.appendingPathComponent("begleit.txt"),
            ], workspace: ws)
        }
        pollMarkdownDrop(ws, tv: tv, base: base, outside: outside,
                         tabsBefore: tabsBefore, tick: 0)
    }

    private static func pollMarkdownDrop(_ ws: Workspace, tv: TextView, base: URL,
                                         outside: URL, tabsBefore: Int, tick: Int) {
        let maxTicks = 40
        let copied = FileManager.default.fileExists(
            atPath: base.appendingPathComponent("quelle.png").path)
        let linked = tv.string.contains("![quelle](quelle.png)")
        let opened = ws.tabs.contains { $0.title == "begleit.txt" }
        func cleanup() {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: outside)
        }
        if copied, linked, opened {
            cleanup()
            finish(true, "Toolbar layoutet, Bild-Paste legt Datei + relativen Link an, "
                + "Vorschau rendert + scrollt, Drop trennt einfügen/öffnen")
        }
        if tick >= maxTicks {
            cleanup()
            finish(false, "(c) nach 10 s: kopiert=\(copied), verlinkt=\(linked), "
                + "geöffnet=\(opened)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollMarkdownDrop(ws, tv: tv, base: base, outside: outside,
                             tabsBefore: tabsBefore, tick: tick + 1)
        }
    }

    private static func firstWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for sub in view.subviews {
            if let found = firstWebView(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Selbsttest help (Etappe 4 Wunschpaket 2026-07b)

    /// End-to-End-Prüfung der Hilfe:
    /// (a) Beide Sprachdateien laden aus dem GEPACKTEN Bundle.
    /// (b) Das Hilfe-Fenster rendert echte Überschriften (DOM-Beobachtung
    ///     in der WKWebView, analog zum `markdown`-Selbsttest).
    /// (c) „Hilfe öffnen bei Anker X“ scrollt real zum Abschnitt.
    /// (d) ⌘W bei vorderer Hilfe schließt nur dieses Fenster; mindestens
    ///     zwei Hintergrund-Dokument-Tabs bleiben exakt unverändert.
    private static func runHelpTest() {
        testLabel = "help"
        guard HelpContent.markdown(languageCode: "de") != nil,
              HelpContent.markdown(languageCode: "en") != nil,
              let workspace = Workspace.shared else {
            finish(false, "(a) Hilfe-Markdown (de/en) fehlt im gepackten Bundle")
        }
        while workspace.tabs.count < 2 { workspace.openNewTab() }
        let tabSnapshot = workspace.tabs.map { "\($0.id.uuidString)|\($0.content)" }
        MainActor.assumeIsolated { HelpWindow.show() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pollHelpRendered(workspace: workspace, tabSnapshot: tabSnapshot, tick: 0)
        }
    }

    private static func pollHelpRendered(workspace: Workspace, tabSnapshot: [String], tick: Int) {
        guard let webView = MainActor.assumeIsolated({ HelpWindow.currentWebView }) else {
            finish(false, "(b) Hilfe-Fenster ohne WebView")
        }
        webView.evaluateJavaScript("document.querySelectorAll('h2').length") { value, _ in
            let count = value as? Int ?? 0
            if count >= HelpSection.allCases.count {
                // (c) Anker-Sprung: Abschnitt weiter unten ansteuern.
                MainActor.assumeIsolated {
                    HelpWindow.show(anchor: HelpSection.encodings.anchor())
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    pollHelpAnchorScrolled(webView: webView, workspace: workspace,
                                           tabSnapshot: tabSnapshot, tick: 0)
                }
                return
            }
            if tick >= 40 {
                finish(false, "(b) nur \(count) gerenderte h2-Überschriften nach 10 s "
                    + "(erwartet ≥ \(HelpSection.allCases.count))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                pollHelpRendered(workspace: workspace, tabSnapshot: tabSnapshot, tick: tick + 1)
            }
        }
    }

    private static func pollHelpAnchorScrolled(webView: WKWebView, workspace: Workspace,
                                               tabSnapshot: [String], tick: Int) {
        webView.evaluateJavaScript("window.scrollY") { value, _ in
            let y = (value as? Double) ?? Double(value as? Int ?? 0)
            if y > 50 {
                guard let helpWindow = NSApp.windows.first(where: HelpWindow.isHelpWindow) else {
                    finish(false, "(d) Hilfe-Fenster für ⌘W nicht auffindbar")
                }
                helpWindow.makeKeyAndOrderFront(nil)
                pollHelpKeyThenClose(helpWindow, workspace: workspace,
                                     tabSnapshot: tabSnapshot, anchorY: y)
                return
            }
            if tick >= 20 {
                finish(false, "(c) Anker-Sprung scrollt nicht (scrollY=\(y))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                pollHelpAnchorScrolled(webView: webView, workspace: workspace,
                                       tabSnapshot: tabSnapshot, tick: tick + 1)
            }
        }
    }

    private static func pollHelpKeyThenClose(_ helpWindow: NSWindow, workspace: Workspace,
                                             tabSnapshot: [String], anchorY: Double,
                                             tick: Int = 0) {
        if helpWindow.isKeyWindow {
            postCmd("w", keyCode: 13, windowNumber: helpWindow.windowNumber)
            pollHelpClosed(helpWindow, workspace: workspace, tabSnapshot: tabSnapshot,
                            anchorY: anchorY)
            return
        }
        if tick >= 100 {
            finish(false, "Umgebungsproblem: Hilfe-Fenster wurde nicht "
                + "Key-Window für ⌘W")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollHelpKeyThenClose(helpWindow, workspace: workspace, tabSnapshot: tabSnapshot,
                                 anchorY: anchorY, tick: tick + 1)
        }
    }

    private static func pollHelpClosed(_ helpWindow: NSWindow, workspace: Workspace,
                                       tabSnapshot: [String], anchorY: Double,
                                       tick: Int = 0) {
        let currentTabs = workspace.tabs.map { "\($0.id.uuidString)|\($0.content)" }
        if !helpWindow.isVisible {
            guard currentTabs == tabSnapshot, workspace.tabs.count >= 2 else {
                finish(false, "(d) ⌘W an der Hilfe veränderte einen Hintergrund-Tab")
            }
            finish(true, "Hilfe aus dem Bundle gerendert "
                + "(\(HelpSection.allCases.count)+ Abschnitte), Anker-Sprung (y=\(Int(anchorY))); "
                + "⌘W schließt nur die Hilfe, zwei Dokument-Tabs bleiben erhalten")
        }
        if tick >= 100 {
            finish(false, "(d) ⌘W ließ das vordere Hilfe-Fenster offen")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollHelpClosed(helpWindow, workspace: workspace, tabSnapshot: tabSnapshot,
                            anchorY: anchorY, tick: tick + 1)
        }
    }

    // MARK: - Selbsttest searchmark (Etappe 2 Wunschpaket 2026-07b)

    /// Zählt die Emphasis-Layer der Live-Trefferanzeige in der Editor-
    /// TextView — ECHTE Beobachtung des gerenderten Layer-Baums (analog
    /// `highlight`, das echte Vordergrundfarben beobachtet). Unsere Layer
    /// sind CAShapeLayer im Outline-Stil: Border 0,5 pt UND Füllfarbe.
    private static func searchEmphasisLayerCount(in tv: TextView) -> Int {
        (tv.layer?.sublayers ?? []).filter { layer in
            guard let shape = layer as? CAShapeLayer else { return false }
            return shape.fillColor != nil && abs(shape.borderWidth - 0.5) < 0.01
        }.count
    }

    /// Liegt mindestens ein Emphasis-Layer im sichtbaren Ausschnitt der
    /// TextView? Nach einem Sprung ans Dokumentende beweist das, dass der
    /// Scroll-Relay die Anzeige für neu ausgelegte Zeilen nachzeichnet.
    private static func searchEmphasisVisible(in tv: TextView) -> Bool {
        let visible = tv.visibleRect
        return (tv.layer?.sublayers ?? []).contains { layer in
            guard let shape = layer as? CAShapeLayer,
                  shape.fillColor != nil,
                  abs(shape.borderWidth - 0.5) < 0.01 else { return false }
            return visible.intersects(shape.frame)
        }
    }

    /// End-to-End-Prüfung der Live-Trefferanzeige (Etappe 2):
    /// (a) 120 Treffer im Datei-Scope → Emphasis-Layer real in der TextView
    ///     (nur der AUSGELEGTE Bereich bekommt Layer, daher > 0 und ≤ 120),
    ///     Tab bleibt sauber (reine Anzeige, kein Dirty).
    /// (b) Navigation ans Listenende → die NSTableView der Trefferliste
    ///     scrollt real mit UND der Editor zeigt am Sprungziel markierte
    ///     Treffer (Scroll-Relay zeichnet neu ausgelegte Zeilen nach).
    /// (c) Dialog schließen → alle Emphasis-Layer sind geräumt.
    private static func runSearchMarkTest() {
        testLabel = "searchmark"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }
        // 120 Zeilen mit je einem Treffer — genug, damit die Trefferliste
        // scrollen MUSS und die Layer-Zahl aussagekräftig ist.
        let content = (1...120).map { "zeile \($0) MARKTREFFER ende" }
            .joined(separator: "\n")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-searchmark-\(UUID().uuidString).txt")
        do { try content.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let tvView = editorTextView(in: root), let tv = tvView as? TextView else {
                    finish(false, "Editor-TextView nicht erreichbar")
                }
                ws.scope = .file
                ws.useRegex = false
                ws.caseSensitive = true
                ws.findPattern = "MARKTREFFER"
                pollSearchMarkDrawn(ws, tv: tv, tick: 0)
            }
        }
    }

    private static func pollSearchMarkDrawn(_ ws: Workspace, tv: TextView, tick: Int) {
        let maxTicks = 100   // 100 × 50 ms = 5 s (Debounce + async-Zeichnung)
        let layers = searchEmphasisLayerCount(in: tv)
        if !ws.bufferSearching, ws.bufferMatches.count == 120,
           layers > 0, layers <= 120, searchEmphasisVisible(in: tv) {
            guard ws.activeTab?.isDirty == false else {
                finish(false, "(a) Live-Markierung machte den Tab dirty — sie muss reine Anzeige sein")
            }
            // (b) Navigation ans Ende: erst „erster Treffer", dann 110× weiter.
            NotificationCenter.default.post(name: .fastraGotoFirstMatch, object: nil)
            for _ in 0..<110 {
                NotificationCenter.default.post(name: .fastraGotoNextMatch, object: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                pollSearchMarkListScrolled(ws, tv: tv, tick: 0)
            }
            return
        }
        if tick >= maxTicks {
            finish(false, "(a) erwartet 120 Treffer + sichtbare Layer, "
                + "ist: matches=\(ws.bufferMatches.count), layer=\(layers), "
                + "sichtbar=\(searchEmphasisVisible(in: tv)), "
                + "searching=\(ws.bufferSearching)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollSearchMarkDrawn(ws, tv: tv, tick: tick + 1)
        }
    }

    private static func pollSearchMarkListScrolled(_ ws: Workspace, tv: TextView, tick: Int) {
        let maxTicks = 40    // 40 × 50 ms = 2 s
        guard let searchWin = NSApp.windows.first(where: {
            $0.frameAutosaveName == SearchWindow.frameAutosaveName && $0.isVisible
        }), let searchRoot = searchWin.contentView else {
            finish(false, "(b) keine sichtbare Suchmaske")
        }
        // Die SwiftUI-`List` ist NSTableView-backed — die erste sichtbare
        // Zeile verrät die echte Scroll-Position der Trefferliste.
        let table = firstTableView(in: searchRoot)
        let firstVisible = table.map { $0.rows(in: $0.visibleRect).location } ?? -1
        if ws.activeMatchIndex == 110, firstVisible > 40, searchEmphasisVisible(in: tv) {
            // (c) Dialog schließen → Markierung muss vollständig verschwinden.
            ws.showSearchDialog = false
            pollSearchMarkCleared(tv: tv, tick: 0)
            return
        }
        if tick >= maxTicks {
            finish(false, "(b) Trefferliste/Editor folgen nicht: "
                + "activeIndex=\(ws.activeMatchIndex), ersteSichtbareZeile=\(firstVisible), "
                + "editorMarkierungSichtbar=\(searchEmphasisVisible(in: tv))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollSearchMarkListScrolled(ws, tv: tv, tick: tick + 1)
        }
    }

    private static func pollSearchMarkCleared(tv: TextView, tick: Int) {
        let maxTicks = 40    // 2 s
        let layers = searchEmphasisLayerCount(in: tv)
        if layers == 0 {
            finish(true, "Treffer live markiert (Layer real beobachtet, auch nach "
                + "Sprung ans Ende), Liste scrollt zum aktiven Treffer, "
                + "Dialogschluss räumt alles")
        }
        if tick >= maxTicks {
            finish(false, "(c) nach Dialogschluss bleiben \(layers) Emphasis-Layer übrig")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollSearchMarkCleared(tv: tv, tick: tick + 1)
        }
    }

    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let found = firstTableView(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Selbsttest sidebarheader (Etappe 1 Wunschpaket 2026-07b)

    /// Sucht eine `SelfTestMarker`-NSView (per Accessibility-Identifier) im
    /// NSView-Baum des Fensters. SwiftUI erzeugt die Marker-View nur, wenn
    /// der zugehörige View wirklich layoutet wird — Existenz der Marker-View
    /// belegt also die echte Sichtbarkeitsbedingung.
    private static func markerViewExists(id: String, in view: NSView) -> Bool {
        if view.accessibilityIdentifier() == id { return true }
        return view.subviews.contains { markerViewExists(id: id, in: $0) }
    }

    /// Sichtbares Hauptfenster (nicht der Suchdialog) für AX-Prüfungen.
    private static func mainWindowForAXChecks() -> NSWindow? {
        NSApp.windows.first {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.isVisible && $0.contentView != nil
        }
    }

    /// Prüft im ECHTEN Fenster (Etappe 1 Wunschpaket 2026-07b):
    /// (a) Nach dem Projekt-Öffnen erscheint der gemeinsame Seitenleisten-
    ///     Kopf (`sidebarProjectHeader`) im Accessibility-Baum.
    /// (b) Der Ansichts-Umschalter (`viewModePicker`) liegt in der Fußzeile,
    ///     sobald die geladene Datei mehr als eine Ansicht bietet.
    /// (c) Für einen ungespeicherten Tab (nur Text-Ansicht) verschwindet der
    ///     Umschalter wieder.
    private static func runSidebarHeaderTest() {
        testLabel = "sidebarheader"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("fastra-sidebarheader-\(UUID().uuidString)")
        let project = base.appendingPathComponent("projekt")
        do {
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            try fm.createDirectory(at: base.appendingPathComponent("nachbar"),
                                   withIntermediateDirectories: true)
            try "KOPFTEST".write(to: project.appendingPathComponent("notiz.txt"),
                                 atomically: true, encoding: .utf8)
        } catch {
            finish(false, "(setup) Testprojekt nicht anlegbar: \(error.localizedDescription)")
        }
        ws.openProject(at: project)
        ws.loadFile(at: project.appendingPathComponent("notiz.txt")) { ok in
            guard ok else {
                try? fm.removeItem(at: base)
                finish(false, "(setup) notiz.txt lädt nicht")
            }
            pollSidebarHeader(ws, base: base, tick: 0)
        }
    }

    private static func pollSidebarHeader(_ ws: Workspace, base: URL, tick: Int) {
        let maxTicks = 40            // 40 × 0,25 s = 10 s Beobachtungsfenster
        let content = mainWindowForAXChecks()?.contentView
        let headerFound = content.map { markerViewExists(id: "sidebarProjectHeader", in: $0) } ?? false
        let pickerFound = content.map { markerViewExists(id: "viewModePickerMarker", in: $0) } ?? false
        if headerFound, pickerFound {
            // (c) Ungespeicherter Tab bietet nur die Text-Ansicht — der
            // Umschalter muss aus der Fußzeile verschwinden.
            ws.openNewTab()
            pollViewModePickerGone(base: base, tick: 0)
            return
        }
        if tick >= maxTicks {
            try? FileManager.default.removeItem(at: base)
            finish(false, "nach 10 s: Seitenleisten-Kopf=\(headerFound), "
                + "Fußzeilen-Umschalter=\(pickerFound)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollSidebarHeader(ws, base: base, tick: tick + 1)
        }
    }

    private static func pollViewModePickerGone(base: URL, tick: Int) {
        let maxTicks = 20            // 20 × 0,25 s = 5 s
        let content = mainWindowForAXChecks()?.contentView
        let pickerFound = content.map { markerViewExists(id: "viewModePickerMarker", in: $0) } ?? true
        if !pickerFound {
            try? FileManager.default.removeItem(at: base)
            finish(true, "Kopf + Fußzeilen-Umschalter real im Fenster layoutet; "
                + "Umschalter verschwindet für ungespeicherte Tabs")
        }
        if tick >= maxTicks {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Umschalter bleibt trotz ungespeicherten Tabs sichtbar")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollViewModePickerGone(base: base, tick: tick + 1)
        }
    }

    // MARK: - Selbsttest sidebarfilter (Etappe 3 Wunschpaket 2026-07c)

    /// Prüft den Dateinamens-Filter der Projekt-Seitenleiste im ECHTEN
    /// Fenster:
    /// (a) Ausgangslage: Datei der obersten Ebene gerendert, Datei im
    ///     EINGEKLAPPTEN Unterordner nicht.
    /// (b) Filter tippen (case-insensitiv) → Treffer-Datei erscheint samt
    ///     aufgeklapptem Elternordner, Nicht-Treffer verschwinden, der
    ///     Zähler „1 von 3 Dateien" ist real gerendert.
    /// (c) Filter leeren → voriger Aufklappzustand kehrt zurück (Unterordner
    ///     wieder zu, Nicht-Treffer wieder da).
    private static func runSidebarFilterTest() {
        testLabel = "sidebarfilter"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("fastra-sidebarfilter-\(UUID().uuidString)")
        let project = base.appendingPathComponent("projekt")
        do {
            try fm.createDirectory(at: project.appendingPathComponent("sub"),
                                   withIntermediateDirectories: true)
            try "A".write(to: project.appendingPathComponent("eins.txt"),
                          atomically: true, encoding: .utf8)
            try "B".write(to: project.appendingPathComponent("zwei.md"),
                          atomically: true, encoding: .utf8)
            try "C".write(to: project.appendingPathComponent("sub/drei-treffer.txt"),
                          atomically: true, encoding: .utf8)
        } catch {
            finish(false, "(setup) Testprojekt nicht anlegbar: \(error.localizedDescription)")
        }
        ws.openProject(at: project)
        pollSidebarFilterBaseline(ws, base: base, tick: 0)
    }

    private static func pollSidebarFilterBaseline(_ ws: Workspace, base: URL, tick: Int) {
        let maxTicks = 40            // 10 s
        // Die Marker-IDs enden auf die Filterphase („voll"/„gefiltert") —
        // gepoolte LazyVStack-Views alter Phasen stören die Prüfung so nie.
        let content = mainWindowForAXChecks()?.contentView
        let topLevelVisible = content.map {
            markerViewExists(id: "fileTreeRow-zwei.md-voll", in: $0)
        } ?? false
        let nestedHidden = content.map {
            !markerViewExists(id: "fileTreeRow-drei-treffer.txt-voll", in: $0)
        } ?? false
        if topLevelVisible, nestedHidden {
            // Groß geschrieben tippen — die Datei heißt klein „…-treffer…":
            // belegt die Case-Insensitivität am echten Baum.
            ws.fileTreeFilterQuery = "TREFFER"
            pollSidebarFilterFiltered(ws, base: base, tick: 0)
            return
        }
        if tick >= maxTicks {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Ausgangslage nach 10 s falsch: zwei.md sichtbar=\(topLevelVisible), "
                + "verschachtelte Datei verborgen=\(nestedHidden)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollSidebarFilterBaseline(ws, base: base, tick: tick + 1)
        }
    }

    private static func pollSidebarFilterFiltered(_ ws: Workspace, base: URL, tick: Int) {
        let maxTicks = 40            // 10 s (Debounce 150 ms + Scan)
        let content = mainWindowForAXChecks()?.contentView
        let matchVisible = content.map {
            markerViewExists(id: "fileTreeRow-drei-treffer.txt-gefiltert", in: $0)
        } ?? false
        let nonMatchHidden = content.map {
            !markerViewExists(id: "fileTreeRow-zwei.md-gefiltert", in: $0)
        } ?? false
        let counterVisible = content.map {
            markerViewExists(id: "sidebarFilterState-n1-m3", in: $0)
        } ?? false
        if matchVisible, nonMatchHidden, counterVisible {
            ws.fileTreeFilterQuery = ""
            pollSidebarFilterRestored(base: base, tick: 0)
            return
        }
        if tick >= maxTicks {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Filter „TREFFER\u{201C} nach 10 s: Treffer sichtbar=\(matchVisible), "
                + "Nicht-Treffer verborgen=\(nonMatchHidden), Zähler 1/3=\(counterVisible)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollSidebarFilterFiltered(ws, base: base, tick: tick + 1)
        }
    }

    private static func pollSidebarFilterRestored(base: URL, tick: Int) {
        let maxTicks = 20            // 5 s
        let content = mainWindowForAXChecks()?.contentView
        let nestedHiddenAgain = content.map {
            !markerViewExists(id: "fileTreeRow-drei-treffer.txt-voll", in: $0)
        } ?? false
        let topLevelBack = content.map {
            markerViewExists(id: "fileTreeRow-zwei.md-voll", in: $0)
        } ?? false
        if nestedHiddenAgain, topLevelBack {
            try? FileManager.default.removeItem(at: base)
            finish(true, "Filter blendet real gerenderte Zeilen ein/aus (case-insensitiv), "
                + "Zähler 1 von 3 gerendert, Aufklappzustand nach Leeren wiederhergestellt")
        }
        if tick >= maxTicks {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Nach Filter-Leeren: Unterordner wieder zu=\(nestedHiddenAgain), "
                + "zwei.md wieder da=\(topLevelBack)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollSidebarFilterRestored(base: base, tick: tick + 1)
        }
    }

    // MARK: - Selbsttests tool4d (Wunschpaket 2026-07c)

    /// Prüft den echten localhost-TCP-/LSP-Start gegen ein bereits lokal
    /// installiertes tool4d und eine ausdrücklich übergebene sichere
    /// Projektkopie. Ein `null`-Ergebnis reicht nicht: Der Test besteht nur
    /// bei einem echten LSP-Report. Fehlt tool4d oder die sichere Testkopie,
    /// meldet der Runner bewusst ein Umgebungsproblem statt einen grünen Skip.
    private static func runTool4DLSPIntegrationTest() {
        testLabel = "tool4dlsp"
        guard let tool = Tool4DAssist.installedTool() else {
            finish(false, "Umgebungsproblem: tool4d ist nicht installiert — Integrations-Selbsttest übersprungen")
        }
        let environment = ProcessInfo.processInfo.environment
        guard let rawRoot = environment["FASTRA_TOOL4D_TEST_PROJECT"],
              !rawRoot.isEmpty else {
            finish(false, "Umgebungsproblem: tool4d ist vorhanden, aber FASTRA_TOOL4D_TEST_PROJECT verweist auf keine sichere Projektkopie")
        }
        let root = URL(fileURLWithPath: rawRoot).canonicalFileURL
        guard Tool4DProjectLocator.projectFile(in: root) != nil else {
            finish(false, "Umgebungsproblem: FASTRA_TOOL4D_TEST_PROJECT enthält keine .4DProject-Datei")
        }
        let document: URL?
        if let rawDocument = environment["FASTRA_TOOL4D_TEST_DOCUMENT"], !rawDocument.isEmpty {
            let candidate = URL(fileURLWithPath: rawDocument).canonicalFileURL
            let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            document = candidate.path.hasPrefix(rootPrefix) ? candidate : nil
        } else {
            let methods = root.appendingPathComponent("Project/Sources/Methods", isDirectory: true)
            let files = try? FileManager.default.contentsOfDirectory(
                at: methods, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            // Die Auswahl bleibt für eine sichere Projektkopie reproduzierbar;
            // bei mehreren Methoden entscheidet nicht die zufällige Reihenfolge
            // des Dateisystems über den Integrations-Selbsttest.
            document = files?
                .filter { $0.pathExtension.lowercased() == "4dm" }
                .sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                        == .orderedAscending
                }
                .first
        }
        guard let document,
              let text = try? String(contentsOf: document, encoding: .utf8) else {
            finish(false, "Umgebungsproblem: sichere 4D-Testmethode fehlt oder ist nicht UTF-8 lesbar")
        }

        let validation = Tool4DLSPValidation()
        retainedTool4DValidation = validation
        validation.start(executable: tool.executableURL, workspaceRoot: root, documentURL: document,
                         text: text,
                         timeout: 6) { result in
            retainedTool4DValidation = nil
            switch result {
            case .success(let diagnostics):
                finish(true, "tool4d-LSP verbunden; Pull-Diagnosen empfangen (\(diagnostics.count))")
            case .failure(.noDiagnosticResult):
                finish(false, "tool4d-LSP lieferte nur null statt eines echten Diagnose-Reports")
            case .failure(let error):
                finish(false, "tool4d-LSP-Integration fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Selbsttest tool4dhint (Etappe 4 Wunschpaket 2026-07c)

    /// Prüft den 4D-Erst-Kontakt-Hinweis im ECHTEN Fenster:
    /// (a) Erste `.4dm`-Datei → Hinweis-Leiste erscheint.
    /// (b) Echter Klick auf „Einrichtung anzeigen" → Hilfe-Fenster öffnet
    ///     (Anker „4D & tool4d"), Leiste verschwindet, Flag gesetzt.
    /// (c) Zweite `.4dm`-Datei → Hinweis erscheint NICHT erneut
    ///     („einmal pro Nutzer"). Die Defaults sind die isolierte
    ///     Selbsttest-Suite — das echte Nutzer-Flag bleibt unberührt.
    private static func runTool4DHintTest() {
        testLabel = "tool4dhint"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard !Tool4DAssist.firstContactHintShown else {
            finish(false, "(setup) Flag ist in der frischen Selbsttest-Suite schon gesetzt")
        }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-tool4dhint-\(UUID().uuidString)")
        let first = base.appendingPathComponent("Methode.4dm")
        let second = base.appendingPathComponent("Andere.4dm")
        do {
            try FileManager.default.createDirectory(at: base,
                                                    withIntermediateDirectories: true)
            try "$x:=1".write(to: first, atomically: true, encoding: .utf8)
            try "$y:=2".write(to: second, atomically: true, encoding: .utf8)
        } catch {
            finish(false, "(setup) Fixtures nicht anlegbar: \(error.localizedDescription)")
        }
        ws.loadFile(at: first) { ok in
            guard ok else {
                try? FileManager.default.removeItem(at: base)
                finish(false, "(setup) Methode.4dm lädt nicht")
            }
            pollTool4DHintVisible(ws, base: base, second: second, tick: 0)
        }
    }

    private static func pollTool4DHintVisible(_ ws: Workspace, base: URL,
                                              second: URL, tick: Int) {
        let maxTicks = 40            // 10 s
        guard let window = mainWindowForAXChecks(), let content = window.contentView else {
            if tick >= maxTicks { finish(false, "kein Hauptfenster") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                pollTool4DHintVisible(ws, base: base, second: second, tick: tick + 1)
            }
            return
        }
        if let button = markerView(id: "tool4dHintHelpButton", in: content),
           markerViewExists(id: "tool4dHintBar", in: content) {
            // Echter Klick auf „Einrichtung anzeigen" (Down+Up durch die
            // Event-Pipeline; der 0×0-Marker sitzt in der Button-Mitte).
            let point = button.convert(NSPoint.zero, to: nil)
            let time = ProcessInfo.processInfo.systemUptime
            guard let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: time, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ), let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: time + 0.05, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0
            ) else {
                try? FileManager.default.removeItem(at: base)
                finish(false, "Maus-Events nicht baubar")
            }
            window.sendEvent(down)
            window.sendEvent(up)
            pollTool4DHelpOpened(ws, base: base, second: second, tick: 0)
            return
        }
        if tick >= maxTicks {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Hinweis-Leiste erscheint binnen 10 s nicht für Methode.4dm")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollTool4DHintVisible(ws, base: base, second: second, tick: tick + 1)
        }
    }

    private static func pollTool4DHelpOpened(_ ws: Workspace, base: URL,
                                             second: URL, tick: Int) {
        let maxTicks = 40            // 10 s
        let helpOpen = NSApp.windows.contains {
            $0.frameAutosaveName == "FastraHelpWindow" && $0.isVisible
        }
        let hintGone = mainWindowForAXChecks()?.contentView.map {
            !markerViewExists(id: "tool4dHintBar", in: $0)
        } ?? false
        if helpOpen, hintGone, Tool4DAssist.firstContactHintShown {
            // (c) Zweite 4D-Datei — der Hinweis darf NICHT wiederkommen.
            ws.loadFile(at: second) { ok in
                guard ok else {
                    try? FileManager.default.removeItem(at: base)
                    finish(false, "(setup) Andere.4dm lädt nicht")
                }
                // Negativ-Beweis mit fester Frist: nach 1,5 s immer noch weg.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let stillGone = mainWindowForAXChecks()?.contentView.map {
                        !markerViewExists(id: "tool4dHintBar", in: $0)
                    } ?? false
                    try? FileManager.default.removeItem(at: base)
                    finish(stillGone,
                           stillGone
                           ? "Hinweis erschien genau einmal; Klick öffnete die Hilfe "
                             + "(Anker 4D & tool4d); zweite 4D-Datei ohne erneuten Hinweis"
                           : "Hinweis erschien nach Quittierung erneut")
                }
            }
            return
        }
        if tick >= maxTicks {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Nach Klick: Hilfe offen=\(helpOpen), Leiste weg=\(hintGone), "
                + "Flag=\(Tool4DAssist.firstContactHintShown)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollTool4DHelpOpened(ws, base: base, second: second, tick: tick + 1)
        }
    }

    // MARK: - Selbsttest gototarget (Etappe 7 Wunschpaket 2026-07c)

    /// Prüft Alt-Doppelklick „Gehe zum Ziel" mit ECHTEN synthetischen
    /// Mausereignissen (über die App-Event-Queue, damit der lokale Monitor
    /// sie sieht):
    /// (a) 4D: Klick auf einen Methodennamen öffnet die Projektmethode.
    /// (b) Markdown: Klick auf einen relativen Link öffnet die Zieldatei.
    private static func runGoToTargetTest() {
        testLabel = "gototarget"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("fastra-gototarget-\(UUID().uuidString)")
        let methods = base.appendingPathComponent("Project/Sources/Methods")
        let caller = methods.appendingPathComponent("Aufrufer.4dm")
        let target = methods.appendingPathComponent("ZielMethode.4dm")
        let markdown = base.appendingPathComponent("start.md")
        let markdownTarget = base.appendingPathComponent("ziel-datei.md")
        do {
            try fm.createDirectory(at: methods, withIntermediateDirectories: true)
            try "ZielMethode($x)\n".write(to: caller, atomically: true,
                                          encoding: .utf8)
            try "$y:=1\n".write(to: target, atomically: true, encoding: .utf8)
            try "Siehe [Ziel](ziel-datei.md) hier.\n".write(
                to: markdown, atomically: true, encoding: .utf8)
            try "# Ziel\n".write(to: markdownTarget, atomically: true,
                                 encoding: .utf8)
        } catch {
            finish(false, "(setup) Fixtures nicht anlegbar: \(error.localizedDescription)")
        }
        ws.loadFile(at: caller) { ok in
            guard ok else {
                try? fm.removeItem(at: base)
                finish(false, "(setup) Aufrufer.4dm lädt nicht")
            }
            goToTargetClick(ws, base: base, needle: "ZielMethode",
                            expectedFile: "ZielMethode.4dm", tick: 0) {
                // (b) Markdown-Teil im Anschluss.
                ws.loadFile(at: markdown) { ok in
                    guard ok else {
                        try? fm.removeItem(at: base)
                        finish(false, "(setup) start.md lädt nicht")
                    }
                    goToTargetClick(ws, base: base, needle: "Ziel]",
                                    expectedFile: "ziel-datei.md", tick: 0) {
                        try? fm.removeItem(at: base)
                        finish(true, "Alt-Doppelklick öffnete real die 4D-Methode "
                            + "und das Markdown-Linkziel (echte Events über die Queue)")
                    }
                }
            }
        }
    }

    /// Wartet auf den Editor mit `needle` im Text, synthetisiert einen
    /// Alt-Doppelklick auf dessen erster Fundstelle und pollt, bis der
    /// aktive Tab `expectedFile` zeigt — dann `completion`.
    private static func goToTargetClick(_ ws: Workspace, base: URL,
                                        needle: String, expectedFile: String,
                                        tick: Int, completion: @escaping () -> Void) {
        let maxTicks = 40            // 10 s
        guard tick < maxTicks else {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Editor mit „\(needle)“ erscheint nicht binnen 10 s")
        }
        guard let window = mainWindowForAXChecks(),
              let content = window.contentView,
              let textView = editorTextView(in: content) as? TextView,
              textView.string.contains(needle) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                goToTargetClick(ws, base: base, needle: needle,
                                expectedFile: expectedFile, tick: tick + 1,
                                completion: completion)
            }
            return
        }
        let range = (textView.string as NSString).range(of: needle)
        guard let rect = textView.layoutManager.rectsFor(range:
            NSRange(location: range.location, length: 1)).first else {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Keine Layout-Position für „\(needle)“")
        }
        // Punkt in Fenster-Koordinaten; Events über die App-Queue posten,
        // damit der lokale Monitor (GoToTargetGesture) sie WIRKLICH sieht.
        let windowPoint = textView.convert(NSPoint(x: rect.midX, y: rect.midY),
                                           to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        for (clickCount, type) in [(1, NSEvent.EventType.leftMouseDown),
                                   (1, .leftMouseUp),
                                   (2, .leftMouseDown),
                                   (2, .leftMouseUp)] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: windowPoint, modifierFlags: [.option],
                timestamp: time, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clickCount, pressure: 1
            ) else {
                try? FileManager.default.removeItem(at: base)
                finish(false, "Maus-Events nicht baubar")
            }
            NSApp.postEvent(event, atStart: false)
        }
        pollGoToTargetResult(ws, base: base, expectedFile: expectedFile,
                             tick: 0, completion: completion)
    }

    private static func pollGoToTargetResult(_ ws: Workspace, base: URL,
                                             expectedFile: String, tick: Int,
                                             completion: @escaping () -> Void) {
        let maxTicks = 40            // 10 s
        if ws.activeTab?.url?.lastPathComponent == expectedFile {
            completion()
            return
        }
        if tick >= maxTicks {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Sprung nach „\(expectedFile)“ blieb aus "
                + "(aktiver Tab: \(ws.activeTab?.title ?? "?"))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollGoToTargetResult(ws, base: base, expectedFile: expectedFile,
                                 tick: tick + 1, completion: completion)
        }
    }

    // MARK: - Selbsttest filediff (Etappe 1 Wunschpaket 2026-07c)

    /// Liefert die Marker-NSView selbst (nicht nur ihre Existenz) — für
    /// Positionsermittlung beim synthetischen Klick.
    private static func markerView(id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews {
            if let found = markerView(id: id, in: sub) { return found }
        }
        return nil
    }

    /// Prüft den git-losen Datei-Vergleich im ECHTEN Fenster:
    /// (a) „Dateien vergleichen…" öffnet wirklich ein Sheet.
    /// (b) Zwei Fixture-Dateien mit drei bekannten Unterschieden rendern
    ///     einen Diff-Tab mit drei Blöcken (Marker `fileDiffState-b3-c-1`).
    /// (c) Ein ECHTER Mausklick auf den letzten Eintrag der Differenzen-
    ///     Liste wählt ihn aus (Marker `…-c2`) und scrollt den Diff dorthin
    ///     (Scrollposition ändert sich beobachtbar).
    private static func runFileDiffTest() {
        testLabel = "filediff"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        // ── Fixtures: identische Basis, drei gezielte Unterschiede ────────
        // Drei längere Blöcke statt bloß weit auseinanderliegender Einzelzeilen:
        // unveränderte Zwischenräume werden im Renderer eingeklappt und würden
        // allein deshalb keine Scrollstrecke garantieren. Die sichtbaren
        // Änderungszeilen selbst müssen höher als der Viewport sein.
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("fastra-filediff-\(UUID().uuidString)")
        var leftLines = (1...155).map { "zeile \($0)" }
        var rightLines = leftLines
        for index in 1..<31 {
            leftLines[index] = "alpha \(index) ALT"
            rightLines[index] = "alpha \(index) NEU"
        }
        leftLines.insert(
            contentsOf: (1...30).map { "nur-links \($0)" },
            at: 80
        )
        for offset in 0..<30 {
            leftLines[leftLines.count - 1 - offset] = "omega \(offset) ALT"
            rightLines[rightLines.count - 1 - offset] = "omega \(offset) NEU"
        }
        let leftURL = base.appendingPathComponent("links.txt")
        let rightURL = base.appendingPathComponent("rechts.txt")
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            try leftLines.joined(separator: "\n")
                .write(to: leftURL, atomically: true, encoding: .utf8)
            try rightLines.joined(separator: "\n")
                .write(to: rightURL, atomically: true, encoding: .utf8)
        } catch {
            finish(false, "(setup) Fixtures nicht anlegbar: \(error.localizedDescription)")
        }
        // ── (a) Dialog öffnen — erscheint ein echtes Sheet? ────────────────
        ws.showCompareFilesDialog = true
        pollFileDiffSheet(ws, base: base, left: leftURL, right: rightURL, tick: 0)
    }

    private static func pollFileDiffSheet(_ ws: Workspace, base: URL,
                                          left: URL, right: URL, tick: Int) {
        let maxTicks = 40            // 10 s
        if mainWindowForAXChecks()?.attachedSheet != nil {
            // Dialog ist real da — wieder schließen und den Vergleich über
            // denselben Pfad starten, den der „Vergleichen"-Button nimmt.
            ws.showCompareFilesDialog = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                ws.openFileDiffTab(request: FileDiffRequest(
                    left: .file(left), right: .file(right),
                    options: FileDiffOptions()
                ))
                pollFileDiffRendered(ws, base: base, tick: 0)
            }
            return
        }
        if tick >= maxTicks {
            try? FileManager.default.removeItem(at: base)
            finish(false, "„Dateien vergleichen…“-Sheet erscheint nicht binnen 10 s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollFileDiffSheet(ws, base: base, left: left, right: right, tick: tick + 1)
        }
    }

    private static func pollFileDiffRendered(_ ws: Workspace, base: URL, tick: Int) {
        let maxTicks = 40            // 10 s
        let content = mainWindowForAXChecks()?.contentView
        // Marker trägt Blockzahl + Auswahl: 3 Blöcke, Start beim ersten
        // Unterschied (wie der Git-Diff: „Unterschied 1 von 3").
        let rendered = content.map {
            markerViewExists(id: "diffState-b3-c0", in: $0)
        } ?? false
        if rendered {
            // Modell-Gegenprobe: der Tab hält wirklich 3 Differenz-Blöcke.
            guard let tab = ws.tabs.first(where: { $0.fileDiffRequest != nil }),
                  let result = tab.fileDiffDocument?.result,
                  result.blocks.count == 3 else {
                try? FileManager.default.removeItem(at: base)
                finish(false, "Marker gerendert, aber Modell hat nicht 3 Blöcke")
            }
            clickLastFileDiffListRow(ws, base: base)
            return
        }
        if tick >= maxTicks {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Diff-Tab rendert binnen 10 s keine 3 Unterschiede "
                + "(Marker diffState-b3-c0 fehlt)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollFileDiffRendered(ws, base: base, tick: tick + 1)
        }
    }

    /// Größte Scroll-View im Fenster = der Diff-Bereich (die Differenzen-
    /// Liste ist auf 132 pt Höhe fixiert, das Sheet ist zu).
    private static func largestScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView? = nil
        func walk(_ v: NSView) {
            if let scroll = v as? NSScrollView {
                if scroll.frame.height > (best?.frame.height ?? 0) { best = scroll }
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        return best
    }

    /// Echter Mausklick (Down+Up durch die Event-Pipeline) auf den letzten
    /// Eintrag der Differenzen-Liste — der 0×0-Marker sitzt in Zeilenmitte.
    private static func clickLastFileDiffListRow(_ ws: Workspace, base: URL) {
        guard let window = mainWindowForAXChecks(),
              let content = window.contentView,
              let marker = markerView(id: "diffListRow-2", in: content) else {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Listeneintrag „Block 2“ nicht im Fensterbaum gefunden")
        }
        let scrollBefore = largestScrollView(in: content)?
            .contentView.documentVisibleRect.origin.y ?? -1
        let point = marker.convert(NSPoint.zero, to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: time, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: time + 0.05, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0
        ) else {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Maus-Events nicht baubar")
        }
        window.sendEvent(down)
        window.sendEvent(up)
        pollFileDiffJumped(base: base, scrollBefore: scrollBefore, tick: 0)
    }

    private static func pollFileDiffJumped(base: URL, scrollBefore: CGFloat, tick: Int) {
        let maxTicks = 20            // 5 s (Scroll-Animation: 0,16 s)
        let content = mainWindowForAXChecks()?.contentView
        let selected = content.map {
            markerViewExists(id: "diffState-b3-c2", in: $0)
        } ?? false
        let scrollNow = content.flatMap { largestScrollView(in: $0) }?
            .contentView.documentVisibleRect.origin.y ?? scrollBefore
        if selected, scrollNow != scrollBefore {
            try? FileManager.default.removeItem(at: base)
            finish(true, "Sheet real geöffnet; 3 Unterschiede gerendert; Klick "
                + "auf Differenzen-Liste wählt Block 3 und scrollt den Diff "
                + "(\(Int(scrollBefore)) → \(Int(scrollNow)))")
        }
        if tick >= maxTicks {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Klick auf Differenzen-Liste: Auswahl=\(selected), "
                + "Scroll \(Int(scrollBefore)) → \(Int(scrollNow)) — Sprung fehlt")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pollFileDiffJumped(base: base, scrollBefore: scrollBefore, tick: tick + 1)
        }
    }

    private static func runProjectTest() {
        testLabel = "project"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }

        // ── Testprojekt im Temp-Ordner bauen: repo/.git + Dateien ─────────
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("fastra-selftest-project-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("repo")
        do {
            try fm.createDirectory(at: repo.appendingPathComponent(".git"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: repo.appendingPathComponent("sub"),
                                   withIntermediateDirectories: true)
            try "PROJEKTTEST-A".write(to: repo.appendingPathComponent("a.txt"),
                                      atomically: true, encoding: .utf8)
            try "PROJEKTTEST-B".write(to: repo.appendingPathComponent("sub/b.txt"),
                                      atomically: true, encoding: .utf8)
        } catch {
            finish(false, "(setup) Testprojekt nicht anlegbar: \(error)")
        }

        // ── (a) Willkommens-Bedingung ─────────────────────────────────────
        // Erststart-Demo-Tab (hat Inhalt) → Willkommen verborgen. Danach
        // Folgestart simulieren (ein leerer unbenannter Tab) → sichtbar.
        ws.tabs = [EditorTab(title: "contacts.md", path: "Demo", content: "Demo-Inhalt")]
        ws.activeTabID = ws.tabs[0].id
        if ws.isWelcomeScreen {
            finish(false, "(a) Willkommen sichtbar, obwohl der aktive Tab kein Willkommen-Tab ist")
        }
        ws.tabs = [EditorTab(title: Workspace.untitledBaseName,
                             path: "noch nicht gespeichert", isWelcome: true)]
        ws.activeTabID = ws.tabs[0].id
        ws.projectURL = nil
        guard ws.isWelcomeScreen else {
            finish(false, "(a) Willkommen verborgen trotz aktivem Willkommen-Tab")
        }

        // ── (b) Projekt öffnen ────────────────────────────────────────────
        // openProject/loadFile kanonisieren URLs (`/var` → `/private/var`,
        // via canonicalPathKey) — die Erwartungswerte entsprechend auch.
        let resolved = repo.canonicalFileURL
        ws.openProject(at: repo)
        guard ws.projectURL == resolved else {
            finish(false, "(b) projectURL=\(String(describing: ws.projectURL)) statt \(resolved.path)")
        }
        guard !ws.isWelcomeScreen else {
            finish(false, "(b) openProject hat den Willkommensbildschirm nicht geschlossen")
        }
        guard ws.recentProjects.first?.url.path == resolved.path else {
            finish(false, "(b) Projekt nicht oben in recentProjects: \(ws.recentProjects.map(\.path))")
        }

        // ── (c) Dateibaum-Ebene: Ordner zuerst, .git übersprungen ─────────
        let children = FileTree.children(of: repo)
        guard children.map(\.name) == ["sub", "a.txt"] else {
            finish(false, "(c) Dateibaum-Ebene falsch: \(children.map(\.name))")
        }

        // ── (d) Datei „aus dem Baum" laden + stille Repo-Erkennung ────────
        ws.loadFile(at: repo.appendingPathComponent("a.txt")) { ok in
            guard ok else {
                finish(false, "(d) loadFile scheiterte")
            }
            guard ws.activeTab?.content == "PROJEKTTEST-A" else {
                finish(false, "(d) Tab-Inhalt falsch: \(ws.activeTab?.content ?? "nil")")
            }
            // Der Tab muss die NORMALISIERTE URL tragen — sonst schlüge die
            // Aktiv-Markierung im Projektbaum fehl (Listing liefert
            // `/private/…`-Form).
            guard ws.activeTab?.url == resolved.appendingPathComponent("a.txt") else {
                finish(false, "(d) Tab-URL nicht normalisiert: \(ws.activeTab?.url?.path ?? "nil")")
            }
            // Die Repo-Erkennung in noteRecentFile darf KEIN Duplikat neben
            // dem openProject-Eintrag anlegen (gleiche Pfad-Normalisierung).
            let matches = ws.recentProjects.filter { $0.url.path == resolved.path }
            guard matches.count == 1, ws.recentProjects.first?.url.path == resolved.path else {
                finish(false, "(d) Projektliste falsch (Duplikat?): \(ws.recentProjects.map(\.path))")
            }

            // ── (e) Projekt-Scope mit gespeichertem Datei-Set ────────────
            // Die Projektwurzel enthält zwei Trefferdateien; „sub" wird
            // ausgeschlossen, daher darf nur a.txt im Ergebnis stehen.
            let set = ProjectFileSet(name: "Nur Quellen", paths: ["."])
            ws.projectSearchConfiguration = ProjectSearchConfiguration(
                fileSets: [set], activeSetID: set.id, fileTypeFilter: .knownText,
                excludePatternsText: "sub"
            )
            ws.scope = .project
            ws.findPattern = "PROJEKTTEST"
            ws.useRegex = false
            ws.runFolderSearchNow()
            pollProjectScope(ws, base: base, tick: 0)
        }
    }

    /// Stellt sicher, dass die Build-Verpackung die englischen SwiftUI- und
    /// Info.plist-Tabellen ins Haupt-App-Bundle kopiert. Ein Eintrag nur im
    /// SwiftPM-Modulbundle reicht für dynamische `L10n`-Texte, aber nicht für
    /// statische `Text("…")`-Schlüssel.
    private static func runLocalizationTest() {
        testLabel = "localization"
        guard let lproj = Bundle.main.url(forResource: "en", withExtension: "lproj"),
              let english = Bundle(url: lproj) else {
            finish(false, "englisches en.lproj fehlt im Haupt-App-Bundle")
        }
        let scope = english.localizedString(forKey: "Suchbereich",
                                            value: "Suchbereich", table: nil)
        let infoURL = lproj.appendingPathComponent("InfoPlist.strings")
        guard scope == "Search Scope", FileManager.default.fileExists(atPath: infoURL.path) else {
            finish(false, "Haupt-Bundle unvollständig: Suchbereich=\(scope), "
                + "InfoPlist=\(FileManager.default.fileExists(atPath: infoURL.path))")
        }
        guard L10n.string("Abbrechen", language: "en") == "Cancel" else {
            finish(false, "SwiftPM-Modulbundle löst Englisch nicht auf")
        }
        let markdownResources = ["katex.js", "highlight.js", "highlight.css", "mermaid.js"]
        guard markdownResources.allSatisfy({ MarkdownPreviewAssets.resource(named: $0) != nil }) else {
            finish(false, "lokale Markdown-Renderbibliotheken fehlen im gepackten Ressourcenbundle")
        }
        finish(true, "englische Tabellen + lokale Markdown-Renderbibliotheken im App-Bundle")
    }

    private static func pollProjectScope(_ ws: Workspace, base: URL, tick: Int) {
        if !ws.folderSearching, !ws.folderNeedsSearch {
            let urls = ws.folderResults.filter { !$0.matches.isEmpty }.map(\.url.lastPathComponent)
            guard ws.folderTotalMatches == 1, urls == ["a.txt"] else {
                finish(false, "(e) Projekt-Scope missachtet Datei-Set/Ausschluss: "
                    + "total=\(ws.folderTotalMatches), Dateien=\(urls)")
            }
            try? FileManager.default.removeItem(at: base)
            finish(true, "Willkommen, Projekt öffnen, Dateibaum, Datei-Laden, "
                + "Repo-Dedup + Projekt-Datei-Set/Ausschluss ok")
        }
        guard tick < 200 else {
            finish(false, "(e) Timeout der Projekt-Suche")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollProjectScope(ws, base: base, tick: tick + 1)
        }
    }

    // MARK: - Reale Projekt-Performance (nur explizit über Umgebungsvariable)

    private struct PerformanceResourceSnapshot {
        let userSeconds: Double
        let systemSeconds: Double
        let maximumRSSMiB: Double
    }

    private static func performanceResourceSnapshot() -> PerformanceResourceSnapshot {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return PerformanceResourceSnapshot(
                userSeconds: 0, systemSeconds: 0, maximumRSSMiB: 0
            )
        }
        func seconds(_ value: timeval) -> Double {
            Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
        return PerformanceResourceSnapshot(
            userSeconds: seconds(usage.ru_utime),
            systemSeconds: seconds(usage.ru_stime),
            // Auf Darwin ist ru_maxrss die maximale Resident-Menge in Bytes.
            maximumRSSMiB: Double(usage.ru_maxrss) / 1_048_576
        )
    }

    private static func projectPerformanceRoot() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["FASTRA_PROJECT_PERF_ROOT"],
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).canonicalFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return url
    }

    /// Ein Warm-up plus drei echte Läufe durch denselben FolderSearch-Pfad,
    /// den die Projekt-Suche verwendet. Dieser Diagnosemodus schreibt nichts
    /// ins übergebene Projekt und liegt absichtlich außerhalb von ALL_TESTS.
    private static func runProjectPerformanceTest() {
        testLabel = "projectperf"
        guard let root = projectPerformanceRoot() else {
            finish(false, "FASTRA_PROJECT_PERF_ROOT fehlt oder ist kein Ordner")
        }
        let exclusions = [".json", "userPreferences.*", "DerivedData"]
        let matcher = PathExclusion.Matcher(patterns: exclusions, relativeTo: root)
        let allFiles: [URL]
        let ripgrepFiltered: [URL]
        do {
            allFiles = try RipgrepFileEnumerator.files(in: root)
            ripgrepFiltered = try RipgrepFileEnumerator.files(
                in: root, excludedPatterns: exclusions
            )
        } catch {
            finish(false, "Kandidatenliste fehlgeschlagen: \(error)")
        }
        let candidates = ripgrepFiltered.filter { !matcher.matches($0) }
        let textCandidates = candidates.filter {
            FolderSearch.passesFilter(url: $0, filter: .knownText)
        }
        func hasDerivedData(_ url: URL) -> Bool {
            url.pathComponents.contains("DerivedData")
        }
        let jsonCount = allFiles.filter { $0.pathExtension == "json" }.count
        let preferencesCount = allFiles.filter {
            $0.pathComponents.contains {
                $0.hasPrefix("userPreferences.")
            }
        }.count
        let derivedDataCount = allFiles.filter(hasDerivedData).count
        let leakedJSON = candidates.contains { $0.pathExtension == "json" }
        let leakedPreferences = candidates.contains {
            $0.pathComponents.contains {
                $0.hasPrefix("userPreferences.")
            }
        }
        let leakedDerivedData = candidates.contains(where: hasDerivedData)
        guard !allFiles.isEmpty, candidates.count < allFiles.count,
              jsonCount > 0, preferencesCount > 0, derivedDataCount > 0,
              !leakedJSON, !leakedPreferences, !leakedDerivedData else {
            finish(false, "Ausschlussinventar fehlerhaft: alle=\(allFiles.count), "
                + "Kandidaten=\(candidates.count), json=\(jsonCount), "
                + "userPreferences=\(preferencesCount), DerivedData=\(derivedDataCount), "
                + "Leaks=\(leakedJSON)/\(leakedPreferences)/\(leakedDerivedData)")
        }

        let inventory = String(
            format: "PROJECTPERF inventory all=%d candidates=%d text_candidates=%d "
                + "search_filter=all "
                + "json_excluded=%d user_preferences_excluded=%d "
                + "derived_data_excluded=%d\n",
            allFiles.count, candidates.count, textCandidates.count, jsonCount,
            preferencesCount, derivedDataCount
        )
        FileHandle.standardError.write(Data(inventory.utf8))

        let options = SearchOptions(
            find: "util_*", replace: "", isRegex: false,
            caseSensitive: false, wholeWord: false,
            treatWildcardLiterally: false
        )
        let warmupError: String? = autoreleasepool {
            FolderSearch.find(
                in: [root], filter: .all, options: options,
                excludedPatterns: exclusions, relativeTo: root
            ).invalidPatternMessage
        }
        guard warmupError == nil else {
            finish(false, "Warm-up fehlgeschlagen: \(warmupError ?? "")")
        }

        var wallTimes: [Double] = []
        var lastMatches = 0
        for run in 1...3 {
            let measurement = autoreleasepool { () -> (
                wall: Double, matches: Int, capped: Bool, error: String?,
                userCPU: Double, systemCPU: Double, maximumRSSMiB: Double
            ) in
                let resourcesBefore = performanceResourceSnapshot()
                let started = ProcessInfo.processInfo.systemUptime
                let result = FolderSearch.find(
                    in: [root], filter: .all, options: options,
                    excludedPatterns: exclusions, relativeTo: root
                )
                let wall = ProcessInfo.processInfo.systemUptime - started
                let resourcesAfter = performanceResourceSnapshot()
                return (
                    wall, result.totalMatches, result.wasCapped,
                    result.invalidPatternMessage,
                    resourcesAfter.userSeconds - resourcesBefore.userSeconds,
                    resourcesAfter.systemSeconds - resourcesBefore.systemSeconds,
                    resourcesAfter.maximumRSSMiB
                )
            }
            guard measurement.error == nil else {
                finish(false, "Lauf \(run) fehlgeschlagen: "
                    + (measurement.error ?? "unbekannt"))
            }
            wallTimes.append(measurement.wall)
            lastMatches = measurement.matches
            let line = String(
                format: "PROJECTPERF run=%d candidates=%d matches=%d capped=%@ "
                    + "wall_s=%.4f user_cpu_s=%.4f system_cpu_s=%.4f "
                    + "max_rss_mib=%.1f\n",
                run, candidates.count, measurement.matches,
                measurement.capped ? "yes" : "no", measurement.wall,
                measurement.userCPU, measurement.systemCPU,
                measurement.maximumRSSMiB
            )
            FileHandle.standardError.write(Data(line.utf8))
        }
        let median = wallTimes.sorted()[1]
        guard median < 1.5 else {
            finish(false, String(
                format: "Median %.4f s verfehlt Ziel <1,5 s "
                    + "(Kandidaten=%d, Treffer=%d)",
                median, candidates.count, lastMatches
            ))
        }
        finish(true, String(
            format: "3 warme Realprojekt-Läufe, Median %.4f s (<1,5 s), "
                + "%d Kandidaten, %d Treffer; Ausschlüsse leakfrei",
            median, candidates.count, lastMatches
        ))
    }

    /// Misst `folders.json` unabhängig vom Suchlauf vom Workspace-Aufruf bis
    /// zum tatsächlich montierten Editor-Text. Ein schneller Befund belegt,
    /// dass die beobachtete Wartezeit aus dem Suchscan statt aus FileLoader/
    /// Editor stammt; nur eine eigenständig langsame Messung rechtfertigt hier
    /// einen zusätzlichen Ladepfad-Fix.
    private static func runProjectOpenPerformanceTest() {
        testLabel = "projectopenperf"
        guard let ws = Workspace.shared,
              let root = projectPerformanceRoot(),
              let mainWindow = NSApp.windows.first(where: {
                  $0.frameAutosaveName != SearchWindow.frameAutosaveName
                      && $0.contentView != nil && $0.isVisible
              }),
              let view = mainWindow.contentView else {
            finish(false, "Workspace, Fenster oder FASTRA_PROJECT_PERF_ROOT fehlt")
        }
        let file = root.appendingPathComponent("Project/Sources/folders.json")
            .canonicalFileURL
        guard let expected = try? String(contentsOf: file, encoding: .utf8) else {
            finish(false, "Project/Sources/folders.json ist nicht UTF-8-lesbar")
        }

        ws.openProject(at: root)
        let resourcesBefore = performanceResourceSnapshot()
        let started = ProcessInfo.processInfo.systemUptime
        ws.loadFile(at: file) { ok in
            let callbackSeconds = ProcessInfo.processInfo.systemUptime - started
            guard ok else {
                ws.closeProject()
                finish(false, "Workspace.loadFile meldete Fehler")
            }
            pollProjectOpenPerformance(
                ws: ws, root: view, expected: expected, file: file,
                started: started, callbackSeconds: callbackSeconds,
                resourcesBefore: resourcesBefore, tick: 0
            )
        }
    }

    private static func pollProjectOpenPerformance(
        ws: Workspace,
        root: NSView,
        expected: String,
        file: URL,
        started: TimeInterval,
        callbackSeconds: TimeInterval,
        resourcesBefore: PerformanceResourceSnapshot,
        tick: Int
    ) {
        if ws.activeTab?.url == file, ws.activeTab?.isLoading == false,
           let textView = editorTextView(in: root) as? TextView,
           textView.string == expected {
            let renderedSeconds = ProcessInfo.processInfo.systemUptime - started
            let resourcesAfter = performanceResourceSnapshot()
            let line = String(
                format: "PROJECTOPEN file_bytes=%d load_callback_s=%.4f "
                    + "editor_rendered_s=%.4f user_cpu_s=%.4f "
                    + "system_cpu_s=%.4f max_rss_mib=%.1f\n",
                expected.utf8.count, callbackSeconds, renderedSeconds,
                resourcesAfter.userSeconds - resourcesBefore.userSeconds,
                resourcesAfter.systemSeconds - resourcesBefore.systemSeconds,
                resourcesAfter.maximumRSSMiB
            )
            FileHandle.standardError.write(Data(line.utf8))
            ws.closeProject()
            guard renderedSeconds < 1.5 else {
                finish(false, String(
                    format: "folders.json brauchte bis zum Editor %.4f s", renderedSeconds
                ))
            }
            finish(true, String(
                format: "folders.json separat: Load %.4f s, Editor %.4f s (<1,5 s)",
                callbackSeconds, renderedSeconds
            ))
        }
        if tick >= 200 {
            ws.closeProject()
            finish(false, "folders.json nach 5 s nicht im Editor montiert")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            pollProjectOpenPerformance(
                ws: ws, root: root, expected: expected, file: file,
                started: started, callbackSeconds: callbackSeconds,
                resourcesBefore: resourcesBefore, tick: tick + 1
            )
        }
    }

    /// Fensterlos — Git-Status end-to-end (Projekt- & Git-Ausbau, Etappe 2):
    /// echtes Temp-Repo via `git init`, Datei-Zustände (untracked/modified/
    /// staged), Branch-Anzeige, Ordner-Rollup und die dialogfreie git-Auflösung.
    /// Braucht ein installiertes git — sonst ausgewiesener SKIP (kein FAIL).
    private static func runGitTest() {
        testLabel = "git"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        guard GitRunner.isAvailable else {
            // Genau der „git fehlt"-Pfad: keine Git-Anzeige. Als PASS werten,
            // weil das gewünschte Verhalten ist (still weg) — aber sichtbar
            // machen, dass der echte Repo-Teil übersprungen wurde.
            finish(true, "git nicht verfügbar — Git-UI bleibt still weg (erwartetes Verhalten)")
        }

        let fm = FileManager.default
        let repo = fm.temporaryDirectory
            .appendingPathComponent("fastra-selftest-git-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: repo.appendingPathComponent("sub"),
                                   withIntermediateDirectories: true)
            try "eins\nzwei\n".write(to: repo.appendingPathComponent("tracked.txt"),
                                     atomically: true, encoding: .utf8)
            try "tief".write(to: repo.appendingPathComponent("sub/deep.txt"),
                             atomically: true, encoding: .utf8)
        } catch {
            finish(false, "(setup) Temp-Repo nicht anlegbar: \(error)")
        }

        // git init + Erst-Commit über GitRunner selbst (seriell verkettet).
        // -c-Flags: deterministischer Branch-Name + lokale Identität, damit
        // der Test unabhängig von der globalen git-Config läuft.
        let initArgs = ["-c", "init.defaultBranch=main", "init"]
        GitRunner.run(initArgs, in: repo) { r0 in
            guard let r0, r0.ok else { finish(false, "(init) \(r0?.stderr ?? "nil")") }
            GitRunner.run(["-c", "user.email=t@t", "-c", "user.name=T", "add", "tracked.txt", "sub/deep.txt"], in: repo) { r1 in
                guard let r1, r1.ok else { finish(false, "(add) \(r1?.stderr ?? "nil")") }
                GitRunner.run(["-c", "user.email=t@t", "-c", "user.name=T", "commit", "-m", "init"], in: repo) { r2 in
                    guard let r2, r2.ok else { finish(false, "(commit) \(r2?.stderr ?? "nil")") }
                    // Jetzt Änderungen erzeugen: tracked ändern, sub/deep ändern,
                    // eine neue Datei anlegen (untracked).
                    do {
                        try "eins\nzwei GEÄNDERT\n".write(to: repo.appendingPathComponent("tracked.txt"),
                                                          atomically: true, encoding: .utf8)
                        try "tief geändert".write(to: repo.appendingPathComponent("sub/deep.txt"),
                                                  atomically: true, encoding: .utf8)
                        try "neu".write(to: repo.appendingPathComponent("neu.txt"),
                                        atomically: true, encoding: .utf8)
                    } catch {
                        finish(false, "(mutate) \(error)")
                    }
                    ws.openProject(at: repo)
                    pollGitStatus(ws, repo: repo, fm: fm)
                }
            }
        }
    }

    /// Pollt, bis `refreshGitStatus` (asynchron) den erwarteten Zustand liefert,
    /// prüft dann Branch, Datei-Zustände, gitState/gitFolderHasChanges-Helfer.
    private static func pollGitStatus(_ ws: Workspace, repo: URL, fm: FileManager, tick: Int = 0) {
        let maxTicks = 100   // 100 × 30 ms ≈ 3 s
        if let status = ws.gitStatus,
           status.entries["tracked.txt"] == .modified,
           status.entries["neu.txt"] == .untracked,
           status.entries["sub/deep.txt"] == .modified {
            guard status.branch == "main" else {
                finish(false, "(status) Branch=\(status.branch ?? "nil") statt main")
            }
            // URL-basierte Helfer (Seitenleisten-Einfärbung).
            let resolved = repo.canonicalFileURL
            guard ws.gitState(for: resolved.appendingPathComponent("tracked.txt")) == .modified else {
                finish(false, "(helper) gitState(tracked) falsch")
            }
            guard ws.gitState(for: resolved.appendingPathComponent("nichtda.txt")) == nil else {
                finish(false, "(helper) gitState für unveränderte Datei nicht nil")
            }
            guard ws.gitFolderHasChanges(resolved.appendingPathComponent("sub")) else {
                finish(false, "(helper) gitFolderHasChanges(sub) sollte true sein")
            }
            // Weiter mit Schritt 2+3: Verlauf + Diff als read-only-Tabs.
            ws.openGitLog()
            pollGitLog(ws, repo: repo, fm: fm)
            return
        }
        if tick >= maxTicks {
            try? fm.removeItem(at: repo)
            finish(false, "(status) Timeout — gitStatus=\(String(describing: ws.gitStatus))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollGitStatus(ws, repo: repo, fm: fm, tick: tick + 1)
        }
    }

    /// Wartet auf den Verlaufs-Tab (git log), extrahiert einen Commit-Hash und
    /// öffnet ihn per `openGitCommit` (git show), dann weiter zum Diff.
    private static func pollGitLog(_ ws: Workspace, repo: URL, fm: FileManager, tick: Int = 0) {
        let maxTicks = 100
        if let tab = ws.tabs.first(where: { $0.gitKind == .log }), !tab.content.isEmpty {
            // Der Log-Tab muss aktiv und read-only sein; sein Inhalt muss den
            // Init-Commit enthalten und einen klickbaren Hash liefern.
            guard ws.activeTab?.id == tab.id else {
                finish(false, "(log) Verlaufs-Tab nicht aktiv")
            }
            let hash = tab.content
                .split(separator: "\n")
                .compactMap { GitLog.commitHash(inLine: String($0)) }
                .first
            guard let hash else {
                finish(false, "(log) kein Commit-Hash im Verlauf: \(tab.content.prefix(80))")
            }
            ws.openGitCommit(hash: hash)
            pollGitCommit(ws, repo: repo, fm: fm, hash: hash)
            return
        }
        if tick >= maxTicks { try? fm.removeItem(at: repo); finish(false, "(log) Timeout") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollGitLog(ws, repo: repo, fm: fm, tick: tick + 1)
        }
    }

    /// Wartet auf den Commit-Tab (git show) und prüft, dass er den Diff enthält.
    private static func pollGitCommit(_ ws: Workspace, repo: URL, fm: FileManager, hash: String, tick: Int = 0) {
        let maxTicks = 100
        if let tab = ws.tabs.first(where: { $0.gitKind == .commit }), !tab.content.isEmpty {
            guard tab.content.contains("commit \(hash)") || tab.content.contains(hash) else {
                finish(false, "(commit) git show ohne passenden Hash")
            }
            ws.openGitDiff()
            pollGitDiff(ws, repo: repo, fm: fm)
            return
        }
        if tick >= maxTicks { try? fm.removeItem(at: repo); finish(false, "(commit) Timeout") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollGitCommit(ws, repo: repo, fm: fm, hash: hash, tick: tick + 1)
        }
    }

    /// Wartet auf den Diff-Tab (git diff HEAD) und prüft, dass die Änderung an
    /// tracked.txt drinsteht — plus die Dedup-Garantie (kein zweiter Diff-Tab).
    private static func pollGitDiff(_ ws: Workspace, repo: URL, fm: FileManager, tick: Int = 0) {
        let maxTicks = 100
        if let tab = ws.tabs.first(where: { $0.gitKind == .diff }), !tab.content.isEmpty {
            guard tab.content.contains("tracked.txt"), tab.content.contains("GEÄNDERT") else {
                finish(false, "(diff) Änderung fehlt: \(tab.content.prefix(120))")
            }
            // Dedup: nochmal öffnen darf keinen zweiten Diff-Tab erzeugen.
            let before = ws.tabs.filter { $0.gitKind == .diff }.count
            ws.openGitDiff()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let after = ws.tabs.filter { $0.gitKind == .diff }.count
                try? fm.removeItem(at: repo)
                guard before == 1, after == 1 else {
                    finish(false, "(diff) Dedup verletzt: \(before) → \(after)")
                }
                finish(true, "Status + Verlauf (klickbarer Hash → git show) + Diff (gefärbt, "
                    + "dedupliziert) ok")
            }
            return
        }
        if tick >= maxTicks { try? fm.removeItem(at: repo); finish(false, "(diff) Timeout") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollGitDiff(ws, repo: repo, fm: fm, tick: tick + 1)
        }
    }

    // MARK: - Selbsttest: Git-Aktionen (Etappe 2, Schritt 4)

    /// Führt eine Kette von git-Kommandos seriell aus (Setup-Helfer). Bricht bei
    /// erstem Fehler ab und meldet ihn über den Completion (`false`, Fehlertext).
    private static func runGitSequence(_ cmds: [[String]], in dir: URL,
                                       _ completion: @escaping (Bool, String) -> Void) {
        guard let first = cmds.first else { completion(true, ""); return }
        GitRunner.run(first, in: dir) { r in
            guard let r, r.ok else {
                completion(false, "\(first.joined(separator: " ")): \(r?.stderr ?? "nil")")
                return
            }
            runGitSequence(Array(cmds.dropFirst()), in: dir, completion)
        }
    }

    /// Reproduziert den gemeldeten realen Bedienfall: `git status` fasst einen
    /// vollständig unversionierten Ordner als `material/` zusammen. Der echte
    /// Plus-Knopf dieser SwiftUI-Zeile muss den Ordnerinhalt stagen; der
    /// umgebende Ein-/Doppelklickpfad darf den Ordner nicht als Datei öffnen.
    private static func runGitStageFolderTest() {
        testLabel = "gitstagefolder"
        guard ProcessInfo.processInfo.environment["FASTRA_SIDEBAR"] == "changes" else {
            finish(false, "Launch-Fixture FASTRA_SIDEBAR=changes fehlt")
        }
        guard let ws = Workspace.shared else { finish(false, "Workspace.shared ist nil") }
        guard GitRunner.isAvailable else {
            finish(true, "git nicht verfügbar — Git-Ansicht bleibt erwartungsgemäß verborgen")
        }
        Workspace.presentGitDialogs = false

        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("fastra-gitstagefolder-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("working-copy")
        do {
            try fm.createDirectory(at: repo, withIntermediateDirectories: true)
            try "Basis\n".write(to: repo.appendingPathComponent("README.md"),
                                atomically: true, encoding: .utf8)
        } catch {
            finish(false, "(setup) \(error.localizedDescription)")
        }

        let setup: [[String]] = [
            ["init", "-b", "main"],
            ["config", "user.email", "t@t"],
            ["config", "user.name", "T"],
            ["config", "status.showUntrackedFiles", "normal"],
            ["add", "--", "README.md"],
            ["commit", "-m", "init"],
        ]
        runGitSequence(setup, in: repo) { ok, error in
            guard ok else {
                try? fm.removeItem(at: base)
                finish(false, "(setup git) \(error)")
            }
            let material = repo.appendingPathComponent("material", isDirectory: true)
            do {
                try fm.createDirectory(at: material, withIntermediateDirectories: true)
                try "Notizen\n".write(to: material.appendingPathComponent("chat.txt"),
                                      atomically: true, encoding: .utf8)
                try Data("Bilddaten".utf8).write(
                    to: material.appendingPathComponent("portrait.jpg"))
            } catch {
                try? fm.removeItem(at: base)
                finish(false, "(material setup) \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                ws.openProject(at: repo)
                pollGitStageFolderRow(ws, base: base, repo: repo,
                                      material: material, tick: 0)
            }
        }
    }

    /// Wartet auf die wirklich gerenderte, zusammengefasste `material/`-Zeile
    /// und klickt deren Plus über AppKits Fenster-Hit-Testing.
    private static func pollGitStageFolderRow(_ ws: Workspace, base: URL,
                                              repo: URL, material: URL,
                                              tick: Int) {
        let maxTicks = 100
        guard let change = ws.gitStatus?.unstagedChanges.first(where: {
            $0.path == "material/" && $0.unstaged == .untracked
        }), let window = mainWindowForAXChecks(), let content = window.contentView else {
            if tick >= maxTicks {
                try? FileManager.default.removeItem(at: base)
                let shown = ws.gitStatus?.unstagedChanges.map(\.path) ?? []
                finish(false, "zusammengefasste Ordnerzeile material/ fehlt "
                    + "(sichtbar: \(shown))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pollGitStageFolderRow(ws, base: base, repo: repo,
                                      material: material, tick: tick + 1)
            }
            return
        }

        let stageMarkerID = "gitStageAction-\(change.rawPath.hashValue)"
        let discardMarkerID = "gitDiscardAction-\(change.rawPath.hashValue)"
        guard let stageMarker = markerView(id: stageMarkerID, in: content),
              let discardMarker = markerView(id: discardMarkerID, in: content) else {
            if tick >= maxTicks {
                try? FileManager.default.removeItem(at: base)
                finish(false, "Hover-Knöpfe der material/-Zeile fehlen im AppKit-Baum")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pollGitStageFolderRow(ws, base: base, repo: repo,
                                      material: material, tick: tick + 1)
            }
            return
        }
        window.layoutIfNeeded()
        guard stageMarker.bounds.width > 0, stageMarker.bounds.height > 0,
              discardMarker.bounds.width > 0, discardMarker.bounds.height > 0 else {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Hover-Knöpfe besitzen keinen klickbaren Bereich")
        }
        let stageFrame = stageMarker.convert(stageMarker.bounds, to: content)
        let discardFrame = discardMarker.convert(discardMarker.bounds, to: content)
        guard discardFrame.maxX <= stageFrame.minX else {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Verwerfen und Plus liegen noch übereinander "
                + "(Verwerfen: \(discardFrame), Plus: \(stageFrame))")
        }
        let point = stageMarker.convert(
            NSPoint(x: stageMarker.bounds.midX, y: stageMarker.bounds.midY),
            to: nil
        )
        guard sendMouseClick(at: point, in: window, modifiers: []) else {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Mausklick auf Plus nicht erzeugbar")
        }
        pollGitStageFolderResult(ws, base: base, repo: repo,
                                 material: material, tick: 0)
    }

    /// Prüft gegen Gits echten Index. Parallel bleibt der Workspace unter
    /// Beobachtung: Öffnet die Zeilengeste `material/` als Datei, erscheint
    /// synchron ein Lade-Tab — genau der vom Nutzer gehörte Warnton-Pfad.
    private static func pollGitStageFolderResult(_ ws: Workspace, base: URL,
                                                 repo: URL, material: URL,
                                                 tick: Int) {
        if !FileManager.default.fileExists(atPath: material.path) {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Plus-Klick traf stattdessen die überlagerte "
                + "Verwerfen-Aktion und löschte das temporäre material/")
        }
        if ws.tabs.contains(where: {
            $0.url?.standardizedFileURL == material.standardizedFileURL
        }) {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Plus-Klick wurde von der Zeilengeste abgefangen "
                + "und versuchte material/ als Datei zu öffnen")
        }
        GitRunner.run(["diff", "--cached", "--name-only", "-z"], in: repo) { result in
            let names = result?.stdoutData.split(separator: 0).map {
                String(decoding: $0, as: UTF8.self)
            } ?? []
            let expected = Set(["material/chat.txt", "material/portrait.jpg"])
            if result?.ok == true, Set(names) == expected {
                try? FileManager.default.removeItem(at: base)
                finish(true, "Verwerfen und Plus liegen getrennt nebeneinander; "
                    + "echter Plus-Klick staged die zusammengefasste Ordnerzeile "
                    + "material/ vollständig, ohne sie als Datei zu öffnen")
            }
            if tick >= 100 {
                try? FileManager.default.removeItem(at: base)
                finish(false, "Plus-Klick staged material/ nicht "
                    + "(Index: \(names), git: \(result?.stderr ?? "nil"))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pollGitStageFolderResult(ws, base: base, repo: repo,
                                         material: material, tick: tick + 1)
            }
        }
    }

    /// Reproduziert den echten Erst-Push eines sauberen Projekts ohne
    /// Upstream. `primary` steht zuerst in `.git/config`, `github` würde von
    /// `git remote` aber alphabetisch zuerst ausgegeben. Der sichtbare Knopf
    /// und der ausgeführte Push müssen beide dem Config-Ziel folgen.
    private static func runGitPushButtonTest() {
        testLabel = "gitpushbutton"
        guard ProcessInfo.processInfo.environment["FASTRA_SIDEBAR"] == "changes" else {
            finish(false, "Launch-Fixture FASTRA_SIDEBAR=changes fehlt")
        }
        guard let ws = Workspace.shared else { finish(false, "Workspace.shared ist nil") }
        guard GitRunner.isAvailable else {
            finish(true, "git nicht verfügbar — Git-Ansicht bleibt erwartungsgemäß verborgen")
        }
        Workspace.presentGitDialogs = false

        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("fastra-gitpushbutton-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("working-copy")
        let primary = base.appendingPathComponent("primary.git")
        let github = base.appendingPathComponent("github.git")
        do {
            try fm.createDirectory(at: repo, withIntermediateDirectories: true)
            try fm.createDirectory(at: primary, withIntermediateDirectories: true)
            try fm.createDirectory(at: github, withIntermediateDirectories: true)
            try "Basis\n".write(to: repo.appendingPathComponent("README.md"),
                                atomically: true, encoding: .utf8)
        } catch {
            finish(false, "(setup) \(error.localizedDescription)")
        }

        runGitSequence([["init", "--bare", "-b", "main"]], in: primary) {
            primaryOK, primaryError in
            guard primaryOK else {
                try? fm.removeItem(at: base)
                finish(false, "(primary setup) \(primaryError)")
            }
            runGitSequence([["init", "--bare", "-b", "main"]], in: github) {
                githubOK, githubError in
                guard githubOK else {
                    try? fm.removeItem(at: base)
                    finish(false, "(github setup) \(githubError)")
                }
                let setup: [[String]] = [
                    ["init", "-b", "main"],
                    ["config", "user.email", "t@t"],
                    ["config", "user.name", "T"],
                    ["add", "--", "README.md"],
                    ["commit", "-m", "lokaler Commit"],
                    // Reihenfolge ist die Sicherheitsbehauptung des Tests.
                    ["remote", "add", "primary", primary.path],
                    ["remote", "add", "github", github.path],
                ]
                runGitSequence(setup, in: repo) { ok, error in
                    guard ok else {
                        try? fm.removeItem(at: base)
                        finish(false, "(repo setup) \(error)")
                    }
                    DispatchQueue.main.async {
                        ws.openProject(at: repo)
                        pollGitPushButton(ws, base: base, repo: repo,
                                          primary: primary, github: github, tick: 0)
                    }
                }
            }
        }
    }

    /// Wartet auf die gerenderte Sicherheitsanzeige und klickt den echten
    /// SwiftUI-Knopf über AppKits Fenster-Hit-Testing.
    private static func pollGitPushButton(_ ws: Workspace, base: URL, repo: URL,
                                          primary: URL, github: URL, tick: Int) {
        let expected = GitPushTarget(remote: "primary", addresses: [primary.path])
        let buttonID = "gitPrimaryPush-primary"
        let addressID = "gitPrimaryPushAddress-primary-"
            + "\(expected.displayAddress.hashValue)"
        guard ws.gitPushTarget == expected,
              GitChangesPrimaryAction.resolve(status: ws.gitStatus,
                                              target: ws.gitPushTarget)
                == .push(expected),
              !ws.gitOperationsAreBusy,
              let window = mainWindowForAXChecks(),
              let content = window.contentView,
              let buttonMarker = markerView(id: buttonID, in: content),
              let addressMarker = markerView(id: addressID, in: content) else {
            if tick >= 120 {
                try? FileManager.default.removeItem(at: base)
                finish(false, "Push-Knopf mit erstem Remote und sichtbarer "
                    + "primary-Adresse erschien nicht (Ziel: "
                    + "\(String(describing: ws.gitPushTarget)), Status: "
                    + "\(String(describing: ws.gitStatus)))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pollGitPushButton(ws, base: base, repo: repo,
                                  primary: primary, github: github, tick: tick + 1)
            }
            return
        }

        window.layoutIfNeeded()
        guard buttonMarker.bounds.width > 0, buttonMarker.bounds.height > 0,
              addressMarker.bounds.width > 0, addressMarker.bounds.height > 0 else {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Push-Knopf oder Zieladresse besitzen keinen sichtbaren Bereich")
        }
        let point = buttonMarker.convert(
            NSPoint(x: buttonMarker.bounds.midX, y: buttonMarker.bounds.midY),
            to: nil
        )
        guard sendMouseClick(at: point, in: window, modifiers: []) else {
            try? FileManager.default.removeItem(at: base)
            finish(false, "Mausklick auf Push zu primary nicht erzeugbar")
        }
        pollGitPushButtonResult(ws, base: base, repo: repo,
                                primary: primary, github: github, tick: 0)
    }

    /// Ground Truth sind beide bare Remotes und Gits echter Upstream. Der
    /// alphabetisch frühere `github`-Remote muss vollständig unberührt bleiben.
    private static func pollGitPushButtonResult(
        _ ws: Workspace, base: URL, repo: URL, primary: URL, github: URL, tick: Int
    ) {
        GitRunner.run(["rev-parse", "--verify", "refs/heads/main"], in: primary) {
            primaryResult in
            GitRunner.run(
                ["show-ref", "--verify", "--quiet", "refs/heads/main"], in: github
            ) { githubResult in
                GitRunner.run(["rev-parse", "--abbrev-ref", "@{u}"], in: repo) {
                    upstreamResult in
                    DispatchQueue.main.async {
                        if githubResult?.ok == true {
                            try? FileManager.default.removeItem(at: base)
                            finish(false, "Push traf den nicht ausgewählten Remote github")
                        }
                        let upstream = upstreamResult?.stdout
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let returnedToCommit = GitChangesPrimaryAction.resolve(
                            status: ws.gitStatus, target: ws.gitPushTarget
                        ) == .commit
                        if primaryResult?.ok == true, upstream == "primary/main",
                           returnedToCommit {
                            try? FileManager.default.removeItem(at: base)
                            finish(true, "Knopf zeigte Push zu primary und dessen "
                                + "Adresse; echter Klick pushte nur zu primary, "
                                + "setzte primary/main als Upstream und kehrte "
                                + "danach in den Commit-Modus zurück")
                        }
                        if tick >= 150 {
                            try? FileManager.default.removeItem(at: base)
                            finish(false, "Push zu primary nicht vollständig "
                                + "(primary: \(primaryResult?.ok == true), "
                                + "upstream: \(upstream ?? "nil"), "
                                + "Commit-Modus: \(returnedToCommit))")
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            pollGitPushButtonResult(
                                ws, base: base, repo: repo, primary: primary,
                                github: github, tick: tick + 1
                            )
                        }
                    }
                }
            }
        }
    }

    /// Fensterlos — kuratierte Git-Aktionen end-to-end über die echten
    /// Workspace-Methoden mit einem lokalen bare-Remote: Push, Pull
    /// (Fast-Forward), Amend, Branch-Wechsel, Pickaxe. Braucht installiertes git.
    private static func runGitActionsTest() {
        testLabel = "gitactions"
        guard let ws = Workspace.shared else { finish(false, "Workspace.shared ist nil") }
        guard GitRunner.isAvailable else {
            finish(true, "git nicht verfügbar — Aktionen bleiben still weg (erwartet)")
        }
        // Fehler-Dialoge unterdrücken, damit ein unerwarteter Fehler den Lauf
        // nicht an einem modalen NSAlert aufhängt.
        Workspace.presentGitDialogs = false

        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("fastra-gitactions-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("work")
        let bare = base.appendingPathComponent("remote.git")
        do {
            try fm.createDirectory(at: repo, withIntermediateDirectories: true)
            try fm.createDirectory(at: bare, withIntermediateDirectories: true)
            try "PICKAXE_MARKER\n".write(to: repo.appendingPathComponent("marker.txt"),
                                         atomically: true, encoding: .utf8)
            try "v1\n".write(to: repo.appendingPathComponent("app.txt"),
                             atomically: true, encoding: .utf8)
        } catch { finish(false, "(setup) \(error)") }

        // Setup: bare-Remote initialisieren, Arbeitskopie einrichten + push -u.
        runGitSequence([["init", "--bare", "-b", "main"]], in: bare) { ok0, e0 in
            guard ok0 else { finish(false, "(bare) \(e0)") }
            let setup: [[String]] = [
                ["init", "-b", "main"],
                ["config", "user.email", "t@t"],
                ["config", "user.name", "T"],
                ["add", "-A"],
                ["commit", "-m", "init"],
                ["remote", "add", "origin", bare.path],
                ["push", "-u", "origin", "main"],
            ]
            runGitSequence(setup, in: repo) { ok1, e1 in
                guard ok1 else { finish(false, "(setup) \(e1)") }
                ws.openProject(at: repo)
                gitActionsPush(ws, repo: repo, bare: bare, base: base, fm: fm)
            }
        }
    }

    /// PUSH: neuen Commit lokal anlegen, `gitPush()` aufrufen, warten bis der
    /// bare-Remote 2 Commits hat (Ground Truth statt lokalem Status-Cache —
    /// der Cache-Wert vor der Aktion würde sonst eine Race auslösen).
    private static func gitActionsPush(_ ws: Workspace, repo: URL, bare: URL, base: URL, fm: FileManager) {
        try? "feature\n".write(to: repo.appendingPathComponent("feature.txt"),
                               atomically: true, encoding: .utf8)
        runGitSequence([["add", "-A"], ["commit", "-m", "feature"]], in: repo) { ok, e in
            guard ok else { try? fm.removeItem(at: base); finish(false, "(push-setup) \(e)") }
            ws.gitPush()
            pollAsync(maxTicks: 150, base: base, fm: fm, label: "push",
                      check: { done in
                          GitRunner.run(["rev-list", "--count", "main"], in: bare) { r in
                              done(Int(r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == 2)
                          }
                      },
                      next: { gitActionsPull(ws, repo: repo, bare: bare, base: base, fm: fm) })
        }
    }

    /// PULL (Fast-Forward): über einen zweiten Klon einen Remote-Commit erzeugen,
    /// dann `gitPullFastForward()` im Original — die neue Datei muss auftauchen.
    private static func gitActionsPull(_ ws: Workspace, repo: URL, bare: URL, base: URL, fm: FileManager) {
        let clone = base.appendingPathComponent("clone")
        runGitSequence([["clone", bare.path, clone.path]], in: base) { ok, e in
            guard ok else { try? fm.removeItem(at: base); finish(false, "(clone) \(e)") }
            try? "vom-remote\n".write(to: clone.appendingPathComponent("remote.txt"),
                                      atomically: true, encoding: .utf8)
            let push2: [[String]] = [
                ["config", "user.email", "t@t"], ["config", "user.name", "T"],
                ["add", "-A"], ["commit", "-m", "remote-commit"], ["push"],
            ]
            runGitSequence(push2, in: clone) { ok2, e2 in
                guard ok2 else { try? fm.removeItem(at: base); finish(false, "(push2) \(e2)") }
                gitActionsWhenIdle(ws, base: base, fm: fm, label: "pull-idle") {
                    ws.gitPullFastForward()
                }
                pollUntil(maxTicks: 150, base: base, fm: fm, label: "pull",
                          cond: { fm.fileExists(atPath: repo.appendingPathComponent("remote.txt").path) },
                          next: { gitActionsAmend(ws, repo: repo, bare: bare, base: base, fm: fm) })
            }
        }
    }

    /// AMEND: app.txt ändern, `gitAmendNoEdit()` — die Änderung muss in den
    /// letzten Commit wandern (`show HEAD:app.txt` == v2, Commit-Zahl gleich).
    /// Ground Truth via git, um den lokalen Status-Cache-Race zu vermeiden.
    private static func gitActionsAmend(_ ws: Workspace, repo: URL, bare: URL, base: URL, fm: FileManager) {
        GitRunner.run(["rev-list", "--count", "HEAD"], in: repo) { before in
            let countBefore = Int(before?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
            try? "v2\n".write(to: repo.appendingPathComponent("app.txt"),
                              atomically: true, encoding: .utf8)
            gitActionsWhenIdle(ws, base: base, fm: fm, label: "amend-idle") {
                ws.gitAmendNoEdit()
            }
            pollAsync(maxTicks: 150, base: base, fm: fm, label: "amend",
                      check: { done in
                          GitRunner.run(["show", "HEAD:app.txt"], in: repo) { r in
                              done(r?.ok == true && r!.stdout.contains("v2"))
                          }
                      },
                      next: {
                          GitRunner.run(["rev-list", "--count", "HEAD"], in: repo) { after in
                              let countAfter = Int(after?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -2
                              guard countAfter == countBefore else {
                                  try? fm.removeItem(at: base)
                                  finish(false, "(amend) Commit-Zahl \(countBefore) → \(countAfter) (amend darf nicht erhöhen)")
                              }
                              gitActionsSwitch(ws, repo: repo, bare: bare, base: base, fm: fm)
                          }
                      })
        }
    }

    /// SWITCH: neuen Branch anlegen, Liste neu laden und über die neue explizite
    /// Branch-Auswahl zurück auf main wechseln. Prüft zugleich Erfolgs-Feedback.
    private static func gitActionsSwitch(_ ws: Workspace, repo: URL, bare: URL, base: URL, fm: FileManager) {
        runGitSequence([["switch", "-c", "feature"]], in: repo) { ok, e in
            guard ok else { try? fm.removeItem(at: base); finish(false, "(switch-setup) \(e)") }
            ws.refreshGitBranches()
            pollUntil(maxTicks: 150, base: base, fm: fm, label: "branch-list",
                      cond: {
                          ws.gitBranches.contains(where: { $0.name == "main" })
                              && ws.gitBranches.contains(where: { $0.name == "feature" && $0.isCurrent })
                      },
                      next: {
                          gitActionsWhenIdle(ws, base: base, fm: fm, label: "switch-idle") {
                              ws.gitSwitchBranch("main")
                          }
                          pollAsync(maxTicks: 150, base: base, fm: fm, label: "switch",
                                    check: { done in
                                        GitRunner.run(["branch", "--show-current"], in: repo) { r in
                                            let onMain = r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "main"
                                            let feedback = ws.gitFeedback?.message.contains("main") == true
                                            done(onMain && feedback)
                                        }
                                    },
                                    next: { gitActionsPickaxe(ws, repo: repo, bare: bare, base: base, fm: fm) })
                      })
        }
    }

    /// PICKAXE: `git log -S` muss den Commit finden, der PICKAXE_MARKER einführte.
    private static func gitActionsPickaxe(_ ws: Workspace, repo: URL, bare: URL, base: URL, fm: FileManager) {
        GitRunner.run(["log", "-SPICKAXE_MARKER", "--oneline"], in: repo) { r in
            guard let r, r.ok, !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                try? fm.removeItem(at: base)
                finish(false, "(pickaxe) kein Treffer: \(r?.stderr ?? "nil")")
            }
            gitActionsAutoUpstream(ws, repo: repo, bare: bare, base: base, fm: fm)
        }
    }

    /// AUTO-UPSTREAM: neuen Branch OHNE Upstream anlegen, `gitPush()` muss ihn
    /// selbstständig mit `-u` beim Remote anlegen (der pfiffige Erst-Push).
    private static func gitActionsAutoUpstream(_ ws: Workspace, repo: URL, bare: URL, base: URL, fm: FileManager) {
        runGitSequence([["switch", "-c", "ohne-upstream"]], in: repo) { ok, e in
            guard ok else { try? fm.removeItem(at: base); finish(false, "(auto-u setup) \(e)") }
            gitActionsWhenIdle(ws, base: base, fm: fm, label: "auto-upstream-idle") {
                ws.gitPush()
            }
            pollAsync(maxTicks: 150, base: base, fm: fm, label: "auto-upstream",
                      check: { done in
                          // Der Branch muss jetzt im bare-Remote als Ref existieren.
                          GitRunner.run(["rev-parse", "--verify", "refs/heads/ohne-upstream"], in: bare) { r in
                              done(r?.ok == true)
                          }
                      },
                      next: {
                          try? fm.removeItem(at: base)
                          finish(true, "Git-Aktionen: Push (ahead→0), Pull-FF (Remote-Datei da), "
                              + "Amend (Datei in Commit, Zahl gleich), Branch-Liste + Auswahl, "
                              + "Pickaxe, Auto-Upstream-Push ok")
                      })
        }
    }

    /// Wartet, bis der Git-Koordinator frei ist, bevor die nächste Workspace-
    /// Aktion ausgelöst wird. Die echte UI deaktiviert die Aktions-Menüpunkte
    /// während `gitOperationsAreBusy`; ein Test-Aufruf im Freigabe-Fenster der
    /// Vorgänger-Aktion verpufft dagegen still (Befund 2026-07-17: „(amend)
    /// Timeout" — busy=true im Aufrufmoment, die Ground-Truth-Datei des Pulls
    /// war schon auf der Platte, der exklusive Slot aber noch nicht wieder
    /// freigegeben). Der Test wartet deshalb wie ein Nutzer auf das aktive Menü.
    private static func gitActionsWhenIdle(_ ws: Workspace, base: URL, fm: FileManager,
                                           label: String, tick: Int = 0,
                                           then action: @escaping () -> Void) {
        if !ws.gitOperationsAreBusy { action(); return }
        if tick >= 150 {
            try? fm.removeItem(at: base)
            finish(false, "(\(label)) Git-Koordinator wird nicht frei")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            gitActionsWhenIdle(ws, base: base, fm: fm, label: label,
                               tick: tick + 1, then: action)
        }
    }

    /// Kleiner Poll-Helfer: ruft `cond` alle 30 ms, bei `true` → `next`; nach
    /// `maxTicks` → FAIL mit Label. Räumt bei Timeout das Basis-Verzeichnis ab.
    private static func pollUntil(maxTicks: Int, base: URL, fm: FileManager, label: String,
                                  cond: @escaping () -> Bool, next: @escaping () -> Void, tick: Int = 0) {
        if cond() { next(); return }
        if tick >= maxTicks { try? fm.removeItem(at: base); finish(false, "(\(label)) Timeout") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollUntil(maxTicks: maxTicks, base: base, fm: fm, label: label,
                      cond: cond, next: next, tick: tick + 1)
        }
    }

    /// Wie `pollUntil`, aber mit ASYNCHRONER Bedingung (`check` liefert das
    /// Ergebnis über einen Callback) — für Ground-Truth-Checks, die selbst git
    /// aufrufen. Vermeidet den Race mit dem lokalen Status-Cache.
    private static func pollAsync(maxTicks: Int, base: URL, fm: FileManager, label: String,
                                  check: @escaping (@escaping (Bool) -> Void) -> Void,
                                  next: @escaping () -> Void, tick: Int = 0) {
        check { ok in
            if ok { next(); return }
            if tick >= maxTicks { try? fm.removeItem(at: base); finish(false, "(\(label)) Timeout") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                pollAsync(maxTicks: maxTicks, base: base, fm: fm, label: label,
                          check: check, next: next, tick: tick + 1)
            }
        }
    }

    private static func runSearchTest() {
        testLabel = "search"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }

        // ── Teiltest a: Buffer-Scope ──────────────────────────────────────
        //
        // Eindeutiger Inhalt mit genau 3 Vorkommen von „TESTMARKER".
        // Variiert die Zeilenlängen bewusst, damit Zeile/Spalte-Logik
        // nicht zufällig durch gleich lange Zeilen trivial klappt.
        // Inhalt mit genau 3 „TESTMARKER"-Vorkommen (Erwartungswerte stehen in
        // `runSearchTestAfterLoad` — ausgelagert wegen asynchronem loadFile).
        let bufferContent = "erste Zeile ohne Treffer\n"
            + "zweite Zeile TESTMARKER hier\n"
            + "kurz\n"
            + "TESTMARKER am Zeilenbeginn\n"
            + "eine mittellange vierte Zeile, dann TESTMARKER am Ende"

        // Temp-Datei für den Buffer-Test — Workspace.loadFile ist der
        // offizielle Weg, Inhalt in einen Tab zu bringen (gleicher Pfad
        // wie der Tab-Wechsel-Test).
        let tmpBuf = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-search-buf-\(UUID().uuidString).txt")
        do { try bufferContent.write(to: tmpBuf, atomically: true, encoding: .utf8) }
        catch { finish(false, "(a) Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        // loadFile ist jetzt asynchron (v0.9) — Temp-Datei-Löschung UND
        // Folge-Schritte in der Completion, damit der Inhalt beim Prüfen
        // wirklich im Tab steht und die Datei beim Hintergrund-Read existiert.
        ws.loadFile(at: tmpBuf) { ok in
            // Temp-Datei erst nach erfolgtem Lesen löschen.
            try? FileManager.default.removeItem(at: tmpBuf)
            guard ok else { finish(false, "(a) loadFile schlug fehl (completion false)") }
            runSearchTestAfterLoad(ws)
        }
    }

    /// Folge-Schritte von `runSearchTest` nach erfolgreichem Datei-Laden.
    /// Ausgelagert, damit runSearchTest übersichtlich bleibt.
    private static func runSearchTestAfterLoad(_ ws: Workspace) {
        // Erwartungswerte: identisch mit den lokalen Konstanten in runSearchTest.
        let expectedBufferCount = 3
        let expectedFirstLine   = 2
        let expectedFirstCol    = 14

        // Scope sicher auf .file setzen. SearchRunner erkennt den Wechsel
        // über seinen Combine-Trigger und sucht im Buffer neu.
        ws.scope = .file
        ws.useRegex = false          // Plain-Text → kein Regex-Syntax-Fehler möglich
        ws.caseSensitive = true
        ws.findPattern = "TESTMARKER"

        // Buffer-Debounce = 120 ms; wir pollen bis zu 2 Sekunden engmaschig
        // und gehen erst weiter, wenn die erwartete Trefferanzahl erreicht ist
        // oder das Fenster abgelaufen ist.
        pollForBufferMatches(ws,
                             expectedCount: expectedBufferCount,
                             expectedFirstLine: expectedFirstLine,
                             expectedFirstCol: expectedFirstCol)
    }

    /// Pollt auf `bufferMatches.count == expectedCount`. Läuft max. ~2 s.
    /// Bei Erfolg → Teiltest b starten. Bei Timeout oder falschen Werten → FAIL.
    private static func pollForBufferMatches(
        _ ws: Workspace,
        expectedCount: Int,
        expectedFirstLine: Int,
        expectedFirstCol: Int,
        tick: Int = 0
    ) {
        // 67 Ticks × 30 ms ≈ 2 Sekunden Beobachtungsfenster.
        let maxTicks = 67

        let got = ws.bufferMatches.count
        // Richtige Anzahl → Zeile/Spalte des ersten Treffers prüfen.
        if got == expectedCount {
            let first = ws.bufferMatches[0]
            if first.line != expectedFirstLine || first.column != expectedFirstCol {
                finish(false,
                    "(a) Treffer-Anzahl \(got) korrekt, aber erster Treffer "
                    + "an Z\(first.line)/S\(first.column), erwartet "
                    + "Z\(expectedFirstLine)/S\(expectedFirstCol)")
            }
            // Teiltest a bestanden → weiter mit b.
            runSearchTestPartB(ws)
            return
        }
        if tick >= maxTicks {
            finish(false,
                "(a) Buffer-Matches nach \(maxTicks) Ticks: \(got), "
                + "erwartet \(expectedCount) "
                + "(Pattern=\"\(ws.findPattern)\", "
                + "searchError=\(ws.searchError ?? "nil"))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollForBufferMatches(ws,
                                 expectedCount: expectedCount,
                                 expectedFirstLine: expectedFirstLine,
                                 expectedFirstCol: expectedFirstCol,
                                 tick: tick + 1)
        }
    }

    // MARK: - „Nur in Auswahl" (K3) — fensterlos

    /// Lädt einen Buffer mit drei „foo"-Treffern (je einer pro Zeile), friert
    /// eine Selektion auf Zeile 2 ein und prüft, dass die Suche NUR den
    /// Treffer in der Auswahl liefert — mit ABSOLUTER Zeilennummer (2).
    /// Danach „Nur in Auswahl" wieder aus → alle drei Treffer.
    private static func runSelSearchTest() {
        testLabel = "selsearch"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        // Zeilen je 11 Zeichen: „xxx foo yyy". foo-Offsets: 4 (Z1), 16 (Z2), 28 (Z3).
        let content = "aaa foo bbb\nccc foo ddd\neee foo fff"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-selsearch-\(UUID().uuidString).txt")
        do { try content.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }

            ws.scope = .file
            ws.useRegex = false
            ws.caseSensitive = false
            ws.findPattern = "foo"
            // Selektion auf Zeile 2 („ccc foo ddd", Offset 12, Länge 11)
            // einfrieren → nur der mittlere Treffer darf zählen.
            ws.selectionRange = NSRange(location: 12, length: 11)
            ws.setSearchInSelectionOnly(true)
            pollSelSearchRestricted(ws)
        }
    }

    /// Pollt auf genau 1 Treffer (in der Auswahl), Zeile 2 / Spalte 5.
    private static func pollSelSearchRestricted(_ ws: Workspace, tick: Int = 0) {
        let maxTicks = 67   // ~2 s
        if ws.bufferMatches.count == 1 {
            let m = ws.bufferMatches[0]
            // foo in Zeile 2 beginnt an Offset 16 → Spalte 16−12+1 = 5.
            if m.line != 2 || m.column != 5 {
                finish(false, "(restricted) Treffer an Z\(m.line)/S\(m.column), erwartet Z2/S5")
            }
            // Phase 2: „Nur in Auswahl" aus → wieder alle drei Treffer.
            ws.setSearchInSelectionOnly(false)
            pollSelSearchFull(ws)
            return
        }
        if tick >= maxTicks {
            finish(false, "(restricted) bufferMatches=\(ws.bufferMatches.count), erwartet 1 "
                + "(searchError=\(ws.searchError ?? "nil"))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollSelSearchRestricted(ws, tick: tick + 1)
        }
    }

    /// Pollt auf alle 3 Treffer, nachdem „Nur in Auswahl" abgeschaltet wurde.
    private static func pollSelSearchFull(_ ws: Workspace, tick: Int = 0) {
        let maxTicks = 67
        if ws.bufferMatches.count == 3 {
            finish(true, "Nur-in-Auswahl: 1 Treffer (Z2/S5) in Auswahl, 3 ohne Auswahl")
        }
        if tick >= maxTicks {
            finish(false, "(full) bufferMatches=\(ws.bufferMatches.count) nach Abschalten, erwartet 3")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollSelSearchFull(ws, tick: tick + 1)
        }
    }

    // MARK: - Platzhalter-Suche `*` (Feature J) — fensterlos

    /// Lädt „ring, The", sucht im Plain-Modus mit `*, the` (Platzhalter →
    /// 1 Treffer über die ganze Zeile) und schaltet dann den Mini-Schalter
    /// „* wörtlich" ein (→ 0 Treffer, weil der literale Text „*, the" fehlt).
    /// Belegt die Verdrahtung UND den Live-Trigger des Schalters.
    private static func runWildcardTest() {
        testLabel = "wildcard"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-wildcard-\(UUID().uuidString).txt")
        do { try "ring, The".write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            ws.scope = .file
            ws.useRegex = false
            ws.treatWildcardLiterally = false
            // Ersetzen-Seite VOR dem Find setzen, damit die erste Such-Runde
            // schon den aufgelösten `replacedText` trägt — genau dieser speist
            // die Inline-Live-Vorschau (Feature J, todo 3). `The *` → `The $1`.
            ws.replacePattern = "The *"
            ws.findPattern = "*, the"
            pollWildcardPlaceholder(ws)
        }
    }

    /// Phase 1: Platzhalter aktiv → genau 1 Treffer (greift über die ganze Zeile).
    private static func pollWildcardPlaceholder(_ ws: Workspace, tick: Int = 0) {
        let maxTicks = 67
        if ws.bufferMatches.count == 1, ws.searchError == nil {
            let m = ws.bufferMatches[0]
            // Der Treffer deckt „ring, The" ab (gierige Gruppe + Anker „, the").
            if m.matchText != "ring, The" {
                finish(false, "(platzhalter) Treffer-Text \"\(m.matchText)\", erwartet \"ring, The\"")
            }
            // Ersetzen-Seite END-TO-END: der Platzhalter-Replace „The *" muss in
            // der LIVE-Suche bereits zu „The ring" aufgelöst sein. Genau dieser
            // `replacedText` ist die Datenquelle der Inline-Vorschau — der Check
            // sichert den Vorschau-Pfad ohne fragiles View-Tree-Abtasten ab.
            if m.replacedText != "The ring" {
                finish(false, "(platzhalter) replacedText \"\(m.replacedText)\", erwartet \"The ring\"")
            }
            ws.treatWildcardLiterally = true   // → literal, Live-Trigger
            pollWildcardLiteral(ws)
            return
        }
        if tick >= maxTicks {
            finish(false, "(platzhalter) bufferMatches=\(ws.bufferMatches.count), erwartet 1 "
                + "(searchError=\(ws.searchError ?? "nil"))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollWildcardPlaceholder(ws, tick: tick + 1)
        }
    }

    /// Phase 2: Mini-Schalter „wörtlich" an → 0 Treffer (literaler „*, the" fehlt).
    private static func pollWildcardLiteral(_ ws: Workspace, tick: Int = 0) {
        let maxTicks = 67
        if ws.bufferMatches.isEmpty, ws.searchError == nil {
            finish(true, "Platzhalter: 1 Treffer (ring, The) -> ersetzt zu The ring; literal: 0 Treffer")
        }
        if tick >= maxTicks {
            finish(false, "(literal) bufferMatches=\(ws.bufferMatches.count), erwartet 0")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollWildcardLiteral(ws, tick: tick + 1)
        }
    }

    // MARK: - Screenshot-Setup für Platzhalter-Pillen + Live-Vorschau (Diagnose)

    /// Diagnose-Setup für einen fenstergezielten Screenshot der neuen
    /// Platzhalter-Oberflächen (Feature J): nummerierte Pillen + inline
    /// Live-Vorschau. Lädt mehrzeiligen Demo-Text, schaltet RegEx aus, setzt
    /// `*, the` / `The *`, wartet auf die LIVE-Treffer (damit Pillen UND
    /// Vorschau Daten haben) und dumpt dann die Fenster-Nummer der Suchmaske
    /// für `screencapture -l <nr>`. Hält die Maske ~12 s offen, dann `exit(0)`.
    /// KEIN PASS/FAIL-Funktionstest — die Funktion deckt der `wildcard`-Test ab.
    private static func runWildcardShot() {
        testLabel = "wildcardshot"
        guard let ws = Workspace.shared else { finish(false, "Workspace.shared ist nil") }
        // Fester, lesbarer Name — der Dateiname erscheint im Trefferbaum und
        // damit auf README-Screenshots (UUID-Namen sähen dort wüst aus). Der
        // Screenshot-Runner wählt passend zur App-Sprache die Beispielsprache.
        let fileName = screenshotIsEnglish ? "MovieList.txt" : "Filmliste.txt"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
        // Mehrere Zeilen → die Live-Vorschau zeigt „erste 3 + … und N weitere".
        let demo = "ring, The\nhobbit, The\nempire, The\nphantom menace, The\nmatrix, The\n"
        do { try demo.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }
        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            ws.scope = .file
            ws.useRegex = false
            ws.treatWildcardLiterally = false
            ws.replacePattern = "The *"   // → $1: Vorher „ring, The" / Nachher „The ring"
            ws.findPattern = "*, the"
            pollWildcardShot(ws)
        }
    }

    /// Diagnose-Setup (`-selftest regexshot`): wie `runWildcardShot`, aber im
    /// RegEx-Modus — gleicher Demo-Inhalt, Muster `(\w+), (\w+)` → `$2 $1`
    /// (Capture Groups + Token-Highlighting sichtbar). Dumpt die Fenster-Nummer
    /// der Suchmaske für `screencapture -l <nr>`, ~12 s offen, dann `exit(0)`.
    private static func runRegexShot() {
        testLabel = "regexshot"
        guard let ws = Workspace.shared else { finish(false, "Workspace.shared ist nil") }
        // Fester, lesbarer Name — erscheint im Trefferbaum (README-Screenshots).
        let fileName = screenshotIsEnglish ? "MovieList.txt" : "Filmliste.txt"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
        let demo = "ring, The\nhobbit, The\nempire, The\nphantom menace, The\nmatrix, The\n"
        do { try demo.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }
        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            ws.scope = .file
            ws.useRegex = true
            ws.replacePattern = "$2 $1"
            ws.findPattern = "(\\w+), (\\w+)"
            pollRegexShot(ws)
        }
    }

    /// Wartet auf Live-Treffer im RegEx-Modus, holt die Suchmaske nach vorn
    /// und gibt ihre Fenster-Nummer aus, dann Selbst-Exit (wie Wildcard-Shot).
    private static func pollRegexShot(_ ws: Workspace, tick: Int = 0) {
        let maxTicks = 100           // 100 × 30 ms ≈ 3 s
        if ws.bufferMatches.count >= 1, ws.searchError == nil,
           let win = NSApp.windows.first(where: {
               $0.frameAutosaveName == SearchWindow.frameAutosaveName && $0.isVisible
           }) {
            win.orderFront(nil)
            FileHandle.standardError.write(Data("REGEXSHOT-WINDOW \(win.windowNumber)\n".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { exit(0) }
            return
        }
        if tick >= maxTicks {
            finish(false, "(regexshot) keine Treffer/Suchmaske binnen ~3 s "
                + "(bufferMatches=\(ws.bufferMatches.count), error=\(ws.searchError ?? "nil"))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollRegexShot(ws, tick: tick + 1)
        }
    }

    /// Diagnose (`-selftest searchshot`): Suchmaske im LEEREN Ausgangszustand
    /// nach vorn holen und die Fenster-Nummer ausgeben (für `screencapture -l`),
    /// nach 12 s Selbst-Exit. Kein Funktionstest — ein Screenshot-Helfer wie
    /// `wildcardshot`, nur ohne Feld-Befüllung (Placeholder sichtbar).
    private static func runSearchShot() {
        testLabel = "searchshot"
        // Felder explizit leeren — der Erststart lädt sonst den Demo-Inhalt
        // mit vorbefülltem Suchmuster, und die Placeholder wären unsichtbar.
        Workspace.shared?.findPattern = ""
        Workspace.shared?.replacePattern = ""
        guard let win = NSApp.windows.first(where: {
            $0.frameAutosaveName == SearchWindow.frameAutosaveName && $0.isVisible
        }) else {
            finish(false, "(searchshot) Suchmaske nicht sichtbar")
        }
        win.orderFront(nil)
        FileHandle.standardError.write(Data("SEARCHSHOT-WINDOW \(win.windowNumber)\n".utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { exit(0) }
    }

    /// Diagnose (`-selftest welcomeshot`): Willkommensbildschirm mit gefüllter
    /// Projektliste herstellen, Fenster-Nummer des Hauptfensters ausgeben
    /// (für `screencapture -l`), nach 12 s Selbst-Exit. Kein Funktionstest —
    /// die Logik deckt der `project`-Selbsttest ab.
    private static func runWelcomeShot() {
        testLabel = "welcomeshot"
        guard let ws = Workspace.shared else { finish(false, "Workspace.shared ist nil") }
        // Folgestart-Zustand simulieren (die Selbsttest-Suite ist frisch →
        // die App startete mit dem Demo-Tab): leerer unbenannter Tab plus
        // Beispiel-Projekte, damit die Liste auf dem Screenshot gefüllt ist.
        ws.tabs = [EditorTab(title: Workspace.untitledBaseName,
                             path: "noch nicht gespeichert", isWelcome: true)]
        ws.activeTabID = ws.tabs.first?.id
        ws.projectURL = nil
        ws.recentProjects = [
            ProjectEntry(path: "~/git/fastra"),
            ProjectEntry(path: "~/git/Beispielprojekt"),
            ProjectEntry(path: "~/Projekte/Newsletter"),
        ]
        dumpMainWindowThenExit(prefix: "WELCOMESHOT-WINDOW")
    }

    /// Diagnose (`-selftest aboutshot`): Über-Dialog öffnen und seine
    /// Fenster-Nummer für ein gezieltes `screencapture -l` ausgeben.
    @MainActor
    private static func runAboutShot() {
        testLabel = "aboutshot"
        AboutWindow.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let win = NSApp.windows.first(where: {
                $0.isVisible && $0.title == L10n.string("Über Fastra")
            }) else {
                finish(false, "(aboutshot) Über-Dialog nicht sichtbar")
            }
            win.orderFront(nil)
            FileHandle.standardError.write(
                Data("ABOUTSHOT-WINDOW \(win.windowNumber)\n".utf8)
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { exit(0) }
        }
    }

    /// Diagnose (`-selftest projectshot`): Temp-Projekt mit sprechenden
    /// Dateinamen anlegen, als Projekt laden (Dateibaum in der Seitenleiste)
    /// und eine Datei öffnen — dann Fenster-Nummer fürs Capture ausgeben,
    /// nach 12 s Selbst-Exit. Kein Funktionstest.
    private static func runProjectShot() {
        testLabel = "projectshot"
        guard let ws = Workspace.shared else { finish(false, "Workspace.shared ist nil") }
        let fm = FileManager.default
        let projectName = screenshotIsEnglish ? "Website" : "Webseite"
        let language = screenshotIsEnglish ? "en" : "de"
        let greeting = screenshotIsEnglish ? "Hello" : "Hallo"
        let description = screenshotIsEnglish
            ? "Demo project for the screenshot."
            : "Demo-Projekt für den Screenshot."
        let repo = fm.temporaryDirectory.appendingPathComponent(projectName)
        do {
            try? fm.removeItem(at: repo)
            try fm.createDirectory(at: repo.appendingPathComponent(".git"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: repo.appendingPathComponent("styles"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: repo.appendingPathComponent("js"),
                                   withIntermediateDirectories: true)
            try "<!doctype html>\n<html lang=\"\(language)\">\n<head>\n  <meta charset=\"utf-8\">\n  <title>\(projectName)</title>\n</head>\n<body>\n  <h1>\(greeting)!</h1>\n</body>\n</html>\n"
                .write(to: repo.appendingPathComponent("index.html"),
                       atomically: true, encoding: .utf8)
            try "# \(projectName)\n\n\(description)\n"
                .write(to: repo.appendingPathComponent("README.md"),
                       atomically: true, encoding: .utf8)
            try "body { margin: 0; }\n"
                .write(to: repo.appendingPathComponent("styles/main.css"),
                       atomically: true, encoding: .utf8)
            try "console.log(\"\(greeting)\");\n"
                .write(to: repo.appendingPathComponent("js/app.js"),
                       atomically: true, encoding: .utf8)
        } catch {
            finish(false, "(setup) Temp-Projekt nicht anlegbar: \(error)")
        }
        ws.openProject(at: repo)
        ws.loadFile(at: repo.appendingPathComponent("index.html")) { ok in
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            // Ein Runloop-Tick, damit Dateibaum + Editor fertig gerendert sind.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                dumpMainWindowThenExit(prefix: "PROJECTSHOT-WINDOW")
            }
        }
    }

    /// Nur für die README-Diagnosen: UI-Sprache und sichtbare Beispieldaten
    /// werden vom Screenshot-Runner gemeinsam gesetzt.
    private static var screenshotIsEnglish: Bool {
        ProcessInfo.processInfo.environment["FASTRA_SCREENSHOT_LANGUAGE"] == "en"
    }

    /// Prüft die echte WebKit-Vorschau samt gebündelten Bibliotheken. Anders als
    /// ein String-Test beobachtet dieser Pfad das fertige DOM: Bild dekodiert,
    /// KaTeX-MathML erzeugt, Mermaid-SVG gezeichnet und Code hervorgehoben.
    private static func runMarkdownRenderTest() {
        testLabel = "markdown"
        guard let ws = Workspace.shared else { finish(false, "Workspace.shared ist nil") }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-Markdown-Selbsttest-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("Vorschau.md")
        let image = directory.appendingPathComponent("pixel.png")
        let twoSpaces = String(repeating: " ", count: 2)
        let threeSpaces = String(repeating: " ", count: 3)
        let demo = """
        # Render-Test

        ![Lokales Pixel](pixel.png)

        Inline $x^2 + y^2$.

        ==Textmarker mit **Fettung**==

        Kopierstart
        \(twoSpaces)
        \(threeSpaces)
        Kopierende

        ```swift
        let answer = 42
        ```

        ```mermaid
        flowchart LR
          A --> B
        ```

        <p align="center"><img src="pixel.png" width="8" alt="zentriert"></p>

        <img src="fehlt.png" onerror="window.__fastraPwned = 1">

        <script>window.__fastraPwned = 1;</script>
        """
        // Kleines echtes PNG: Der DOM-Test prüft `naturalWidth`, nicht nur das
        // Vorhandensein eines <img>-Elements.
        let pixelPNG = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try pixelPNG.write(to: image, options: .atomic)
            try demo.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            finish(false, "Markdown-Testdateien nicht schreibbar: \(error.localizedDescription)")
        }

        workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
        ws.loadFile(at: file) { ok in
            guard ok else { finish(false, "Markdown-Datei konnte nicht geladen werden") }
            pollMarkdownDOM(directory: directory, tick: 0)
        }
    }

    private static func pollMarkdownDOM(directory: URL, tick: Int) {
        guard tick < 120 else {
            try? FileManager.default.removeItem(at: directory)
            finish(false, "WebKit-DOM nach 12 s nicht vollständig gerendert")
        }
        guard let root = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        })?.contentView,
              let webView = markdownWebView(in: root) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pollMarkdownDOM(directory: directory, tick: tick + 1)
            }
            return
        }

        let script = """
        (() => {
          const blanks = Array.from(
            document.querySelectorAll('.fastra-visible-blank-line')
          );
          const lineHeight = parseFloat(getComputedStyle(document.body).lineHeight);
          const start = Array.from(document.querySelectorAll('p'))
            .find(node => node.textContent === 'Kopierstart');
          const end = Array.from(document.querySelectorAll('p'))
            .find(node => node.textContent === 'Kopierende');
          let selected = '';
          if (start && end) {
            const range = document.createRange();
            range.setStartBefore(start);
            range.setEndAfter(end);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            selected = selection.toString();
            selection.removeAllRanges();
          }
          return {
            image: Array.from(document.images).some(image => image.naturalWidth > 0),
            math: !!document.querySelector('.math-inline math'),
            mermaid: !!document.querySelector('.mermaid-render svg'),
            highlight: !!document.querySelector('pre code.hljs span'),
            mark: (() => {
              const node = document.querySelector('mark');
              if (!node || !node.querySelector('strong')) return false;
              const background = getComputedStyle(node).backgroundColor;
              return background !== 'rgba(0, 0, 0, 0)'
                && background !== 'transparent';
            })(),
            blankLines: blanks.length === 2
              && blanks.every(node => node.textContent === ''
                && Math.abs(node.getBoundingClientRect().height - lineHeight) < 0.75),
            blankCopy: /Kopierstart\\n{3,}Kopierende/.test(selected),
            // Die HTML-Positivliste: Das zentrierte Bild MUSS erscheinen …
            centered: (() => {
              const box = document.querySelector('p[align="center"]');
              const image = box && box.querySelector('img');
              return !!image && image.naturalWidth > 0;
            })(),
            // … und weder ein Ereignis-Attribut noch ein eingeschleustes
            // <script> darf im echten Renderer zur Ausführung kommen. Ein
            // reiner String-Test könnte das nicht belegen.
            notPwned: typeof window.__fastraPwned === 'undefined'
          };
        })()
        """
        webView.evaluateJavaScript(script) { result, error in
            let flags = result as? [String: Bool]
            let passed = flags?["image"] == true
                && flags?["math"] == true
                && flags?["mermaid"] == true
                && flags?["highlight"] == true
                && flags?["mark"] == true
                && flags?["blankLines"] == true
                && flags?["blankCopy"] == true
                && flags?["centered"] == true
                && flags?["notPwned"] == true
            if passed {
                try? FileManager.default.removeItem(at: directory)
                finish(true, "Bild + KaTeX + Mermaid + Codefarben + Textmarker + sichtbare Leerzeilen "
                    + "+ zentriertes HTML-Bild + kein ausgeführtes Fremdskript im DOM")
            }
            if tick == 119 {
                try? FileManager.default.removeItem(at: directory)
                if let error {
                    finish(false, "JavaScript-Fehler: \(error.localizedDescription)")
                }
                finish(false, "DOM unvollständig: \(String(describing: flags))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pollMarkdownDOM(directory: directory, tick: tick + 1)
            }
        }
    }

    /// Prüft die dokumentierte Leerzeilen-Erweiterung im problematischen
    /// Listen-Kontext. Entscheidend sind echte WebKit-Rechtecke: HTML-Klassen
    /// allein würden auch dann bestehen, wenn der Browser keinen Platz zeigt.
    private static func runMarkdownVisibleBlankLinesTest() {
        testLabel = "markdownblanklines"
        guard let ws = Workspace.shared else { finish(false, "Workspace.shared ist nil") }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-Markdown-Leerzeilen-Selbsttest-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("Listen-Leerzeilen.md")
        let blankLines = Array(repeating: "  ", count: 6).joined(separator: "\n")
        // Dieser Aufbau entspricht dem gemeldeten Fall: Die Leerraumzeilen
        // liegen direkt NACH der Liste, aber noch in deren cmark-Quellbereich.
        let demo = """
        ***Getestet:***

        -
        -
        -
        -
        -
        -
        \(blankLines)
        ***Frage:***

        Text nach den sichtbaren Leerzeilen.
        """
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try demo.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            finish(false, "Markdown-Testdatei nicht schreibbar: \(error.localizedDescription)")
        }

        workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
        ws.loadFile(at: file) { ok in
            guard ok else { finish(false, "Markdown-Datei konnte nicht geladen werden") }
            pollMarkdownVisibleBlankLinesDOM(directory: directory, tick: 0)
        }
    }

    private static func pollMarkdownVisibleBlankLinesDOM(directory: URL, tick: Int) {
        guard tick < 120 else {
            try? FileManager.default.removeItem(at: directory)
            finish(false, "WebKit-DOM nach 12 s nicht vollständig gerendert")
        }
        guard let root = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        })?.contentView,
              let webView = markdownWebView(in: root) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pollMarkdownVisibleBlankLinesDOM(directory: directory, tick: tick + 1)
            }
            return
        }

        let script = """
        (() => {
          const blanks = Array.from(
            document.querySelectorAll('.fastra-visible-blank-line')
          );
          const question = Array.from(document.querySelectorAll('p')).find(
            node => node.textContent.trim() === 'Frage:'
          );
          const lineHeight = parseFloat(getComputedStyle(document.body).lineHeight);
          const boxes = blanks.map(node => node.getBoundingClientRect());
          const visibleLines = boxes.length === 6
            && boxes.every(box => Math.abs(box.height - lineHeight) < 0.75);
          const stackedWithoutCollapse = boxes.length === 6
            && boxes.slice(1).every((box, index) =>
              Math.abs(box.top - boxes[index].bottom) < 0.75
            );
          const gapBeforeQuestion = !!question && boxes.length === 6
            && question.getBoundingClientRect().top - boxes[0].top
              >= lineHeight * 6 - 0.75;
          return { visibleLines, stackedWithoutCollapse, gapBeforeQuestion };
        })()
        """
        webView.evaluateJavaScript(script) { result, error in
            let flags = result as? [String: Bool]
            let passed = flags?["visibleLines"] == true
                && flags?["stackedWithoutCollapse"] == true
                && flags?["gapBeforeQuestion"] == true
            if passed {
                try? FileManager.default.removeItem(at: directory)
                finish(true, "sechs sichtbare Leerzeilen nach einer Liste im echten WebKit-Layout")
            }
            if tick == 119 {
                try? FileManager.default.removeItem(at: directory)
                if let error {
                    finish(false, "JavaScript-Fehler: \(error.localizedDescription)")
                }
                finish(false, "Leerzeilen-Layout unvollständig: \(String(describing: flags))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pollMarkdownVisibleBlankLinesDOM(directory: directory, tick: tick + 1)
            }
        }
    }

    /// Prüft den Klick-Sprung von der Vorschau in den Editor am echten DOM.
    ///
    /// Der interessante Fall ist ein Klick MITTEN in einen Absatz: Der Block
    /// kennt nur seine erste Zeile, die restlichen löst das Vorschau-JS über
    /// die Zeilenumbrüche im gerenderten Text auf. Ein String-Test kann das
    /// nicht abdecken — dafür muss echtes WebKit den Klick verarbeiten.
    private static func runMarkdownJumpTest() {
        testLabel = "markdownjump"
        guard let ws = Workspace.shared else { finish(false, "Workspace.shared ist nil") }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-Sprung-Selbsttest-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("Sprung.md")
        // Zeile 3/4/5 bilden EINEN Absatz — genau das, was Blockpositionen
        // allein nicht auflösen können.
        let demo = """
        # Sprungtest

        Zeile A
        Zeile B
        Zeile C

        Schlusswort.
        """
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try demo.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            finish(false, "Testdatei nicht schreibbar: \(error.localizedDescription)")
        }

        workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
        ws.loadFile(at: file) { ok in
            guard ok else { finish(false, "Markdown-Datei konnte nicht geladen werden") }
            pollMarkdownJump(workspace: ws, directory: directory, tick: 0)
        }
    }

    private static func pollMarkdownJump(workspace: Workspace,
                                         directory: URL,
                                         tick: Int) {
        guard tick < 120 else {
            try? FileManager.default.removeItem(at: directory)
            finish(false, "Vorschau nach 12 s nicht bereit")
        }
        guard let root = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        })?.contentView,
              let webView = markdownWebView(in: root) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pollMarkdownJump(workspace: workspace, directory: directory, tick: tick + 1)
            }
            return
        }

        // Klick auf das Wort „C" in der dritten Absatzzeile. Der Zielpunkt wird
        // über die Zeichen-Geometrie bestimmt statt geschätzt: Der Absatz darf
        // beliebig umbrechen, ohne den Test unzuverlässig zu machen.
        let script = """
        (() => {
          const paragraph = Array.from(document.querySelectorAll('p'))
            .find(node => node.textContent.includes('Zeile C'));
          if (!paragraph) return { error: 'Absatz nicht gefunden' };
          const text = paragraph.firstChild;
          const offset = paragraph.textContent.indexOf('Zeile C') + 6;
          const range = document.createRange();
          range.setStart(text, offset);
          range.setEnd(text, offset + 1);
          const rect = range.getBoundingClientRect();
          paragraph.dispatchEvent(new MouseEvent('click', {
            bubbles: true,
            clientX: rect.left + rect.width / 2,
            clientY: rect.top + rect.height / 2
          }));
          return { dispatched: true };
        })()
        """
        webView.evaluateJavaScript(script) { result, error in
            if let error {
                try? FileManager.default.removeItem(at: directory)
                finish(false, "JavaScript-Fehler: \(error.localizedDescription)")
            }
            if let info = result as? [String: Any], info["dispatched"] as? Bool == true {
                // Der Sprung läuft über Notification und Editor-Reconcile,
                // beides asynchron — deshalb den Cursor nachlaufend prüfen.
                pollMarkdownJumpResult(workspace: workspace, directory: directory, tick: 0)
                return
            }
            if tick == 119 {
                try? FileManager.default.removeItem(at: directory)
                finish(false, "Klick nicht auslösbar: \(String(describing: result))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pollMarkdownJump(workspace: workspace, directory: directory, tick: tick + 1)
            }
        }
    }

    private static func pollMarkdownJumpResult(workspace: Workspace,
                                               directory: URL,
                                               tick: Int) {
        // „Zeile C" ist die fünfte Zeile der Datei; der Absatz beginnt bei 3.
        // Bliebe die Auflösung innerhalb des Blocks aus, stünde hier 3.
        let expected = 5
        if workspace.cursorLine == expected {
            try? FileManager.default.removeItem(at: directory)
            finish(true, "Klick in Absatzzeile 3 setzt den Cursor auf Dateizeile \(expected)")
        }
        guard tick < 50 else {
            try? FileManager.default.removeItem(at: directory)
            finish(false, "Cursor steht auf Zeile \(workspace.cursorLine), erwartet \(expected)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollMarkdownJumpResult(workspace: workspace, directory: directory, tick: tick + 1)
        }
    }

    /// Prüft, dass die Vorschau einem Hell-/Dunkel-Wechsel IM LAUFENDEN BETRIEB
    /// vollständig folgt.
    ///
    /// Hintergrund: `underPageBackgroundColor` färbt den Bereich außerhalb der
    /// Seite — Overscroll und den Streifen unter der Scrollleiste. Wurde sie nur
    /// beim Erzeugen der WebView gesetzt, blieb nach einem Wechsel ein dunkler
    /// Balken am rechten Rand stehen, obwohl das Dokument bereits hell war.
    /// Ein reiner Start im Zielmodus hätte den Fehler nie gezeigt.
    private static func runMarkdownAppearanceTest() {
        testLabel = "markdownappearance"
        guard let ws = Workspace.shared else { finish(false, "Workspace.shared ist nil") }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-Appearance-Selbsttest-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("Aussehen.md")
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try "# Aussehen\n\nEin Absatz.\n".write(to: file, atomically: true,
                                                    encoding: .utf8)
        } catch {
            finish(false, "Testdatei nicht schreibbar: \(error.localizedDescription)")
        }

        let original = NSApp.appearance
        workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
        // Bewusst dunkel STARTEN und später wechseln — nur so entsteht der
        // Zustand, in dem die Farbe veraltet zurückbleiben konnte.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        ws.loadFile(at: file) { ok in
            guard ok else { finish(false, "Markdown-Datei konnte nicht geladen werden") }
            pollAppearance(expectDark: true, directory: directory, original: original, tick: 0) {
                NSApp.appearance = NSAppearance(named: .aqua)
                pollAppearance(expectDark: false, directory: directory,
                               original: original, tick: 0) {
                    NSApp.appearance = original
                    try? FileManager.default.removeItem(at: directory)
                    finish(true, "Vorschau folgt dem Hell-/Dunkel-Wechsel im laufenden Betrieb")
                }
            }
        }
    }

    private static func pollAppearance(expectDark: Bool,
                                       directory: URL,
                                       original: NSAppearance?,
                                       tick: Int,
                                       then next: @escaping () -> Void) {
        let webView = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        })?.contentView.flatMap { markdownWebView(in: $0) }

        // In sRGB umrechnen: Ein direkter NSColor-Vergleich scheitert schon an
        // unterschiedlichen Farbräumen.
        if let color = webView?.underPageBackgroundColor,
           let srgb = color.usingColorSpace(.sRGB) {
            let isDark = srgb.redComponent < 0.5
            if isDark == expectDark {
                next()
                return
            }
        }
        guard tick < 60 else {
            NSApp.appearance = original
            try? FileManager.default.removeItem(at: directory)
            let mode = expectDark ? "dunkel" : "hell"
            finish(false, "Hintergrund außerhalb der Seite wurde nach dem Wechsel nicht \(mode)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollAppearance(expectDark: expectDark, directory: directory,
                           original: original, tick: tick + 1, then: next)
        }
    }

    private static func markdownWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let webView = markdownWebView(in: child) { return webView }
        }
        return nil
    }

    /// Diagnose (`-selftest markdownshot`): öffnet ein kleines GFM-Dokument,
    /// erzwingt die integrierte Vorschau und gibt die Hauptfenster-Nummer aus.
    /// Auswahl und Clipboard-Formate decken Unit-Tests ab; dieser Helfer prüft
    /// bewusst nur die tatsächliche Fensteraufteilung und Rich-Text-Typografie.
    private static func runMarkdownShot() {
        testLabel = "markdownshot"
        guard let ws = Workspace.shared else { finish(false, "Workspace.shared ist nil") }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-Markdown-Vorschau.md")
        let demo = """
        # Markdown-Vorschau

        Markierter Text wird als **formatierter Rich Text** und als Klartext kopiert.

        ## Funktionen

        - Auswahl über mehrere Absätze
        - Links wie [Fastra](https://example.invalid)
        - Inline-Code wie `NSPasteboard`

        | Format | Clipboard |
        | --- | --- |
        | Klartext | ja |
        | Formatiertes HTML | ja |
        """
        do { try demo.write(to: file, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
        ws.loadFile(at: file) { ok in
            guard ok else { finish(false, "Markdown-Datei konnte nicht geladen werden") }
            // WebKit braucht nach dem Tabwechsel einen Layoutdurchlauf, bevor
            // ein Screenshot vollständig aussagekräftig ist.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                dumpMainWindowThenExit(prefix: "MARKDOWNSHOT-WINDOW")
            }
        }
    }

    /// Diagnose (`-selftest gitshot`): echtes Git-Repo mit gemischten Datei-
    /// Zuständen (modified/untracked/staged) anlegen, als Projekt öffnen und
    /// den Git-Status einlesen — dann Fenster-Nummer fürs Capture ausgeben.
    /// Zeigt die Branch-Zeile + eingefärbte Dateien in der Seitenleiste.
    private static func runGitShot() {
        testLabel = "gitshot"
        guard ProcessInfo.processInfo.environment["FASTRA_SIDEBAR"] == "changes" else {
            finish(false, "Launch-Fixture FASTRA_SIDEBAR=changes fehlt")
        }
        guard let ws = Workspace.shared else { finish(false, "Workspace.shared ist nil") }
        guard GitRunner.isAvailable else { finish(false, "git nicht verfügbar") }
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("Webseite")
        do {
            try? fm.removeItem(at: repo)
            try fm.createDirectory(at: repo.appendingPathComponent("styles"),
                                   withIntermediateDirectories: true)
            try "<!doctype html>\n<h1>Hallo</h1>\n"
                .write(to: repo.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            let readme = (1...180).map { "Dokumentationszeile \($0)" }
                .joined(separator: "\n") + "\n"
            try readme.write(to: repo.appendingPathComponent("README.md"),
                             atomically: true, encoding: .utf8)
            try "body{margin:0}\n".write(to: repo.appendingPathComponent("styles/main.css"),
                                         atomically: true, encoding: .utf8)
        } catch { finish(false, "(setup) \(error)") }

        let id = ["-c", "user.email=t@t", "-c", "user.name=T"]
        GitRunner.run(["-c", "init.defaultBranch=main", "init"], in: repo) { r0 in
            guard let r0, r0.ok else { finish(false, "(init) \(r0?.stderr ?? "")") }
            GitRunner.run(id + ["add", "."], in: repo) { _ in
                GitRunner.run(id + ["commit", "-m", "init"], in: repo) { _ in
                    // Änderungen für sichtbare Einfärbung: README ändern (M),
                    // styles/main.css ändern (Ordner-Rollup), app.js stagen
                    // und notes.txt unversioniert lassen. Zwei weit getrennte
                    // README-Hunks machen Faltung und Hunk-Navigation sichtbar.
                    var changedReadme = (1...180).map { "Dokumentationszeile \($0)" }
                    changedReadme[2] = "Dokumentationszeile 3 — früher Hunk geändert"
                    changedReadme[149] = "Dokumentationszeile 150 — später Hunk geändert"
                    try? (changedReadme.joined(separator: "\n") + "\n")
                        .write(to: repo.appendingPathComponent("README.md"),
                               atomically: true, encoding: .utf8)
                    try? "body{margin:0;padding:0}\n".write(to: repo.appendingPathComponent("styles/main.css"),
                                                            atomically: true, encoding: .utf8)
                    try? "console.log(1)\n".write(to: repo.appendingPathComponent("app.js"),
                                                  atomically: true, encoding: .utf8)
                    try? "Noch nicht versioniert\n".write(
                        to: repo.appendingPathComponent("notes.txt"),
                        atomically: true, encoding: .utf8)
                    // app.js bewusst stagen: Der Shot soll gleichzeitig die
                    // Bereiche „Bereitgestellt“ und „Änderungen“ zeigen.
                    GitRunner.run(id + ["add", "--", "app.js"], in: repo) { staged in
                        guard let staged, staged.ok else {
                            finish(false, "(stage fixture) \(staged?.stderr ?? "")")
                        }
                        validateGitShotFixture(repository: repo, identity: id) {
                            ws.openProject(at: repo)
                            // Über FASTRA_GITSHOT wählbar, was im Editor-Bereich steht:
                            // "diff" / "log" öffnen den jeweiligen read-only-Tab, sonst
                            // eine geladene Datei (Seitenleisten-Einfärbung).
                            let variant = ProcessInfo.processInfo.environment["FASTRA_GITSHOT"] ?? "sidebar"
                            let afterStatus = {
                                switch variant {
                                case "diff": ws.openGitDiff()
                                case "log":  ws.openGitLog()
                                default:     break
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                    dumpMainWindowThenExit(prefix: "GITSHOT-WINDOW")
                                }
                            }
                            ws.loadFile(at: repo.appendingPathComponent("README.md")) { _ in
                                // Kurz warten, bis refreshGitStatus (async) durch ist.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6,
                                                              execute: afterStatus)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Der Diagnose-Shot soll nicht nur behaupten, gemischte Zustände und
    /// Faltungen zu zeigen. Vor dem Öffnen prüfen wir die echte Porcelain-v2-
    /// Ausgabe sowie zwei weit getrennte Unified-Hunks; driftet die Fixture,
    /// endet der Helfer sichtbar mit FAIL statt einen irreführenden Shot zu
    /// liefern.
    private static func validateGitShotFixture(repository: URL, identity: [String],
                                               completion: @escaping () -> Void) {
        GitRunner.run(identity + GitStatusParser.arguments, in: repository) { statusResult in
            guard let statusResult, statusResult.ok else {
                finish(false, "(fixture status) \(statusResult?.stderr ?? "")")
            }
            let status = GitStatusParser.parse(statusResult.stdoutData)
            let app = status.changes.first { $0.path == "app.js" }
            let readme = status.changes.first { $0.path == "README.md" }
            let css = status.changes.first { $0.path == "styles/main.css" }
            let notes = status.changes.first { $0.path == "notes.txt" }
            guard app?.staged == .added, app?.unstaged == nil,
                  readme?.staged == nil, readme?.unstaged == .modified,
                  css?.staged == nil, css?.unstaged == .modified,
                  notes?.staged == nil, notes?.unstaged == .untracked else {
                finish(false, "(fixture states) staged=\(status.stagedChanges.map(\.path)), "
                    + "changes=\(status.unstagedChanges.map(\.path))")
            }
            GitRunner.run(identity + ["diff", "--no-ext-diff", "--no-textconv",
                                      "--", "README.md"], in: repository) { diffResult in
                guard let diffResult, diffResult.ok else {
                    finish(false, "(fixture diff) \(diffResult?.stderr ?? "")")
                }
                let diff = String(decoding: diffResult.stdoutData, as: UTF8.self)
                let hunks = diff.split(separator: "\n").filter { $0.hasPrefix("@@ ") }
                guard hunks.count == 2,
                      diff.contains("früher Hunk geändert"),
                      diff.contains("später Hunk geändert") else {
                    finish(false, "(fixture hunks) \(hunks.count) statt 2")
                }
                completion()
            }
        }
    }

    /// Baut ein kleines Repo MIT Verzweigung und Merge, öffnet es und hält das
    /// Fenster fürs Graph-Capture. Der Graph-Modus wird über FASTRA_SIDEBAR=graph
    /// vorgewählt (Test-Hook in EditorView).
    private static func runGraphShot() {
        testLabel = "graphshot"
        guard let ws = Workspace.shared else { finish(false, "Workspace.shared ist nil") }
        guard GitRunner.isAvailable else { finish(false, "git nicht verfügbar") }
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("GraphDemo")
        try? fm.removeItem(at: repo)
        try? fm.createDirectory(at: repo, withIntermediateDirectories: true)

        let id = ["-c", "user.email=t@t", "-c", "user.name=Demo"]
        // Kette von git-Aufrufen, die eine echte Verzweigung + Merge erzeugt.
        func write(_ name: String, _ text: String) {
            try? text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func step(_ args: [String], _ next: @escaping () -> Void) {
            GitRunner.run(id + args, in: repo) { r in
                guard let r, r.ok else { finish(false, "(git \(args.first ?? "")) \(r?.stderr ?? "")") }
                next()
            }
        }

        write("f.txt", "a\n")
        step(["-c", "init.defaultBranch=main", "init"]) {
        step(["add", "."]) { step(["commit", "-m", "Erster Commit"]) {
        write("f.txt", "a\nb\n"); step(["commit", "-am", "Zweiter Commit"]) {
        step(["tag", "v0.1"]) {
        step(["checkout", "-b", "feature"]) {
        write("f.txt", "a\nb\nfeat\n"); step(["commit", "-am", "Feature: Teil 1"]) {
        write("f.txt", "a\nb\nfeat\nfeat2\n"); step(["commit", "-am", "Feature: Teil 2"]) {
        step(["checkout", "main"]) {
        write("g.txt", "main\n"); step(["add", "."]) { step(["commit", "-m", "Main: Fix nebenher"]) {
        step(["merge", "--no-ff", "feature", "-m", "Merge feature in main"]) {
        step(["checkout", "-b", "hotfix", "HEAD~1"]) {
        write("h.txt", "hot\n"); step(["add", "."]) { step(["commit", "-m", "Hotfix offen"]) {
        step(["checkout", "main"]) {
            ws.openProject(at: repo)
            // Nach dem Öffnen ist der Graph über FASTRA_SIDEBAR=graph aktiv.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                dumpMainWindowThenExit(prefix: "GRAPHSHOT-WINDOW")
            }
        } } } } } } } } } } } } } } } }
    }

    /// Gemeinsames Shot-Finale: größtes sichtbares Fenster (= Hauptfenster)
    /// nach vorn ordnen, Fenster-Nummer auf stderr ausgeben, nach 12 s
    /// Selbst-Exit — gleiche Mechanik wie die Suchmasken-Shots.
    private static func dumpMainWindowThenExit(prefix: String) {
        let main = NSApp.windows
            .filter { $0.isVisible }
            .max(by: { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) })
        guard let win = main else { finish(false, "kein sichtbares Hauptfenster") }
        win.orderFront(nil)
        FileHandle.standardError.write(Data("\(prefix) \(win.windowNumber)\n".utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { exit(0) }
    }

    /// Wartet auf die ersten Live-Treffer (Pillen + Vorschau gefüllt), holt die
    /// Suchmaske nach vorn und gibt ihre Fenster-Nummer aus, dann Selbst-Exit.
    private static func pollWildcardShot(_ ws: Workspace, tick: Int = 0) {
        let maxTicks = 100           // 100 × 30 ms ≈ 3 s
        if ws.bufferMatches.count >= 1, ws.searchError == nil,
           let win = NSApp.windows.first(where: {
               $0.frameAutosaveName == SearchWindow.frameAutosaveName && $0.isVisible
           }) {
            win.orderFront(nil)
            // Fenster-Nummer == CGWindowID → direkt für `screencapture -l` nutzbar.
            FileHandle.standardError.write(Data("WILDCARDSHOT-WINDOW \(win.windowNumber)\n".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { exit(0) }
            return
        }
        if tick >= maxTicks {
            finish(false, "(wildcardshot) keine Treffer/Suchmaske binnen ~3 s "
                + "(bufferMatches=\(ws.bufferMatches.count), error=\(ws.searchError ?? "nil"))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollWildcardShot(ws, tick: tick + 1)
        }
    }

    /// Teiltest b: Live-Ordner-Suche mit einem echten Temp-Ordner.
    private static func runSearchTestPartB(_ ws: Workspace) {
        // Temp-Ordner mit eindeutigem Namen anlegen (NSTemporaryDirectory
        // liefert einen Pfad, auf den die App Schreibrecht hat).
        let tmpDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fastra-search-folder-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                atPath: tmpDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            finish(false, "(b) Temp-Ordner nicht anlegbar: \(error.localizedDescription)")
        }

        // Datei 1: 2 Treffer. Datei 2: 1 Treffer → Summe 3.
        let file1 = (tmpDir as NSString).appendingPathComponent("a.txt")
        let file2 = (tmpDir as NSString).appendingPathComponent("b.txt")
        let folderPattern = "ORDNERMARKER"   // ≥ 3 Zeichen → Live-Schwelle OK
        let expectedFolderTotal = 3

        do {
            try "Zeile 1\nORDNERMARKER erste\nORDNERMARKER zweite\n"
                .write(toFile: file1, atomically: true, encoding: .utf8)
            try "Keine Zeile davor\nORDNERMARKER dritte\n"
                .write(toFile: file2, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(atPath: tmpDir)
            finish(false, "(b) Testdatei nicht schreibbar: \(error.localizedDescription)")
        }

        // Scope wechseln und Temp-Ordner als einzigen aktivierten Eintrag
        // setzen. Alle anderen Einträge deaktivieren, damit kein alter
        // Ordner die Trefferzahl verfälscht.
        ws.recentSearchFolders = ws.recentSearchFolders.map { entry in
            var e = entry; e.enabled = false; return e
        }
        ws.recentSearchFolders.insert(
            SearchFolderEntry(path: tmpDir, enabled: true),
            at: 0
        )
        ws.scope = .folder
        ws.useRegex = false
        ws.caseSensitive = true
        // Pattern zuletzt setzen → Combine-Trigger feuert und startet
        // den SearchRunner-Debounce-Zyklus.
        ws.findPattern = folderPattern

        // Folder-Debounce: ~0,42 s nach dem Trigger (120 ms Pipeline-
        // Debounce + 300 ms Extra-Debounce in SearchRunner). Dann läuft
        // FolderSearch async via Task.detached. Wir pollen bis zu 3 s.
        pollForFolderMatches(ws,
                             expectedTotal: expectedFolderTotal,
                             tmpDir: tmpDir)
    }

    /// Pollt auf `folderTotalMatches == expectedTotal`. Läuft max. ~3 s.
    /// Bei Erfolg → Aufräumen + Teiltest c. Bei Timeout → FAIL + Aufräumen.
    private static func pollForFolderMatches(
        _ ws: Workspace,
        expectedTotal: Int,
        tmpDir: String,
        tick: Int = 0
    ) {
        // 100 Ticks × 30 ms = 3 Sekunden Beobachtungsfenster.
        let maxTicks = 100

        // Suche noch aktiv → warten (kein vorzeitiges FAIL bei 0 Treffern
        // mitten in einem laufenden Folder-Lauf).
        if ws.folderSearching {
            if tick >= maxTicks {
                try? FileManager.default.removeItem(atPath: tmpDir)
                finish(false,
                    "(b) Folder-Suche nach \(maxTicks) Ticks noch aktiv — kein Ergebnis")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                pollForFolderMatches(ws, expectedTotal: expectedTotal,
                                     tmpDir: tmpDir, tick: tick + 1)
            }
            return
        }

        let got = ws.folderTotalMatches
        if got == expectedTotal {
            // Teiltest b bestanden → Aufräumen und weiter mit c.
            try? FileManager.default.removeItem(atPath: tmpDir)
            runSearchTestPartC(ws)
            return
        }

        // Suche nicht aktiv, aber falsches Ergebnis. Mindest-Debounce-Zeit
        // (~14 × 30 ms = 420 ms) abwarten, bevor wir FAIL melden — der
        // Runner könnte noch im Extra-Debounce hängen.
        if !ws.folderNeedsSearch, tick >= 14 {
            try? FileManager.default.removeItem(atPath: tmpDir)
            finish(false,
                "(b) folderTotalMatches=\(got), erwartet \(expectedTotal) "
                + "(folderNeedsSearch=\(ws.folderNeedsSearch), "
                + "folderSearching=\(ws.folderSearching), "
                + "searchError=\(ws.searchError ?? "nil"))")
        }
        if tick >= maxTicks {
            try? FileManager.default.removeItem(atPath: tmpDir)
            finish(false,
                "(b) Folder-Treffer nach \(maxTicks) Ticks: \(got), "
                + "erwartet \(expectedTotal)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollForFolderMatches(ws, expectedTotal: expectedTotal,
                                 tmpDir: tmpDir, tick: tick + 1)
        }
    }

    /// Teiltest c: Negativ-Pfad — Pattern, das nichts matcht → 0 Treffer.
    private static func runSearchTestPartC(_ ws: Workspace) {
        // Zurück auf Buffer-Scope mit dem Tab aus Teiltest a.
        ws.scope = .file
        ws.useRegex = false
        ws.caseSensitive = true
        // Pattern, das im TESTMARKER-Inhalt definitiv nicht vorkommt.
        ws.findPattern = "GIBTESNICHT_XYZ_9999"

        // Buffer-Debounce (120 ms) abwarten, dann Ergebnis prüfen.
        pollForZeroMatches(ws)
    }

    /// Pollt bis `bufferMatches` leer ist (Negativ-Pfad). Max. ~1 s.
    /// PASS sobald 0 Treffer bestätigt; FAIL bei Timeout mit Nicht-Null.
    private static func pollForZeroMatches(_ ws: Workspace, tick: Int = 0) {
        // 34 Ticks × 30 ms ≈ 1 Sekunde Beobachtungsfenster.
        let maxTicks = 34

        if ws.bufferMatches.isEmpty {
            // Teiltest c bestanden → weiter mit d (Cap/Async).
            runSearchTestPartD(ws)
            return
        }
        if tick >= maxTicks {
            finish(false,
                "(c) bufferMatches.count=\(ws.bufferMatches.count) nach \(maxTicks) Ticks, "
                + "erwartet 0 (Pattern=\"\(ws.findPattern)\")")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollForZeroMatches(ws, tick: tick + 1)
        }
    }

    /// Teiltest d: Großer Buffer + kurzes Pattern → Cap greift, echte
    /// Gesamtzahl bleibt ehrlich, Suche läuft async (kein Beachball). Treibt
    /// die v0.10-Pipeline (async Buffer-Suche + Cap) END-TO-END über
    /// Workspace + SearchRunner — genau die Klasse, die der Crash-Report vom
    /// 2026-06-13 aufdeckte (nicht-lazy Riesenliste → AttributeGraph-Overflow).
    private static func runSearchTestPartD(_ ws: Workspace) {
        // 5000 Zeilen mit je einem „1" → 5000 Treffer, Cap = 2000.
        let bigContent = String(repeating: "marker1zeile\n", count: 5000)
        let tmpBig = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-search-big-\(UUID().uuidString).txt")
        do { try bigContent.write(to: tmpBig, atomically: true, encoding: .utf8) }
        catch { finish(false, "(d) Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmpBig) { ok in
            try? FileManager.default.removeItem(at: tmpBig)
            guard ok else { finish(false, "(d) loadFile schlug fehl (completion false)") }
            ws.scope = .file
            ws.useRegex = false
            ws.caseSensitive = true
            ws.findPattern = "1"
            pollForCappedBuffer(ws)
        }
    }

    /// Pollt, bis die async Buffer-Suche fertig ist (`!bufferSearching`), und
    /// prüft Cap + echte Gesamtzahl. Max. ~3 s.
    private static func pollForCappedBuffer(_ ws: Workspace, tick: Int = 0) {
        let maxTicks = 100   // 100 × 30 ms = 3 s

        // Noch am Suchen → warten (belegt zugleich: die Suche läuft async,
        // der Main-Thread tickt weiter, sonst käme dieser Poll nie dran).
        if ws.bufferSearching {
            if tick >= maxTicks {
                finish(false, "(d) Buffer-Suche nach \(maxTicks) Ticks noch aktiv")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                pollForCappedBuffer(ws, tick: tick + 1)
            }
            return
        }

        let expectedTotal = 5000
        let expectedCap = BufferSearch.defaultMaxMatches
        if ws.bufferTotalMatches == expectedTotal {
            guard ws.bufferMatches.count == expectedCap else {
                finish(false,
                    "(d) bufferMatches.count=\(ws.bufferMatches.count), "
                    + "erwartet Cap \(expectedCap)")
            }
            guard ws.bufferResultsWereCapped else {
                finish(false, "(d) bufferResultsWereCapped=false, erwartet true")
            }
            // Alles bestanden — Gesamt-PASS.
            finish(true,
                "(a) Buffer-Treffer + Zeile/Spalte korrekt, "
                + "(b) Folder-Treffer korrekt, "
                + "(c) Negativ-Pfad korrekt (0 Treffer), "
                + "(d) Cap greift: \(expectedCap) gelistet / \(expectedTotal) gezählt, async")
        }
        if tick >= maxTicks {
            finish(false,
                "(d) bufferTotalMatches=\(ws.bufferTotalMatches) nach \(maxTicks) Ticks, "
                + "erwartet \(expectedTotal) (searchError=\(ws.searchError ?? "nil"))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            pollForCappedBuffer(ws, tick: tick + 1)
        }
    }

    // MARK: - Selbsttest contrast

    /// Wächter gegen weiß-auf-weiß (und analoge unsichtbare Farb-Kombos):
    ///
    /// 1. Suchmaske öffnen (via .fastraShowSearchFile — gleicher Weg wie CMD+F).
    /// 2. Im Suchfenster UND im Hauptfenster alle NSTextField-Instanzen
    ///    rekursiv einsammeln (sichtbar, nicht versteckt — Labels sind in
    ///    SwiftUI ebenfalls als NSTextField gebrückt).
    /// 3. Für jedes sichtbare Feld: Textfarbe gegen den effektiven Fensterhinter-
    ///    grund nach sRGB konvertieren, relative Luminanz per WCAG-Formel
    ///    berechnen, Kontrastverhältnis bestimmen. Verhältnis < 2.0 → FAIL.
    /// 4. PASS: kein Feld unter der Schwelle. FAIL bei 0 geprüften Feldern
    ///    (dann ist die Einsammel-Logik kaputt — soll auffallen).
    ///
    /// Schwelle 2.0 ist absichtlich niedrig (WCAG AA für Fließtext wäre 4.5).
    /// Ziel: klares „weiß auf weiß" fangen, ohne bei leicht gedämpften
    /// Sekundärfarben (z.B. Platzhalter auf hellem Hintergrund) zu klagen.
    private static func runContrastTest() {
        testLabel = "contrast"

        // Suchmaske öffnen — exakt der Weg, den CMD+F auch geht.
        NotificationCenter.default.post(name: .fastraShowSearchFile, object: nil)

        // SwiftUI/AppKit Zeit geben, das Fenster zu rendern. Ohne die
        // Verzögerung sind viele Subviews noch nicht in der View-Hierarchie
        // (lazy SwiftUI body rendering).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            var allFields: [NSTextField] = []

            // Alle NSTextField aus dem Suchfenster einsammeln.
            if let searchWindow = NSApp.windows.first(where: {
                $0.frameAutosaveName == SearchWindow.frameAutosaveName
            }), let root = searchWindow.contentView {
                collectAllTextFields(in: root, into: &allFields)
            }

            // Alle NSTextField aus dem Hauptfenster einsammeln.
            if let mainWindow = NSApp.windows.first(where: {
                $0.frameAutosaveName != SearchWindow.frameAutosaveName
                    && $0.contentView != nil && $0.isVisible
            }), let root = mainWindow.contentView {
                collectAllTextFields(in: root, into: &allFields)
            }

            // Mindestens 1 Feld muss gefunden worden sein — sonst ist der
            // Test selbst kaputt (und würde sonst fälschlich PASS liefern).
            guard !allFields.isEmpty else {
                finish(false, "0 NSTextField gefunden — View-Hierarchie nicht traversierbar")
            }

            // Hintergrundfarbe des Suchfensters als Standard-Fallback. Die
            // Suchmaske hat einen expliziten hellen Hintergrund (Theme.surfaceRaised),
            // NSWindow.backgroundColor spiegelt das systemseitig wider.
            // Für Felder ohne eigenen definierten Hintergrund ist das der
            // beste Proxy, den wir ohne vollständiges CALayer-Traversal haben.
            let searchWin = NSApp.windows.first(where: {
                $0.frameAutosaveName == SearchWindow.frameAutosaveName
            })
            // Konservativer Fallback: reines Weiß — ist das Suchfenster
            // nicht auffindbar, bleibt die Prüfung auf der sicheren Seite
            // (Textfarbe wird gegen Weiß verglichen, genau die Bug-Klasse).
            let windowBg = searchWin?.backgroundColor ?? NSColor.white

            var failDescriptions: [String] = []
            var checkedCount = 0

            for field in allFields {
                // Versteckte oder transparent gerenderte Felder überspringen —
                // sie sind für den Nutzer nicht sichtbar.
                guard !field.isHidden, field.alphaValue > 0.05 else { continue }
                // Felder ohne window-Kontext sind noch nicht auf dem Schirm.
                guard field.window != nil else { continue }
                // Leere Felder überspringen: SwiftUIs `Menu` (.borderlessButton)
                // legt intern ein leeres NSTextField-Hilfsfeld an (stringValue
                // ""), das fg≈bg hat (contrast ~1.07). Da es KEINEN Text zeigt,
                // ist es per Definition kein „weiß-auf-weiß"-Lesbarkeitsproblem —
                // der Test zielt auf SICHTBAREN Text (Dark-Mode-Bug-Klasse).
                guard !field.stringValue.isEmpty else { continue }

                checkedCount += 1

                // Textfarbe des Felds — SwiftUI setzt `.textColor` auf dem
                // gebrückten NSTextField. Fehlt die Farbe, Fallback: schwarz.
                let rawText = field.textColor ?? NSColor.labelColor

                // Hintergrundfarbe: wenn das Feld selbst einen definierten,
                // nicht-transparenten Hintergrund hat, nehmen wir den.
                // Sonst Fensterhintergrund als Fallback.
                let rawBg: NSColor = {
                    if field.drawsBackground,
                       let bg = field.backgroundColor,
                       bg.alphaComponent > 0.05 {
                        return bg
                    }
                    return windowBg
                }()

                // Beide Farben nach sRGB konvertieren. `usingColorSpace`
                // kann nil liefern (z.B. bei Systemfarben im P3-Farbraum)
                // — in dem Fall Feld überspringen (kein false FAIL).
                guard
                    let textSRGB = rawText.usingColorSpace(.sRGB),
                    let bgSRGB   = rawBg.usingColorSpace(.sRGB)
                else { continue }

                let ratio = contrastRatio(textSRGB, bgSRGB)
                if ratio < 2.0 {
                    // Beschreibung enthält genug Info, um das Feld im UI
                    // zu identifizieren: Platzhalter + Wert-Präfix + Frame.
                    let valuePreview = String(field.stringValue.prefix(20))
                    let desc = "ph=\"\(field.placeholderString ?? "")\" "
                        + "value=\"\(valuePreview)\" "
                        + "frame=\(field.frame) "
                        + "contrast=\(String(format: "%.2f", ratio))"
                    failDescriptions.append(desc)
                }
            }

            if checkedCount == 0 {
                // Alle Felder waren versteckt oder ohne window-Kontext —
                // verdächtig, könnte aber beim Erst-Start kurz auftreten.
                finish(false,
                    "0 sichtbare NSTextField geprüft "
                    + "(von \(allFields.count) insgesamt gefunden)")
            }

            if failDescriptions.isEmpty {
                finish(true,
                    "\(checkedCount) Felder geprüft, keins unter Kontrast 2.0")
            } else {
                finish(false,
                    "\(failDescriptions.count) Feld(er) unter Kontrast 2.0 "
                    + "(von \(checkedCount) geprüft):\n"
                    + failDescriptions.joined(separator: "\n"))
            }
        }
    }

    /// Sammelt ALLE `NSTextField` (editierbar UND Labels) rekursiv ein.
    /// Im Gegensatz zu `collectEditableFields` werden auch nicht-editierbare
    /// Labels erfasst — in SwiftUI sind `Text`-Views als `NSTextField` mit
    /// `isEditable=false` gebrückt und können genauso unsichtbar sein
    /// (weiß auf weiß war exakt dieser Fall, s. Commit-Historie).
    private static func collectAllTextFields(in view: NSView, into out: inout [NSTextField]) {
        if let tf = view as? NSTextField {
            out.append(tf)
        }
        for sub in view.subviews {
            collectAllTextFields(in: sub, into: &out)
        }
    }

    /// Berechnet das WCAG-Kontrastverhältnis zweier Farben.
    ///
    /// Formel: (L_hell + 0.05) / (L_dunkel + 0.05), wobei L die
    /// relative Luminanz nach WCAG 2.1 Appendix A ist. Ergebnis liegt
    /// zwischen 1.0 (kein Kontrast, identische Farben) und 21.0
    /// (maximaler Kontrast: schwarz auf weiß). Beide Farben müssen im
    /// sRGB-Farbraum vorliegen — das stellt der Aufrufer sicher.
    private static func contrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        // Die hellere Farbe kommt in den Zähler.
        let lighter = max(la, lb)
        let darker  = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Relative Luminanz einer sRGB-Farbe nach WCAG 2.1 (linearisierter
    /// Gamma-Wert, gewichtet nach menschlicher Empfindlichkeit).
    private static func relativeLuminance(_ color: NSColor) -> Double {
        // WCAG-Linearisierung: Werte ≤ 0.04045 werden linear skaliert,
        // höhere Werte über eine Potenzfunktion (Gamma ≈ 2.2).
        func linearize(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        // `redComponent` etc. sind im sRGB-Farbraum im Bereich 0…1.
        let r = linearize(Double(color.redComponent))
        let g = linearize(Double(color.greenComponent))
        let b = linearize(Double(color.blueComponent))
        // ITU-R BT.709 Gewichtung (WCAG-Standard).
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: - -selftest loadperf

    /// Misst, ob das asynchrone Datei-Laden den Main-Runloop NICHT blockiert.
    ///
    /// Vorgehen:
    /// 1. Heartbeat-Timer (30-ms-Takt) auf Main starten — misst die größte
    ///    Tick-Lücke (= wie lange der Main-Thread ohne Chance zum Reagieren war).
    /// 2. `Workspace.loadFile` mit der Testdatei aus Env `FASTRA_LOADPERF_FILE`
    ///    starten.
    /// 3. Phase 1 = bis Completion (I/O + Encoding-Erkennung, Hintergrund).
    ///    Akzeptanz: keine Main-Lücke > 250 ms.
    /// 4. Nach Completion (isLoading = false): Phase 2 = CESE-Mount messen
    ///    (manuell beobachten — kein PASS/FAIL, nur Protokoll).
    ///
    /// Aufruf: `-selftest loadperf -ApplePersistenceIgnoreState YES`
    /// Testdatei: Env `FASTRA_LOADPERF_FILE` (z.B. `/tmp/fastra-perf/50mb-lf.txt`).
    private static func runLoadPerfTest() {
        testLabel = "loadperf"
        guard let ws = Workspace.shared else {
            finish(false, "Workspace.shared ist nil (Test-Hook fehlt)")
        }

        // Testdatei-Pfad aus der Umgebungsvariable lesen.
        guard let filePath = ProcessInfo.processInfo.environment["FASTRA_LOADPERF_FILE"],
              !filePath.isEmpty else {
            finish(false, "Env FASTRA_LOADPERF_FILE nicht gesetzt — Testdatei-Pfad fehlt")
        }
        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            finish(false, "Testdatei nicht gefunden: \(filePath)")
        }

        // Heartbeat-Timer: misst die maximale Tick-Lücke auf dem Main-Thread.
        // Wird der Main-Thread blockiert, verpasst er Ticks → Lücke wächst.
        let heartbeatInterval = 0.030          // 30 ms Soll-Takt
        let maxAcceptableGap  = 0.250          // 250 ms Akzeptanz-Grenze
        var lastTick          = Date()
        var maxGapPhase1      = 0.0            // größte Lücke während I/O
        var tickCount         = 0

        // Timer auf dem Main-Runloop.
        var timer: Timer? = Timer.scheduledTimer(withTimeInterval: heartbeatInterval,
                                                 repeats: true) { _ in
            let now    = Date()
            let gap    = now.timeIntervalSince(lastTick)
            lastTick   = now
            tickCount += 1
            if gap > maxGapPhase1 { maxGapPhase1 = gap }
        }

        let phase1Start = Date()

        // loadFile ist asynchron — kehrt sofort zurück, I/O im Hintergrund.
        ws.loadFile(at: fileURL) { ok in
            // Completion ist auf Main → hier laufen wir wieder im Hauptthread.
            let phase1Elapsed = Date().timeIntervalSince(phase1Start)

            // Timer stoppen — Phase 1 beendet.
            timer?.invalidate()
            timer = nil

            guard ok else {
                finish(false, "loadFile schlug fehl (completion false)")
            }

            // Ergebnis formatieren.
            let gapMs   = Int(maxGapPhase1 * 1000)
            let phase1s = String(format: "%.2f", phase1Elapsed)
            let passed  = maxGapPhase1 < maxAcceptableGap

            // Phase-2-Beobachtung: CESE-Mount (Editor-Neuerzeugung) geschieht
            // jetzt auf Main als SwiftUI-Render-Pass. Wir warten kurz und
            // protokollieren die Gesamt-Zeit nach Phase 2.
            let phase2Start = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let phase2Elapsed = Date().timeIntervalSince(phase2Start)
                let p2s = String(format: "%.2f", phase2Elapsed)
                let msg = "Datei=\(URL(fileURLWithPath: filePath).lastPathComponent) "
                    + "Phase1=\(phase1s)s maxMainLücke=\(gapMs)ms "
                    + "Ticks=\(tickCount) "
                    + "Phase2-mount≈\(p2s)s"
                finish(passed, msg)
            }
        }
    }

    // MARK: - markdownimport (Umwandlung nach Markdown über poormans-text)

    /// End-to-end gegen das ECHTE `poormans-text`: Formatkatalog, eine
    /// Umwandlung ohne Bilder, eine mit Bildern und der Kollisionsschutz.
    ///
    /// Ein Unit-Test kann hier nur die Zerlegung der Antworten prüfen. Ob das
    /// Werkzeug wirklich gefunden wird, ob `--formats` von diesem Stand
    /// verstanden wird und ob das Ergebnis tatsächlich neben der Quelle landet,
    /// zeigt sich erst mit echten Dateien und einem echten Prozess.
    private static func runMarkdownImportTest() {
        testLabel = "markdownimport"
        guard MarkdownImportTool.locate() != nil else {
            finish(false, "Umgebungsproblem: poormans-text ist nicht installiert "
                + "(oder \(MarkdownImportTool.overrideEnvironmentKey) zeigt ins Leere)")
        }
        MarkdownImportService.shared.withCatalog { catalog in
            guard let catalog else {
                finish(false, "Umgebungsproblem: dieser poormans-text-Stand kennt "
                    + "--formats nicht — Werkzeug aktualisieren")
            }
            checkMarkdownImportCatalog(catalog)
        }
    }

    private static func checkMarkdownImportCatalog(_ catalog: MarkdownImportCatalog) {
        guard let rtf = catalog.availableFormat(forExtension: "rtf") else {
            finish(false, "Katalog meldet RTF nicht als benutzbar — Pandoc installiert?")
        }
        guard !rtf.isPackage else {
            finish(false, "RTF darf kein Ordner-Paket sein")
        }
        // RTFD ist der einzige Grund, warum Fastra beim Öffnen eines Ordners
        // überhaupt nachfragt. Fällt die Kennzeichnung weg, öffnet ein
        // Dokument still als Projekt.
        guard catalog.availableFormat(forExtension: "rtfd")?.isPackage == true else {
            finish(false, "RTFD wird nicht als Ordner-Paket gemeldet")
        }

        // Zweiter Abruf muss SYNCHRON aus dem Zwischenspeicher kommen, sonst
        // startet jedes Öffnen einer Datei einen neuen Prozess.
        var servedSynchronously = false
        MarkdownImportService.shared.withCatalog { _ in servedSynchronously = true }
        guard servedSynchronously else {
            finish(false, "Formatkatalog wird nicht zwischengespeichert")
        }

        let base: URL
        do {
            base = try makeMarkdownImportFixtures()
        } catch {
            finish(false, "Fixtures nicht erzeugbar: \(error.localizedDescription)")
        }
        convertPlainMarkdownImportFixture(in: base)
    }

    /// Legt drei Quellen an: eine schlichte RTF, eine RTF mit eingebettetem
    /// PNG und eine bereits belegte `Belegt.md`, die nicht überschrieben
    /// werden darf.
    private static func makeMarkdownImportFixtures() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-markdownimport-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        try Data(#"{\rtf1\ansi Schlichter Text ohne Bild.}"#.utf8)
            .write(to: base.appendingPathComponent("Schlicht.rtf"), options: .atomic)

        // Bereits belegter Zielname — die Umwandlung muss auf `-2` ausweichen
        // und diesen Inhalt unangetastet lassen.
        try Data("bereits da\n".utf8)
            .write(to: base.appendingPathComponent("Belegt.md"), options: .atomic)
        try Data(#"{\rtf1\ansi Zweites Dokument.}"#.utf8)
            .write(to: base.appendingPathComponent("Belegt.rtf"), options: .atomic)

        guard let png = markdownImportPNG() else { throw MarkdownImportFixtureError.png }
        let hex = png.map { String(format: "%02x", $0) }.joined()
        let withPicture = "{\\rtf1\\ansi Mit Bild: "
            + "{\\pict\\pngblip\\picw8\\pich8\\picwgoal120\\pichgoal120\n\(hex)\n}}"
        try Data(withPicture.utf8)
            .write(to: base.appendingPathComponent("MitBild.rtf"), options: .atomic)
        return base
    }

    private enum MarkdownImportFixtureError: Error { case png }

    private static func markdownImportPNG() -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Schritt 1: RTF ohne Bilder → `Schlicht.md` direkt neben der Quelle.
    private static func convertPlainMarkdownImportFixture(in base: URL) {
        let source = base.appendingPathComponent("Schlicht.rtf")
        let sourceBytes = try? Data(contentsOf: source)
        MarkdownImportService.shared.convert(source) { markdownFile in
            guard let markdownFile else {
                finishMarkdownImport(base, false,
                                     "schlichte RTF nicht umgewandelt: "
                                        + markdownImportFailureText())
            }
            guard markdownFile.path == base.appendingPathComponent("Schlicht.md").path else {
                finishMarkdownImport(base, false,
                                     "falscher Zielname: \(markdownFile.lastPathComponent)")
            }
            let markdown = (try? String(contentsOf: markdownFile, encoding: .utf8)) ?? ""
            guard markdown.contains("Schlichter Text") else {
                finishMarkdownImport(base, false, "Markdown ohne Quelltext: \(markdown.prefix(80))")
            }
            // Die Quelle darf die Umwandlung bytegleich überstehen.
            guard (try? Data(contentsOf: source)) == sourceBytes else {
                finishMarkdownImport(base, false, "die Quelldatei wurde verändert")
            }
            // Kein Zwischenverzeichnis darf liegen bleiben.
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: base.path))?
                .filter { $0.hasPrefix(".fastra-markdown-") } ?? []
            guard leftovers.isEmpty else {
                finishMarkdownImport(base, false, "Zwischenverzeichnis blieb liegen: \(leftovers)")
            }
            convertCollidingMarkdownImportFixture(in: base)
        }
    }

    /// Schritt 2: Zielname ist belegt → `-2`, ohne das Vorhandene anzufassen.
    private static func convertCollidingMarkdownImportFixture(in base: URL) {
        let occupied = base.appendingPathComponent("Belegt.md")
        MarkdownImportService.shared.convert(base.appendingPathComponent("Belegt.rtf")) { file in
            guard let file else {
                finishMarkdownImport(base, false,
                                     "Kollisionsfall nicht umgewandelt: "
                                        + markdownImportFailureText())
            }
            guard file.lastPathComponent == "Belegt-2.md" else {
                finishMarkdownImport(base, false,
                                     "Kollision falsch aufgelöst: \(file.lastPathComponent)")
            }
            let kept = (try? String(contentsOf: occupied, encoding: .utf8)) ?? ""
            guard kept == "bereits da\n" else {
                finishMarkdownImport(base, false, "bestehende Datei wurde überschrieben")
            }
            convertPictureMarkdownImportFixture(in: base)
        }
    }

    /// Schritt 3: RTF mit Bild → Ordner `MitBild` samt `MitBild.md` und Bild.
    private static func convertPictureMarkdownImportFixture(in base: URL) {
        MarkdownImportService.shared.convert(base.appendingPathComponent("MitBild.rtf")) { file in
            guard let file else {
                finishMarkdownImport(base, false,
                                     "Bild-RTF nicht umgewandelt: " + markdownImportFailureText())
            }
            let expected = base.appendingPathComponent("MitBild/MitBild.md")
            guard file.path == expected.path else {
                finishMarkdownImport(base, false, "Ordnerfall falsch benannt: \(file.path)")
            }
            var isDirectory: ObjCBool = false
            let folder = base.appendingPathComponent("MitBild")
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  FileManager.default.fileExists(atPath: file.path) else {
                finishMarkdownImport(base, false, "Ordner oder Markdown fehlt")
            }
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            guard contents.contains("images") else {
                finishMarkdownImport(base, false, "Bildordner fehlt: \(contents)")
            }
            routePackageMarkdownImportFixture(in: base)
        }
    }

    /// Schritt 4: Ein `.rtfd` ist auf der Platte ein ORDNER. Fastra darf es
    /// deshalb nicht still als Projekt öffnen, sondern muss die Rückfrage
    /// anbieten und danach wirklich umwandeln. Genau das ging beim ersten
    /// Anlauf im Dateibaum verloren (Daniel-Befund 2026-07-26).
    private static func routePackageMarkdownImportFixture(in base: URL) {
        let package = base.appendingPathComponent("Paket.rtfd", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: package,
                                                    withIntermediateDirectories: true)
            try Data(#"{\rtf1\ansi Inhalt eines RTFD-Pakets.}"#.utf8)
                .write(to: package.appendingPathComponent("TXT.rtf"), options: .atomic)
        } catch {
            finishMarkdownImport(base, false, "RTFD-Fixture nicht erzeugbar")
        }

        // Der Katalog muss das Paket als Paket erkennen — sonst landet es im
        // Ordnerzweig und wird als Projekt geöffnet.
        guard let workspace = Workspace.shared else {
            finishMarkdownImport(base, false, "Umgebungsproblem: kein Workspace")
        }
        guard let format = workspace.markdownImportPackageFormat(at: package) else {
            finishMarkdownImport(base, false,
                                 "RTFD wird nicht als Dokumentpaket erkannt — "
                                    + "ein Klick würde es nur aufklappen")
        }
        guard format.identifier == "rtfd" else {
            finishMarkdownImport(base, false, "falsches Paketformat: \(format.identifier)")
        }
        // Ein echter Ordner darf davon unberührt bleiben.
        guard workspace.markdownImportPackageFormat(at: base) == nil else {
            finishMarkdownImport(base, false, "gewöhnlicher Ordner gilt fälschlich als Dokument")
        }

        // Die Rückfrage ist modal und würde einen fensterlosen Lauf anhalten;
        // der Testhaken beantwortet sie mit „umwandeln".
        var asked = 0
        Workspace.markdownImportPackageChoiceProvider = { _, _ in
            asked += 1
            return .convert
        }
        workspace.openFileOrFolder(at: package)
        pollPackageMarkdownImport(base: base, package: package, asked: { asked }, tick: 0)
    }

    private static func pollPackageMarkdownImport(base: URL, package: URL,
                                                  asked: @escaping () -> Int, tick: Int) {
        let expected = base.appendingPathComponent("Paket.md")
        if FileManager.default.fileExists(atPath: expected.path) {
            Workspace.markdownImportPackageChoiceProvider = nil
            guard asked() == 1 else {
                finishMarkdownImport(base, false,
                                     "Rückfrage \(asked())-mal statt einmal gestellt")
            }
            // Das Paket selbst muss unangetastet bleiben.
            guard FileManager.default.fileExists(
                atPath: package.appendingPathComponent("TXT.rtf").path
            ) else {
                finishMarkdownImport(base, false, "das RTFD-Paket wurde verändert")
            }
            guard Workspace.shared?.projectURL != package.canonicalFileURL else {
                finishMarkdownImport(base, false, "das Paket wurde als Projekt geöffnet")
            }
            finishMarkdownImport(base, true,
                                 "Formatkatalog, Zwischenspeicher, flache Umwandlung, "
                                    + "Kollisionsschutz, Ordnerfall und RTFD-Paketweg ok")
        }
        guard tick < 100 else {
            Workspace.markdownImportPackageChoiceProvider = nil
            finishMarkdownImport(base, false,
                                 "RTFD-Paket nicht umgewandelt (Rückfragen: \(asked()), "
                                    + "Zustand: " + markdownImportFailureText() + ")")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pollPackageMarkdownImport(base: base, package: package, asked: asked, tick: tick + 1)
        }
    }

    private static func markdownImportFailureText() -> String {
        if case .failed(let message) = MarkdownImportService.shared.state { return message }
        return "kein Grund gemeldet"
    }

    private static func finishMarkdownImport(_ base: URL, _ ok: Bool, _ message: String) -> Never {
        try? FileManager.default.removeItem(at: base)
        finish(ok, message)
    }
}
