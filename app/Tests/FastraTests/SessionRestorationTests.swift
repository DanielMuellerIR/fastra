import AppKit
import Foundation
import Testing
@testable import Fastra

private func sessionDefaults() -> (UserDefaults, String) {
    let suite = "fastra-test-session-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
}

private func sessionFile(_ name: String, content: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-session-\(UUID().uuidString)",
                                isDirectory: true)
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url.canonicalFileURL
}

@Test("Sitzungswiederherstellung ist ohne gespeicherten Wert standardmäßig an")
func sessionPreferenceDefaultsToEnabled() {
    let (defaults, suite) = sessionDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(SessionRestorationPreferences.isEnabled(in: defaults))
    defaults.set(false, forKey: SessionRestorationPreferences.enabledKey)
    #expect(!SessionRestorationPreferences.isEnabled(in: defaults))
}

@Test("Sitzungsstore schreibt und liest Fenster verlustfrei")
func sessionStoreRoundTrip() {
    let (defaults, suite) = sessionDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let window = RestorableWindowState(
        projectPath: "/tmp/projekt",
        documentPaths: ["/tmp/a.txt", "/tmp/b.txt"],
        activeDocumentPath: "/tmp/b.txt",
        frame: RestorableWindowFrame(
            NSRect(x: 10, y: 20, width: 900, height: 600)
        )
    )
    let state = RestorableSessionState(windows: [window])

    SessionStateStore.save(state, to: defaults)
    #expect(SessionStateStore.load(from: defaults) == state)
    SessionStateStore.clear(in: defaults)
    #expect(SessionStateStore.load(from: defaults) == nil)
}

@Test("Nur-Projekt-Fenster ohne offene Dateien ist nicht wiederherstellenswert")
func sessionProjectOnlyWindowIsNotRestorable() {
    let projectOnly = RestorableWindowState(
        projectPath: "/tmp/repo", documentPaths: [],
        activeDocumentPath: nil, frame: nil
    )
    #expect(!projectOnly.hasRestorableContent,
            "Ordner ohne offene Dateien darf den Willkommensbildschirm nicht ersetzen")

    let withDocument = RestorableWindowState(
        projectPath: "/tmp/repo", documentPaths: ["/tmp/repo/a.txt"],
        activeDocumentPath: nil, frame: nil
    )
    #expect(withDocument.hasRestorableContent)
}

@Test("Snapshot eines Projekt-Fensters ohne Dateien bleibt leer (→ Willkommen)")
@MainActor
func sessionSnapshotOfProjectWithoutFilesIsEmpty() {
    let (defaults, suite) = sessionDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = Workspace(defaults: defaults)
    workspace.projectURL = URL(fileURLWithPath: "/tmp/repo")
    // Wie nach „alle Tabs schließen": nur ein leerer Scratch-Tab bleibt übrig.
    let scratch = EditorTab(title: "Ohne Titel", path: "—")
    workspace.tabs = [scratch]
    workspace.activeTabID = scratch.id

    #expect(workspace.restorableWindowState(frame: nil) == nil)
}

@Test("Snapshot enthält nur Dateipfade, nie ungesicherten Inhalt")
@MainActor
func sessionSnapshotExcludesUnsavedContent() throws {
    let (defaults, suite) = sessionDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let savedURL = try sessionFile("saved.txt", content: "Plattenstand")
    defer {
        try? FileManager.default.removeItem(
            at: savedURL.deletingLastPathComponent()
        )
    }
    let workspace = Workspace(defaults: defaults)
    let scratch = EditorTab(
        title: "Ohne Titel", path: "—",
        content: "HOCHGEHEIMER UNGESICHERTER INHALT", isDirty: true
    )
    let saved = EditorTab(
        title: savedURL.lastPathComponent,
        path: savedURL.deletingLastPathComponent().path,
        url: savedURL,
        content: "UNGESICHERTE ÄNDERUNG EINER DATEI", isDirty: true
    )
    workspace.tabs = [scratch, saved]
    workspace.activeTabID = scratch.id

    let snapshot = workspace.restorableWindowState(frame: nil)
    #expect(snapshot?.documentPaths == [savedURL.path])
    #expect(snapshot?.activeDocumentPath == nil)

    let encoded = try JSONEncoder().encode(snapshot)
    let json = String(decoding: encoded, as: UTF8.self)
    #expect(!json.contains("HOCHGEHEIMER"))
    #expect(!json.contains("UNGESICHERTE ÄNDERUNG"))
}

