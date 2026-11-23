// SelfTestGitHistory.swift
//
// Besitzt Git-Graph-/Dateiverlauf samt vollständigen Gitfixtures und Reviewphasen.
// Geteilte Start-, Fenster-, Screenshot- und Abschlussdienste bleiben im Root.

import AppKit

final class SelfTestGitHistory {
    struct Runtime {
        let currentWorkspace: () -> Workspace?
        let missingWorkspaceMessage: () -> String
        let mainWindowForAXChecks: () -> NSWindow?
        let markerViewExists: (String, NSView) -> Bool
        let markerView: (String, NSView) -> NSView?
        let sendMouseClick: (NSPoint, NSWindow, NSEvent.ModifierFlags, Bool) -> Bool
        let waitFor: (TimeInterval, TimeInterval, @escaping () -> Bool,
                      @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void
        let finish: (SelfTestOutcome, String) -> Never
        let runGitSequence: ([[String]], URL, @escaping (Bool, String) -> Void) -> Void
        let makeScreenshotFixtureDirectory: () -> URL
        let prepareRemoteBadgeShot: (URL, Workspace, @escaping () -> Void) -> Void
        let dumpMainWindowThenExit: (String) -> Void
    }

    private let runtime: Runtime

    init(runtime: Runtime) { self.runtime = runtime }

    private func markerViewExists(id: String, in view: NSView) -> Bool {
        runtime.markerViewExists(id, view)
    }

    private func markerView(id: String, in view: NSView) -> NSView? {
        runtime.markerView(id, view)
    }

    private func sendMouseClick(at point: NSPoint, in window: NSWindow,
                                modifiers: NSEvent.ModifierFlags, viaApp: Bool) -> Bool {
        runtime.sendMouseClick(point, window, modifiers, viaApp)
    }

    private func waitFor(budget: TimeInterval, pause: TimeInterval,
                         condition: @escaping () -> Bool,
                         onTimeout: @escaping (SelfTestPollBudget) -> Void,
                         then body: @escaping () -> Void) {
        runtime.waitFor(budget, pause, condition, onTimeout, body)
    }

    private func finish(_ ok: Bool, _ message: String) -> Never {
        runtime.finish(ok ? .pass : .fail, message)
    }

    private func finish(_ outcome: SelfTestOutcome, _ message: String) -> Never {
        runtime.finish(outcome, message)
    }

    private func runGitSequence(_ commands: [[String]], in directory: URL,
                                _ completion: @escaping (Bool, String) -> Void) {
        runtime.runGitSequence(commands, directory, completion)
    }

    private func prepareRemoteBadgeShot(repository: URL, workspace: Workspace,
                                        completion: @escaping () -> Void) {
        runtime.prepareRemoteBadgeShot(repository, workspace, completion)
    }

    private func dumpMainWindowThenExit(prefix: String) {
        runtime.dumpMainWindowThenExit(prefix)
    }

    // MARK: - Selbsttest githistory (Verlauf einer einzelnen Datei)

