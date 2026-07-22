import Foundation
import Testing
@testable import Fastra

private func homeWorkspace() -> (Workspace, UserDefaults, String) {
    let suite = "fastra-home-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (Workspace(defaults: defaults), defaults, suite)
}

private func homeFile(_ name: String, content: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-home-\(UUID().uuidString)",
                                isDirectory: true)
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url.canonicalFileURL
}

@Test("Home schließt saubere Tabs ohne Rückfrage und zeigt nur Willkommen")
@MainActor
func homeCleanTabsReturnDirectly() throws {
    let (workspace, defaults, suite) = homeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }
    let url = try homeFile("sauber.txt", content: "Inhalt")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let clean = EditorTab(title: url.lastPathComponent,
                          path: url.deletingLastPathComponent().path,
                          url: url, content: "Inhalt")
    workspace.tabs = [clean]
    workspace.activeTabID = clean.id
    workspace.projectURL = url.deletingLastPathComponent()
    var projectPromptCount = 0
    var filePromptCount = 0
    workspace.confirmReturnToWelcomeHandler = {
        projectPromptCount += 1
        return false
    }
    workspace.confirmSaveForWelcomeHandler = { _ in
        filePromptCount += 1
        return false
    }

    #expect(workspace.returnToWelcome())
    #expect(projectPromptCount == 0)
    #expect(filePromptCount == 0)
    #expect(workspace.projectURL == nil)
    #expect(workspace.tabs.count == 1)
    #expect(workspace.tabs[0].isWelcome)
    #expect(workspace.activeTabID == workspace.tabs[0].id)
}

@Test("Erste Home-Rückfrage: Abbrechen lässt Zustand vollständig unangetastet")
@MainActor
func homeInitialCancelChangesNothing() {
    let (workspace, defaults, suite) = homeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }
    let draft = EditorTab(title: "Entwurf", path: "—",
                          content: "ungesichert", isDirty: true)
    workspace.tabs = [draft]
    workspace.activeTabID = draft.id
    workspace.projectURL = URL(fileURLWithPath: "/tmp/projekt")
    let originalTabs = workspace.tabs
    let originalProject = workspace.projectURL
    var filePromptCount = 0
    workspace.confirmReturnToWelcomeHandler = { false }
    workspace.confirmSaveForWelcomeHandler = { _ in
        filePromptCount += 1
        return true
    }

    #expect(!workspace.returnToWelcome())
    #expect(filePromptCount == 0,
            "Vor der Projektbestätigung darf kein Datei-Dialog erscheinen")
    #expect(workspace.tabs == originalTabs)
    #expect(workspace.activeTabID == draft.id)
    #expect(workspace.projectURL == originalProject)
}

@Test("Nach Projektbestätigung: Datei-Abbrechen hält Projekt und Tabs offen")
@MainActor
func homeFileCancelKeepsWorkspace() {
    let (workspace, defaults, suite) = homeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }
    let draft = EditorTab(title: "Entwurf", path: "—",
                          content: "ungesichert", isDirty: true)
    workspace.tabs = [draft]
    workspace.activeTabID = draft.id
    workspace.projectURL = URL(fileURLWithPath: "/tmp/projekt")
    workspace.confirmReturnToWelcomeHandler = { true }
    workspace.confirmSaveForWelcomeHandler = { _ in false }

    #expect(!workspace.returnToWelcome())
    #expect(workspace.tabs == [draft])
    #expect(workspace.activeTabID == draft.id)
    #expect(workspace.projectURL?.path == "/tmp/projekt")
}

@Test("Home sichert geänderte Datei und wechselt danach zu Willkommen")
@MainActor
func homeSavesDirtyFileBeforeWelcome() throws {
    let (workspace, defaults, suite) = homeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }
    let url = try homeFile("geaendert.txt", content: "alt")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let dirty = EditorTab(
        title: url.lastPathComponent,
        path: url.deletingLastPathComponent().path,
        url: url,
        content: "neu",
        isDirty: true,
        diskSnapshot: FileSnapshot(data: Data("alt".utf8), at: url)
    )
    workspace.tabs = [dirty]
    workspace.activeTabID = dirty.id
    workspace.projectURL = url.deletingLastPathComponent()
    workspace.confirmReturnToWelcomeHandler = { true }
    workspace.confirmSaveForWelcomeHandler = { _ in true }

    #expect(workspace.returnToWelcome())
    #expect(try String(contentsOf: url, encoding: .utf8) == "neu")
    #expect(workspace.projectURL == nil)
    #expect(workspace.tabs.count == 1)
    #expect(workspace.tabs[0].isWelcome)
}