@Test("Workspace stellt gespeicherte Tabs in Reihenfolge und aktiven Tab wieder her")
@MainActor
func sessionWorkspaceRestore() async throws {
    let (defaults, suite) = sessionDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = try sessionFile("a.txt", content: "A")
    let directory = first.deletingLastPathComponent()
    let second = directory.appendingPathComponent("b.txt")
    try "B".write(to: second, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: directory) }

    let workspace = Workspace(defaults: defaults)
    let state = RestorableWindowState(
        projectPath: nil,
        documentPaths: [first.path, second.path],
        activeDocumentPath: first.path,
        frame: nil
    )
    var finished = false
    workspace.restore(state) { finished = true }
    let deadline = Date().addingTimeInterval(5)
    while !finished, Date() < deadline {
        await Task.yield()
    }

    #expect(finished)
    #expect(workspace.tabs.compactMap(\.url).map(\.lastPathComponent)
            == ["a.txt", "b.txt"])
    #expect(workspace.activeTab?.url == first)
    #expect(!workspace.tabs.contains(where: { $0.url == nil }))
}

@Test("Restore lässt keinen leeren „Ohne Titel“-/Willkommen-Tab aufblitzen")
@MainActor
func sessionRestoreHasNoTransientScratchTab() throws {
    let (defaults, suite) = sessionDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = try sessionFile("a.txt", content: "A")
    let directory = first.deletingLastPathComponent()
    let second = directory.appendingPathComponent("b.txt")
    try "B".write(to: second, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: directory) }

    let workspace = Workspace(defaults: defaults)
    // Ausgangslage wie beim echten Folgestart: ein Willkommen-Tab ist offen.
    #expect(workspace.tabs.contains { $0.isWelcome })

    let state = RestorableWindowState(
        projectPath: directory.path,
        documentPaths: [first.path, second.path],
        activeDocumentPath: first.path,
        frame: nil
    )
    // Bewusst OHNE await: Die Lade-Platzhalter werden synchron angehängt, die
    // asynchronen Ladeabschlüsse können den Main-Actor bis zum ersten `await`
    // nicht betreten. So prüft der Test genau den Zustand, den SwiftUI im
    // ersten Frame zeichnen würde (Daniel-Befund 2026-07-20).
    workspace.restore(state)

    #expect(!workspace.tabs.contains { $0.isWelcome },
            "Willkommen-Tab darf beim Restore nicht kurz aufblitzen")
    #expect(!workspace.tabs.contains { $0.url == nil },
            "Kein leerer „Ohne Titel“-Tab neben den geladenen Dateien")
    #expect(workspace.tabs.count == 2)
}

@Test("Gespeicherter Fensterrahmen wird auf einen vorhandenen Monitor begrenzt")
func sessionFrameIsKeptVisible() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let missingMonitorFrame = RestorableWindowFrame(
        NSRect(x: 5000, y: 4000, width: 1000, height: 700)
    )
    let restored = missingMonitorFrame.visibleRect(in: [screen])

    #expect(restored == NSRect(x: 220, y: 100, width: 1000, height: 700))
    #expect(screen.contains(restored))
}

@Test("Gelöschte Sitzungsziele erzeugen kein leeres Fenster")
func sessionUnavailableStateIsDiscarded() {
    let missing = "/tmp/fastra-fehlt-\(UUID().uuidString)"
    let state = RestorableWindowState(
        projectPath: missing,
        documentPaths: [missing + ".txt"],
        activeDocumentPath: missing + ".txt",
        frame: nil
    )
    #expect(state.availableState() == nil)
}