    /// Prüft den auf eine Datei eingeschränkten Verlauf im echten Fenster:
    /// (a) Ausgangslage: Der Graph-Tab zeigt alle vier Commits des Fixtures.
    /// (b) „Git-Historie anzeigen" schaltet auf den Graph-Tab und zeigt nur
    ///     die drei Commits, die `alpha.txt` geändert haben.
    /// (c) Ein Wechsel auf den Dateien-Tab und zurück lässt die Einschränkung
    ///     stehen — genau das ging vorher verloren.
    /// (d) Ein echter Mausklick auf „Ganze Historie" bringt alle vier zurück.
    func runGitHistoryTest() {
        guard let ws = self.runtime.currentWorkspace() else { self.finish(false, self.runtime.missingWorkspaceMessage()) }
        guard GitRunner.isAvailable else {
            self.finish(.skip, "git nicht verfügbar — Verlaufsansicht bleibt erwartungsgemäß verborgen")
        }
        ws.gitInteraction.presentsDialogs = false

        let fm = FileManager.default
        let base = selfTestTemporaryDirectory()
            .appendingPathComponent("fastra-githistory-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("working-copy")
        let alpha = repo.appendingPathComponent("alpha.txt")
        let beta = repo.appendingPathComponent("beta.txt")
        do {
            try fm.createDirectory(at: repo, withIntermediateDirectories: true)
            try "alpha 1\n".write(to: alpha, atomically: true, encoding: .utf8)
            try "beta 1\n".write(to: beta, atomically: true, encoding: .utf8)
        } catch {
            self.finish(false, "(setup) \(error.localizedDescription)")
        }
        // Vier Commits, von denen nur drei alpha.txt anfassen. Die Zahlen
        // 4 und 3 sind der eigentliche Beweis: Eine Ansicht, die den Filter
        // ignoriert, zeigt vier Zeilen.
        let steps: [[String]] = [
            ["init", "-b", "main"],
            ["config", "user.email", "t@t"],
            ["config", "user.name", "T"],
            ["add", "-A"],
            ["commit", "-m", "beide angelegt"],
        ]
        self.runGitSequence(steps, in: repo) { ok, error in
            guard ok else {
                try? fm.removeItem(at: base)
                self.finish(false, "(setup git) \(error)")
            }
            do {
                try "alpha 2\n".write(to: alpha, atomically: true, encoding: .utf8)
            } catch {
                try? fm.removeItem(at: base)
                self.finish(false, "(alpha 2) \(error.localizedDescription)")
            }
            self.runGitSequence([["add", "-A"], ["commit", "-m", "alpha zwei"]], in: repo) { ok2, error2 in
                guard ok2 else {
                    try? fm.removeItem(at: base)
                    self.finish(false, "(commit alpha zwei) \(error2)")
                }
                do {
                    try "beta 2\n".write(to: beta, atomically: true, encoding: .utf8)
                } catch {
                    try? fm.removeItem(at: base)
                    self.finish(false, "(beta 2) \(error.localizedDescription)")
                }
                self.runGitSequence([["add", "-A"], ["commit", "-m", "beta zwei"]], in: repo) { ok3, error3 in
                    guard ok3 else {
                        try? fm.removeItem(at: base)
                        self.finish(false, "(commit beta zwei) \(error3)")
                    }
                    do {
                        try "alpha 3\n".write(to: alpha, atomically: true, encoding: .utf8)
                    } catch {
                        try? fm.removeItem(at: base)
                        self.finish(false, "(alpha 3) \(error.localizedDescription)")
                    }
                    self.runGitSequence([["add", "-A"], ["commit", "-m", "alpha drei"]], in: repo) { ok4, error4 in
                        guard ok4 else {
                            try? fm.removeItem(at: base)
                            self.finish(false, "(commit alpha drei) \(error4)")
                        }
                        DispatchQueue.main.async {
                            ws.openProject(at: repo)
                            ws.sidebarMode = .graph
                            self.pollGitHistoryFull(ws, base: base, alpha: alpha)
                        }
                    }
                }
            }
        }
    }

    /// (a) Ganze Historie: vier gerenderte Zeilen, keine Kopfzeile.
    private func pollGitHistoryFull(_ ws: Workspace, base: URL, alpha: URL) {
        self.waitFor(budget: 8, pause: 0.05,
                condition: {
                    let content = self.runtime.mainWindowForAXChecks()?.contentView
                    return content.map { self.markerViewExists(id: "gitGraphRows-4", in: $0) } ?? false
                },
                onTimeout: { book in
                    try? FileManager.default.removeItem(at: base)
                    self.finish(false, "Ganze Historie zeigt keine vier Commits "
                        + "(Modell: \(ws.gitLog.count)) — \(book.summary)")
                },
                then: {
                    ws.showGitHistory(for: alpha)
                    self.pollGitHistoryFiltered(ws, base: base, alpha: alpha, phase: 0)
                })
    }

    /// (b) und (c): eingeschränkte Ansicht, danach dieselbe Prüfung nach
    /// einem Ausflug auf den Dateien-Tab.
    private func pollGitHistoryFiltered(_ ws: Workspace, base: URL, alpha: URL,
                                               phase: Int) {
        var header = false
        var threeRows = false
        var onGraph = false
        self.waitFor(budget: 8, pause: 0.05,
                condition: {
                    let content = self.runtime.mainWindowForAXChecks()?.contentView
                    header = content.map {
                        self.markerViewExists(id: "gitHistoryFile-alpha.txt", in: $0)
                    } ?? false
                    threeRows = content.map { self.markerViewExists(id: "gitGraphRows-3", in: $0) } ?? false
                    onGraph = ws.sidebarMode == .graph
                    return header && threeRows && onGraph
                },
                onTimeout: { book in
                    try? FileManager.default.removeItem(at: base)
                    self.finish(false, "Dateiverlauf (Durchgang \(phase + 1)) falsch: "
                        + "Kopfzeile=\(header), drei Zeilen=\(threeRows), Graph-Tab=\(onGraph), "
                        + "Modell: \(ws.gitFileHistory.count) Commits — \(book.summary)")
                },
                then: {
                    if phase == 0 {
                        // Reiner Tab-Wechsel — er darf die Einschränkung nicht
                        // zurücksetzen.
                        ws.sidebarMode = .files
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            ws.sidebarMode = .graph
                            self.pollGitHistoryFiltered(ws, base: base, alpha: alpha, phase: 1)
                        }
                        return
                    }
                    self.clickGitHistoryFullButton(ws, base: base)
                })
    }

