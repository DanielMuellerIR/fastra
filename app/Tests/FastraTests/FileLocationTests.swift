import Darwin
import Foundation
import Testing
@testable import Fastra

private final class PausedLocationReader: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var reading = false
    var started: Bool { lock.withLock { reading } }
    func read(_ url: URL) -> FileSnapshot? {
        let shouldPause = lock.withLock {
            let first = !reading
            reading = true
            return first
        }
        if shouldPause, gate.wait(timeout: .now() + 10) != .success { return nil }
        return try? FileSnapshot.readSnapshotOnly(from: url)
    }
    func release() { gate.signal() }
}

@Suite("Externe Datei- und Ordnerumbenennungen", .serialized)
@MainActor
struct FileLocationTests {
    private func fixture() throws -> (URL, URL) {
        let root = testTemporaryDirectory().appendingPathComponent("locations-\(UUID().uuidString)").canonicalFileURL
        let directory = root.appendingPathComponent("Vorher")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (root.canonicalFileURL, directory.canonicalFileURL)
    }

    private func load(_ url: URL, workspace: Workspace = Workspace()) async throws -> Workspace {
        workspace.externalReloadConfirmHandler = { title in
            Issue.record("Unerwartete Fremdänderungs-Rückfrage: \(title)")
            return false
        }
        workspace.saveSafetyWarningHandler = { title, message in Issue.record("\(title): \(message)") }
        var loaded = false
        workspace.loadFile(at: url) { loaded = $0 }
        try #require(await waitUntil { loaded && workspace.activeTab?.fileLocationReference != nil })
        return workspace
    }

