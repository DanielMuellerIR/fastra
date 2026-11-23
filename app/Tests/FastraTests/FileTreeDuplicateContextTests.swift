import Foundation
import Testing
@testable import Fastra

/// Verzögert den echten Dateikopierer, ohne Dateigröße oder Scheduler-Timing
/// zur Voraussetzung des Regressionstests zu machen.
private final class DuplicateSchedule: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var started = false
    private var reads = 0

    var hasStarted: Bool { lock.withLock { started } }
    var readCount: Int { lock.withLock { reads } }
    func resume() { release.signal() }
    func noteRead() { lock.withLock { reads += 1 } }

    func copy(_ source: URL) throws -> URL {
        #expect(!Thread.isMainThread)
        lock.withLock { started = true }
        guard release.wait(timeout: .now() + 15) == .success else {
            throw CocoaError(.userCancelled)
        }
        return try FileTreeOperations.duplicate(source)
    }
}

enum DuplicateNavigation: String, CaseIterable {
    case unchanged, menuHandlerAfterTabChange, sameProjectTab, tabRoundTrip, reusedDocument
    case otherProject, reopenedProject, windowClosed
}

@Suite("Duplizieren bleibt beim ursprünglichen Bedienkontext")
@MainActor
struct FileTreeDuplicateContextTests {
    @Test("Später Kopierabschluss erhält Auswahl und Bytes", arguments: DuplicateNavigation.allCases)
    func delayedCopy(_ navigation: DuplicateNavigation) async throws {
        let temporaryDirectory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let directory = temporaryDirectory.canonicalFileURL
        defer { try? FileManager.default.removeItem(at: directory) }
        let otherProject = directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherProject, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("A.txt")
        let unrelated = directory.appendingPathComponent("B.txt")
        let originalBytes = Data([0xEF, 0xBB, 0xBF]) + Data("Original\r\nZweite Zeile\r\n".utf8)
        let unrelatedBytes = Data("Unabhängig\r\n".utf8)
        try originalBytes.write(to: source)
        try unrelatedBytes.write(to: unrelated)
        let suite = "fastra-test-duplicate-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        workspace.openProject(at: directory)
        let first = EditorTab(title: "A.txt", path: directory.path, url: source,
                              content: "Original\r\nZweite Zeile\r\n", isPreview: navigation == .reusedDocument)
        let second = EditorTab(title: "B.txt", path: directory.path, url: unrelated, content: "Noch nicht gesicherte Eingabe", isDirty: true)
        workspace.tabs = [first, second]
        workspace.activeTabID = first.id
        let schedule = DuplicateSchedule()
        defer { schedule.resume() }
        workspace.fileTreeDuplicator = { try schedule.copy($0) }
        workspace.initialFileLoader = { url in
            schedule.noteRead()
            return try FileLoader.load(url: url)
        }
        var results: [Result<URL, Error>] = []
        let openingContext = workspace.fileTreeDuplicateContext()
        if navigation == .menuHandlerAfterTabChange {
            workspace.selectTab(id: second.id)
        }
        workspace.duplicateFileTreeItem(at: source, isDirectory: false,
                                        openingContext: openingContext) { result in
            #expect(Thread.isMainThread)
            results.append(result)
        }
        try #require(await waitUntil { schedule.hasStarted })
        #expect(results.isEmpty)
        switch navigation {
        case .unchanged, .menuHandlerAfterTabChange:
            break
        case .sameProjectTab:
            workspace.selectTab(id: second.id)
        case .tabRoundTrip:
            workspace.selectTab(id: second.id)
            workspace.selectTab(id: first.id)
        case .reusedDocument:
            let third = directory.appendingPathComponent("C.txt")
            try "Neues Vorschaudokument".write(to: third, atomically: true, encoding: .utf8)
            workspace.loadFile(at: third, preview: true)
            try #require(await waitUntil { workspace.activeTab?.isLoading == false })
            #expect(workspace.activeTabID == first.id)
            #expect(workspace.activeDocumentID != first.documentID)
        case .otherProject:
            workspace.openProject(at: otherProject, keepingUnrelatedTabs: true)
        case .reopenedProject:
            workspace.openProject(at: directory, keepingUnrelatedTabs: true)
        case .windowClosed:
            workspace.confirmCloseHandler = { _ in .dontSave }
            try #require(workspace.prepareToCloseWindow())
        }
        let laterSelection = workspace.activeTabID
        let laterProject = workspace.projectURL
        let laterTabs = workspace.tabs.map(\.id)
        schedule.resume()
        try #require(await waitUntil { !results.isEmpty })
        let destination = try #require(results.first).get()
        #expect(results.count == 1)
        #expect(destination.deletingLastPathComponent().canonicalFileURL.path == directory.path)
        #expect(try Data(contentsOf: destination) == originalBytes)
        #expect(try Data(contentsOf: source) == originalBytes)
        #expect(try Data(contentsOf: unrelated) == unrelatedBytes)
        if navigation == .unchanged {
            let copiedFile = destination.canonicalFileURL
            try #require(await waitUntil { workspace.tabs.first(where: { $0.url == copiedFile })?.isLoading == false })
            #expect(workspace.activeTab?.url == copiedFile)
            #expect(workspace.activeTab?.content == first.content)
            #expect(schedule.readCount == 1)
        } else {
            #expect(workspace.activeTabID == laterSelection)
            #expect(workspace.projectURL == laterProject)
            #expect(workspace.tabs.map(\.id) == laterTabs)
            #expect(schedule.readCount == 0)
        }
        if navigation != .windowClosed {
            #expect(workspace.tabs.first(where: { $0.id == second.id })?.content == second.content)
            #expect(workspace.tabs.first(where: { $0.id == second.id })?.isDirty == true)
        }
    }

