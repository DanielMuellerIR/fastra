import AppKit
import Darwin
import Foundation
import Testing
@testable import Fastra

@Suite("Dokumentziel der Blockübernahme")
@MainActor
struct FileDiffTransferWorkspaceTests {
    @Test("Ein bestätigter Block ändert nur sein Dokument, erhält Undo und berechnet den Diff neu")
    func transferAndRefresh() async throws {
        try await fixture { workspace in
            let target = workspace.tabs[0].id, source = workspace.tabs[1].id, other = workspace.tabs[2].id
            let diff = try await comparison(in: workspace)
            let originalRequest = try #require(workspace.activeTab?.fileDiffRequest)
            workspace.prepareFileDiffTransfer(tabID: diff, requestID: originalRequest.id, blockID: 0, direction: .toLeft)
            let previewReady = await waitUntil { workspace.fileDiffTransferPreview != nil }
            try #require(previewReady)
            let preview = try #require(workspace.fileDiffTransferPreview)
            let validation = try await Task.detached { try preview.validateForApply() }.value
            try workspace.applyFileDiffTransfer(validation)
            #expect(workspace.tabs.first { $0.id == target }?.content == "one\nright\nend\n")
            #expect(workspace.tabs.first { $0.id == source }?.content == "one\nright\nend\nextra\n")
            #expect(workspace.tabs.first { $0.id == other }?.content == "untouched")
            let changed = try #require(workspace.tabs.first { $0.id == target })
            #expect(changed.isDirty)
            #expect(changed.undoHistory.manager(for: changed.content).canUndo)
            #expect(workspace.fileDiffTransferPreview == nil)
            #expect(workspace.activeTabID == diff)
            #expect(workspace.activeTab?.fileDiffRequest?.id != originalRequest.id)
            #expect(await waitUntil { workspace.activeTab?.fileDiffDocument?.result != nil })
            #expect(workspace.activeTab?.fileDiffDocument?.result?.blocks.count == 1)
            #expect(workspace.tabs.filter { $0.fileDiffRequest != nil }.count == 1)
            let currentRequest = try #require(workspace.activeTab?.fileDiffRequest)
            workspace.activeTabID = target
            // Die echte Menü-/Editor-Rücknahme wird zusätzlich im Fenster geprüft.
            let targetIndex = try #require(workspace.tabs.firstIndex { $0.id == target })
            workspace.tabs[targetIndex].content = "one\nleft\nend\n"
            workspace.activeTabID = diff
            #expect(workspace.fileDiffTransferStatus(tabID: diff, requestID: currentRequest.id) != nil)
            workspace.refreshFileDiffOnReturn(tabID: diff, requestID: currentRequest.id)
            #expect(await waitUntil { workspace.activeTab?.fileDiffDocument?.result?.blocks.count == 2 })
            #expect(workspace.fileDiffTransferStatus(tabID: diff, requestID: workspace.activeTab!.fileDiffRequest!.id) == nil)
        }
    }

    @Test("Veraltete Ziele, Quellen und Fenster dürfen keine Speicheränderung ausführen", arguments: 0..<7)
    func stale(_ mutation: Int) async throws {
        try await fixture { workspace in
            let target = workspace.tabs[0].id, source = workspace.tabs[1].id
            _ = try await comparison(in: workspace)
            let preview = try await prepared(in: workspace)
            let validation = try await Task.detached { try preview.validateForApply() }.value
            switch mutation {
            case 0: workspace.tabs[0].content = "external target"
            case 1: let same = workspace.tabs[0].content; workspace.tabs[0].content = same
            case 2: workspace.tabs[0].documentID = UUID()
            case 3: workspace.tabs.removeAll { $0.id == source }
            case 4: workspace.tabs[0].readOnlyReason = "protected"
            case 5: workspace.activeTabID = target
            default: workspace.fileDiffTransferPreview = nil
            }
            let expected = workspace.tabs.map { ($0.id, Data($0.content.utf8)) }
            #expect(throws: FileDiffTransfer.Failure.stale) { try workspace.applyFileDiffTransfer(validation) }
            #expect(workspace.tabs.map(\.id) == expected.map(\.0))
            #expect(workspace.tabs.map { Data($0.content.utf8) } == expected.map(\.1))
        }
    }

    @Test("Ein identischer Tabname im anderen Fenster ist kein Ersatz für das gebundene Dokument")
    func otherWindow() async throws {
        try await fixture { workspace in
            _ = try await comparison(in: workspace)
            let preview = try await prepared(in: workspace)
            let validation = try await Task.detached { try preview.validateForApply() }.value
            try await fixture { other in
                other.tabs = workspace.tabs
                other.activeTabID = workspace.activeTabID
                other.fileDiffTransferPreview = preview
                #expect(!preview.isCurrent(in: other))
                let expected = other.tabs.map { Data($0.content.utf8) }
                #expect(throws: FileDiffTransfer.Failure.stale) { try other.applyFileDiffTransfer(validation) }
                #expect(other.tabs.map { Data($0.content.utf8) } == expected)
            }
        }
    }

