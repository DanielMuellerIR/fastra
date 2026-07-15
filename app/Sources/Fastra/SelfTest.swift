// SelfTest.swift
//
// In-App-Smoke-Test für die Bug-Klasse, die reine Unit-Tests NICHT fangen:
// App-weites Event-Routing und die LIFO-Reihenfolge der CMD+F-Monitore
// (Zombie-Find-Bar). Läuft im ECHTEN App-Prozess mit den ECHTEN Monitoren.
//
// Aufruf: `Fastra --selftest-findbar`. Der Test postet ein echtes CMD+F in
// die Event-Queue (läuft dadurch durch alle lokalen Monitore, genau wie ein
// Tastendruck), und prüft danach, ob CodeEditSourceEditors eigenes
// Find-Panel aufgetaucht ist. Gibt `SELFTEST findbar: PASS/FAIL` aus und
// beendet die App mit Exit-Code 0/1 — so im CI/Skript auswertbar.
//
// Bewusst KEIN Accessibility/System-Events nötig: das Event wird intern
// gepostet, nicht über die Systemsteuerung simuliert.

import AppKit
import WebKit
// Echte Editor-Klasse von CodeEditSourceEditor (Modul CodeEditTextView).
// Wird gebraucht, um im Sprung-Selbsttest die TATSÄCHLICHE Selektion des
// Editors (`TextView.selectedRange()` + `.string`) zurückzulesen.
import CodeEditTextView
// Sprach-Registry — für die FAIL-Diagnose des Highlight-Selbsttests
// (erkannte Sprache, tree-sitter-Grammatik, Query-Pfad).
import CodeEditLanguages

