import AppKit
import Foundation
import Testing
@testable import Fastra

private func sessionDefaults() -> (UserDefaults, String) {
    let suite = "fastra-test-session-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
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

@Test("Restore-Gate akzeptiert nur den primären Workspace und nur einmal")
@MainActor
func sessionPrimaryWindowGateIsIdentityBoundAndOneShot() async {
    let (defaults, suite) = sessionDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let primary = Workspace(defaults: defaults)
    let foreign = Workspace(defaults: defaults)
    let primaryWindow = NSWindow()
    var restoredWindow: NSWindow?
    var restoreCount = 0
    let gate = PrimaryWindowRestoreGate(expectedWorkspace: primary) { window in
        restoreCount += 1
        restoredWindow = window
    }

    // Auch sehr viele fremde Registrierungen lassen das Gate scharf. Damit
    // hängt die Entscheidung weder an einer Uhr noch an einer Versuchszahl.
    for _ in 0..<1_000 {
        #expect(!gate.scheduleAction(for: foreign, window: primaryWindow))
    }
    #expect(restoreCount == 0)

    #expect(gate.scheduleAction(for: primary, window: primaryWindow))
    // Der Bridge-Aufruf darf den Restore nicht synchron aus dem laufenden
    // SwiftUI-Update starten; ein doppeltes Ereignis bleibt trotzdem wirkungslos.
    #expect(restoreCount == 0)
    #expect(!gate.scheduleAction(for: primary, window: primaryWindow))
    #expect(!gate.scheduleAction(for: foreign, window: primaryWindow))

    // Der anschließend eingereihte Block beweist, dass die vorher geplante
    // Restore-Aktion im nächsten Main-Queue-Umlauf abgeschlossen wurde.
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
    #expect(restoreCount == 1)
    #expect(restoredWindow === primaryWindow)
    #expect(restoreCount == 1)
}

@Test("Restore-Completion wird nach allen Fenstern exakt einmal gemeldet")
@MainActor
func sessionRestoreCompletionLatchFinishesExactlyOnce() {
    var completionCount = 0
    var latch: RestoreCompletionLatch!
    latch = RestoreCompletionLatch(count: 3) {
        completionCount += 1
        // Reentrante oder versehentlich doppelte Child-Completion.
        latch.finishOne()
    }

    latch.finishOne()
    latch.finishOne()
    #expect(completionCount == 0)
    latch.finishOne()
    #expect(completionCount == 1)
    latch.finishOne()
    latch.finishOne()
    #expect(completionCount == 1)
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

@Test("Restore richtet den Projektkontext am gespeicherten aktiven Repo-Tab aus")
@MainActor
func sessionWorkspaceRestoreSelectsActiveRepositoryContext() async throws {
    let (defaults, suite) = sessionDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-session-repos-\(UUID().uuidString)")
    let repoA = base.appendingPathComponent("repo-a", isDirectory: true)
    let repoB = base.appendingPathComponent("repo-b", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    for repo in [repoA, repoB] {
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
    }
    let fileA = repoA.appendingPathComponent("inter/2026/a.txt")
    let fileB = repoB.appendingPathComponent("tief/b.txt")
    try FileManager.default.createDirectory(
        at: fileA.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: fileB.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try "A".write(to: fileA, atomically: true, encoding: .utf8)
    try "B".write(to: fileB, atomically: true, encoding: .utf8)

    // Der Produktpfad löst den Projektkontext absichtlich asynchron auf.
    // Dieser Test prüft das Restore-Ergebnis statt die Queue-Latenz und
    // injiziert deshalb synchrone Scheduler; die eigene Projektkontext-Suite
    // belegt separat, dass der echte UI-Pfad nicht inline ins Dateisystem geht.
    let workspace = Workspace(
        defaults: defaults,
        scheduleProjectContextWork: { $0() },
        deliverProjectContextResult: { $0() }
    )
    let state = RestorableWindowState(
        projectPath: nil,
        documentPaths: [fileA.path, fileB.path],
        activeDocumentPath: fileA.path,
        frame: nil
    )
    var finished = false
    workspace.restore(state) { finished = true }
    let deadline = Date().addingTimeInterval(5)
    while !finished, Date() < deadline {
        await Task.yield()
    }

    #expect(finished)
    #expect(workspace.activeTab?.url?.canonicalFileURL == fileA.canonicalFileURL)
    #expect(workspace.projectURL?.canonicalFileURL == repoA.canonicalFileURL,
            "Der Projektkontext muss dem endgültigen aktiven Restore-Tab folgen")
}

@Test("Restore lässt keinen leeren Start-Tab aufblitzen")
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
    // Ausgangslage wie beim echten Folgestart: ein unberührter Start-Tab
    // (zeigt den Willkommens-Platzhalter) ist offen.
    #expect(workspace.tabs.contains { $0.isPristineScratch })

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

    #expect(!workspace.tabs.contains { $0.isPristineScratch },
            "Start-Tab darf beim Restore nicht kurz aufblitzen")
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
    #expect(workspace.tabs[0].isPristineScratch)
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

@Test("Eingefrorene Fensterliste erfasst nachträglich benannten Tab")
@MainActor
func sessionCaptureUsesFrozenWindowsWithCurrentTabState() throws {
    let (defaults, suite) = sessionDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let savedURL = try sessionFile("nachtraeglich-benannt.txt", content: "Text")
    defer {
        try? FileManager.default.removeItem(
            at: savedURL.deletingLastPathComponent()
        )
    }

    let workspace = Workspace(defaults: defaults)
    let window = NSWindow()
    WorkspaceWindowRegistry.register(workspace, for: window)
    defer { WorkspaceWindowRegistry.unregister(window) }

    // Der Beenden-Pfad friert die Fensterreihenfolge vor den Dialogen ein.
    // „Sichern unter…" ergänzt die Datei-URL erst danach.
    let frozenWindows = [window]
    workspace.tabs[0].title = savedURL.lastPathComponent
    workspace.tabs[0].path = savedURL.deletingLastPathComponent().path
    workspace.tabs[0].url = savedURL

    SessionRestorationCoordinator.captureCurrentSession(
        defaults: defaults,
        windows: frozenWindows
    )

    let capturedPaths = SessionStateStore.load(from: defaults)?.windows
        .map(\.documentPaths)
    #expect(capturedPaths == [[savedURL.path]])
}