    @Test("Eine nach dem Worker-Preflight geänderte Dateiquelle sperrt die Speichermutation", arguments: [false, true])
    func fileChangesAfterValidation(_ atomic: Bool) async throws {
        let root = testTemporaryDirectory().appendingPathComponent("fastra-transfer-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.txt")
        try Data("one\nnew\nend\n".utf8).write(to: file)
        let original = try FileSnapshot.openRegularFile(at: file)
        close(original.descriptor)
        try await fixture { workspace in
            _ = try await comparison(in: workspace, right: .file(file))
            let preview = try await prepared(in: workspace)
            let validation = try await Task.detached { try preview.validateForApply() }.value
            let changed = Data("one\nBAD\nend\n".utf8)
            if atomic { try changed.write(to: file, options: .atomic) }
            else {
                let handle = try FileHandle(forWritingTo: file)
                try handle.write(contentsOf: changed)
                let times = [original.stat.st_atimespec, original.stat.st_mtimespec]
                try #require(times.withUnsafeBufferPointer { futimens(handle.fileDescriptor, $0.baseAddress) } == 0)
                var actual = stat()
                try #require(fstat(handle.fileDescriptor, &actual) == 0)
                #expect(actual.st_ino == original.stat.st_ino)
                #expect(actual.st_size == original.stat.st_size)
                #expect(actual.st_mtimespec.tv_sec == original.stat.st_mtimespec.tv_sec)
                #expect(actual.st_mtimespec.tv_nsec == original.stat.st_mtimespec.tv_nsec)
                #expect(actual.st_ctimespec.tv_sec != original.stat.st_ctimespec.tv_sec
                    || actual.st_ctimespec.tv_nsec != original.stat.st_ctimespec.tv_nsec)
                try handle.close()
            }
            let expected = workspace.tabs.map { Data($0.content.utf8) }
            #expect(throws: FileDiffTransfer.Failure.stale) { try workspace.applyFileDiffTransfer(validation) }
            #expect(workspace.tabs.map { Data($0.content.utf8) } == expected)
        }
    }

    @Test("Eine schnelle zweite Anfrage oder geschlossener Vergleich verwirft die alte Vorbereitung")
    func pendingRequest() async throws {
        try await fixture { workspace in
            let diff = try await comparison(in: workspace)
            let request = try #require(workspace.activeTab?.fileDiffRequest)
            workspace.prepareFileDiffTransfer(tabID: diff, requestID: request.id, blockID: 0, direction: .toLeft)
            let firstTicket = workspace.activeTab?.fileDiff?.pendingTransferID
            workspace.prepareFileDiffTransfer(tabID: diff, requestID: request.id, blockID: 1, direction: .toLeft)
            #expect(workspace.activeTab?.fileDiff?.pendingTransferID == firstTicket)
            workspace.cancelFileDiffTransfer(tabID: diff, requestID: request.id)
            workspace.prepareFileDiffTransfer(tabID: diff, requestID: request.id, blockID: 0, direction: .toLeft)
            workspace.closeTab(id: diff)
            try await Task.sleep(for: .milliseconds(100))
            #expect(workspace.fileDiffTransferPreview == nil)
            #expect(workspace.tabs[0].content == "one\nleft\nend\n")
            #expect(workspace.fileDiffComputations.activeCount == 0)
        }
    }

    @Test("Eine reine externe Textseite bleibt Ziel einer Übernahme gesperrt")
    func externalSide() async throws {
        try await fixture { workspace in
            let right = try #require(FileDiffSide.document(workspace.tabs[0], in: workspace))
            let diff = try await comparison(in: workspace, left: .text("external", name: "external.txt"), right: right)
            let request = try #require(workspace.activeTab?.fileDiffRequest)
            #expect(!workspace.fileDiffTransferIsAvailable(tabID: diff, requestID: request.id, direction: .toLeft))
            #expect(workspace.fileDiffTransferIsAvailable(tabID: diff, requestID: request.id, direction: .toRight))
        }
    }

    private func comparison(in workspace: Workspace, left: FileDiffSide? = nil, right: FileDiffSide? = nil) async throws -> UUID {
        let left = try #require(left ?? FileDiffSide.document(workspace.tabs[0], in: workspace))
        let right = try #require(right ?? FileDiffSide.document(workspace.tabs[1], in: workspace))
        workspace.openFileDiffTab(request: FileDiffRequest(left: left, right: right, options: FileDiffOptions()))
        let id = try #require(workspace.activeTabID)
        let ready = await waitUntil { workspace.tabs.first { $0.id == id }?.fileDiffDocument?.result != nil }
        try #require(ready)
        return id
    }

    private func prepared(in workspace: Workspace) async throws -> FileDiffTransferPreview {
        let tab = try #require(workspace.activeTab), request = try #require(tab.fileDiffRequest)
        workspace.prepareFileDiffTransfer(tabID: tab.id, requestID: request.id, blockID: 0, direction: .toLeft)
        let ready = await waitUntil { workspace.fileDiffTransferPreview != nil }
        try #require(ready)
        return try #require(workspace.fileDiffTransferPreview)
    }

    private func fixture(_ body: (Workspace) async throws -> Void) async throws {
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra-diff-transfer-\(UUID().uuidString)"))
        workspace.tabs = [EditorTab(title: "left.txt", path: "", content: "one\nleft\nend\n"),
                          EditorTab(title: "right.txt", path: "", content: "one\nright\nend\nextra\n"),
                          EditorTab(title: "other.txt", path: "", content: "untouched")]
        workspace.activeTabID = workspace.tabs[0].id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer {
            workspace.fileDiffComputations.cancelAll()
            workspace.fileDiffTransferPreview = nil
            WorkspaceWindowRegistry.unregister(window)
            window.close()
        }
        try await body(workspace)
    }
}
