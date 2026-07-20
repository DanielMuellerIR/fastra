// SidebarUXTests.swift
//
// Tests für die Etappe-1-UX des Wunschpakets 2026-07:
// - Save-Dialog-Vorschlagsordner (markierter Sidebar-Ordner vor Projektordner)
// - Elternordner-Öffnen beim Einzeldatei-Öffnen ohne Projekt
// - Entschärfter Ordnerwechsel nach Tab-Schließen (projectSwitchTarget)
// - Leere-Ordner-Erkennung (FolderEmptinessCache, gleiche Filterregeln)

import Foundation
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

@Test("Einzeldatei ohne Projekt → Elternordner erscheint als Projekt, Fokus bleibt")
@MainActor
func loadFile_opensParentFolderWithoutProject() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let dir = try makeTmpDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("solo.txt")
    try "Inhalt".write(to: file, atomically: true, encoding: .utf8)

    let ws = Workspace(defaults: defaults)
    var done: Bool? = nil
    ws.loadFile(at: file) { ok in done = ok }
    let deadline = Date().addingTimeInterval(5)
    while done == nil, Date() < deadline { await Task.yield() }

    #expect(done == true)
    #expect(ws.projectURL == dir, "Elternordner muss als Projekt geöffnet sein")
    #expect(ws.activeTab?.url == file.canonicalFileURL,
            "Der Editor-Fokus muss auf der Datei bleiben")
}

@Test("Einzeldatei bei offenem Projekt → Projekt bleibt unverändert")
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
    var done: Bool? = nil
    ws.loadFile(at: file) { ok in done = ok }
    let deadline = Date().addingTimeInterval(5)
    while done == nil, Date() < deadline { await Task.yield() }

    #expect(done == true)
    #expect(ws.projectURL == projectDir,
            "Ein bereits geöffneter Ordner darf sich nicht ändern")
}

@Test("Implizites Elternordner-Öffnen schließt fremde offene Tabs NICHT")
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
    var doneA: Bool? = nil
    ws.loadFile(at: fileA) { ok in doneA = ok }
    var deadline = Date().addingTimeInterval(5)
    while doneA == nil, Date() < deadline { await Task.yield() }
    #expect(ws.projectURL == dirA)

    // Projekt wieder schließen (Seitenleiste ohne Projekt), dann zweite
    // Datei öffnen: deren Elternordner wird Projekt, aber der saubere Tab
    // aus dirA muss offen bleiben (kein ausdrücklicher Projektwechsel).
    ws.closeProject()
    var doneB: Bool? = nil
    ws.loadFile(at: fileB) { ok in doneB = ok }
    deadline = Date().addingTimeInterval(5)
    while doneB == nil, Date() < deadline { await Task.yield() }

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

@Test("Einzeldatei im Repo-Unterordner → Seitenleiste zeigt den Repo-Root")
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
    var done: Bool? = nil
    ws.loadFile(at: file) { ok in done = ok }
    let deadline = Date().addingTimeInterval(5)
    while done == nil, Date() < deadline { await Task.yield() }

    #expect(done == true)
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
