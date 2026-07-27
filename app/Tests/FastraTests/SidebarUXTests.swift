// SidebarUXTests.swift
//
// Tests für die Etappe-1-UX des Wunschpakets 2026-07:
// - Save-Dialog-Vorschlagsordner (markierter Sidebar-Ordner vor Projektordner)
// - Elternordner-Öffnen beim Einzeldatei-Öffnen ohne Projekt
// - Entschärfter Ordnerwechsel nach Tab-Schließen (projectSwitchTarget)
// - Leere-Ordner-Erkennung (FolderEmptinessCache, gleiche Filterregeln)

import Foundation
import Combine
import Testing
@testable import Fastra

// MARK: - Hilfsfunktionen

private func makeFreshDefaults() -> (UserDefaults, suiteName: String) {
    let suiteName = "fastra-test-sidebarux-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
}

/// Legt einen temporären Ordner an und gibt seine kanonische URL zurück.
private func makeTmpDirectory(_ name: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-sidebarux-\(name)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.canonicalFileURL
}

/// Öffnet eine Datei und wartet ereignisbasiert auf die Ladezusage, statt eine
/// Wanduhrfrist abzupollen. `loadFile` lädt über einen Hintergrund-Task, dessen
/// Rücklauf unter voller paralleler Testlast deutlich länger braucht als die
/// frühere Fünf-Sekunden-Schranke — und ein Dauer-`Task.yield()` auf dem Main
/// Actor verzögerte obendrein genau die Zustellung, auf die hier gewartet wird.
/// Die Zusage kommt pro Aufruf genau einmal; bleibt sie ganz aus, greift die
/// Zeitgrenze des jeweiligen Tests.
@MainActor
private func awaitLoadFile(_ workspace: Workspace, _ url: URL) async -> Bool {
    await withCheckedContinuation { continuation in
        workspace.loadFile(at: url) { continuation.resume(returning: $0) }
    }
}

// MARK: - Save-Dialog-Vorschlagsordner

@Test("Save-Vorschlag: markierter Sidebar-Ordner gewinnt vor Projektordner")
func saveDirectory_selectedFolderWins() {
    let selected = URL(fileURLWithPath: "/tmp/projekt/unterordner")
    let project = URL(fileURLWithPath: "/tmp/projekt")
    #expect(Workspace.suggestedSaveDirectory(
        selectedFolder: selected, projectURL: project
    ) == selected)
}

@Test("Save-Vorschlag: ohne Markierung fällt er auf den Projektordner zurück")
func saveDirectory_projectFallback() {
    let project = URL(fileURLWithPath: "/tmp/projekt")
    #expect(Workspace.suggestedSaveDirectory(
        selectedFolder: nil, projectURL: project
    ) == project)
}

@Test("Save-Vorschlag: ohne beides bleibt es beim Systemverhalten (nil)")
func saveDirectory_systemDefault() {
    #expect(Workspace.suggestedSaveDirectory(
        selectedFolder: nil, projectURL: nil
    ) == nil)
}

// MARK: - Elternordner beim Einzeldatei-Öffnen

@Test("Einzeldatei ohne Projekt → Elternordner erscheint als Projekt, Fokus bleibt",
      .timeLimit(.minutes(1)))
@MainActor
func loadFile_opensParentFolderWithoutProject() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let dir = try makeTmpDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("solo.txt")
    try "Inhalt".write(to: file, atomically: true, encoding: .utf8)

    let ws = Workspace(defaults: defaults)
    let done = await awaitLoadFile(ws, file)

    #expect(done)
    #expect(ws.projectURL == dir, "Elternordner muss als Projekt geöffnet sein")
    #expect(ws.activeTab?.url == file.canonicalFileURL,
            "Der Editor-Fokus muss auf der Datei bleiben")
}

@Test("Einzeldatei bei offenem Projekt → Projekt bleibt unverändert",
      .timeLimit(.minutes(1)))
