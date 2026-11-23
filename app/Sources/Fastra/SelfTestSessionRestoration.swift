// Startfixtures und vollständige Wiederherstellungsprüfungen teilen einen
// prozesslangen Besitzer. Gemeinsame UI-Helfer und der Abschluss bleiben im Root.
import AppKit
import Foundation
import WebKit
import CodeEditTextView
import CodeEditSourceEditor

final class SelfTestSessionRestoration {
    struct Runtime {
        let defaults: () -> UserDefaults
        let waitFor: (TimeInterval, TimeInterval, @escaping () -> Bool,
                      @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void
        let finish: (Bool, String) -> Never
        let windowsSummary: () -> String
        let verifyNativeWindowTabSelection: (Workspace, NSWindow, Bool, @escaping (Bool, String) -> Void) -> Void
        let selectionScrollWorkspace: () -> Workspace?
        let selectionScrollMissingWorkspaceMessage: () -> String
        let selectionScrollWindows: () -> [NSWindow]
        let markdownWebView: (NSView) -> WKWebView?
        let editorTextView: (NSView) -> NSView?
        let sourceEditorController: (TextView) -> TextViewController?
        let markerViewExists: (String, NSView) -> Bool
        let typeScrollLayerSnapshot: (NSWindow) -> Data?
    }

    private let runtime: Runtime

    init(runtime: Runtime) { self.runtime = runtime }

    /// Fixture der echten Start-Sitzungswiederherstellung. Sie wird noch vor
    /// dem ersten Workspace angelegt und unmittelbar vor dem Test-Exit
    /// entfernt.
    private var sessionRestoreFixtureDirectory: URL?
    private var sessionRestoreSetupError: String?
    /// Kombiniertes Kaltstart-Fixture: LaunchServices liefert eine ausdrücklich
    /// geöffnete Datei, während im isolierten Store eine andere alte Sitzung
    /// liegt. Genau diese Konkurrenz hat die Finder-Datei bisher verdrängt.
    private var coldOpenFixtureDirectory: URL?
    private var coldOpenExternalURL: URL?
    private var coldOpenRestoredURLs: [URL] = []
    private var coldOpenRestoredProjectURLs: [URL] = []
    private var coldOpenSetupError: String?
    /// Eigenes Kaltstart-Fixture für den Auswahl-Scrolltest. Es benutzt
    /// denselben produktiven SessionStateStore wie ein normaler App-Start.
    private var selectionScrollFixtureDirectory: URL?
    private var selectionScrollFixtureURL: URL?
    private var selectionScrollSetupError: String?

    /// Die Rootschleife entfernt zuerst alle Verzeichnisse; erst danach
    /// werden wie bisher die drei eigenen Verzeichnisreferenzen geleert.
    var fixtureDirectories: [URL?] {
        [sessionRestoreFixtureDirectory, coldOpenFixtureDirectory, selectionScrollFixtureDirectory]
    }

    func clearFixtureDirectoryReferences() {
        sessionRestoreFixtureDirectory = nil
        coldOpenFixtureDirectory = nil
        selectionScrollFixtureDirectory = nil
    }

    private func workspaceDefaults() -> UserDefaults { runtime.defaults() }

    private func waitFor(budget: TimeInterval, pause: TimeInterval,
                         condition: @escaping () -> Bool,
                         onTimeout: @escaping (SelfTestPollBudget) -> Void,
                         then: @escaping () -> Void) {
        runtime.waitFor(budget, pause, condition, onTimeout, then)
    }

    private func finish(_ ok: Bool, _ message: String) -> Never {
        runtime.finish(ok, message)
    }

    private func windowsSummary() -> String { runtime.windowsSummary() }

    private func verifyNativeWindowTabSelection(
        workspace: Workspace, window: NSWindow, requireTabChange: Bool = true,
        completion: @escaping (Bool, String) -> Void
    ) {
        runtime.verifyNativeWindowTabSelection(workspace, window, requireTabChange, completion)
    }

    private func markdownWebView(in view: NSView) -> WKWebView? { runtime.markdownWebView(view) }
    private func editorTextView(in view: NSView) -> NSView? { runtime.editorTextView(view) }
    private func sourceEditorController(for textView: TextView) -> TextViewController? {
        runtime.sourceEditorController(textView)
    }
    private func markerViewExists(id: String, in view: NSView) -> Bool { runtime.markerViewExists(id, view) }
    private func typeScrollLayerSnapshot(window: NSWindow) -> Data? { runtime.typeScrollLayerSnapshot(window) }

