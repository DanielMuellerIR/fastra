import Darwin
import Foundation
import Testing
@testable import Fastra

@Suite("Dateisystemübergreifender Schreib- und Vorschau-Schutz", .serialized)
@MainActor
struct FileSystemSafetyTests {
    private func fixture() throws -> (URL, URL) {
        let environment = ProcessInfo.processInfo.environment
        let parent = environment["FASTRA_FILESYSTEM_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? testTemporaryDirectory()
        var info = statfs()
        try #require(statfs(parent.path, &info) == 0)
        let filesystem = withUnsafeBytes(of: info.f_fstypename) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        if let expected = environment["FASTRA_FILESYSTEM_EXPECTED"] {
            try #require(filesystem == expected, "Der Test muss auf dem ausdrücklich ausgewählten Dateisystem laufen")
        }
        let root = parent.appendingPathComponent("fastra-filesystem-\(UUID().uuidString)")
        let backups = testTemporaryDirectory().appendingPathComponent("fastra-backups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        return (root.canonicalFileURL, backups)
    }

    private func transaction(_ files: [URL], options: SearchOptions) throws -> ApplyTransaction {
        let plan = ApplyEngine.plan(files: files, options: options)
        try #require(plan.files.count == files.count)
        return ApplyTransaction(inputs: try plan.files.map {
            ApplyTransaction.Input(url: $0.url, snapshot: try #require($0.originalSnapshot), matches: $0.matches)
        }, options: options)
    }

    @Test("Mehrdatei-Vorschau folgt weder Umbenennungen noch wiederverwendeten Namen",
          arguments: ["file", "folder", "reused-name", "unchanged-input"], [false, true])
    func renamedPreviewAbortsAllWrites(_ change: String, _ duringPreflight: Bool) throws {
        let (root, backups) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: backups) }
        let directory = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("first.txt"), second = directory.appendingPathComponent("second.txt")
        let firstBytes = Data("FOO first".utf8), secondBytes = Data("foo second".utf8)
        try firstBytes.write(to: first); try secondBytes.write(to: second)
        let options = SearchOptions(find: "foo", replace: change == "unchanged-input" ? "foo" : "bar",
                                    isRegex: false, caseSensitive: false)
        let preview = try transaction([first, second], options: options)
        var actualFirst = first, actualSecond = second
        let relocate = {
            if change == "folder" {
                let destination = root.appendingPathComponent("moved")
                try FileManager.default.moveItem(at: directory, to: destination)
                actualFirst = destination.appendingPathComponent(first.lastPathComponent)
                actualSecond = destination.appendingPathComponent(second.lastPathComponent)
            } else {
                actualSecond = directory.appendingPathComponent("renamed.txt")
                try FileManager.default.moveItem(at: second, to: actualSecond)
                if change == "reused-name" { try secondBytes.write(to: second) }
            }
        }
        if !duringPreflight { try relocate() }
        do {
            _ = try preview.execute(backupRoot: backups, cleanupOlderThan: nil,
                                    beforePreflight: duringPreflight ? relocate : nil)
            Issue.record("Eine veraltete Mehrdatei-Vorschau wurde geschrieben")
        } catch ApplyError.conflict { }
        #expect(try Data(contentsOf: actualFirst) == firstBytes)
        #expect(try Data(contentsOf: actualSecond) == secondBytes)
        if change == "reused-name" { #expect(try Data(contentsOf: second) == secondBytes) }
        #expect(preview.inputs.map(\.url) == [first, second])
    }

    @Test("Mehrdatei-Apply und Undo funktionieren atomar oder lassen sämtliche Originale erhalten")
    func applyAndUndoRequireAtomicSupport() throws {
        let (root, backups) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: backups) }
        let files = [root.appendingPathComponent("a.txt"), root.appendingPathComponent("b.txt")]
        for file in files { try Data("foo".utf8).write(to: file) }
        let support = try #require(root.resourceValues(forKeys: [.volumeSupportsSwapRenamingKey]).volumeSupportsSwapRenaming)
        let preview = try transaction(files, options: SearchOptions(find: "foo", replace: "bar", isRegex: false))
        if support {
            let session = try preview.execute(backupRoot: backups, cleanupOlderThan: nil)
            #expect(session.entries.count == 2)
            for file in files { #expect(try Data(contentsOf: file) == Data("bar".utf8)) }
            _ = try ApplyEngine.undo(session)
        } else {
            do {
                _ = try preview.execute(backupRoot: backups, cleanupOlderThan: nil)
                Issue.record("Apply schrieb trotz fehlender atomarer Austausch-Unterstützung")
            } catch ApplyError.conflict(let message) {
                #expect(message == AtomicFileCommit.Failure.unsupportedAtomicSwap.localizedDescription)
            }
        }
        for file in files { #expect(try Data(contentsOf: file) == Data("foo".utf8)) }
    }

    @Test("Umbenennungserkennung verlangt verlässliche IDs; fremde Save-Ziele bleiben unverändert")
    func fileReferencesAndSaveConflicts() async throws {
        let (root, backups) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: backups) }
        let file = root.appendingPathComponent("original.txt"), moved = root.appendingPathComponent("moved.txt")
        let original = Data("Original".utf8)
        try original.write(to: file)
        let supportsIDs = try #require(file.resourceValues(forKeys: [.volumeSupportsPersistentIDsKey]).volumeSupportsPersistentIDs)
        let ws = Workspace()
        ws.externalReloadConfirmHandler = { _ in false }
        ws.saveConflictConfirmHandler = { _ in false }
        ws.saveSafetyWarningHandler = { _, _ in }
        var loaded = false
        ws.loadFile(at: file) { loaded = $0 }
        try #require(await waitUntil { loaded })
        #expect((ws.activeTab?.fileLocationReference != nil) == supportsIDs)
        ws.activeTabContent.wrappedValue = "Eigene Änderung"
        try FileManager.default.moveItem(at: file, to: moved)
        ws.checkExternalChanges()
        try #require(await waitUntil { supportsIDs ? ws.activeTab?.url == moved : ws.activeTab?.externalFileUnavailable == true })
        #expect(ws.activeTab?.content == "Eigene Änderung")
        #expect(try Data(contentsOf: moved) == original)
        // Ein bytegleiches, aber fremdes Ziel darf beim Save nicht überschrieben werden.
        let target = try #require(ws.activeTab?.url)
        let displaced = root.appendingPathComponent("displaced.txt")
        if supportsIDs { try FileManager.default.moveItem(at: moved, to: displaced) }
        try original.write(to: target)
        #expect(!ws.write(tab: ws.activeTab!, to: target))
        #expect(try Data(contentsOf: target) == original)
        #expect(try Data(contentsOf: supportsIDs ? displaced : moved) == original)
        #expect(ws.activeTab?.hasUnsavedChanges == true)
    }