    @Test("Ordnerkopie öffnet keinen Tab und meldet vollständig kopierten Inhalt")
    func folderCopy() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString).canonicalFileURL
        let folder = directory.appendingPathComponent("Ordner")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([0, 1, 0xFF, 0x0D, 0x0A])
        try bytes.write(to: folder.appendingPathComponent("binary.dat"))
        let suite = "fastra-test-duplicate-folder-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        let initialTabs = workspace.tabs.map(\.id)
        let active = workspace.activeTabID
        var result: Result<URL, Error>?
        workspace.duplicateFileTreeItem(at: folder, isDirectory: true,
                                        openingContext: workspace.fileTreeDuplicateContext()) { result = $0 }
        try #require(await waitUntil { result != nil })
        let destination = try #require(result).get()
        #expect(try Data(contentsOf: destination.appendingPathComponent("binary.dat")) == bytes)
        #expect(workspace.tabs.map(\.id) == initialTabs)
        #expect(workspace.activeTabID == active)
    }

    @Test("Kopierfehler kommt einmal unverändert zurück und öffnet keinen Tab")
    func copyFailure() async throws {
        let suite = "fastra-test-duplicate-error-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        let initialTabs = workspace.tabs.map(\.id)
        let error = CocoaError(.fileReadNoPermission)
        workspace.fileTreeDuplicator = { _ in throw error }
        var results: [Result<URL, Error>] = []
        workspace.duplicateFileTreeItem(at: URL(fileURLWithPath: "/unused"), isDirectory: false,
                                        openingContext: workspace.fileTreeDuplicateContext()) { results.append($0) }
        try #require(await waitUntil { !results.isEmpty })
        #expect(results.count == 1)
        if case .failure(let returned) = results[0] {
            #expect((returned as NSError) == (error as NSError))
        } else {
            Issue.record("Erwarteter Kopierfehler fehlt")
        }
        #expect(workspace.tabs.map(\.id) == initialTabs)
    }
}