@MainActor
func loadFile_keepsExistingProject() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let projectDir = try makeTmpDirectory("projekt")
    let otherDir = try makeTmpDirectory("woanders")
    defer {
        try? FileManager.default.removeItem(at: projectDir)
        try? FileManager.default.removeItem(at: otherDir)
    }
    let file = otherDir.appendingPathComponent("fremd.txt")
    try "Inhalt".write(to: file, atomically: true, encoding: .utf8)

    let ws = Workspace(defaults: defaults)
    ws.openProject(at: projectDir)
    let done = await awaitLoadFile(ws, file)

    #expect(done)
    #expect(ws.projectURL == projectDir,
            "Ein bereits geöffneter Ordner darf sich nicht ändern")
}

@Test("Implizites Elternordner-Öffnen schließt fremde offene Tabs NICHT",
      .timeLimit(.minutes(1)))
@MainActor
func loadFile_parentFolderKeepsUnrelatedTabs() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let dirA = try makeTmpDirectory("a")
    let dirB = try makeTmpDirectory("b")
    defer {
        try? FileManager.default.removeItem(at: dirA)
        try? FileManager.default.removeItem(at: dirB)
    }
    let fileA = dirA.appendingPathComponent("erste.txt")
    let fileB = dirB.appendingPathComponent("zweite.txt")
    try "A".write(to: fileA, atomically: true, encoding: .utf8)
    try "B".write(to: fileB, atomically: true, encoding: .utf8)

    let ws = Workspace(defaults: defaults)
    let doneA = await awaitLoadFile(ws, fileA)
    #expect(doneA)
    #expect(ws.projectURL == dirA)

    // Projekt wieder schließen (Seitenleiste ohne Projekt), dann zweite
    // Datei öffnen: deren Elternordner wird Projekt, aber der saubere Tab
    // aus dirA muss offen bleiben (kein ausdrücklicher Projektwechsel).
    ws.closeProject()
    let doneB = await awaitLoadFile(ws, fileB)
    #expect(doneB)
    #expect(ws.projectURL == dirB)
    #expect(ws.tabs.contains { $0.url == fileA.canonicalFileURL },
            "Fremder sauberer Tab darf nicht stillschweigend schließen")
}

// MARK: - Git-Root beim automatischen Ordner-Öffnen (Wunschpaket 2026-07b)

@Test("autoProjectFolder: Datei tief im Repo → Git-Wurzelordner statt Elternordner")
func autoProject_prefersRepositoryRoot() throws {
    let repo = try makeTmpDirectory("repo")
    defer { try? FileManager.default.removeItem(at: repo) }
    let nested = repo.appendingPathComponent("src/deep")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"),
                                            withIntermediateDirectories: true)
    let file = nested.appendingPathComponent("main.swift")
    try "x".write(to: file, atomically: true, encoding: .utf8)

    #expect(Workspace.autoProjectFolder(for: file)?.path == repo.path)
}

@Test("autoProjectFolder: .git als DATEI (worktree) → ebenfalls Wurzelordner")
func autoProject_acceptsWorktreeGitFile() throws {
    let repo = try makeTmpDirectory("worktree")
    defer { try? FileManager.default.removeItem(at: repo) }
    let nested = repo.appendingPathComponent("sub")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "gitdir: /woanders/.git/worktrees/wt"
        .write(to: repo.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    let file = nested.appendingPathComponent("notiz.txt")
    try "x".write(to: file, atomically: true, encoding: .utf8)

    #expect(Workspace.autoProjectFolder(for: file)?.path == repo.path)
}

@Test("autoProjectFolder: ohne Repo bleibt es beim unmittelbaren Elternordner")
func autoProject_fallsBackToParent() throws {
    let dir = try makeTmpDirectory("kein-repo")
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("solo.txt")
    try "x".write(to: file, atomically: true, encoding: .utf8)

    #expect(Workspace.autoProjectFolder(for: file)?.path == dir.path)
}

@Test("Einzeldatei im Repo-Unterordner → Seitenleiste zeigt den Repo-Root",
      .timeLimit(.minutes(1)))
@MainActor
func loadFile_opensRepositoryRootWithoutProject() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let repo = try makeTmpDirectory("repo-root")
    defer { try? FileManager.default.removeItem(at: repo) }
    let nested = repo.appendingPathComponent("docs")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"),
                                            withIntermediateDirectories: true)
    let file = nested.appendingPathComponent("lies-mich.md")
    try "Inhalt".write(to: file, atomically: true, encoding: .utf8)

    let ws = Workspace(defaults: defaults)
    let done = await awaitLoadFile(ws, file)

    #expect(done)
    #expect(ws.projectURL == repo, "Der Git-Root muss als Projekt geöffnet sein, nicht docs/")
}

