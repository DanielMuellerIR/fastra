import Foundation
import AppKit
import Testing
@testable import Fastra

@Suite("Freigabevorschau für Plattendateien")
@MainActor
struct SearchApprovalFilePreviewTests {
    @Test("Die Teilvorschau erhält UTF-16/BOM und zeigt Unicode exakt, ohne Dateien zu ändern")
    func partialEncodedPreview() throws {
        try fixture { workspace, files, original in
            let preview = try SearchApprovalPreview.build(SearchApprovalPreview.Request.capture(in: workspace))
            #expect(preview.entries.count == 1)
            #expect(preview.changedCount == 1)
            #expect(preview.entries[0].hasAnnotations)
            let rows = try #require(preview.entries[0].document.result?.rows)
            #expect(rows.contains { $0.after?.contains("bar") == true })
            #expect(rows.contains { $0.before == "foo" && $0.after == "foo" })
            #expect(try Data(contentsOf: files[0]) == original)
            #expect(try Data(contentsOf: files[1]) == Data("foo\n".utf8))
        }
    }

    @Test("Eine Fremdänderung an freigegebenen oder unfreigegebenen Dateien verhindert die gesamte Vorschau", arguments: [0, 1])
    func changedFile(_ index: Int) throws {
        try fixture { workspace, files, _ in
            let request = try SearchApprovalPreview.Request.capture(in: workspace)
            if index == 1 { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files[1].path) }
            try Data("external foo\n".utf8).write(to: files[index], options: .atomic)
            var failure: Error?
            do { _ = try SearchApprovalPreview.build(request) }
            catch { failure = error }
            #expect(failure != nil)
            if index == 1 {
                #expect(failure.map(TextWorkflowFailure.message) == TextWorkflowFailure.stale)
            }
            #expect(try Data(contentsOf: files[index]) == Data("external foo\n".utf8))
        }
    }

    @Test("Schreibschutz nach der Suche sperrt die Vorschau, eine unfreigegebene geschützte Datei bleibt erlaubt")
    func permissionChanged() throws {
        try fixture { workspace, files, original in
            let request = try SearchApprovalPreview.Request.capture(in: workspace)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: files[0].path)
            #expect(throws: (any Error).self) { try SearchApprovalPreview.build(request) }
            #expect(try Data(contentsOf: files[0]) == original)
        }
    }

    @Test("Eine stark gewachsene freigegebene Quelle erklärt die Neuberechnung ohne vollständigen Read")
    func grownSelectedFile() throws {
        try fixture { workspace, files, _ in
            let request = try SearchApprovalPreview.Request.capture(in: workspace)
            let grownSize = FileLoader.largeFileThreshold + 1
            let handle = try FileHandle(forWritingTo: files[0])
            defer { try? handle.close() }
            try handle.truncate(atOffset: grownSize)
            var failure: Error?
            do { _ = try SearchApprovalPreview.build(request) }
            catch { failure = error }
            #expect(failure.map(TextWorkflowFailure.message) == TextWorkflowFailure.stale)
            let size = try FileManager.default.attributesOfItem(atPath: files[0].path)[.size] as? NSNumber
            #expect(size?.uint64Value == grownSize)
        }
    }

    @Test("Eine reale Kappung pro Datei unter dem Gesamtlimit sperrt Freigaben und bleibt als Grenze erkennbar")
    func perFileCap() throws {
        try fixture { workspace, files, _ in
            try Data(String(repeating: "foo\n", count: 6000).utf8).write(to: files[0])
            let result = FolderSearch.find(in: files, filter: .all, options: workspace.currentSearchOptions)
            #expect(!result.wasCapped)
            workspace.folderResults = result.perFile
            workspace.folderTotalMatches = result.totalMatches
            workspace.folderResultsWereCapped = result.wasCapped
            workspace.publishSearchApprovals()
            #expect(workspace.folderResultsContainCappedFiles)
            #expect(workspace.navMatches.count == 5001)
            #expect(workspace.folderTotalMatches == 6001)
            #expect(!workspace.searchApproval.isComplete)
            #expect(!workspace.setAllSearchMatchesApproved(true, generation: workspace.searchApproval.generation))
        }
    }

    @Test("Reale nicht lesbare oder zu große Dateien sperren Freigaben; bewusste Binär-Skips bleiben erlaubt", arguments: [0, 1, 2])
    func incompleteSources(_ kind: Int) throws {
        try fixture { workspace, files, original in
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files[1].path)
            switch kind {
            case 0:
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: files[1].path)
            case 1:
                let handle = try FileHandle(forWritingTo: files[1])
                defer { try? handle.close() }
                try handle.truncate(atOffset: FileLoader.largeFileThreshold + 1)
            default: try Data([0]).write(to: files[1])
            }
            let result = FolderSearch.find(in: files, filter: .all, options: workspace.currentSearchOptions)
            #expect(result.invalidPatternMessage == nil)
            let reasons: [FolderSearch.SkipReason] = [.unreadable, .tooLarge, .binary]
            #expect(result.perFile.contains { $0.url.lastPathComponent == files[1].lastPathComponent && $0.skipped == reasons[kind] })
            workspace.folderResults = result.perFile
            workspace.folderTotalMatches = result.totalMatches
            workspace.folderResultsWereCapped = result.wasCapped
            workspace.publishSearchApprovals()
            #expect(workspace.searchApprovalIncompleteFiles.count == (kind == 2 ? 0 : 1))
            #expect(workspace.searchApproval.isComplete == (kind == 2))
            let approved = workspace.setAllSearchMatchesApproved(true, generation: workspace.searchApproval.generation)
            #expect(approved == (kind == 2))
            #expect(try Data(contentsOf: files[0]) == original)
        }
    }

    @Test("Eine Ausgabegrenze stoppt die gemeinsame Ersetzungsplanung vor einer übergroßen Vorschau")
    func outputBound() throws {
        try fixture(replacement: String(repeating: "X", count: 8192)) { workspace, files, original in
            let request = try SearchApprovalPreview.Request.capture(in: workspace)
            var limits = SearchApprovalPreview.Limits.standard
            limits.outputBytes = 128
            #expect(throws: SearchApprovalPreview.Failure.self) { try SearchApprovalPreview.build(request, limits: limits) }
            #expect(try Data(contentsOf: files[0]) == original)
        }
    }

    @Test("Eine gekappte oder fehlerhafte Ordnerliste kann auch für eine einzelne Freigabe kein Ticket liefern", arguments: [0, 1])
    func incompleteList(_ kind: Int) throws {
        try fixture { workspace, files, _ in
            if kind == 0 { workspace.folderResultsWereCapped = true }
            else {
                workspace.folderResults.append(FolderSearch.PerFileResult(url: files[0].deletingLastPathComponent().appendingPathComponent("missing.txt"),
                    matches: [], totalMatches: 0, skipped: .unreadable, snapshot: nil, searchOptions: workspace.currentSearchOptions))
            }
            workspace.publishSearchApprovals()
            #expect(workspace.searchApproval.approvedIDs.isEmpty)
            #expect(throws: (any Error).self) { try SearchApprovalPreview.Request.capture(in: workspace) }
        }
    }

    @Test("Ein geschlossenes Dokumentfenster entwertet auch eine fertige Plattenvorschau")
    func closedWindow() throws {
        try fixture { workspace, files, original in
            let request = try SearchApprovalPreview.Request.capture(in: workspace)
            let preview = try SearchApprovalPreview.build(request)
            let window = try #require(CommandTargeting.registeredWindow(for: workspace))
            WorkspaceWindowRegistry.unregister(window)
            #expect(!request.isCurrent(in: workspace))
            #expect(throws: (any Error).self) { try workspace.applySearchApproval(preview) }
            #expect(try Data(contentsOf: files[0]) == original)
        }
    }

    @Test("Eine verschwundene Suchquelle darf eine teilweise Ordnersuche nicht zur Trefferfreigabe machen")
    func missingSource() throws {
        try fixture { workspace, files, original in
            let missing = files[0].deletingLastPathComponent().appendingPathComponent("missing-folder")
            let result = FolderSearch.find(in: [files[0], missing], filter: .all, options: workspace.currentSearchOptions)
            #expect(result.invalidPatternMessage != nil)
            #expect(result.perFile.isEmpty)
            workspace.folderResults = result.perFile
            workspace.folderTotalMatches = result.totalMatches
            workspace.searchError = result.invalidPatternMessage
            workspace.publishSearchApprovals()
            _ = workspace.setAllSearchMatchesApproved(true, generation: workspace.searchApproval.generation)
            #expect(workspace.searchApproval.ticket == nil)
            let unchanged = try Data(contentsOf: files[0])
            #expect(unchanged == original)
        }
    }

    @Test("UTF-32-Unicode nutzt die tatsächliche Bytequote statt einer zu kleinen UTF-8-Ersatzgrenze")
    func utf32ExactQuota() throws {
        try fixture { workspace, files, _ in
            let text = "foo " + String(repeating: "漢", count: 20)
            var original = Data([0xFF, 0xFE, 0x00, 0x00])
            original.append(try #require(text.data(using: .utf32LittleEndian)))
            try original.write(to: files[0])
            workspace.folderResults = files.map { FolderSearch.searchOneFile(at: $0, options: workspace.currentSearchOptions) }
            workspace.folderTotalMatches = workspace.folderResults.reduce(0) { $0 + $1.totalMatches }
            workspace.publishSearchApprovals()
            let approved = workspace.setAllSearchMatchesApproved(true, generation: workspace.searchApproval.generation)
            try #require(approved)
            let request = try SearchApprovalPreview.Request.capture(in: workspace)
            var limits = SearchApprovalPreview.Limits.standard
            limits.outputBytes = original.count
            let preview = try SearchApprovalPreview.build(request, limits: limits)
            #expect(preview.changedCount == 1)
            limits.outputBytes -= 1
            #expect(throws: SearchApprovalPreview.Failure.self) { try SearchApprovalPreview.build(request, limits: limits) }
            let unchanged = try Data(contentsOf: files[0])
            #expect(unchanged == original)
        }
    }

    private func fixture(replacement: String = "bar", _ body: (Workspace, [URL], Data) throws -> Void) throws {
        let root = testTemporaryDirectory().appendingPathComponent("approval-preview-\(UUID().uuidString)").canonicalFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = [root.appendingPathComponent("A.txt"), root.appendingPathComponent("B.txt")]
        defer {
            for file in files { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            try? FileManager.default.removeItem(at: root)
        }
        var original = Data([0xFF, 0xFE])
        original.append(try #require("foo\r\n🙂 foo\n".data(using: .utf16LittleEndian)))
        try original.write(to: files[0]); try Data("foo\n".utf8).write(to: files[1])
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: files[1].path)
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra-approval-file-preview-\(UUID().uuidString)"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { WorkspaceWindowRegistry.unregister(window); window.close() }
        workspace.scope = .folder; workspace.findPattern = "foo"; workspace.replacePattern = replacement; workspace.useRegex = false
        workspace.folderResults = files.map { FolderSearch.searchOneFile(at: $0, options: workspace.currentSearchOptions) }
        workspace.folderTotalMatches = workspace.folderResults.reduce(0) { $0 + $1.totalMatches }
        workspace.folderSearching = false; workspace.folderNeedsSearch = false; workspace.folderResultsAreStale = false
        workspace.publishSearchApprovals()
        let selected = try #require(workspace.folderResults[0].matches.last?.id)
        let approved = workspace.setSearchMatchesApproved(true, ids: [selected], generation: workspace.searchApproval.generation)
        try #require(approved)
        try body(workspace, files, original)
    }
}