    @Test("Ein Zielwechsel zwischen zwei Schreibschritten überschreibt keine fremde Datei")
    func replacementDuringMultiFileCommitPreservesForeignFile() throws {
        let (root, backups) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: backups) }
        let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
        let moved = root.appendingPathComponent("moved.txt"), bytes = Data("foo".utf8)
        try bytes.write(to: first); try bytes.write(to: second)
        let supportsSwap = try #require(root.resourceValues(forKeys: [.volumeSupportsSwapRenamingKey]).volumeSupportsSwapRenaming)
        let preview = try transaction([first, second], options: SearchOptions(find: "foo", replace: "bar", isRegex: false))
        var renamed = false
        do {
            _ = try preview.execute(backupRoot: backups, cleanupOlderThan: nil, beforeAtomicReplace: { target in
                if target == second {
                    try FileManager.default.moveItem(at: second, to: moved)
                    try bytes.write(to: second)
                    renamed = true
                }
            })
            Issue.record("Eine fremde Datei wurde trotz Zielwechsel überschrieben")
        } catch ApplyError.writeFailed(let partial, _) {
            #expect(supportsSwap && renamed)
            #expect(partial.entries.count == 1)
            #expect(try Data(contentsOf: second) == bytes)
            _ = try ApplyEngine.undo(partial)
        } catch ApplyError.conflict(let message) {
            #expect(!supportsSwap && !renamed)
            #expect(message == AtomicFileCommit.Failure.unsupportedAtomicSwap.localizedDescription)
        }
        #expect(try Data(contentsOf: first) == bytes)
        #expect(try Data(contentsOf: second) == bytes)
        if renamed { #expect(try Data(contentsOf: moved) == bytes) }
    }
}