// MARK: - Entschärfter Ordnerwechsel nach Tab-Schließen

private func fileTab(_ path: String) -> EditorTab {
    let url = URL(fileURLWithPath: path)
    return EditorTab(title: url.lastPathComponent,
                     path: url.deletingLastPathComponent().path, url: url)
}

@Test("Ordnerwechsel: alle verbliebenen Dateien im selben fremden Ordner → Ziel")
func projectSwitch_targetsForeignFolder() {
    let tabs = [fileTab("/tmp/anderswo/a.txt"), fileTab("/tmp/anderswo/b.txt")]
    let target = Workspace.projectSwitchTarget(
        tabs: tabs, projectURL: URL(fileURLWithPath: "/tmp/projekt"),
        searchUIActive: false
    )
    #expect(target?.path == "/tmp/anderswo")
}

@Test("Ordnerwechsel: Datei im Projekt verbleibt → kein Wechsel")
func projectSwitch_keepsProjectWithRemainingFile() {
    let tabs = [fileTab("/tmp/projekt/drin.txt"), fileTab("/tmp/anderswo/a.txt")]
    #expect(Workspace.projectSwitchTarget(
        tabs: tabs, projectURL: URL(fileURLWithPath: "/tmp/projekt"),
        searchUIActive: false
    ) == nil)
}

@Test("Ordnerwechsel: aktive Such-/Ersetzungsvorschau blockiert den Wechsel")
func projectSwitch_blockedDuringSearchPreview() {
    let tabs = [fileTab("/tmp/anderswo/a.txt")]
    #expect(Workspace.projectSwitchTarget(
        tabs: tabs, projectURL: URL(fileURLWithPath: "/tmp/projekt"),
        searchUIActive: true
    ) == nil)
}

@Test("Ordnerwechsel: Dateien aus VERSCHIEDENEN fremden Ordnern → kein Wechsel")
func projectSwitch_blockedForMixedForeignFolders() {
    // Ein Wechsel würde den zweiten Tab schließen (liegt außerhalb des
    // Zielordners) — also konservativ gar nicht wechseln.
    let tabs = [fileTab("/tmp/anderswo/a.txt"), fileTab("/tmp/nochwoanders/b.txt")]
    #expect(Workspace.projectSwitchTarget(
        tabs: tabs, projectURL: URL(fileURLWithPath: "/tmp/projekt"),
        searchUIActive: false
    ) == nil)
}

@Test("Ordnerwechsel: Unterordner-Datei unter dem Zielordner zählt als drin")
func projectSwitch_allowsSubfolderUnderTarget() {
    let tabs = [fileTab("/tmp/anderswo/a.txt"), fileTab("/tmp/anderswo/sub/b.txt")]
    let target = Workspace.projectSwitchTarget(
        tabs: tabs, projectURL: URL(fileURLWithPath: "/tmp/projekt"),
        searchUIActive: false
    )
    #expect(target?.path == "/tmp/anderswo")
}

@Test("Ordnerwechsel: Git-Ansicht offen → Projekt bleibt")
func projectSwitch_blockedWithGitTab() {
    var git = EditorTab(title: "Verlauf", path: "—")
    git.gitKind = .log
    let tabs = [git, fileTab("/tmp/anderswo/a.txt")]
    #expect(Workspace.projectSwitchTarget(
        tabs: tabs, projectURL: URL(fileURLWithPath: "/tmp/projekt"),
        searchUIActive: false
    ) == nil)
}