@Test("Später Datei-Abbruch behält alle Tabs; frühere Sicherung bleibt erhalten")
@MainActor
func homeLaterFileCancelKeepsTabs() throws {
    let (workspace, defaults, suite) = homeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }
    let url = try homeFile("zuerst.txt", content: "alt")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let first = EditorTab(
        title: url.lastPathComponent,
        path: url.deletingLastPathComponent().path,
        url: url,
        content: "gesichert",
        isDirty: true,
        diskSnapshot: FileSnapshot(data: Data("alt".utf8), at: url)
    )
    let second = EditorTab(title: "Abbruch", path: "—",
                           content: "bleibt", isDirty: true)
    workspace.tabs = [first, second]
    workspace.activeTabID = second.id
    workspace.projectURL = url.deletingLastPathComponent()
    workspace.confirmReturnToWelcomeHandler = { true }
    workspace.confirmSaveForWelcomeHandler = { title in title == first.title }

    #expect(!workspace.returnToWelcome())
    #expect(try String(contentsOf: url, encoding: .utf8) == "gesichert")
    #expect(workspace.tabs.map(\.id) == [first.id, second.id])
    #expect(workspace.tabs[0].isDirty == false)
    #expect(workspace.tabs[1].isDirty)
    #expect(workspace.activeTabID == second.id)
    #expect(workspace.projectURL == url.deletingLastPathComponent())
}

@Test("Home bleibt während einer schreibenden Ordner-Ersetzung gesperrt")
@MainActor
func homeBlockedWhileFolderApplyRuns() {
    let (workspace, defaults, suite) = homeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }
    let originalTabs = workspace.tabs
    workspace.folderApplying = true

    #expect(!workspace.returnToWelcome())
    #expect(workspace.tabs == originalTabs)
    #expect(workspace.isWelcomeScreen)
}

@Test("Projekt öffnen entfernt Willkommen, behält aber ungesicherten Entwurf")
@MainActor
func projectOpenRemovesWelcomeAndKeepsDraft() throws {
    let (workspace, defaults, suite) = homeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = try homeFile("dummy.txt", content: "x")
        .deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    workspace.openNewTab()
    let draftID = workspace.activeTabID!
    let index = workspace.tabs.firstIndex { $0.id == draftID }!
    workspace.tabs[index].content = "Entwurf"
    workspace.tabs[index].isDirty = true

    workspace.openProject(at: directory)

    #expect(workspace.projectURL == directory)
    #expect(!workspace.tabs.contains { $0.isWelcome })
    #expect(workspace.tabs.contains { $0.id == draftID && $0.content == "Entwurf" })
}

@Test("Projekt öffnen ersetzt reines Willkommen durch normalen Scratch-Tab")
@MainActor
func projectOpenNeverCoexistsWithWelcome() throws {
    let (workspace, defaults, suite) = homeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = try homeFile("dummy.txt", content: "x")
        .deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }

    workspace.openProject(at: directory)

    #expect(workspace.projectURL == directory)
    #expect(workspace.tabs.count == 1)
    #expect(!workspace.tabs[0].isWelcome)
    #expect(workspace.tabs[0].url == nil)
}

@Test("Datei-Laden unterdrückt Willkommen sofort und stellt es bei Fehler wieder her")
@MainActor
func fileLoadNeverCoexistsWithWelcome() async {
    let (workspace, defaults, suite) = homeWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-fehlt-\(UUID().uuidString).txt")
        .canonicalFileURL
    var result: Bool?

    workspace.loadFile(at: missing) { result = $0 }
    #expect(!workspace.tabs.contains { $0.isWelcome })
    #expect(workspace.tabs.contains { $0.url == missing && $0.isLoading })

    let deadline = Date().addingTimeInterval(5)
    while result == nil, Date() < deadline { await Task.yield() }

    #expect(result == false)
    #expect(workspace.projectURL == nil)
    #expect(workspace.tabs.count == 1)
    #expect(workspace.tabs[0].isWelcome)
    #expect(workspace.activeTabID == workspace.tabs[0].id)
}