    /// (d) Echter Mausklick auf „Ganze Historie".
    private func clickGitHistoryFullButton(_ ws: Workspace, base: URL) {
        guard let window = self.runtime.mainWindowForAXChecks(),
              let content = window.contentView,
              let marker = self.markerView(id: "gitHistoryFullButton", in: content) else {
            try? FileManager.default.removeItem(at: base)
            self.finish(false, "Knopf „Ganze Historie“ fehlt")
        }
        window.layoutIfNeeded()
        let point = marker.convert(NSPoint(x: marker.bounds.midX,
                                           y: marker.bounds.midY), to: nil)
        guard self.sendMouseClick(at: point, in: window, modifiers: [], viaApp: true) else {
            try? FileManager.default.removeItem(at: base)
            self.finish(false, "Klick auf „Ganze Historie“ nicht erzeugbar")
        }
        self.pollGitHistoryRestored(ws, base: base)
    }

    private func pollGitHistoryRestored(_ ws: Workspace, base: URL) {
        var fourRows = false
        var headerGone = false
        self.waitFor(budget: 5, pause: 0.05,
                condition: {
                    let content = self.runtime.mainWindowForAXChecks()?.contentView
                    fourRows = content.map { self.markerViewExists(id: "gitGraphRows-4", in: $0) } ?? false
                    headerGone = content.map {
                        !self.markerViewExists(id: "gitHistoryFile-alpha.txt", in: $0)
                    } ?? false
                    return fourRows && headerGone && ws.gitHistoryFile == nil
                },
                onTimeout: { book in
                    try? FileManager.default.removeItem(at: base)
                    self.finish(false, "Nach dem Klick auf „Ganze Historie“: vier Zeilen=\(fourRows), "
                        + "Kopfzeile weg=\(headerGone), Filter=\(String(describing: ws.gitHistoryFile)) "
                        + "— \(book.summary)")
                },
                then: {
                    func done() {
                        try? FileManager.default.removeItem(at: base)
                        self.finish(true, "Dateiverlauf zeigt 3 von 4 Commits, überlebt den Tab-Wechsel, "
                            + "und „Ganze Historie“ stellt alle 4 wieder her")
                    }
                    guard let directory = ProcessInfo.processInfo.environment["FASTRA_GITHISTORY_REVIEW_DIR"] else {
                        done(); return
                    }
                    let review = URL(fileURLWithPath: directory)
                    let repo = base.appendingPathComponent("working-copy")
                    ws.loadFile(at: repo.appendingPathComponent("beta.txt")) { loaded in
                        guard loaded, let window = self.runtime.mainWindowForAXChecks() else { self.finish(false, "History-Fixture nicht bereit") }
                        window.title = "fastra-githistory-\(UUID().uuidString)"
                        do {
                            try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
                            try Data(repo.path.utf8).write(to: review.appendingPathComponent("fixture-repo"))
                            try Data("ready\n".utf8).write(to: review.appendingPathComponent("ready"))
                        } catch { self.finish(.environment, "History-Abnahmemarker nicht schreibbar") }
                        self.waitFor(budget: 300, pause: 0.1, condition: {
                            FileManager.default.fileExists(atPath: review.appendingPathComponent("continue").path)
                        }, onTimeout: { _ in
                            try? FileManager.default.removeItem(at: base)
                            self.finish(.environment, "Manuelle History-Abnahme nicht freigegeben")
                        }, then: {
                            guard ws.activeTab?.url?.lastPathComponent == "alpha.txt",
                                  ws.activeTab?.content == "alpha 3\n" else {
                                self.finish(false, "History-Menü öffnete nicht die aktuelle normale Datei")
                            }
                            done()
                        })
                    }
                })
    }