@Test("Ordnerwechsel: ohne Projekt oder ohne Datei-Tabs → kein Wechsel")
func projectSwitch_needsProjectAndFiles() {
    let scratch = EditorTab(title: "Ohne Titel", path: "—")
    #expect(Workspace.projectSwitchTarget(
        tabs: [fileTab("/tmp/anderswo/a.txt")], projectURL: nil,
        searchUIActive: false
    ) == nil)
    #expect(Workspace.projectSwitchTarget(
        tabs: [scratch], projectURL: URL(fileURLWithPath: "/tmp/projekt"),
        searchUIActive: false
    ) == nil)
}

@Test("Ordnerwechsel: ähnlicher Präfix-Nachbar gilt nicht als im Projekt")
func projectSwitch_prefixNeighborIsForeign() {
    // /tmp/projekt-alt beginnt wie /tmp/projekt, liegt aber außerhalb.
    let tabs = [fileTab("/tmp/projekt-alt/a.txt")]
    let target = Workspace.projectSwitchTarget(
        tabs: tabs, projectURL: URL(fileURLWithPath: "/tmp/projekt"),
        searchUIActive: false
    )
    #expect(target?.path == "/tmp/projekt-alt")
}

// MARK: - Leere-Ordner-Erkennung

@Test("FileTree.children: Ordner nur mit versteckten Einträgen zählt als leer")
func fileTree_hiddenOnlyFolderIsEmpty() throws {
    let dir = try makeTmpDirectory("hidden-only")
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appendingPathComponent(".versteckt"))

    #expect(FileTree.children(of: dir).isEmpty,
            "Versteckte Einträge zählen nicht als sichtbarer Inhalt")
}

@Test("FolderEmptinessCache: leerer Ordner wird asynchron erkannt")
@MainActor
func emptinessCache_detectsEmptyFolder() throws {
    let empty = try makeTmpDirectory("leer")
    let filled = try makeTmpDirectory("voll")
    defer {
        try? FileManager.default.removeItem(at: empty)
        try? FileManager.default.removeItem(at: filled)
    }
    try "x".write(to: filled.appendingPathComponent("datei.txt"),
                  atomically: true, encoding: .utf8)

    let cache = FolderEmptinessCache(
        scheduleProbe: { $0() },
        deliverProbeResult: { work in MainActor.assumeIsolated { work() } }
    )
    // Erst Chevron, dann ggf. entfernen: vor der Probe gilt NICHTS als leer.
    #expect(!cache.isKnownEmpty(empty))
    cache.probe(empty)
    cache.probe(filled)

    #expect(cache.isKnownEmpty(empty))
    #expect(!cache.isKnownEmpty(filled))
}

@Test("FolderEmptinessCache: gefüllter Ordner verliert den Leer-Status wieder")
@MainActor
func emptinessCache_isIdempotentAcrossRefreshes() throws {
    let dir = try makeTmpDirectory("wechselnd")
    defer { try? FileManager.default.removeItem(at: dir) }

    let cache = FolderEmptinessCache(
        scheduleProbe: { $0() },
        deliverProbeResult: { work in MainActor.assumeIsolated { work() } }
    )
    cache.probe(dir)
    #expect(cache.isKnownEmpty(dir))

    // Ordner bekommt Inhalt (wie ein FSEvents-Nachzügler) → erneute Probe
    // muss den Leer-Status idempotent wieder aufheben.
    try "x".write(to: dir.appendingPathComponent("neu.txt"),
                  atomically: true, encoding: .utf8)
    cache.probe(dir)
    #expect(!cache.isKnownEmpty(dir))
}

// MARK: - Verzeichnis-Cache des Dateibaums (Performance-Befund 2026-07-24)