@Test("Scheitern alle Restore-Ladevorgänge, erscheint Willkommen statt Null-Tab")
@MainActor
func sessionAllLoadsFailReturnsToWelcome() async throws {
    let (defaults, suite) = sessionDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let file = try sessionFile("nicht-lesbar.txt", content: "Inhalt")
    let directory = file.deletingLastPathComponent()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: file.path)
        try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0],
                                          ofItemAtPath: file.path)

    let state = RestorableWindowState(
        projectPath: directory.path,
        documentPaths: [file.path],
        activeDocumentPath: file.path,
        frame: nil
    )
    #expect(state.availableState() != nil,
            "Der Vorcheck sieht die Datei noch; erst das echte Laden muss scheitern")
    let workspace = Workspace(defaults: defaults)
    var finished = false
    workspace.restore(state) { finished = true }
    let deadline = Date().addingTimeInterval(5)
    while !finished, Date() < deadline { await Task.yield() }

    #expect(finished)
    #expect(workspace.projectURL == nil)
    #expect(workspace.tabs.count == 1)
    #expect(workspace.tabs[0].isWelcome)
    #expect(workspace.activeTabID == workspace.tabs[0].id)
}

@Test("Verspäteter leerer Restore verwirft keinen inzwischen erstellten Entwurf")
@MainActor
func sessionEmptyRestorePreservesNewDraft() throws {
    let (defaults, suite) = sessionDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-session-race-\(UUID().uuidString)",
                                isDirectory: true)
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let missing = directory.appendingPathComponent("inzwischen-geloescht.txt")
    let state = RestorableWindowState(
        projectPath: directory.path,
        documentPaths: [missing.path],
        activeDocumentPath: missing.path,
        frame: nil
    )
    let workspace = Workspace(defaults: defaults)
    workspace.openNewTab()
    let draftID = try #require(workspace.activeTabID)
    let draftIndex = try #require(workspace.tabs.firstIndex { $0.id == draftID })
    workspace.tabs[draftIndex].content = "Neu eingegeben"
    workspace.tabs[draftIndex].isDirty = true
    let originalTabs = workspace.tabs
    var finished = false

    workspace.restore(state) { finished = true }

    #expect(finished)
    #expect(workspace.projectURL == nil)
    #expect(workspace.tabs == originalTabs)
    #expect(workspace.activeTabID == draftID)
}

@Test("Sitzungssnapshot behält auch beim Beenden ausgeblendete offene Fenster")
@MainActor
func sessionCaptureIncludesRegisteredHiddenWindows() throws {
    let (defaults, suite) = sessionDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let firstURL = try sessionFile("erstes.txt", content: "A")
    let directory = firstURL.deletingLastPathComponent()
    let secondURL = directory.appendingPathComponent("zweites.txt")
    try "B".write(to: secondURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstWorkspace = Workspace(defaults: defaults)
    let firstTab = EditorTab(
        title: firstURL.lastPathComponent,
        path: directory.path,
        url: firstURL,
        content: "A"
    )
    firstWorkspace.tabs = [firstTab]
    firstWorkspace.activeTabID = firstTab.id

    let secondWorkspace = Workspace(defaults: defaults)
    let secondTab = EditorTab(
        title: secondURL.lastPathComponent,
        path: directory.path,
        url: secondURL,
        content: "B"
    )
    secondWorkspace.tabs = [secondTab]
    secondWorkspace.activeTabID = secondTab.id

    let firstWindow = NSWindow()
    let secondWindow = NSWindow()
    WorkspaceWindowRegistry.register(firstWorkspace, for: firstWindow)
    WorkspaceWindowRegistry.register(secondWorkspace, for: secondWindow)
    defer {
        WorkspaceWindowRegistry.unregister(firstWindow)
        WorkspaceWindowRegistry.unregister(secondWindow)
    }

    // `orderOut` bildet den beobachteten ⌘Q-Zwischenzustand nach: Das
    // Fenster ist noch offen/registriert, aber `isVisible == false`.
    firstWindow.orderOut(nil)
    secondWindow.orderOut(nil)
    SessionRestorationCoordinator.captureCurrentSession(defaults: defaults)

    let capturedPaths = SessionStateStore.load(from: defaults)?.windows
        .map(\.documentPaths) ?? []
    #expect(capturedPaths.contains([firstURL.path]))
    #expect(capturedPaths.contains([secondURL.path]))
}
