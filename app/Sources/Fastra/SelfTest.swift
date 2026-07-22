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
        case "gitshot": sidebar = "changes"
        case "graphshot": sidebar = "graph"
        default: sidebar = nil
        }
        if let sidebar { setEnvironment("FASTRA_SIDEBAR", sidebar) }
        if name == "sessionrestore" {
            prepareSessionRestoreFixture()
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
            UserDefaults.standard.set(true, forKey: "markdown.integratedPreview")
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
        case "multisearch": waitForMainWindow { runMultiWindowSearchJumpTest() }
        case "cmdw":      waitForMainWindow { openSearchThen { runCmdWTest() } }
        case "fields":    waitForMainWindow { openSearchThen { runFieldsTest() } }
        case "searchoptions": waitForMainWindow { openSearchThen { runSearchOptionsTest() } }
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
                + "(bekannt: findbar, newwindow, welcomenew, sessionrestore, cmdw, fields, searchoptions, tabswitch, tabclosehit, tabcompare, highlight, highlight4d, completion4d, previewrender, xpath, markdown, jump, ghosttext, replaceall, pilldrop, navmatch, search, project, localization, updates, git, gitactions, filemodes, selsearch, wildcard, textop, joinundo, colsel, colselwrap, colpaste, gutterdim, sidebarheader, searchmark, tool4dhint, tool4dlsp, help, mdassist, contrast, windows)")
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
            // Scroll unabhängig über die tatsächlich sichtbare Editorzeile
            // prüfen, nicht über denselben Ziel-Offset wie der Sprung selbst.
            let shownLine = secondTV.layoutManager
                .textLineForPosition(secondTV.visibleRect.midY)
                .map { $0.index + 1 }
            let isVisiblyAtTarget = shownLine.map { abs($0 - 110) <= 8 } ?? false
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
            finish(false, "zweiter Editor erreichte binnen 1,8 s nicht vollständig Auswahl und Sichtbarkeit "
                   + "bei sicherem Suchfenster-Fokus (selection=\(secondRange), "
                   + "searchKey=\(secondSearchWindow.isKeyWindow), documentKey=\(secondWindow.isKeyWindow), "
                   + "sichtbare Zeile=\(shownLine.map(String.init) ?? "nil"))")
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
        let fileURL: URL
        let initialText: String
        var failures: [String] = []

        init(fileURL: URL, initialText: String) {
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

        // Leeres Dokument: Nur die nachfolgende Test-Eingabe darf die Präfixe
        // erzeugen. Die Endung schaltet den produktiven 4D-Delegate an.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-completion4d-\(UUID().uuidString).4dm")
        // `Workspace.loadFile` kanonisiert `/var` zu `/private/var`. Der Test
        // muss dieselbe URL-Form speichern, sonst würde er einen korrekt
        // geladenen 4D-Tab fälschlich nie als aktiv erkennen.
        let fixtureText = "// Completion-Selbsttest\n"
        let state = FourDCompletionTestState(fileURL: url.canonicalFileURL,
                                             initialText: fixtureText)
        do {
            try fixtureText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            finish(false, "Completion-Fixture nicht schreibbar: \(error.localizedDescription)")
        }

        ws.loadFile(at: state.fileURL) { ok in
            guard ok else {
                finishFourDCompletionTest(state, ok: false,
                                          message: "loadFile (.4dm) schlug fehl")
            }
            pollForFourDCompletionEditor(ws: ws, mainWindow: mainWindow,
                                         root: root, state: state)
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
            finishFourDCompletionTest(state, ok: state.failures.isEmpty,
                                      message: state.failures.isEmpty
                                        ? "Auto-Popup, ⌃Leertaste, ↓ und gezielter Doppelklick funktionieren"
                                        : state.failures.joined(separator: "; "))
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
        try? FileManager.default.removeItem(at: state.fileURL)
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
        \tQUERY([Auftraege:1]; [Auftraege:1]Nummer=42)
        \tALERT("fertig")
        End if
        """
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-highlight4d-\(UUID().uuidString)")
        let methods = projectRoot.appendingPathComponent("Project/Sources/Methods",
                                                          isDirectory: true)
        let tmp = methods.appendingPathComponent("Highlight.4dm")
        do {
            try FileManager.default.createDirectory(at: methods, withIntermediateDirectories: true)
            try code.write(to: tmp, atomically: true, encoding: .utf8)
            try "// Projektindex-Fixture\n".write(
                to: methods.appendingPathComponent("Abr_init.4dm"), atomically: true,
                encoding: .utf8
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
        guard ws.fourDProjectMethodNames.contains("abr_init") else {
            if tick >= 40 {
                ws.closeProject()
                try? FileManager.default.removeItem(at: projectRoot)
                finish(false, "4D-Projektmethodenindex enthält Abr_init nach 10 s nicht")
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
            pollFourDColors(root: root, url: file, dark: false, indexedMethod: "Abr_init", tick: 0) {
                // Hell bestanden → dunkel umschalten und erneut beobachten.
                NSApp.appearance = NSAppearance(named: .darkAqua)
                pollFourDColors(root: root, url: file, dark: true, indexedMethod: "Abr_init", tick: 0) {
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

    private static func pollFourDColors(root: NSView, url: URL, dark: Bool,
                                        indexedMethod: String? = nil, tick: Int,
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
                            indexedMethod: indexedMethod, tick: tick + 1, then: next)
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
                            finish(tv.string == expected,
                                   "Text-Op plus beide Sortierrichtungen im echten Editor")
                        }
                    }
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

        UserDefaults.standard.set(true, forKey: "markdown.integratedPreview")
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
            blankCopy: /Kopierstart\\n{3,}Kopierende/.test(selected)
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
            if passed {
                try? FileManager.default.removeItem(at: directory)
                finish(true, "Bild + KaTeX + Mermaid + Codefarben + Textmarker + sichtbare Leerzeilen im DOM")
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

        UserDefaults.standard.set(true, forKey: "markdown.integratedPreview")
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

        UserDefaults.standard.set(true, forKey: "markdown.integratedPreview")
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
        UserDefaults.standard.set(true, forKey: "markdown.integratedPreview")
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

        UserDefaults.standard.set(true, forKey: "markdown.integratedPreview")
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
}