enum SelfTest {
    /// Pro Selbsttest-Prozess genau eine isolierte Defaults-Suite. Mehrere
    /// Dokumentfenster müssen dieselbe Suite teilen; würde jeder Aufruf sie
    /// erneut leeren, hielte sich auch das zweite Fenster fälschlich für den
    /// allerersten App-Start und bekäme den Demo-Inhalt statt eines Leer-Tabs.
    private static var cachedWorkspaceDefaults: UserDefaults?
    /// Hält die beiden produktiven Suchfenster des `multisearch`-Tests bis
    /// zum Prozessende stark am Leben, analog zu `ContentView.searchPanel`.
    private static var retainedSearchPanels: [SearchPanelController] = []

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
        case "multisearch": waitForMainWindow { runMultiWindowSearchJumpTest() }
        case "cmdw":      waitForMainWindow { openSearchThen { runCmdWTest() } }
        case "fields":    waitForMainWindow { openSearchThen { runFieldsTest() } }
        case "tabswitch": waitForMainWindow { runTabSwitchTest() }
        case "highlight": waitForMainWindow { runHighlightTest() }
        case "markdown":  waitForMainWindow { runMarkdownRenderTest() }
        case "jump":      waitForMainWindow { runJumpTest() }
        case "ghosttext": waitForMainWindow { runGhostTextTest() }
        case "replaceall": waitForMainWindow { runReplaceAllTest() }
        case "pilldrop":  waitForMainWindow { openSearchThen { runPillDropTest() } }
        case "navmatch":  waitForMainWindow { openSearchThen { runNavMatchTest() } }
        case "scrolljump": waitForMainWindow { runScrollJumpTest() }
        case "hscroll":   waitForMainWindow { runHScrollTest() }
        case "crjump":    waitForMainWindow { runCRJumpTest() }
        case "textop":    waitForMainWindow { runTextOpTest() }
        case "colsel":    waitForMainWindow { runColumnSelectionTest() }
        case "gutterdim": waitForMainWindow { runGutterDimmingTest() }
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
                + "(bekannt: findbar, newwindow, cmdw, fields, tabswitch, highlight, markdown, jump, ghosttext, replaceall, pilldrop, navmatch, search, project, git, gitactions, filemodes, selsearch, wildcard, textop, colsel, gutterdim, contrast, windows)")
        }
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
        guard let original = Workspace.shared,
              let originalID = original.activeTabID,
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
        postCmd("n", keyCode: 45, windowNumber: mainWindow.windowNumber)
        pollForNewWindow(original: original, originalWindow: mainWindow, marker: marker)
    }

    private static func pollForNewWindow(
        original: Workspace,
        originalWindow: NSWindow,
        marker: String,
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
        // Hauptfenster = sichtbares Fenster, das NICHT die Suchmaske ist.
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }

        guard let textView = editorTextView(in: root) else {
            finish(false, "keine Editor-TextView im Hauptfenster")
        }

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
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }
        guard let tv1 = editorTextView(in: root) else {
            finish(false, "keine Editor-TextView vor dem Tab-Wechsel")
        }
        let id1 = ObjectIdentifier(tv1)

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
                guard let tv2 = editorTextView(in: root) else {
                    finish(false, "keine Editor-TextView nach dem Tab-Wechsel")
                }
                let recreated = ObjectIdentifier(tv2) != id1
                let modelOK = ws.activeTab?.content == marker
                if !recreated {
                    finish(false, "Editor-TextView NICHT neu erzeugt — Inhalt bliebe stehen (genau der Drop-Bug)")
                } else if !modelOK {
                    finish(false, "Editor neu erzeugt, aber aktiver Tab trägt nicht den neuen Inhalt")
                } else {
                    finish(true, "Editor bei Tab-Wechsel neu erzeugt + aktiver Tab hat neuen Datei-Inhalt")
                }
            }
        }
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
            // SwiftUI/CESE Zeit geben, den Editor neu zu erzeugen + Inhalt zu laden.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let tvView = editorTextView(in: root), let tv = tvView as? TextView else {
                    finish(false, "(\(label)) Editor-TextView nicht als CodeEditTextView.TextView erreichbar")
                }
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
    /// „Umbruch aus" aussagekräftig → App dazu mit
    /// `defaults write de.dm0.fastra editor.wrapLines NO` starten.
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
    /// end-to-end: Buffer laden, `.fastraTextOp` (uppercase) posten — wie es
    /// das „Text"-Menü tut — und prüfen, dass der ECHTE Editor-Inhalt danach
    /// großgeschrieben ist. Deckt Observer (AppDelegate) → `applyToActiveEditor`
    /// → `activeEditorTextView` → `apply` → `replaceCharacters` ab. Genau die
    /// Verdrahtung, die beim alten Vorschau-Button tot war (Flag ohne Wirkung).
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
        do { try "hallo welt".write(to: tmp, atomically: true, encoding: .utf8) }
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
                    let s = tv.string
                    finish(s == "HALLO WELT",
                           "Editor-Inhalt nach Menü-Text-Op: \"\(s)\" (erwartet \"HALLO WELT\")")
                }
            }
        }
    }

    // MARK: - -selftest colsel

    /// Verifiziert die RECHTECKIGE (Spalten-)Selektion. CodeEditTextView bringt
    /// sie seit einem neueren Release mit (`TextView.selectColumns`, ALT-Drag-
    /// Delegation in `mouseDragged`) — die alte `decisions.md`-Notiz „kein
    /// ALT-Spalten-Drag" ist überholt. Da computer-use keinen modifizierten
    /// Drag (ALT gehalten) zuverlässig kann, treiben wir hier dieselbe
    /// öffentliche API, die der ALT-Drag aufruft: zwei Punkte über mehrere
    /// Zeilen → es müssen MEHRERE Selektionsbereiche entstehen.
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
                let n = tv.selectionManager.textSelections.count
                finish(n >= 2,
                       "Spalten-Selektion ergab \(n) Bereiche (erwartet ≥2) — "
                       + "ALT-Drag nutzt dieselbe selectColumns-API")
            }
        }
    }

    private static func runGutterDimmingTest() {
        testLabel = "gutterdim"
        guard let mainWindow = NSApp.windows.first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }
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
            try Data(repeating: 0x41, count: FileLoader.binaryProbeSize).write(to: large)
            let handle = try FileHandle(forWritingTo: large)
            try handle.seek(toOffset: FileLoader.largeFileThreshold + 100)
            try handle.write(contentsOf: Data([0x41]))
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

    // MARK: - --selftest-search

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
                ws.gitPullFastForward()
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
            ws.gitAmendNoEdit()
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
                          ws.gitSwitchBranch("main")
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
            ws.gitPush()
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
        // damit auf README-Screenshots (UUID-Namen sähen dort wüst aus).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Filmliste.txt")
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
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Filmliste.txt")
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
        let repo = fm.temporaryDirectory.appendingPathComponent("Webseite")
        do {
            try? fm.removeItem(at: repo)
            try fm.createDirectory(at: repo.appendingPathComponent(".git"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: repo.appendingPathComponent("styles"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: repo.appendingPathComponent("js"),
                                   withIntermediateDirectories: true)
            try "<!doctype html>\n<html lang=\"de\">\n<head>\n  <meta charset=\"utf-8\">\n  <title>Webseite</title>\n</head>\n<body>\n  <h1>Hallo!</h1>\n</body>\n</html>\n"
                .write(to: repo.appendingPathComponent("index.html"),
                       atomically: true, encoding: .utf8)
            try "# Webseite\n\nDemo-Projekt für den Screenshot.\n"
                .write(to: repo.appendingPathComponent("README.md"),
                       atomically: true, encoding: .utf8)
            try "body { margin: 0; }\n"
                .write(to: repo.appendingPathComponent("styles/main.css"),
                       atomically: true, encoding: .utf8)
            try "console.log(\"Hallo\");\n"
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
        let demo = """
        # Render-Test

        ![Lokales Pixel](pixel.png)

        Inline $x^2 + y^2$.

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
        (() => ({
          image: Array.from(document.images).some(image => image.naturalWidth > 0),
          math: !!document.querySelector('.math-inline math'),
          mermaid: !!document.querySelector('.mermaid-render svg'),
          highlight: !!document.querySelector('pre code.hljs span')
        }))()
        """
        webView.evaluateJavaScript(script) { result, error in
            let flags = result as? [String: Bool]
            let passed = flags?["image"] == true
                && flags?["math"] == true
                && flags?["mermaid"] == true
                && flags?["highlight"] == true
            if passed {
                try? FileManager.default.removeItem(at: directory)
                finish(true, "lokales Bild + KaTeX + Mermaid + Syntax-Highlighting im echten DOM")
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
            try "# Webseite\n".write(to: repo.appendingPathComponent("README.md"),
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
                    // styles/main.css ändern (Ordner-Rollup), neue Datei (U).
                    try? "# Webseite\n\nNeu.\n".write(to: repo.appendingPathComponent("README.md"),
                                                      atomically: true, encoding: .utf8)
                    try? "body{margin:0;padding:0}\n".write(to: repo.appendingPathComponent("styles/main.css"),
                                                            atomically: true, encoding: .utf8)
                    try? "console.log(1)\n".write(to: repo.appendingPathComponent("app.js"),
                                                  atomically: true, encoding: .utf8)
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: afterStatus)
                    }
                }
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

    // MARK: - --selftest-contrast

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