    /// Baut ein kleines Repo mit Verzweigung und Merge, öffnet es und hält das
    /// Fenster fürs Graph-Capture. Der Graph-Modus wird über FASTRA_SIDEBAR=graph
    /// vorgewählt (Test-Hook in EditorView).
    func runGraphShot() {
        guard let ws = self.runtime.currentWorkspace() else { self.finish(false, self.runtime.missingWorkspaceMessage()) }
        guard GitRunner.isAvailable else { self.finish(.environment, "git nicht verfügbar") }
        let fm = FileManager.default
        let repo = self.runtime.makeScreenshotFixtureDirectory().appendingPathComponent("GraphDemo")
        try? fm.createDirectory(at: repo, withIntermediateDirectories: true)

        let id = ["-c", "user.email=t@t", "-c", "user.name=Demo"]
        // Kette von git-Aufrufen, die eine echte Verzweigung + Merge erzeugt.
        func write(_ name: String, _ text: String) {
            try? text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func step(_ args: [String], _ next: @escaping () -> Void) {
            GitRunner.run(id + args, in: repo) { r in
                guard let r, r.ok else { self.finish(false, "(git \(args.first ?? "")) \(r?.stderr ?? "")") }
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
            self.prepareRemoteBadgeShot(repository: repo, workspace: ws) {
                ws.openProject(at: repo)
                // Nach dem Öffnen ist der Graph über FASTRA_SIDEBAR=graph aktiv.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.dumpMainWindowThenExit(prefix: "GRAPHSHOT-WINDOW")
                }
            }
        } } } } } } } } } } } } } } } }
    }

    /// Diagnose-Modus für die Sichtprüfung des Dateiverlaufs: dasselbe
    /// Demo-Repo wie `graphshot`, danach die Ansicht auf `f.txt`
    /// eingeschränkt. Zeigt Kopfzeile, Commit-Zahl und den Knopf
    /// „Ganze Historie" in echter Fenstergröße.
    func runGitHistoryShot() {
        guard let ws = self.runtime.currentWorkspace() else { self.finish(false, self.runtime.missingWorkspaceMessage()) }
        guard GitRunner.isAvailable else { self.finish(.environment, "git nicht verfügbar") }
        let fm = FileManager.default
        let repo = self.runtime.makeScreenshotFixtureDirectory().appendingPathComponent("HistoryDemo")
        try? fm.createDirectory(at: repo, withIntermediateDirectories: true)

        let id = ["-c", "user.email=t@t", "-c", "user.name=Demo"]
        func write(_ name: String, _ text: String) {
            try? text.write(to: repo.appendingPathComponent(name), atomically: true,
                            encoding: .utf8)
        }
        func step(_ args: [String], _ next: @escaping () -> Void) {
            GitRunner.run(id + args, in: repo) { r in
                guard let r, r.ok else {
                    self.finish(false, "(git \(args.first ?? "")) \(r?.stderr ?? "")")
                }
                next()
            }
        }

        write("f.txt", "a\n")
        step(["-c", "init.defaultBranch=main", "init"]) {
        step(["add", "."]) { step(["commit", "-m", "Erster Commit"]) {
        write("f.txt", "a\nb\n"); step(["commit", "-am", "Zweite Fassung von f.txt"]) {
        write("g.txt", "x\n"); step(["add", "."]) { step(["commit", "-m", "Nur g.txt"]) {
        write("f.txt", "a\nb\nc\n"); step(["commit", "-am", "Dritte Fassung von f.txt"]) {
        write("g.txt", "y\n"); step(["commit", "-am", "Wieder nur g.txt"]) {
            ws.openProject(at: repo)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                ws.showGitHistory(for: repo.appendingPathComponent("f.txt"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.dumpMainWindowThenExit(prefix: "HISTORYSHOT-WINDOW")
                }
            }
        } } } } } } } }
    }

}