/// Zählt Verzeichnis-Listings threadsicher — belegt, dass wiederholte
/// Body-Zugriffe NICHT erneut von der Platte lesen (der eigentliche Bug).
private final class ListingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Cache mit synchronen Test-Schedulern: Laden und Lieferung laufen sofort,
/// die Zustandslogik ist exakt die produktive.
@MainActor
private func makeSyncChildrenCache(counter: ListingCounter) -> FileTreeChildrenCache {
    FileTreeChildrenCache(
        listChildren: { url in
            counter.increment()
            return FileTree.children(of: url)
        },
        scheduleLoad: { $0() },
        deliverResult: { work in MainActor.assumeIsolated { work() } }
    )
}

@Test("ChildrenCache: erster Zugriff lädt asynchron, danach nur noch Speicher")
@MainActor
func childrenCache_loadsOnceThenServesMemory() throws {
    let dir = try makeTmpDirectory("cache-basis")
    defer { try? FileManager.default.removeItem(at: dir) }
    try "x".write(to: dir.appendingPathComponent("a.txt"),
                  atomically: true, encoding: .utf8)

    // Verzögerte Lieferung: der Ladeauftrag wird eingesammelt statt sofort
    // ausgeführt — wie die echte Hintergrund-Queue.
    var pending: [@Sendable () -> Void] = []
    let counter = ListingCounter()
    let cache = FileTreeChildrenCache(
        listChildren: { url in
            counter.increment()
            return FileTree.children(of: url)
        },
        scheduleLoad: { pending.append($0) },
        deliverResult: { work in MainActor.assumeIsolated { work() } }
    )

    // Vor der Lieferung: leer, aber genau EIN Ladeauftrag geplant — auch
    // bei wiederholten Body-Zugriffen (Bündelung).
    #expect(cache.children(of: dir).isEmpty)
    #expect(cache.children(of: dir).isEmpty)
    #expect(pending.count == 1)

    // Erst entnehmen, DANN ausführen — work() darf neue Aufträge anhängen,
    // ohne mit einer laufenden Array-Mutation zu kollidieren.
    while !pending.isEmpty { pending.removeFirst()() }

    // Nach der Lieferung: Inhalt da — und weitere Zugriffe lesen NUR noch
    // Speicher (kein weiteres Listing; genau das war der Main-Thread-Fresser).
    #expect(cache.children(of: dir).map(\.name) == ["a.txt"])
    _ = cache.children(of: dir)
    _ = cache.children(of: dir)
    #expect(counter.value == 1)
}

@Test("ChildrenCache: Invalidierung zeigt alten Stand weiter und liest neu")
@MainActor
func childrenCache_invalidateKeepsStaleUntilReload() throws {
    let dir = try makeTmpDirectory("cache-invalidierung")
    defer { try? FileManager.default.removeItem(at: dir) }
    try "x".write(to: dir.appendingPathComponent("alt.txt"),
                  atomically: true, encoding: .utf8)

    let counter = ListingCounter()
    let cache = makeSyncChildrenCache(counter: counter)
    // Erster Zugriff stößt das (hier synchrone) Laden an und liefert noch [];
    // ab dem zweiten kommt der Inhalt aus dem Speicher.
    _ = cache.children(of: dir)
    #expect(cache.children(of: dir).map(\.name) == ["alt.txt"])

    // Datei kommt dazu (wie eine externe Änderung); erst die FSEvents-
    // Invalidierung liest neu — synchrone Test-Scheduler liefern sofort.
    try "y".write(to: dir.appendingPathComponent("neu.txt"),
                  atomically: true, encoding: .utf8)
    #expect(cache.children(of: dir).map(\.name) == ["alt.txt"],
            "Ohne Invalidierung bleibt der gecachte Stand stehen")
    cache.invalidateAll()
    #expect(cache.children(of: dir).map(\.name) == ["alt.txt", "neu.txt"])
    #expect(counter.value == 2)
}