    /// Legt den Codable-Snapshot vor `FastraApp` seinen ersten Workspace
    /// erzeugt in der isolierten Selbsttest-Suite ab. So prüft der spätere
    /// Test den echten Kaltstartpfad statt nur Workspace-Methoden direkt
    /// aufzurufen.
    func prepareSessionRestoreFixture() {
        let directory = selfTestTemporaryDirectory()
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

    /// Der Runner legt die externe Datei vor dem Launch an und reicht ihren
    /// Pfad über eine prozesslokale Umgebungsvariable weiter. Parallel entsteht
    /// hier eine abweichende gespeicherte Sitzung in derselben isolierten
    /// Defaults-Suite, die der produktive AppDelegate beim Start liest.
    func prepareColdOpenFixture(restoreEnabled: Bool) {
        let directory = selfTestTemporaryDirectory()
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

    func prepareSelectionScrollFixture() {
        let directory = selfTestTemporaryDirectory()
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

    private func selectionScrollContent() -> String {
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

    func runSessionRestoreTest() {
        if let sessionRestoreSetupError {
            finish(false, "Fixture konnte nicht angelegt werden: \(sessionRestoreSetupError)")
        }
        guard let directory = sessionRestoreFixtureDirectory else {
            finish(false, "Fixture-Verzeichnis fehlt")
        }
        var windows: [NSWindow] = []
        var workspaces: [Workspace] = []
        waitFor(budget: 10, pause: 0.05,
                condition: {
                    windows = MainActor.assumeIsolated {
                        DocumentWindowController.visibleDocumentWindows()
                    }
                    workspaces = windows.compactMap {
                        WorkspaceWindowRegistry.workspace(for: $0)
                    }
                    let loading = workspaces.contains { workspace in
                        workspace.tabs.contains(where: \.isLoading)
                    }
                    return windows.count == 2 && workspaces.count == 2 && !loading
                },
                onTimeout: { [self] book in
                    try? FileManager.default.removeItem(at: directory)
                    finish(false, "Sitzung nicht vollständig — \(book.summary) — \(windowsSummary())")
                },
                then: { [self] in
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
                    // Nach der Wiederherstellung muss jedes Fenster genau ein Tab-Untermenü
                    // besitzen, ohne zusätzlichen AppKit-Eintrag. Der Aufbau muss nachgeholt
                    // werden, falls `NSApp.windowsMenu` beim ersten Titelsetzen noch fehlt.
                    let duplicatePlainEntries = MainActor.assumeIsolated { () -> [String] in
                        (NSApp.windowsMenu?.items ?? [])
                            .filter { $0.submenu == nil && ["eins.txt", "drei.txt"].contains($0.title) }
                            .map(\.title)
                    }
                    guard duplicatePlainEntries.isEmpty else {
                        try? FileManager.default.removeItem(at: directory)
                        finish(false, "Fenster-Menü führt Dokumentfenster doppelt "
                            + "(AppKit-Eintrag ohne Untermenü: \(duplicatePlainEntries))")
                    }
                    guard let projectWindow = windows.first(where: {
                        WorkspaceWindowRegistry.workspace(for: $0) === projectWorkspace
                    }), let otherWindow = windows.first(where: { $0 !== projectWindow }),
                          let otherWorkspace = WorkspaceWindowRegistry.workspace(for: otherWindow) else {
                        try? FileManager.default.removeItem(at: directory)
                        finish(false, "wiederhergestellte Fenster nicht ihren Workspaces zugeordnet")
                    }
                    verifyNativeWindowTabSelection(workspace: projectWorkspace, window: projectWindow) { [self] ok, detail in
                        guard ok else {
                            try? FileManager.default.removeItem(at: directory)
                            finish(false, "Projektfenster nach Wiederherstellung: " + detail)
                        }
                        // Das zweite wiederhergestellte Fenster besitzt absichtlich
                        // nur einen Tab. Auch sein Untermenü muss real geöffnet werden.
                        verifyNativeWindowTabSelection(workspace: otherWorkspace, window: otherWindow,
                                                       requireTabChange: false) { [self] ok, detail in
                            try? FileManager.default.removeItem(at: directory)
                            finish(ok, "zwei Fenster, drei gespeicherte Tabs, Projekt und aktiver Tab "
                                + "wiederhergestellt; beide nativen Tab-Untermenüs bedient: " + detail)
                        }
                    }
                })
    }

    /// Prüft den echten LaunchServices-Kaltstart mit einer gespeicherten Sitzung
    /// aus zwei Projektfenstern und einer zusätzlichen externen Datei. Bei
    /// aktivierter Wiederherstellung müssen alle drei Startabsichten erhalten
    /// bleiben; bei deaktivierter darf ausschließlich die Finder-Datei öffnen.
    func runColdOpenTest(restoreEnabled: Bool) {
        if let coldOpenSetupError {
            finish(false, "Fixture konnte nicht angelegt werden: \(coldOpenSetupError)")
        }
        guard let externalURL = coldOpenExternalURL,
              coldOpenRestoredURLs.count == 2,
              coldOpenRestoredProjectURLs.count == 2 else {
            finish(false, "Kaltstart-Fixture fehlt")
        }
        // Ab dem ersten korrekten Zustand weitere 20 Abfragen (mindestens
        // eine Sekunde) beobachten. Ein verspäteter Restore oder Finder-Aufruf
        // setzt diese Ruhephase zurück; die Gesamtfrist bleibt bestehen.
        var polls = 0
        var stableSincePoll: Int?
        var openedNames: [String] = []
        waitFor(budget: 10, pause: 0.05,
                condition: { [self] in
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
                        // Neben wiederhergestellten Dateien darf kein übrig
                        // gebliebener leerer Start-Tab stehen.
                        workspace.tabs.allSatisfy { !$0.isPristineScratch }
                    }
                    && (restoreEnabled
                        ? restoredProjectsArePresent
                        : !openedURLs.contains(where: coldOpenRestoredURLs.contains))

                    openedNames = openedURLs.map(\.lastPathComponent)
                    let stable = Self.coldOpenStateIsStable(expectedState: expectedState, tick: polls,
                                                       stableSinceTick: &stableSincePoll)
                    polls += 1
                    return stable
                },
                onTimeout: { [self] book in
                    cleanupColdOpenFixture()
                    finish(false, "Kaltstartzustand nicht vollständig "
                        + "(Restore: \(restoreEnabled), Dateien: \(openedNames)) — \(book.summary) — \(windowsSummary())")
                },
                then: { [self] in
                    cleanupColdOpenFixture()
                    finish(
                        true,
                        restoreEnabled
                            ? "zwei Projektfenster wiederhergestellt; Finder-Datei zusätzlich geöffnet"
                            : "Wiederherstellung aus; ausschließlich Finder-Datei geöffnet"
                    )
                })
    }

    /// Prüft die Ruhephase anhand der tatsächlich beobachteten Zustandsfolge.
    static func coldOpenStateIsStable(
        expectedState: Bool, tick: Int, stableSinceTick: inout Int?
    ) -> Bool {
        guard expectedState else {
            stableSinceTick = nil
            return false
        }
        if stableSinceTick == nil { stableSinceTick = tick }
        return tick - (stableSinceTick ?? tick) >= 20
    }

    private func cleanupColdOpenFixture() {
        if let coldOpenFixtureDirectory {
            try? FileManager.default.removeItem(at: coldOpenFixtureDirectory)
        }
    }

    /// Prüft im gepackten Editor den NSTextInputClient-Befehl, den AppKit für
    /// Shift+Pfeil nach unten aufruft. Die Messung verwendet bewusst die
    /// bewegte Range-Kante selbst und nicht CodeEdits Scroll-Hilfsfunktion.
    func runSelectionScrollTest() {
        if let selectionScrollSetupError {
            finishSelectionScroll(
                false,
                "Kaltstart-Fixture nicht anlegbar: \(selectionScrollSetupError)"
            )
        }
        guard let ws = runtime.selectionScrollWorkspace() else {
            finishSelectionScroll(
                false,
                runtime.selectionScrollMissingWorkspaceMessage()
            )
        }
        guard let mainWindow = runtime.selectionScrollWindows().first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finishSelectionScroll(false, "kein Hauptfenster gefunden")
        }
        pollForMarkdownSelectionScrollEditor(
            ws: ws, mainWindow: mainWindow, root: root)
    }

    /// Wartet ausdrücklich auf beide Hälften des Markdown-Splits. So kann ein
    /// TextView-only-Test nicht erneut die entscheidende Produktansicht
    /// umgehen, in der der Nutzer den fehlenden Scroll beobachtet hat.
    private func pollForMarkdownSelectionScrollEditor(
        ws: Workspace, mainWindow: NSWindow, root: NSView
    ) {
        var textView: TextView?
        waitFor(budget: 10, pause: 0.1,
                condition: { [self] in
                    let markdownReady = ws.activeTab?.isLoading == false
                        && ws.activeTab?.url?.canonicalFileURL
                            == selectionScrollFixtureURL?.canonicalFileURL
                        && markdownWebView(in: root) != nil
                    guard markdownReady,
                          let candidate = editorTextView(in: root) as? TextView,
                          sourceEditorController(for: candidate) != nil else { return false }
                    textView = candidate
                    return true
                },
                onTimeout: { [self] book in
                    finishSelectionScroll(
                        false,
                        "Markdown-Split mit linkem Editor nicht bereit — \(book.summary)"
                    )
                },
                then: { [self] in
                    guard let textView else { finish(false, "linker Editor nach Erfolg verschwunden") }
                    exerciseMarkdownSelectionScroll(
                        textView: textView, mainWindow: mainWindow
                    )
                })
    }

    /// Sendet echte Shift+↓-Events an den fokussierten linken Editor. Zwischen
    /// den einzelnen Tastenläufen liegt jeweils ein Runloop-Durchlauf wie bei
    /// mehreren echten Tastendrücken; erst danach wird der Viewport gemessen.
    private func exerciseMarkdownSelectionScroll(
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

    private func sendMarkdownSelectionScrollKey(
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
                sendMarkdownSelectionScrollKey(
                    textView: textView,
                    scrollView: scrollView,
                    mainWindow: mainWindow,
                    initialTop: initialTop,
                    step: step + 1
                )
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
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

    private func finishSelectionScroll(
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

    /// Der separate CLI-Runner startet diese App ausschließlich durch den
    /// gebündelten Helfer. So belegt der Test den echten LaunchServices-Kaltstart.
    @MainActor
    func pollExternalDiffCold() {
        let expected = Int(ProcessInfo.processInfo.environment["FASTRA_DIFF_COLD_COUNT"] ?? "1") ?? 1
        var windows = ExternalDiffWindow.openWindows
        var ready = false
        var polls = 0
        // Ausgewertet wird in beiden Ausgängen: Erfolg und abgelaufene Frist
        // führen in dieselbe Prüfung, die `ready` selbst bewertet.
        func evaluate() {
            // Die von `prepareLaunchEnvironment` angelegte Sitzungs-Fixture explizit
            // aufräumen. LaunchServices ersetzt TMPDIR; sie kann deshalb außerhalb der
            // Runner-Sandbox im Benutzer-Temp liegen.
            if let directory = sessionRestoreFixtureDirectory {
                try? FileManager.default.removeItem(at: directory)
            }
            let active = NSApp.isActive
            let key = windows.contains { $0.window.isKeyWindow }
            var passed = ready
            if let directory = ProcessInfo.processInfo.environment["FASTRA_DIFF_COLD_SCREENSHOTS"] {
                // Aufnahmen aus den tatsächlich gezeichneten Fenster-Layern. Dafür
                // ist keine neue Bildschirmaufnahme-Berechtigung erforderlich.
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                let normal = DocumentWindowController.visibleDocumentWindows().first
                if let diff = windows.first, let normal,
                   let diffImage = typeScrollLayerSnapshot(window: diff.window),
                   let normalImage = typeScrollLayerSnapshot(window: normal) {
                    do {
                        try diffImage.write(to: root.appendingPathComponent("external-diff.png"))
                        try normalImage.write(to: root.appendingPathComponent("normal-window.png"))
                    } catch { passed = false }
                } else { passed = false }
                passed = passed && active && key
            }
            for controller in windows {
                controller.window.makeKeyAndOrderFront(nil)
                passed = passed && CommandTargeting.targetWorkspace() == nil
                passed = passed && CommandTargeting.targetEditorTextView() == nil
            }
            if let path = ProcessInfo.processInfo.environment["FASTRA_DIFF_COLD_RESULT"] {
                let result = "SELFTEST-RESULT v=1 test=externaldiffcold status=\(passed ? "PASS" : "FAIL")\n"
                    + "windows=\(windows.count) rendered=\(ready) writableTarget=false\n"
                    + "active=\(active) key=\(key)\n"
                do { try result.write(toFile: path, atomically: true, encoding: .utf8) }
                catch { finish(false, "Kaltstart-Testbericht konnte nicht geschrieben werden") }
            }
            NSApp.hide(nil)
            for controller in windows { controller.window.close() }
            finish(passed, "Kaltstart über Helfer: \(windows.count) Diff-Fenster, erwartet \(expected)")
        }
        waitFor(budget: 15, pause: 0.1,
                condition: { [self] in
                    windows = ExternalDiffWindow.openWindows
                    ready = windows.count == expected && windows.allSatisfy { controller in
                        controller.model.document?.result?.blocks.count == 1
                            && controller.window.contentView.map { markerViewExists(id: "diffState-b1-c0", in: $0) } == true
                    }
                    polls += 1
                    // Mindestens eine Sekunde beobachten, damit unmittelbar doppelte
                    // Zustellungen nicht erst nach dem erfolgreichen Test sichtbar werden.
                    return ready && polls > 10
                },
                onTimeout: { _ in evaluate() },
                then: { evaluate() })
    }
}
