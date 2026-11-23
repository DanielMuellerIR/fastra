// Projektlebenszyklus vom Startzustand bis zum gespeicherten Datei-Set;
// Laufzeit, Abschluss und Cleanup bleiben beim gestarteten SelfTest.
import Foundation

struct SelfTestProjectLifecycle {
    private let workspace: Workspace
    private let waitForBody: (TimeInterval, TimeInterval, @escaping () -> Bool,
                      @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void
    private let finishBody: (Bool, String) -> Never
    private let finishOutcomeBody: (SelfTestOutcome, String) -> Never

    init(workspace: Workspace,
         waitFor: @escaping (TimeInterval, TimeInterval, @escaping () -> Bool,
                            @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void,
         finish: @escaping (Bool, String) -> Never,
         finishOutcome: @escaping (SelfTestOutcome, String) -> Never) {
        self.workspace = workspace
        self.waitForBody = waitFor
        self.finishBody = finish
        self.finishOutcomeBody = finishOutcome
    }

    // Argumentlabels und Abschlussarten bleiben an den Ablaufaufrufen erhalten;
    // die Funktionswerte führen weiterhin SelfTests private Helfer aus.
    private func waitFor(budget: TimeInterval, pause: TimeInterval,
                         condition: @escaping () -> Bool,
                         onTimeout: @escaping (SelfTestPollBudget) -> Void,
                         then: @escaping () -> Void) {
        waitForBody(budget, pause, condition, onTimeout, then)
    }

    private func finish(_ success: Bool, _ message: String) -> Never {
        finishBody(success, message)
    }

    private func finish(_ outcome: SelfTestOutcome, _ message: String) -> Never {
        finishOutcomeBody(outcome, message)
    }

    func runProjectTest() {
        let ws = workspace

        // ── Testprojekt im Temp-Ordner bauen: repo/.git + Dateien ─────────
        let fm = FileManager.default
        let base = selfTestTemporaryDirectory()
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
            finish(.environment, "Umgebungsproblem: (setup) Testprojekt nicht anlegbar: \(error)")
        }

        // ── (a) Willkommens-Bedingung ─────────────────────────────────────
        // Tab mit Inhalt → Platzhalter verborgen. Danach den Startzustand
        // simulieren (ein unberührter leerer Tab, kein Projekt) → sichtbar.
        ws.tabs = [EditorTab(title: "contacts.md", path: "Demo", content: "Demo-Inhalt")]
        ws.activeTabID = ws.tabs[0].id
        if ws.isWelcomeScreen {
            finish(false, "(a) Willkommen sichtbar, obwohl der aktive Tab Inhalt trägt")
        }
        ws.tabs = [Workspace.makeScratchTab()]
        ws.activeTabID = ws.tabs[0].id
        ws.projectURL = nil
        guard ws.isWelcomeScreen else {
            finish(false, "(a) Willkommen verborgen trotz unberührtem leeren Tab ohne Projekt")
        }

        // ── (b) Projekt öffnen ────────────────────────────────────────────
        // openProject/loadFile kanonisieren URLs (`/var` → `/private/var`,
        // via canonicalPathKey) — die Erwartungswerte entsprechend auch.
        let resolved = repo.canonicalFileURL
        ws.openProject(at: repo)
        guard ws.projectURL == resolved else {
            finish(false, "(b) projectURL=\(String(describing: ws.projectURL)) statt \(resolved.path)")
        }
        // Der unberührte Start-Tab bleibt beim Projektöffnen stehen und zeigt
        // weiterhin die Starthilfe — bewusst ohne Projekt-Sperre.
        guard ws.tabs.count == 1, ws.tabs[0].isPristineScratch else {
            finish(false, "(b) openProject muss den unberührten Start-Tab stehen lassen")
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
            // Der Tab muss die normalisierte URL tragen — sonst schlüge die
            // Aktiv-Markierung im Projektbaum fehl (Listing liefert
            // `/private/…`-Form).
            guard ws.activeTab?.url == resolved.appendingPathComponent("a.txt") else {
                finish(false, "(d) Tab-URL nicht normalisiert: \(ws.activeTab?.url?.path ?? "nil")")
            }
            // Die Repo-Erkennung in noteRecentFile darf kein Duplikat neben
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
            pollProjectScope(ws, base: base)
        }
    }

    private func pollProjectScope(_ ws: Workspace, base: URL) {
        // Bisher 200 × 30 ms = 6 s.
        waitFor(budget: 6, pause: 0.03,
                condition: { !ws.folderSearching && !ws.folderNeedsSearch },
                onTimeout: { book in
                    finish(false, "(e) Timeout der Projekt-Suche — \(book.summary)")
                }) {
            let urls = ws.folderResults.filter { !$0.matches.isEmpty }.map(\.url.lastPathComponent)
            guard ws.folderTotalMatches == 1, urls == ["a.txt"] else {
                finish(false, "(e) Projekt-Scope missachtet Datei-Set/Ausschluss: "
                    + "total=\(ws.folderTotalMatches), Dateien=\(urls)")
            }
            try? FileManager.default.removeItem(at: base)
            finish(true, "Willkommen, Projekt öffnen, Dateibaum, Datei-Laden, "
                + "Repo-Dedup + Projekt-Datei-Set/Ausschluss ok")
        }
    }
}