@Test("ChildrenCache: Invalidierung während laufender Ladung liest erneut")
@MainActor
func childrenCache_reloadsWhenInvalidatedMidFlight() throws {
    let dir = try makeTmpDirectory("cache-rennen")
    defer { try? FileManager.default.removeItem(at: dir) }

    var pending: [@Sendable () -> Void] = []
    let counter = ListingCounter()
    let cache = FileTreeChildrenCache(
        listChildren: { url in
            counter.increment()
            return FileTree.children(of: url)
        },
        scheduleLoad: { pending.append($0) },
        deliverResult: { work in MainActor.assumeIsolated { work() } }
    )

    _ = cache.children(of: dir)          // Ladung läuft (noch nicht geliefert)
    cache.invalidateAll()                // FSEvent überholt die Ladung

    // Zwischen Start der Ladung und Lieferung ändert sich der Ordner —
    // genau das Rennen, das FSEvents-Bündelung real erzeugt.
    try "x".write(to: dir.appendingPathComponent("spät.txt"),
                  atomically: true, encoding: .utf8)

    // Entnehmen-dann-Ausführen: die 1. Lieferung (veraltet) plant dabei
    // automatisch die Nachladung ein, die Schleife arbeitet auch die ab.
    while !pending.isEmpty { pending.removeFirst()() }

    #expect(cache.children(of: dir).map(\.name) == ["spät.txt"],
            "Das überholte Ergebnis muss automatisch ersetzt werden")
    #expect(counter.value == 2)
}

@Test("ChildrenCache: unverändertes Listing publiziert nicht erneut")
@MainActor
func childrenCache_unchangedListingDoesNotPublish() throws {
    let dir = try makeTmpDirectory("cache-still")
    defer { try? FileManager.default.removeItem(at: dir) }
    try "x".write(to: dir.appendingPathComponent("a.txt"),
                  atomically: true, encoding: .utf8)

    let counter = ListingCounter()
    let cache = makeSyncChildrenCache(counter: counter)
    _ = cache.children(of: dir)

    var publishCount = 0
    let subscription = cache.objectWillChange.sink { publishCount += 1 }
    defer { subscription.cancel() }

    // FSEvents ohne sichtbare Änderung (z. B. atomarer Save-Zwischenschritt):
    // neu gelesen wird zwar, aber ohne Render-Kaskade.
    cache.invalidateAll()
    #expect(counter.value == 2)
    #expect(publishCount == 0,
            "Unveränderte Listings dürfen keine Neu-Render auslösen")
}

// MARK: - Splitter-Breiten sind pro Fenster (Daniel-Befund 2026-07-20)

@Test("Splitter-Breiten: Ziehen in einem Fenster verschiebt kein anderes, seedet aber neue")
@MainActor
func splitterWidths_arePerWindowButSeedNewWindows() {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    // Erstes Fenster bei leerer Suite → die Standardbreiten.
    let first = Workspace(defaults: defaults)
    #expect(first.sidebarWidth == SidebarLayout.defaultSidebarWidth)
    #expect(first.markdownPreviewWidth == SidebarLayout.defaultPreviewWidth)

    // Splitter im ersten Fenster ziehen (der persistente Wert wird gemerkt).
    first.sidebarWidth = 300
    first.markdownPreviewWidth = 500

    // Ein danach geöffnetes zweites Fenster erbt diese Breite als Startwert.
    let second = Workspace(defaults: defaults)
    #expect(second.sidebarWidth == 300)
    #expect(second.markdownPreviewWidth == 500)

    // Kernregel: Weiteres Ziehen im ersten Fenster darf das zweite NICHT
    // mitbewegen — genau das war der gemeldete Fehler.
    first.sidebarWidth = 250
    first.markdownPreviewWidth = 460
    #expect(second.sidebarWidth == 300,
            "Der Seitenleisten-Splitter darf nur sein eigenes Fenster verändern")
    #expect(second.markdownPreviewWidth == 500,
            "Der Vorschau-Splitter darf nur sein eigenes Fenster verändern")

    // Und umgekehrt: Ziehen im zweiten Fenster lässt das erste unberührt.
    second.sidebarWidth = 400
    #expect(first.sidebarWidth == 250, "Kein Fenster darf ein anderes mitziehen")
}
