// Finder-/Dock-Ereignisse und der vollständige Mehrfenster-Schließablauf
// teilen ihren Fixturebesitz. Gemeinsame Dienste und der Abschluss bleiben Root.
import AppKit
import Foundation
import CodeEditTextView

final class SelfTestWindowRouting {
    struct Runtime {
        let currentWorkspace: () -> Workspace?
        let windows: () -> [NSWindow]
        let waitFor: (TimeInterval, TimeInterval, @escaping () -> Bool,
                      @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void
        let finish: (SelfTestOutcome, String) -> Never
        let windowsSummary: () -> String
        let activateApplication: (Bool) -> Void
        let menuItem: (String, NSMenu) -> NSMenuItem?
        let postCmd: (String, UInt16, Int) -> Void
        let editorTextView: (NSView) -> NSView?
        let writeSolidPNG: (URL, Int, Int) throws -> Void
        let verifyNativeWindowTabSelection: (Workspace, NSWindow, Bool,
                                            @escaping (Bool, String) -> Void) -> Void
        let typeScrollCapture: (NSWindow,
                                @escaping (SelfTest.TypeScrollSnapshot?) -> Void) -> Void
    }

    private let runtime: Runtime

    init(runtime: Runtime) { self.runtime = runtime }

    /// Reproduziert im `cmdw`-Test den gemeldeten Vorderfenster-Zustand:
    /// Ordner in der Seitenleiste, aber nur ein leerer Willkommen-Tab.
    private var windowRoutingFixtureDirectory: URL?

    var fixtureDirectory: URL? { windowRoutingFixtureDirectory }

    /// Die Rootschleife entfernt erst die Verzeichnisse und leert danach
    /// die Referenzen an derselben Stelle wie vor der Familientrennung.
    func clearFixtureDirectoryReference() { windowRoutingFixtureDirectory = nil }

    private func waitFor(budget: TimeInterval, pause: TimeInterval,
                         condition: @escaping () -> Bool,
                         onTimeout: @escaping (SelfTestPollBudget) -> Void,
                         then: @escaping () -> Void) {
        runtime.waitFor(budget, pause, condition, onTimeout, then)
    }

    private func finish(_ ok: Bool, _ message: String) -> Never {
        runtime.finish(ok ? .pass : .fail, message)
    }

    private func finish(_ outcome: SelfTestOutcome, _ message: String) -> Never {
        runtime.finish(outcome, message)
    }

    private func windowsSummary() -> String { runtime.windowsSummary() }
    private func activateApplication(ignoringOtherApps: Bool) {
        runtime.activateApplication(ignoringOtherApps)
    }
    private func menuItem(forKeyEquivalent key: String, in menu: NSMenu) -> NSMenuItem? {
        runtime.menuItem(key, menu)
    }
    private func postCmd(_ char: String, keyCode: UInt16, windowNumber: Int) {
        runtime.postCmd(char, keyCode, windowNumber)
    }
    private func editorTextView(in view: NSView) -> NSView? { runtime.editorTextView(view) }
    private func writeSolidPNG(to url: URL, width: Int, height: Int) throws {
        try runtime.writeSolidPNG(url, width, height)
    }
    private func verifyNativeWindowTabSelection(
        workspace: Workspace, window: NSWindow, requireTabChange: Bool = true,
        completion: @escaping (Bool, String) -> Void
    ) {
        runtime.verifyNativeWindowTabSelection(workspace, window, requireTabChange, completion)
    }
    private func typeScrollCapture(window: NSWindow,
                                   completion: @escaping (SelfTest.TypeScrollSnapshot?) -> Void) {
        runtime.typeScrollCapture(window, completion)
    }

    // MARK: - Finder-Öffnen nach rotem Schließen-Knopf

    /// Prüft Schließen aller Fenster und erneutes Öffnen derselben Markdown-
    /// Datei auf doppelte Fenster. `odoc` (Öffnen) und `rapp` (Dock-Reopen) gehen
    /// wie bei AppKit an SwiftUIs `NSApp.delegate`, der an Fastra weiterreicht.
    /// Der Test braucht keine App-Aktivierung.
    func runFinderReopenTest() {
        guard let original = self.runtime.currentWorkspace() else {
            self.finish(false, "kein aktiver Ausgangs-Workspace")
        }
        // Fenster und Workspace gemeinsam über die Registry bestimmen, wie
        // `CommandTargeting`. `NSApp.windows` ist unsortiert und könnte ein Fenster
        // liefern, das nicht zum geprüften Workspace gehört.
        guard let mainWindow = MainActor.assumeIsolated({
            CommandTargeting.documentWindow(for: original)
        }) else {
            self.finish(false, "kein sichtbares Dokumentfenster zum Ausgangs-Workspace")
        }
        guard WorkspaceWindowRegistry.workspace(for: mainWindow) === original else {
            self.finish(false, "Hauptfenster und Ausgangs-Workspace gehören nicht zusammen")
        }
        let folder = selfTestTemporaryDirectory()
            .appendingPathComponent("fastra-selftest-finderreopen-\(getpid())")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "# Wieder geöffnet\n\nInhalt.\n".write(
                to: folder.appendingPathComponent("Notiz.md"), atomically: true, encoding: .utf8)
        } catch {
            self.finish(false, "Fixture fehlt: \(error.localizedDescription)")
        }
        self.windowRoutingFixtureDirectory = folder
        // Erst nach dem Anlegen kanonisieren: `/var` wird sonst nicht zu
        // `/private/var` aufgelöst, und der Vergleich mit dem Tab schlägt fehl.
        let file = folder.appendingPathComponent("Notiz.md").canonicalFileURL