    @Test("Umbenennen, Speichern und erneut Umbenennen behalten Inhalt, Identität und Undo")
    func renameAndSave() async throws {
        let (root, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var url = directory.appendingPathComponent("Alt.md")
        try "Original\n".write(to: url, atomically: true, encoding: .utf8)
        let ws = try await load(url)
        let documentID = ws.activeTab!.documentID
        var conflicts = 0
        ws.saveConflictConfirmHandler = { _ in conflicts += 1; return false }
        for name in ["Neu # 😀.md", "Nochmals.md"] {
            ws.activeTab!.undoHistory.replace(ws.activeTab!.content, with: ws.activeTab!.content + name)
            ws.activeTabContent.wrappedValue += name
            let content = ws.activeTab!.content
            let destination = directory.appendingPathComponent(name)
            try FileManager.default.moveItem(at: url, to: destination)
            ws.checkExternalChanges()
            try #require(await waitUntil { ws.activeTab?.url == destination })
            #expect(ws.activeTab?.documentID == documentID)
            #expect(ws.activeTab?.content == content)
            #expect(ws.activeTab?.hasUnsavedChanges == true)
            #expect(ws.activeTab?.undoHistory.manager(for: content).canUndo == true)
            #expect(ws.write(tab: ws.activeTab!, to: destination))
            #expect(try String(contentsOf: destination, encoding: .utf8) == content)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            url = destination
        }
        #expect(conflicts == 0)
    }

    @Test("Projekt- und Elternordner folgen Umbenennungen auch ohne offene Dateien", arguments: [false, true])
    func renameDirectory(_ withDocuments: Bool) async throws {
        let (root, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ws = Workspace()
        ws.openProject(at: directory)
        let names = ["a.txt", "b.txt"]
        if withDocuments {
            for name in names {
                let url = directory.appendingPathComponent(name)
                try name.write(to: url, atomically: true, encoding: .utf8)
                _ = try await load(url, workspace: ws)
            }
            ws.activeTabContent.wrappedValue += " ungespeichert"
        }
        try #require(await waitUntil { ws.projectLocationReference != nil })
        let destination = root.appendingPathComponent("Nachher")
        try FileManager.default.moveItem(at: directory, to: destination)
        // Der alte Name darf nun ein fremdes Verzeichnis bezeichnen.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ws.checkExternalChanges()
        try #require(await waitUntil { ws.projectURL?.path == destination.path })
        if withDocuments {
            try #require(await waitUntil { ws.tabs.allSatisfy { $0.url?.deletingLastPathComponent().path == destination.path } })
            #expect(ws.activeTab?.content == "b.txt ungespeichert")
            #expect(ws.activeTab?.hasUnsavedChanges == true)
        }
    }

    @Test("Safe-Save am vorhandenen Pfad verfolgt keine beiseitegeschobene alte Inode")
    func atomicReplacementStaysAtPath() async throws {
        let (root, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = directory.appendingPathComponent("Datei.txt")
        let backup = directory.appendingPathComponent("Alt.txt")
        try "Original".write(to: url, atomically: true, encoding: .utf8)
        let ws = try await load(url)
        try FileManager.default.moveItem(at: url, to: backup)
        try "Neue Fassung".write(to: url, atomically: true, encoding: .utf8)
        ws.checkExternalChanges()
        try #require(await waitUntil { ws.activeTab?.content == "Neue Fassung" })
        #expect(ws.activeTab?.url == url)
        let renamed = directory.appendingPathComponent("Neu.txt")
        try FileManager.default.moveItem(at: url, to: renamed)
        ws.checkExternalChanges()
        #expect(await waitUntil { ws.activeTab?.url == renamed })
        #expect(try String(contentsOf: backup, encoding: .utf8) == "Original")
    }

    @Test("Nach Wiedererkennung ausgetauschtes Ziel bleibt vor dem Speichern geschützt")
    func replacementAfterRelocationCannotBeOverwritten() async throws {
        let (root, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = directory.appendingPathComponent("Alt.txt"), destination = directory.appendingPathComponent("Neu.txt")
        try "Original".write(to: url, atomically: true, encoding: .utf8)
        let ws = try await load(url)
        ws.activeTabContent.wrappedValue = "Eigene Änderung"
        try FileManager.default.moveItem(at: url, to: destination)
        ws.checkExternalChanges()
        try #require(await waitUntil { ws.activeTab?.url == destination })
        try "Fremde Datei".write(to: destination, atomically: true, encoding: .utf8)
        var conflicts = 0
        ws.saveConflictConfirmHandler = { _ in conflicts += 1; return false }
        #expect(!ws.write(tab: ws.activeTab!, to: destination))
        #expect(conflicts == 1)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Fremde Datei")
        #expect(ws.activeTab?.content == "Eigene Änderung")
        #expect(ws.activeTab?.hasUnsavedChanges == true)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Austausch während der Wiedererkennung bestätigt keine falsche Zielidentität")
    func replacementDuringInspection() async throws {
        let (root, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = directory.appendingPathComponent("Alt.txt"), destination = directory.appendingPathComponent("Neu.txt")
        try "Original".write(to: url, atomically: true, encoding: .utf8)
        let observed = try #require(ExternalFileObservation(url: url))
        try FileManager.default.moveItem(at: url, to: destination)
        let inspector = ExternalChangeInspector(snapshotReader: { candidate in
            try? "Fremd!!!".write(to: candidate, atomically: true, encoding: .utf8)
            return try? FileSnapshot.readSnapshotOnly(from: candidate)
        })
        var result: ExternalChangeInspector.Inspection?
        inspector.inspect(.init(tabID: UUID(), documentID: UUID(), url: url,
            knownObservation: observed, observedByteCount: 8, isDirty: true,
            locationReference: observed.locationReference)) { result = $0 }
        try #require(await waitUntil { result != nil })
        #expect(result?.observation == nil)
        #expect(result?.stableSnapshot == nil)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Fremd!!!")
    }

    @Test("Gelöschte Dateien und ersetzte Namen werden nicht über eine alte Referenz gebunden")
    func deletedReferenceDoesNotFindReplacement() throws {
        let (root, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = directory.appendingPathComponent("Datei.txt")
        try "Original".write(to: url, atomically: true, encoding: .utf8)
        let reference = try #require(FileLocationReference(url: url))
        try FileManager.default.removeItem(at: url)
        #expect(reference.resolvedURL() == nil)
        try "Fremde Datei".write(to: url, atomically: true, encoding: .utf8)
        #expect(reference.resolvedURL() == nil)
        #expect(FileLocationReference(url: url, expectedIdentity: reference.identity) == nil)
    }

    @Test("Eine verspätete Umbenennungserkennung entwertet kein inzwischen bestätigtes Speichern")
    func lateInspectionCannotRebindSavedTab() async throws {
        let (root, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = directory.appendingPathComponent("Alt.txt"), moved = directory.appendingPathComponent("Verschoben.txt")
        try "Original".write(to: url, atomically: true, encoding: .utf8)
        let reader = PausedLocationReader()
        defer { reader.release() }
        let inspector = ExternalChangeInspector(snapshotReader: { reader.read($0) })
        let ws = try await load(url, workspace: Workspace(externalChangeInspector: inspector))
        ws.activeTabContent.wrappedValue = "Bewusst neu gespeichert"
        try FileManager.default.moveItem(at: url, to: moved)
        ws.checkExternalChanges()
        try #require(await waitUntil { reader.started })
        var confirmed = false
        ws.saveConflictConfirmHandler = { _ in confirmed = true; return true }
        #expect(ws.write(tab: ws.activeTab!, to: url))
        #expect(confirmed)
        reader.release()
        try #require(await waitUntil { !inspector.isInspecting(tabID: ws.activeTab!.id) })
        #expect(ws.activeTab?.url == url)
        #expect(ws.activeTab?.content == "Bewusst neu gespeichert")
        #expect(try String(contentsOf: url, encoding: .utf8) == "Bewusst neu gespeichert")
        #expect(try String(contentsOf: moved, encoding: .utf8) == "Original")
    }

    @Test("Mehrdeutige Hardlinks und Papierkorbziele werden nicht automatisch übernommen")
    func ambiguousOrDiscardedLocations() throws {
        let (root, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = directory.appendingPathComponent("Datei.txt")
        try "Original".write(to: url, atomically: true, encoding: .utf8)
        let reference = try #require(FileLocationReference(url: url))
        let linked = directory.appendingPathComponent("Zweiter Name.txt")
        try FileManager.default.linkItem(at: url, to: linked)
        #expect(reference.resolvedURL() == nil)
        #expect(FileLocationReference(url: url) == nil)
        try FileManager.default.removeItem(at: linked)
        let trash = directory.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent("Datei.txt"))
        #expect(reference.resolvedURL() == nil)
    }

    @Test("Eine offene Suchvorschau behält ihren Projektpfad trotz Ordnerumbenennung")
    func projectRenameDoesNotRetargetSearchPreview() async throws {
        let (root, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directory.appendingPathComponent("Datei.txt")
        try "Original".write(to: file, atomically: true, encoding: .utf8)
        let ws = try await load(file)
        try #require(await waitUntil { ws.projectURL == directory && ws.projectLocationReference != nil })
        ws.showSearchDialog = true
        let moved = root.appendingPathComponent("Verschoben")
        try FileManager.default.moveItem(at: directory, to: moved)
        ws.checkExternalChanges()
        try #require(await waitUntil { ws.activeTab?.url?.path == moved.appendingPathComponent("Datei.txt").path })
        #expect(ws.projectURL == directory)
        ws.showSearchDialog = false
        ws.checkExternalChanges()
        #expect(await waitUntil { ws.projectURL?.path == moved.path })
    }
}