        guard let closeButton = mainWindow.standardWindowButton(.closeButton) else {
            self.finish(false, "Hauptfenster hat keinen Schließen-Knopf")
        }
        // Derselbe Ladeweg wie beim Öffnen per Finder; die Completion sagt,
        // wann der Tab wirklich steht.
        original.loadFile(at: file) { ok in
            guard ok, let index = original.tabs.firstIndex(where: {
                $0.url?.canonicalFileURL.path == file.path
            }) else {
                self.finish(false, "Datei kam nicht im Hauptfenster an (ok=\(ok), Tabs: "
                    + "\(original.tabs.map { $0.url?.path ?? "–" }))")
            }
            // Erste Probe: ungesicherte Änderung plus roter Knopf. Der Knopf
            // muss dieselbe Rückfrage stellen wie ⌘W; „Abbrechen" lässt das
            // Fenster stehen. Ohne Umleitung schloss SwiftUI ungefragt.
            original.tabs[index].content += "\nungesichert"
            original.tabs[index].isDirty = true
            var confirmations = 0
            let defaultHandler = original.confirmCloseHandler
            original.confirmCloseHandler = { _ in
                confirmations += 1
                return .cancel
            }
            closeButton.performClick(nil)
            var problems: [String] = []
            if confirmations != 1 || !mainWindow.isVisible {
                problems.append("roter Knopf bei ungesichertem Tab: Rückfragen=\(confirmations), "
                    + "Fenster sichtbar=\(mainWindow.isVisible) (erwartet 1 und sichtbar)")
            }
            // Zweite Probe: „Nicht sichern" — jetzt darf das Fenster zu.
            original.confirmCloseHandler = { _ in .dontSave }
            closeButton.performClick(nil)
            original.confirmCloseHandler = defaultHandler
            self.waitUntilSelfTest(limit: 100, failure: "Hauptfenster schloss nicht "
                + "(\(problems.joined(separator: "; ")))") {
                !mainWindow.isVisible
            } then: {
                // Ein geschlossenes Fenster darf seine Datei nicht behalten —
                // sonst bringt es sie beim nächsten Anzeigen ungefragt zurück.
                // Der Befund wird gesammelt, nicht sofort gemeldet: Die
                // folgenden Phasen zeigen, welche sichtbare Folge er hat.
                let leftover = original.tabs.compactMap { $0.url?.lastPathComponent }
                if !original.isWelcomeScreen
                    || original.tabs.contains(where: { $0.url?.canonicalFileURL.path == file.path }) {
                    problems.append("geschlossenes Hauptfenster behielt seine Tabs: "
                        + "\(leftover), Willkommen=\(original.isWelcomeScreen)")
                }
                print("finderreopen: Delegate des Hauptfensters = "
                    + "\(mainWindow.delegate.map { String(describing: type(of: $0)) } ?? "nil")")
                self.deliverOpenDocumentsEvent(for: file)
                self.waitUntilSelfTest(limit: 100,
                                  failure: "Öffnen-Ereignis zeigte die Datei in keinem Fenster") {
                    self.documentWindows(showing: file).count >= 1
                } then: {
                    // Ein wieder angezeigtes Hauptfenster muss in der Registry
                    // stehen — der Rückfall über die Titelbrücke (v1.118.3)
                    // ist eine Reparatur, keine Registrierung. Ohne Eintrag
                    // zählte das Fenster in v1.117.2 nicht als Dokumentfenster,
                    // und die Datei bekam ein zweites Fenster.
                    let registered = WorkspaceWindowRegistry.registeredWindows()
                        .contains { $0 === mainWindow }
                    print("finderreopen: Hauptfenster sichtbar=\(mainWindow.isVisible) "
                        + "registriert=\(registered)")
                    if mainWindow.isVisible, !registered {
                        problems.append("wieder angezeigtes Hauptfenster fehlt in der Fenster-Registry")
                    }
                    // Ein zweites Fenster kann erst nach dem ersten erscheinen
                    // (SwiftUI zeigt seine Szene asynchron). Bewusst warten.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let showing = self.documentWindows(showing: file)
                        if showing.count != 1 {
                            problems.append("Öffnen-Ereignis zeigte die Datei in "
                                + "\(showing.count) Fenstern (Größen: "
                                + "\(showing.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" }))")
                        }
                        self.verifyReopenWithoutWindows(file: file, problems: problems)
                    }
                }
            }
        }
    }

    /// Zweite Hälfte: Alle Fenster zu, dann Dock-Klick (`rapp`). Danach darf
    /// genau ein Dokumentfenster stehen — nicht eines von AppKit und eines von
    /// SwiftUI — und die zuvor geschlossene Datei darf darin nicht ungefragt
    /// wieder auftauchen: Genau das war in v1.117.2 die sichtbare Folge der
    /// stehen gebliebenen Tabs.
    private func verifyReopenWithoutWindows(file: URL, problems: [String]) {
        var problems = problems
        for window in MainActor.assumeIsolated({ DocumentWindowController.visibleDocumentWindows() }) {
            if let workspace = WorkspaceWindowRegistry.workspace(for: window) {
                workspace.tabs.indices.forEach { workspace.tabs[$0].isDirty = false }
            }
            window.performClose(nil)
        }
        self.waitUntilSelfTest(limit: 100, failure: "Dateifenster schlossen nicht") {
            MainActor.assumeIsolated { DocumentWindowController.visibleDocumentWindows().isEmpty }
        } then: {
            self.deliverReopenEvent()
            self.waitUntilSelfTest(limit: 100, failure: "Reopen zeigte kein Fenster") {
                MainActor.assumeIsolated { !DocumentWindowController.visibleDocumentWindows().isEmpty }
            } then: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let windows = MainActor.assumeIsolated {
                        DocumentWindowController.visibleDocumentWindows()
                    }
                    if windows.count != 1 {
                        problems.append("Reopen ohne Fenster zeigte \(windows.count) Fenster (Größen: "
                            + "\(windows.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" }))")
                    }
                    let resurrected = self.documentWindows(showing: file)
                    if !resurrected.isEmpty {
                        problems.append("Reopen ohne Fenster brachte die geschlossene Datei "
                            + "\(file.lastPathComponent) in \(resurrected.count) Fenster(n) zurück")
                    }
                    guard problems.isEmpty else {
                        self.finish(false, problems.joined(separator: "; "))
                    }
                    self.finish(true, "Datei nach rotem Schließen genau einmal wieder geöffnet, "
                        + "Reopen ohne Fenster zeigt genau ein Fenster")
                }
            }
        }
    }

    /// Alle sichtbaren Dokumentfenster, deren Workspace die Datei zeigt.
    private func documentWindows(showing file: URL) -> [NSWindow] {
        MainActor.assumeIsolated {
            DocumentWindowController.visibleDocumentWindows().filter { window in
                WorkspaceWindowRegistry.workspace(for: window)?.tabs
                    .contains { $0.url?.canonicalFileURL.path == file.path } ?? false
            }
        }
    }

    /// Externe Öffnen-/Reopen-Ereignisse an SwiftUIs `NSApp.delegate` zustellen,
    /// wie AppKit nach `odoc` bzw. `rapp`. SwiftUI aktiviert zuerst seine Szene
    /// und reicht dann an Fastra weiter.
    ///
    /// Ein echtes Apple-Event an denselben Prozess ist ungeeignet: Auf Main
    /// kann es in errAETimeout (-1712) enden; im Hintergrund würde AppKit den
    /// Fensteraufbau auf dem falschen Thread beginnen. Getrennte Funktionen
    /// halten Öffnen und Reopen als unterschiedliche Ereignisse sichtbar.
    private func externalEventDelegate() -> NSApplicationDelegate {
        guard let delegate = NSApp.delegate else {
            self.finish(false, "NSApp.delegate fehlt")
        }
        return delegate
    }

    /// `odoc`: Finder-Doppelklick auf eine Datei.
    private func deliverOpenDocumentsEvent(for fileURL: URL) {
        self.deliverOpenDocumentsEvent(for: [fileURL])
    }

    private func deliverOpenDocumentsEvent(for fileURLs: [URL]) {
        let delegate = self.externalEventDelegate()
        guard delegate.responds(to: #selector(NSApplicationDelegate.application(_:open:))) else {
            self.finish(false, "App-Delegate beantwortet application(_:open:) nicht")
        }
        delegate.application?(NSApp, open: fileURLs)
    }

    /// Misst neben dem Property auch AppKits tatsächlich sichtbares Titelfeld.
    /// Ein grünes `titleVisibility` allein übersieht einen hängen gebliebenen Titel.
    func runWindowChromeTest() {
        Task { @MainActor in
            let directory = selfTestTemporaryDirectory().appendingPathComponent("window-chrome-\(UUID().uuidString)")
            self.windowRoutingFixtureDirectory = directory
            var failures: [String] = []
            func inspect(_ window: NSWindow, _ phase: String) {
                var nativeTitles: [String] = []
                func visit(_ view: NSView) {
                    guard view !== window.contentView else { return }
                    if let field = view as? NSTextField,
                       !field.isHiddenOrHasHiddenAncestor, field.alphaValue > 0,
                       field.stringValue == window.title {
                        nativeTitles.append(field.stringValue)
                    }
                    view.subviews.forEach(visit)
                }
                if let frameView = window.contentView?.superview { visit(frameView) }
                FileHandle.standardError.write(Data("WINDOW_CHROME \(phase) hidden=\(window.titleVisibility == .hidden) nativeTitles=\(nativeTitles.count) title=\(window.title)\n".utf8))
                if window.titleVisibility != .hidden || !nativeTitles.isEmpty {
                    failures.append("\(phase): native Titel sichtbar (\(nativeTitles.count)), hidden=\(window.titleVisibility == .hidden)")
                }
                if !window.styleMask.contains(.fullSizeContentView) || !window.titlebarAppearsTransparent {
                    failures.append("\(phase): eigener Fenster-Chrome fehlt")
                }
            }
            func settle() async { try? await Task.sleep(for: .milliseconds(300)) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let paths = ["Erste lange gemeinsam geöffnete Textdatei.txt", "Zweite lange gemeinsam geöffnete Textdatei.txt"].map { directory.appendingPathComponent($0) }
                for file in paths { try "Eigener Prüfinhalt\n".write(to: file, atomically: true, encoding: .utf8) }
                let files = paths.map(\.canonicalFileURL)
                guard let original = self.runtime.currentWorkspace(),
                      let main = CommandTargeting.documentWindow(for: original) else {
                    self.finish(false, "Ausgangsfenster fehlt")
                }
                // Ein belegtes Fenster erzwingt den zusätzlichen AppKit-Fensterpfad.
                original.openNewTab()
                if let index = original.tabs.firstIndex(where: { $0.id == original.activeTabID }) {
                    original.tabs[index].content = "Ausgangsfenster bleibt belegt"
                    original.tabs[index].isDirty = true
                }
                await settle()
                inspect(main, "main")
                self.deliverOpenDocumentsEvent(for: files)
                var target: NSWindow?
                for _ in 0..<100 {
                    target = DocumentWindowController.visibleDocumentWindows().first { window in
                        guard let ws = WorkspaceWindowRegistry.workspace(for: window) else { return false }
                        return files.allSatisfy { file in ws.tabs.contains { $0.url?.canonicalFileURL == file } }
                    }
                    if target != nil { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard let target, target !== main,
                      let workspace = WorkspaceWindowRegistry.workspace(for: target) else {
                    let actual = DocumentWindowController.visibleDocumentWindows().map { window in
                        "\(window.identifier?.rawValue ?? "main") visible=\(window.isVisible): \(WorkspaceWindowRegistry.workspace(for: window)?.tabs.compactMap { $0.url?.path } ?? [])"
                    }
                    self.finish(false, "Gemeinsam geöffnete Dateien fehlen im zusätzlichen Fenster; erwartet=\(files.map(\.path)), tatsächlich=\(actual)")
                }
                await settle()
                inspect(target, "multi-open")
                for file in files + files.reversed() {
                    self.deliverOpenDocumentsEvent(for: file)
                    await settle()
                    inspect(target, "reopen-\(file.lastPathComponent)")
                }
                target.setContentSize(NSSize(width: MainWindowSizing.minimumWidth, height: MainWindowSizing.minimumHeight))
                await settle()
                inspect(target, "resize")
                guard workspace.tabs.filter({ $0.url != nil }).count == 2 else {
                    self.finish(false, "Wiederholtes Öffnen dupliziert Tabs")
                }
                let restored = DocumentWindowController.openRestoredDocument(RestorableWindowState(
                    projectPath: directory.path, documentPaths: files.map(\.path),
                    activeDocumentPath: files[1].path, frame: nil))
                for _ in 0..<100 {
                    if restored.tabs.filter({ $0.url != nil }).count == 2 { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                await settle()
                guard let restoredWindow = CommandTargeting.documentWindow(for: restored) else {
                    self.finish(false, "Wiederhergestelltes Fenster fehlt")
                }
                inspect(restoredWindow, "restore")
                if let output = ProcessInfo.processInfo.environment["FASTRA_WINDOWCHROME_DIR"] {
                    let folder = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    for (name, window) in [("main", main), ("additional", target), ("restored", restoredWindow)] {
                        let snapshot: SelfTest.TypeScrollSnapshot? = await withCheckedContinuation { done in
                            self.typeScrollCapture(window: window) { done.resume(returning: $0) }
                        }
                        if let snapshot {
                            try snapshot.data.write(to: folder.appendingPathComponent(name + ".png"))
                            print("WINDOW_CHROME_CAPTURE \(name) \(snapshot.source)")
                        }
                    }
                }
                self.finish(failures.isEmpty, failures.isEmpty ? "Haupt-, Mehrdatei- und Restorefenster ohne nativen Titel; Wiederöffnen, Tabwechsel und Resize geprüft" : failures.joined(separator: "; "))
            } catch { self.finish(false, error.localizedDescription) }
        }
    }

    /// `rapp`: Dock-Klick ohne sichtbares Fenster.
    private func deliverReopenEvent() {
        let delegate = self.externalEventDelegate()
        guard delegate.responds(to: #selector(
            NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)
        )) else {
            self.finish(false, "App-Delegate beantwortet applicationShouldHandleReopen nicht")
        }
        _ = delegate.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
    }

    /// Kleines Polling für diesen Test: 50-ms-Takt bis `condition` gilt,
    /// sonst nach `limit` Takten bedienter Zeit ehrlicher FAIL.
    private func waitUntilSelfTest(
        limit: Int, failure: String,
        condition: @escaping () -> Bool, then body: @escaping () -> Void
    ) {
        self.waitFor(budget: Double(limit) * 0.05, pause: 0.05,
                condition: condition,
                onTimeout: { book in self.finish(false, "\(failure) — \(book.summary)") },
                then: body)
    }

    // MARK: - ⌘N / unabhängiges Dokumentfenster

    /// Führt den echten Menüpunkt mit ⌘N aus und prüft danach zwei Dinge, die
    /// ein reiner Unit-Test nicht sehen kann: Es erscheint ein zweites Fenster,
    /// und dessen neuer Workspace teilt seinen Inhalt nicht mit dem ersten.
    func runNewWindowTest(focusedCommandRouting: Bool = false) {
        guard let original = self.runtime.currentWorkspace() else {
            self.finish(false, "kein aktiver Ausgangs-Workspace")
        }
        // Im reinen Willkommenszustand wirkt ⌘N inzwischen bewusst wie ⌘T
        // (Selbsttest `welcomenew`).
        // Für den Fenster-Test daher zuerst einen normalen Editor-Tab
        // öffnen — danach ist ⌘N wieder das Fenster-Kommando.
        if original.isWelcomeScreen { original.openNewTab() }
        guard let originalID = original.activeTabID,
              let originalIndex = original.tabs.firstIndex(where: { $0.id == originalID }) else {
            self.finish(false, "kein aktiver Ausgangs-Workspace")
        }

        let marker = "Inhalt nur im ersten Fenster"
        original.tabs[originalIndex].content = marker

        guard let mainMenu = NSApp.mainMenu,
              self.menuItem(forKeyEquivalent: "n", in: mainMenu) != nil else {
            self.finish(false, "kein Menüpunkt mit ⌘N gefunden")
        }
        guard let mainWindow = self.runtime.windows().first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName && $0.isVisible
        }) else {
            self.finish(false, "kein Ausgangsfenster für ⌘N gefunden")
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
        self.postCmd("n", keyCode: 45, windowNumber: mainWindow.windowNumber)
        self.pollForNewWindow(
            original: original,
            originalWindow: mainWindow,
            marker: marker,
            expectedSize: expectedSize,
            focusedCommandRouting: focusedCommandRouting
        )
    }


    private func pollForNewWindow(
        original: Workspace,
        originalWindow: NSWindow,
        marker: String,
        expectedSize: NSSize,
        focusedCommandRouting: Bool
    ) {
        // Zwei Stufen in einer Frist: erst Fenster samt Workspace, dann der
        // stabile Rahmen.
        var stage = 0
        var found: (workspace: Workspace, window: NSWindow)?
        self.waitFor(budget: 5, pause: 0.05,
                condition: {
                    let newWorkspace = Workspace.allLive.first { $0 !== original }
                    let newWindow = self.runtime.windows().first {
                        $0 !== originalWindow
                            && $0.identifier?.rawValue == "Fastra.DocumentWindow"
                            && $0.isVisible
                    }
                    guard let newWorkspace, let newWindow else {
                        stage = 0
                        return false
                    }
                    guard newWorkspace.tabs.count == 1,
                          let newTab = newWorkspace.activeTab,
                          newTab.title == Workspace.untitledBaseName,
                          newTab.content.isEmpty else {
                        self.finish(false, "zweites Fenster enthält kein einzelnes leeres neues Dokument")
                    }
                    // Der frische leere Tab eines neuen Fensters zeigt die Starthilfe über
                    // dem montierten Editor.
                    guard newWorkspace.isWelcomeScreen else {
                        self.finish(false, "⌘N-Fenster zeigt keinen Willkommens-Platzhalter über dem leeren Tab")
                    }
                    // Das ist die sichtbare Produktwirkung: Das neue AppKit-Fenster
                    // muss denselben tatsächlichen Rahmen wie das zuvor benutzte
                    // Fenster haben. SwiftUI darf seine fitting size im ersten Layout
                    // noch kurz melden; wir warten deshalb auf den stabilen Rahmen,
                    // statt genau in diesem Übergang voreilig fehlzuschlagen.
                    stage = 1
                    found = (newWorkspace, newWindow)
                    return abs(newWindow.frame.width - expectedSize.width) < 0.5
                        && abs(newWindow.frame.height - expectedSize.height) < 0.5
                },
                onTimeout: { book in
                    if stage == 0 {
                        self.finish(false, "kein zweites Dokumentfenster — \(book.summary) — \(self.windowsSummary())")
                    }
                    let frame = found?.window.frame ?? .zero
                    self.finish(false, "⌘N-Fenster übernimmt Größe nicht "
                        + "(erwartet \(expectedSize.width)×\(expectedSize.height), "
                        + "erhalten \(frame.width)×\(frame.height)) — \(book.summary)")
                },
                then: {
                    guard let found else { self.finish(false, "zweites Fenster nach Erfolg verschwunden") }
                    // Nicht bloß den Modellzustand prüfen: Direkt nach dem echten ⌘N
                    // muss die echte CodeEdit-TextView vorhanden sein und einen
                    // gültigen Einfügepunkt besitzen. Den First-Responder- und
                    // Befehlsrouting-Teil prüft der fokuspflichtige `cmdw`-Lauf.
                    self.pollForNewWindowEditorFocus(
                        original: original,
                        originalWindow: originalWindow,
                        marker: marker,
                        newWorkspace: found.workspace,
                        newWindow: found.window,
                        focusedCommandRouting: focusedCommandRouting
                    )
                })
    }

    private func pollForNewWindowEditorFocus(
        original: Workspace,
        originalWindow: NSWindow,
        marker: String,
        newWorkspace: Workspace,
        newWindow: NSWindow,
        focusedCommandRouting: Bool
    ) {
        var editor: TextView?
        self.waitFor(budget: 3, pause: 0.03,
                condition: {
                    editor = newWindow.contentView.flatMap { self.editorTextView(in: $0) as? TextView }
                    let validSelection = editor?.selectionManager.textSelections.map(\.range)
                        == [NSRange(location: 0, length: 0)]
                    let focusReady = !focusedCommandRouting
                        || (newWindow.isKeyWindow && newWindow.firstResponder === editor)
                    return editor != nil && validSelection && focusReady
                },
                onTimeout: { book in
                    if focusedCommandRouting, !newWindow.isKeyWindow {
                        self.finish(.environment, "⌘N-Fenster wurde nie Key-Window (Umgebungsproblem; \(book.summary))")
                    }
                    self.finish(false, "⌘N-Fenster hat keinen verwendbaren Editor "
                        + "(Editor=\(editor != nil), FirstResponder="
                        + "\(String(describing: newWindow.firstResponder)), "
                        + "Selektionen=\(editor?.selectionManager.textSelections.map(\.range) ?? [])) — \(book.summary)")
                },
                then: {
                    newWorkspace.activeTabContent.wrappedValue = "Inhalt nur im zweiten Fenster"
                    guard original.activeTab?.content == marker else {
                        self.finish(false, "Dokumentinhalt wird zwischen den Fenstern geteilt")
                    }
                    if focusedCommandRouting, self.runtime.currentWorkspace() !== newWorkspace {
                        self.finish(false, "neues Fenster ist sichtbar, aber nicht aktiver Workspace")
                    }
                    guard originalWindow.isVisible else {
                        self.finish(false, "erstes Dokumentfenster nach ⌘N nicht mehr sichtbar")
                    }
                    guard WorkspaceWindowRegistry.workspace(for: originalWindow) === original else {
                        self.finish(false, "erstes Fenster ist keinem oder dem falschen Workspace zugeordnet")
                    }
                    guard WorkspaceWindowRegistry.workspace(for: newWindow) === newWorkspace else {
                        self.finish(false, "zweites Fenster ist keinem oder dem falschen Workspace zugeordnet")
                    }
                    guard focusedCommandRouting else {
                        self.finish(true, "⌘N erzeugt im Hintergrund ein passend großes Fenster mit "
                            + "unabhängigem Workspace und gültigem Editor-Einfügepunkt")
                    }

                    // Fokus zurück ins erste Fenster und dort den echten ⌘T-Shortcut
                    // auslösen. So prüft `cmdw` zusätzlich, dass globale Commands
                    // nach einem Fensterwechsel nicht weiter im zweiten Workspace
                    // landen.
                    let originalTabCount = original.tabs.count
                    originalWindow.makeKeyAndOrderFront(nil)
                    self.pollForOriginalWindowActivation(
                        original: original,
                        originalWindow: originalWindow,
                        originalTabCount: originalTabCount,
                        newWorkspace: newWorkspace,
                        newWindow: newWindow
                    )
                })
    }

    /// Fensterfokus ist unter macOS kooperativ: Ein im Hintergrund gestarteter
    /// Testprozess darf `makeKeyAndOrderFront` verweigert bekommen. Der Runner
    /// aktiviert die App deshalb von außen; hier warten wir auf den echten
    /// Key-Status und trennen Umgebungsausfall vom Routing-Fehler.
    private func pollForOriginalWindowActivation(
        original: Workspace,
        originalWindow: NSWindow,
        originalTabCount: Int,
        newWorkspace: Workspace,
        newWindow: NSWindow
    ) {
        var polls = 0
        self.waitFor(budget: 3, pause: 0.03,
                condition: {
                    if originalWindow.isKeyWindow { return true }
                    if polls % 10 == 9 {
                        self.activateApplication(ignoringOtherApps: true)
                        originalWindow.makeKeyAndOrderFront(nil)
                    }
                    polls += 1
                    return false
                },
                onTimeout: { book in
                    self.finish(.environment, "erstes Fenster wurde nie Key-Window (Umgebungsproblem, kein Routing-Fehler; \(book.summary))")
                },
                then: {
                    guard self.runtime.currentWorkspace() === original else {
                        self.finish(false, "Fokus zurück ins erste Fenster aktiviert falschen Workspace")
                    }
                    self.postCmd("t", keyCode: 17, windowNumber: originalWindow.windowNumber)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        guard original.tabs.count == originalTabCount + 1,
                              newWorkspace.tabs.count == 1 else {
                            self.finish(false, "⌘T nach Fensterwechsel landete im falschen Workspace")
                        }
                        newWindow.makeKeyAndOrderFront(nil)
                        self.pollForNewWindowReactivation(
                            original: original,
                            originalWindow: originalWindow,
                            newWorkspace: newWorkspace,
                            newWindow: newWindow
                        )
                    }
                })
    }

    private func pollForNewWindowReactivation(
        original: Workspace,
        originalWindow: NSWindow,
        newWorkspace: Workspace,
        newWindow: NSWindow
    ) {
        var polls = 0
        self.waitFor(budget: 3, pause: 0.03,
                condition: {
                    if newWindow.isKeyWindow { return true }
                    if polls % 10 == 9 {
                        newWindow.makeKeyAndOrderFront(nil)
                    }
                    polls += 1
                    return false
                },
                onTimeout: { book in
                    self.finish(.environment, "zweites Fenster wurde nie wieder Key-Window (Umgebungsproblem, kein Routing-Fehler; \(book.summary))")
                },
                then: {
                    guard self.runtime.currentWorkspace() === newWorkspace else {
                        self.finish(false, "Fokus zurück ins zweite Fenster aktiviert falschen Workspace")
                    }
                    guard let activeID = newWorkspace.activeTabID,
                          let activeIndex = newWorkspace.tabs.firstIndex(where: { $0.id == activeID }) else {
                        self.finish(false, "zweites Fenster hat vor dem ⌘W-Test keinen aktiven Tab")
                    }
                    // Den letzten Tab sauber/leergeleert machen: ⌘W muss nun ohne
                    // Dialog das gesamte zweite Fenster schließen. Zusätzlich bekommt
                    // das Fenster einen echten Ordner in der Seitenleiste, während der
                    // Tab unberührt/leer bleibt — exakt der gemeldete Arbeitszustand.
                    newWorkspace.tabs[activeIndex].content = ""
                    newWorkspace.tabs[activeIndex].isDirty = false
                    let folder = selfTestTemporaryDirectory()
                        .appendingPathComponent("fastra-selftest-windows-folder-\(getpid())")
                        .canonicalFileURL
                    do {
                        try FileManager.default.createDirectory(
                            at: folder, withIntermediateDirectories: true
                        )
                    } catch {
                        self.finish(false, "Ordner-Fixture für den ⌘W-Test fehlt: \(error.localizedDescription)")
                    }
                    self.windowRoutingFixtureDirectory = folder
                    // Nicht direkt am Workspace öffnen: Der gemeldete Zustand entstand
                    // über Finder/Dock. Dieser produktive Router muss dasselbe bereits
                    // aktive Fenster wählen und anschließend wieder nach vorn holen.
                    MainActor.assumeIsolated {
                        DocumentWindowController.openFinderItems([folder])
                    }
                    let commandTargetIsNewWindow = MainActor.assumeIsolated {
                        CommandTargeting.targetDocumentWindow() === newWindow
                            && CommandTargeting.targetWorkspace() === newWorkspace
                    }
                    // Pfade vergleichen: Workspace und Fixture können denselben Ordner als
                    // URL mit bzw. ohne abschließenden Schrägstrich darstellen.
                    guard newWorkspace.projectURL?.resolvingSymlinksInPath().path
                            == folder.resolvingSymlinksInPath().path,
                          newWorkspace.isWelcomeScreen,
                          newWindow.isKeyWindow,
                          commandTargetIsNewWindow,
                          WorkspaceWindowRegistry.workspace(for: newWindow) === newWorkspace else {
                        self.finish(false, "Vorderfenster erreichte nicht den Zustand "
                            + "Ordner plus leerer Willkommen-Tab mit eindeutiger Fensterbindung "
                            + "(Projekt=\(newWorkspace.projectURL?.path ?? "nil"), "
                            + "erwartet=\(folder.path), Willkommen=\(newWorkspace.isWelcomeScreen), "
                            + "Key=\(newWindow.isKeyWindow), Ziel=\(commandTargetIsNewWindow), "
                            + "Registry=\(WorkspaceWindowRegistry.workspace(for: newWindow) === newWorkspace))")
                    }
                    let originalTabIDs = original.tabs.map(\.id)
                    let originalTabContents = original.tabs.map(\.content)
                    self.postCmd("w", keyCode: 13, windowNumber: newWindow.windowNumber)
                    self.pollForLastTabWindowClose(
                        original: original,
                        originalWindow: originalWindow,
                        originalTabIDs: originalTabIDs,
                        originalTabContents: originalTabContents,
                        closedWorkspace: newWorkspace,
                        closedWindow: newWindow
                    )
                })
    }

    private func pollForLastTabWindowClose(
        original: Workspace,
        originalWindow: NSWindow,
        originalTabIDs: [UUID],
        originalTabContents: [String],
        closedWorkspace: Workspace,
        closedWindow: NSWindow
    ) {
        self.waitFor(budget: 3, pause: 0.03,
                condition: {
                    guard !closedWindow.isVisible else { return false }
                    // `prepareToCloseWindow` fährt den Workspace bewusst in den
                    // Willkommens-Zustand zurück (genau ein frischer Scratch-Tab) und
                    // gerade nicht in eine leere Tab-Liste: SwiftUI kann dieselbe Szene
                    // später wieder anzeigen, und ohne Tab stünde dann ein Fenster mit
                    // Editorfläche ohne Ziel da. Erwartet wird deshalb genau dieser
                    // Zustand — die frühere Forderung `tabs.isEmpty` ließ den Test bei
                    // korrektem Produktverhalten immer scheitern.
                    guard closedWorkspace.isWelcomeScreen,
                          closedWorkspace.tabs.count == 1,
                          closedWorkspace.tabs.allSatisfy({ $0.url == nil && !$0.isDirty }) else {
                        self.finish(false, "Fenster schloss, aber der Workspace steht nicht im "
                            + "Willkommens-Zustand: \(closedWorkspace.tabs.count) Tab(s), "
                            + "welcome=\(closedWorkspace.isWelcomeScreen)")
                    }
                    guard originalWindow.isVisible else {
                        self.finish(false, "⌘W auf dem Zweitfenster schloss auch das erste Fenster")
                    }
                    guard original.tabs.map(\.id) == originalTabIDs,
                          original.tabs.map(\.content) == originalTabContents else {
                        self.finish(false, "⌘W auf dem Zweitfenster veränderte Tabs oder Inhalt "
                            + "des Hintergrundfensters")
                    }
                    // Erst wenn auch der aktive Workspace zurückgewechselt ist.
                    return self.runtime.currentWorkspace() === original
                },
                onTimeout: { book in
                    self.finish(false, "⌘W schloss das Zweitfenster nicht oder aktivierte den falschen Workspace — \(book.summary)")
                },
                then: {
                    self.verifyPrimaryWindowRecoveryAndClose(
                        workspace: original,
                        window: originalWindow
                    )
                })
    }

    /// Letzte Phase des Mehrfenster-⌘W-Tests: Nach Schließen der Zusatzfenster
    /// die zentrale Zuordnung des SwiftUI-Hauptfensters entfernen. Fenster-Menü
    /// und Tastaturrouting sollen sie aus der montierten Titelbrücke reparieren;
    /// anschließend über echtes ⌘W schließen.
    private func verifyPrimaryWindowRecoveryAndClose(
        workspace: Workspace,
        window: NSWindow
    ) {
        guard window.isVisible, window.isKeyWindow else {
            self.finish(.environment, "ursprüngliches Fenster wurde nach dem Schließen "
                + "des Zweitfensters nicht Key-Window")
        }

        self.exerciseMarkdownImageUndo(workspace: workspace, window: window) {
            self.continuePrimaryWindowRecoveryAndClose(workspace: workspace, window: window)
        }
    }

    private func continuePrimaryWindowRecoveryAndClose(workspace: Workspace, window: NSWindow) {
        let recovery: (Bool, Int) = MainActor.assumeIsolated {
            WorkspaceWindowRegistry.unregister(window)
            WindowsMenuTabs.shared.synchronizeWithCurrentWindowsMenu()
            let workspaceWasRestored = WorkspaceWindowRegistry.workspace(for: window) === workspace
            let windowEntries = (NSApp.windowsMenu?.items ?? []).filter {
                $0.submenu?.delegate === WindowsMenuTabs.shared
            }
            return (workspaceWasRestored, windowEntries.count)
        }
        guard recovery.0 else {
            self.finish(false, "sichtbares Hauptfenster reparierte seine verlorene "
                + "Workspace-Zuordnung nicht")
        }
        guard recovery.1 == 1 else {
            self.finish(false, "Fenster-Menü baute den verlorenen Eintrag des "
                + "verbliebenen Hauptfensters nicht wieder auf "
                + "(Dokument-Untermenüs: \(recovery.1))")
        }
        self.verifyNativeWindowTabSelection(workspace: workspace, window: window) { ok, detail in
            guard ok else { self.finish(false, "Fenstermenü nach Registry-Recovery: " + detail) }
            self.closeRecoveredPrimaryWindow(workspace: workspace, window: window)
        }
    }

    /// Erst nach dem echten Menüwechsel folgt die zweite Verlustprobe über ⌘W.
    private func closeRecoveredPrimaryWindow(workspace: Workspace, window: NSWindow) {
        // Ein einzelner sauberer Tab bildet den gemeldeten Endzustand. Die
        // älteren Testschritte haben mehrere Tabs nur für ihre Schutzproben
        // angelegt; sie sind synthetisch und dürfen hier ohne Dialog weg.
        guard let remainingID = workspace.activeTabID else {
            self.finish(false, "Hauptfenster besitzt vor dem letzten ⌘W keinen aktiven Tab")
        }
        for index in workspace.tabs.indices {
            workspace.tabs[index].isDirty = false
        }
        workspace.closeOtherTabs(keeping: remainingID)
        guard workspace.tabs.count == 1 else {
            self.finish(false, "Hauptfenster ließ sich nicht auf einen Test-Tab reduzieren")
        }

        // Zweite Verlustprobe: Diesmal muss der echte Tastaturweg die Bindung
        // noch während desselben Events reparieren und genau dieses Fenster
        // schließen. Ohne Fix fällt das Event ins SwiftUI-Menü und endet mit
        // dem vom Nutzer gehörten Systemton.
        WorkspaceWindowRegistry.unregister(window)
        self.postCmd("w", keyCode: 13, windowNumber: window.windowNumber)
        self.pollForPrimaryWindowClose(window)
    }

    /// Bild-Link, Text und die von Fastra kopierte Datei gemeinsam
    /// zurücknehmen — derselbe Ablauf, der dem Live-Fehler unmittelbar
    /// vorausging. Die Datei läuft durch die echte Undo-Nebenwirkung; danach
    /// müssen Fensterbindung und Schließen-Handler unverändert vorhanden sein.
    private func exerciseMarkdownImageUndo(
        workspace: Workspace,
        window: NSWindow,
        completion: @escaping () -> Void
    ) {
        guard let root = window.contentView,
              let textView = self.editorTextView(in: root) as? TextView,
              textView.string.isEmpty else {
            self.finish(false, "kein leerer Editor für die Markdown-Bild-Undo-Probe")
        }
        let fixture = selfTestTemporaryDirectory()
            .appendingPathComponent("fastra-cmdw-image-undo-\(getpid())", isDirectory: true)
        let documentDirectory = fixture.appendingPathComponent("dokument", isDirectory: true)
        let document = documentDirectory.appendingPathComponent("Notizen.md")
        let source = fixture.appendingPathComponent("quelle.png")
        do {
            try FileManager.default.createDirectory(
                at: documentDirectory, withIntermediateDirectories: true
            )
            try "".write(to: document, atomically: true, encoding: .utf8)
            try self.writeSolidPNG(to: source, width: 8, height: 8)
            let stored = try MarkdownImageStore.storeImageFile(
                source, documentURL: document
            )
            textView.replaceCharacters(in: NSRange(location: 0, length: 0),
                                       with: stored.link)
            MainActor.assumeIsolated {
                MarkdownImageUndo.register(
                    textView: textView, insertion: stored.link,
                    storedImages: [stored]
                )
            }
            textView.undoManager?.endUndoGrouping()
            let end = (textView.string as NSString).length
            textView.replaceCharacters(in: NSRange(location: end, length: 0),
                                       with: "\nText danach")
            textView.undoManager?.endUndoGrouping()

            func undoStep(_ count: Int) {
                guard count < 4, !textView.string.isEmpty, textView.undoManager?.canUndo == true else {
                    guard textView.string.isEmpty,
                          !FileManager.default.fileExists(atPath: stored.fileURL.path),
                          WorkspaceWindowRegistry.workspace(for: window) === workspace,
                          workspace.closeWindowHandler != nil else {
                        try? FileManager.default.removeItem(at: fixture)
                        self.finish(false, "Markdown-Bild-Undo beschädigte Text-, Datei- oder Fensterzustand")
                    }
                    try? FileManager.default.removeItem(at: fixture)
                    completion()
                    return
                }
                textView.undoManager?.undo()
                self.waitFor(budget: 5, pause: 0.02,
                    condition: { textView.undoManager?.isUndoing != true },
                    onTimeout: { _ in
                        try? FileManager.default.removeItem(at: fixture)
                        self.finish(false, "Markdown-Bild-Undo schloss seine Dateiphase nicht ab")
                    }, then: { undoStep(count + 1) })
            }
            undoStep(0)
        } catch {
            try? FileManager.default.removeItem(at: fixture)
            self.finish(false, "Markdown-Bild-Undo-Fixture scheiterte: \(error.localizedDescription)")
        }
    }

    private func pollForPrimaryWindowClose(_ window: NSWindow) {
        self.waitFor(budget: 3, pause: 0.03,
                condition: { !window.isVisible },
                onTimeout: { book in
                    self.finish(false, "⌘W schloss das wieder angebundene Hauptfenster nicht — \(book.summary)")
                },
                then: {
                    self.finish(true, "⌘W schließt Suchmaske, Hilfe, Zweitfenster und das "
                        + "Hauptfenster nach Bild-Undo; Fensterbindung und -Menü repariert")
                })
    }


    /// CMD+W bei vorderer Suchmaske → Maske schließt sich.
    ///
    /// War flaky: nach dem CMD+W-Post wurde der Fenster-Zustand einmal nach
    /// fixen 0,6 s geprüft. Schließt das Fenster minimal später (Release-
    /// Timing weicht von Debug ab), meldete der Test fälschlich FAIL, obwohl
    /// die Funktion intakt ist. Jetzt mit demselben Muster wie der Findbar-
    /// Test: App aktivieren, Fenster sicher nach vorn, setteln lassen, CMD+W
    /// posten und dann engmaschig pollen — PASS, sobald das Fenster
    /// unsichtbar wird; FAIL nur, wenn es das ganze Beobachtungsfenster über
    /// sichtbar bleibt.
    func runCmdWTest() {
        guard let searchWindow = self.runtime.windows().first(where: {
            $0.frameAutosaveName == SearchWindow.frameAutosaveName
        }) else {
            self.finish(false, "Suchfenster nicht gefunden")
        }
        guard searchWindow.isVisible else {
            self.finish(false, "Suchfenster startet nicht sichtbar")
        }
        // App nach vorn holen und Fenster key machen — CMD+W routet nur an
        // das vordere Key-Window. Ohne aktive App lief das Event früher
        // gelegentlich ins Leere (Mit-Ursache der Flakiness).
        self.activateApplication(ignoringOtherApps: true)
        searchWindow.makeKeyAndOrderFront(nil)

        // Auf das tatsächliche Key-Window warten und periodisch erneut aktivieren.
        // macOS kann `NSApp.activate` verzögern oder verweigern, besonders kurz nach
        // einem anderen Testprozess. Eine ausbleibende Aktivierung als
        // Umgebungsproblem getrennt vom Funktionsfehler melden.
        self.pollForKeyThenPost(searchWindow)
    }

    /// Bis zu rund 8 s auf das Key-Window der Suchmaske warten, etwa alle 0,3 s
    /// reaktivieren und erst danach ⌘W posten. Auf macOS 26 kann die kooperative
    /// Aktivierung eines Hintergrundprozesses verweigert werden. Der Runner
    /// braucht dann Zeit, um den sichtbaren Prozess extern über System Events
    /// vorzuholen. Bei Erfolg endet das Polling sofort.
    private func pollForKeyThenPost(_ window: NSWindow) {
        var polls = 0
        self.waitFor(budget: 8.1, pause: 0.03,   // 270 × 30 ms ≈ 8 s
                condition: {
                    if window.isKeyWindow { return true }
                    // Alle ~10 Durchläufe erneut um Aktivierung bitten — einzelne
                    // Aufrufe verpuffen unter kooperativer Aktivierung gelegentlich.
                    if polls % 10 == 9 {
                        self.activateApplication(ignoringOtherApps: true)
                        window.makeKeyAndOrderFront(nil)
                    }
                    polls += 1
                    return false
                },
                onTimeout: { book in
                    // Diagnose mitliefern: Ist die App überhaupt aktiv? Welches
                    // Fenster ist stattdessen Key? Unterscheidet „System verweigert
                    // Aktivierung" von „anderes Fenster klaut den Key-Status".
                    let keyDesc = NSApp.keyWindow.map {
                        "[\(type(of: $0))] \"\($0.title)\" autosave=\"\($0.frameAutosaveName)\""
                    } ?? "keins"
                    self.finish(.environment, "Aktivierung fehlgeschlagen — Suchmaske wurde nie Key-Window "
                        + "(Umgebungsproblem, kein CMD+W-Funktionsfehler; "
                        + "NSApp.isActive=\(NSApp.isActive), keyWindow=\(keyDesc), "
                        + "panel: visible=\(window.isVisible) canBecomeKey=\(window.canBecomeKey); "
                        + "\(book.summary))")
                },
                then: {
                    self.postCmd("w", keyCode: 13, windowNumber: window.windowNumber)
                    self.pollForClose(window)
                })
    }

    /// Pollt engmaschig, ob die Suchmaske nach CMD+W unsichtbar wird. Sobald
    /// sie verschwindet → PASS. Bleibt sie über das ganze Fenster sichtbar
    /// → FAIL. Ersetzt die frühere Einzel-Messung mit fixem Delay (flaky).
    private func pollForClose(_ window: NSWindow) {
        self.waitFor(budget: 1.5, pause: 0.03,   // ≈ 1,5 s Beobachtungsfenster
                condition: { !window.isVisible },
                onTimeout: { book in
                    self.finish(false, "Suchmaske nach CMD+W noch sichtbar — \(book.summary)")
                },
                then: { self.runCmdWHelpPhase() })
    }

    /// Zweite `cmdw`-Phase: Ein echtes ⌘W muss das vordere Hilfe-Fenster
    /// schließen, ohne die Dokument-Tabs dahinter zu verändern. Danach folgt
    /// im selben fokuspflichtigen Prozess das fensterübergreifende Routing.
    private func runCmdWHelpPhase() {
        guard let workspace = self.runtime.currentWorkspace() else {
            self.finish(false, "kein Dokument-Workspace für den Hilfe-⌘W-Test")
        }
        while workspace.tabs.count < 2 { workspace.openNewTab() }
        let tabSnapshot = workspace.tabs.map { "\($0.id.uuidString)|\($0.content)" }
        MainActor.assumeIsolated { HelpWindow.show() }
        guard let helpWindow = self.runtime.windows().first(where: HelpWindow.isHelpWindow) else {
            self.finish(false, "Hilfe-Fenster für den ⌘W-Test nicht auffindbar")
        }
        helpWindow.makeKeyAndOrderFront(nil)
        self.pollForCmdWHelpKey(
            helpWindow,
            workspace: workspace,
            tabSnapshot: tabSnapshot
        )
    }

    private func pollForCmdWHelpKey(
        _ helpWindow: NSWindow,
        workspace: Workspace,
        tabSnapshot: [String]
    ) {
        var polls = 0
        self.waitFor(budget: 8.1, pause: 0.03,
                condition: {
                    if helpWindow.isKeyWindow { return true }
                    if polls % 10 == 9 {
                        self.activateApplication(ignoringOtherApps: true)
                        helpWindow.makeKeyAndOrderFront(nil)
                    }
                    polls += 1
                    return false
                },
                onTimeout: { book in
                    self.finish(.environment, "Hilfe-Fenster wurde nie Key-Window für ⌘W "
                        + "(Umgebungsproblem; \(book.summary))")
                },
                then: {
                    self.postCmd("w", keyCode: 13, windowNumber: helpWindow.windowNumber)
                    self.pollForCmdWHelpClose(
                        helpWindow,
                        workspace: workspace,
                        tabSnapshot: tabSnapshot
                    )
                })
    }

    private func pollForCmdWHelpClose(
        _ helpWindow: NSWindow,
        workspace: Workspace,
        tabSnapshot: [String]
    ) {
        self.waitFor(budget: 1.5, pause: 0.03,
                condition: { !helpWindow.isVisible },
                onTimeout: { book in
                    self.finish(false, "⌘W ließ das Hilfe-Fenster offen — \(book.summary)")
                },
                then: {
                    let currentTabs = workspace.tabs.map { "\($0.id.uuidString)|\($0.content)" }
                    guard currentTabs == tabSnapshot else {
                        self.finish(false, "⌘W an der Hilfe veränderte einen Dokument-Tab")
                    }
                    self.runNewWindowTest(focusedCommandRouting: true)
                })
    }

}
