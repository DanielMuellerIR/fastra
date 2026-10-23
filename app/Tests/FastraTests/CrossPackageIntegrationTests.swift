import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Fastra

@Suite("Paketübergreifende Editorabläufe", .serialized)
@MainActor
struct CrossPackageIntegrationTests {
    @Test("4D-Parameterhilfe folgt dem unteren Ausschnitt und verwirft Hilfe beim Pane-Wechsel")
    func splitSignatureHelpFollowsActivePane() async throws {
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra.tests.integration.signature.\(UUID())"))
        let source = String(repeating: "// Line\n", count: 150) + "ALERT(\"Hi\")\n"
        let tab = EditorTab(title: "Caller.4dm", path: "Caller.4dm", content: source)
        workspace.tabs = [tab]; workspace.activeTabID = tab.id; workspace.sourceSplitEnabled = true
        let host = NSHostingView(rootView: EditorView().environmentObject(workspace))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { WorkspaceWindowRegistry.unregister(window); window.close() }
        window.alphaValue = 0; window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000)); window.orderBack(nil)
        try #require(await waitUntil { workspace.sourcePanes.view(for: .secondary, documentID: tab.documentID)?.window === window })
        let first = try #require(workspace.sourcePanes.view(for: .primary, documentID: tab.documentID))
        let second = try #require(workspace.sourcePanes.view(for: .secondary, documentID: tab.documentID))
        let call = (source as NSString).range(of: "ALERT")
        let rect = try #require(second.layoutManager.rectForOffset(call.location))
        _ = second.scrollToVisible(rect)
        try #require(await waitUntil { second.visibleRect.intersects(rect) })
        #expect(!first.visibleRect.intersects(try #require(first.layoutManager.rectForOffset(call.location))))
        #expect(window.makeFirstResponder(second))
        second.selectionManager.setSelectedRange(NSRange(location: call.location + 9, length: 0))
        try #require(await waitUntil { workspace.sourcePanes.activePane == .secondary && workspace.cursorLine == 151 })
        func panels() -> [NSWindow] { (window.childWindows ?? []).filter { $0 is NSPanel && $0.isVisible } }
        try #require(await waitUntil { panels().count == 1 })
        let panel = try #require(panels().first)
        let anchor = window.convertToScreen(second.convert(rect, to: nil))
        #expect(abs(panel.frame.maxY - (anchor.minY - 4)) < 2
            || abs(panel.frame.minY - (anchor.maxY + 4)) < 2)
        #expect(window.makeFirstResponder(first))
        try #require(await waitUntil { workspace.sourcePanes.activePane == .primary && panels().isEmpty })
        // Der Cursor der unteren Pane bleibt gleich: Zurückwechseln muss
        // die Hilfe auch ohne neue Cursorbewegung wieder berechnen.
        #expect(window.makeFirstResponder(second))
        try #require(await waitUntil { panels().count == 1 })
        second.selectionManager.setSelectedRange(NSRange(location: call.location + 8, length: 0))
        #expect(window.makeFirstResponder(first))
        try #require(await waitUntil { panels().isEmpty })
        try await Task.sleep(for: .milliseconds(150))
        #expect(panels().isEmpty)
    }

    @Test("Ein gleichlautender neuer Tab darf keinen noch montierten Editor des alten Dokuments übernehmen", arguments: [false, true])
    func snippetDuringTabTransition(_ reusedSlot: Bool) async throws {
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra.tests.integration.transition.\(UUID())"))
        let source = "same text 😀\r\n"
        workspace.tabs = [EditorTab(title: "first.txt", path: "", content: source),
                          EditorTab(title: "second.txt", path: "", content: source)]
        workspace.activeTabID = workspace.tabs[0].id
        workspace.sourceSplitEnabled = true
        let host = NSHostingView(rootView: EditorView().environmentObject(workspace))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { WorkspaceWindowRegistry.unregister(window); window.close() }
        window.alphaValue = 0; window.orderBack(nil)
        try #require(await waitUntil {
            workspace.sourcePanes.view(for: .primary, documentID: workspace.activeDocumentID)?.window === window
                && workspace.sourcePanes.view(for: .secondary, documentID: workspace.activeDocumentID)?.window === window
        })
        let oldEditor = try #require(CommandTargeting.editorTextView(for: workspace))
        _ = window.makeFirstResponder(oldEditor)
        if reusedSlot {
            workspace.tabs[0] = EditorTab(id: workspace.tabs[0].id, title: "replacement.txt", path: "", content: source)
        } else { workspace.activeTabID = workspace.tabs[1].id }
        // Absichtlich im selben Main-Actor-Durchlauf: SwiftUI hat die alte
        // native View noch nicht gegen das neue Dokument ausgetauscht.
        #expect(CommandTargeting.editorTextView(for: workspace) == nil)
        var captured: Result<TextSnippetInsertionTarget, Error>?
        TextSnippetInsertionTarget.capture(in: workspace) { captured = $0 }
        if case .success(let target) = captured {
            defer { target.release() }
            #expect(!target.isCurrent)
            var inserted = false
            target.insert("WRONG") { if case .success = $0 { inserted = true } }
            #expect(!inserted)
        }
        #expect(workspace.tabs.allSatisfy { $0.content.utf8.elementsEqual(source.utf8) })
        #expect(oldEditor.string.utf8.elementsEqual(source.utf8))
        try #require(await waitUntil {
            guard let editor = CommandTargeting.editorTextView(for: workspace) else { return false }
            return editor !== oldEditor && editor.string.utf8.elementsEqual(source.utf8)
        })
        let current = try #require(CommandTargeting.editorTextView(for: workspace))
        current.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        _ = window.makeFirstResponder(current)
        let target = try await capture(in: workspace)
        defer { target.release() }
        try await insert("NEW", at: target)
        #expect(workspace.activeTab?.content.utf8.elementsEqual(("NEW" + source).utf8) == true)
        #expect(oldEditor.string.utf8.elementsEqual(source.utf8))
        current.undoManager?.undo()
        #expect(await waitUntil { workspace.activeTab?.content.utf8.elementsEqual(source.utf8) == true })
    }

    @Test("Vergleich, geprüfte Übernahme, geteilter Editor und Speichern erhalten BOM und gemischte Zeilenenden")
    func transferSplitAndSave() async throws {
        let root = testTemporaryDirectory().appendingPathComponent("fastra-integration-save-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("mixed.txt")
        let original = "one\r\nold\r\nend\nfooter\rtail 😀\r\n"
        let changed = original.replacingOccurrences(of: "old", with: "new")
        func bytes(_ text: String) -> Data { Data([0xff, 0xfe]) + text.data(using: .utf16LittleEndian)! }
        try bytes(original).write(to: file)
        let loaded = try FileLoader.load(url: file)
        var target = EditorTab(title: file.lastPathComponent, path: root.path, content: loaded.content,
                               encoding: loaded.encoding, bom: loaded.bom, lineEnding: loaded.lineEnding)
        target.url = file; target.diskSnapshot = try FileSnapshot.readSnapshotOnly(from: file)
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra.tests.integration.save.\(UUID())"))
        workspace.tabs = [target, EditorTab(title: "source.txt", path: "", content: changed)]
        workspace.activeTabID = target.id; workspace.sourceSplitEnabled = true
        let host = NSHostingView(rootView: EditorView().environmentObject(workspace))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { workspace.fileDiffComputations.cancelAll(); WorkspaceWindowRegistry.unregister(window); window.close() }
        window.alphaValue = 0; window.orderBack(nil)
        let left = try #require(FileDiffSide.document(workspace.tabs[0], in: workspace))
        let right = try #require(FileDiffSide.document(workspace.tabs[1], in: workspace))
        workspace.openFileDiffTab(request: FileDiffRequest(left: left, right: right, options: FileDiffOptions()))
        try #require(await waitUntil { workspace.activeTab?.fileDiffDocument?.result?.blocks.count == 1 })
        let comparison = try #require(workspace.activeTab), request = try #require(comparison.fileDiffRequest)
        workspace.prepareFileDiffTransfer(tabID: comparison.id, requestID: request.id, blockID: 0, direction: .toLeft)
        try #require(await waitUntil { workspace.fileDiffTransferPreview != nil })
        let preview = try #require(workspace.fileDiffTransferPreview)
        let validation = try await Task.detached { try preview.validateForApply() }.value
        #expect(try Data(contentsOf: file) == bytes(original))
        try workspace.applyFileDiffTransfer(validation)
        #expect(workspace.tabs.first { $0.id == target.id }?.content.utf8.elementsEqual(changed.utf8) == true)
        #expect(try Data(contentsOf: file) == bytes(original))
        workspace.activeTabID = target.id
        try #require(await waitUntil {
            workspace.sourcePanes.view(for: .secondary, documentID: target.documentID)?.string.utf8.elementsEqual(changed.utf8) == true
        })
        let first = try #require(workspace.sourcePanes.view(for: .primary, documentID: target.documentID))
        let second = try #require(workspace.sourcePanes.view(for: .secondary, documentID: target.documentID))
        #expect(first.textStorage === second.textStorage)
        _ = window.makeFirstResponder(second)
        second.undoManager?.undo()
        try #require(await waitUntil { workspace.activeTab?.content.utf8.elementsEqual(original.utf8) == true })
        #expect(first.string.utf8.elementsEqual(original.utf8))
        second.undoManager?.redo()
        try #require(await waitUntil { workspace.activeTab?.content.utf8.elementsEqual(changed.utf8) == true })
        let savedTab = try #require(workspace.activeTab)
        try #require(workspace.write(tab: savedTab, to: file))
        #expect(try Data(contentsOf: file) == bytes(changed))
        #expect(workspace.activeTab?.content.utf8.elementsEqual(changed.utf8) == true)
    }

    @Test("Baustein im zweiten Ausschnitt entwertet eine alte Trefferfreigabe; neue Vorschau und Rücknahme bleiben exakt")
    func splitSnippetAndApproval() async throws {
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra.tests.integration.approval.\(UUID())"))
        let source = "foo\r\nkeep 😀\nfoo\rtail\r\n"
        let tab = EditorTab(title: "mixed.txt", path: "", content: source)
        workspace.tabs = [tab]; workspace.activeTabID = tab.id; workspace.sourceSplitEnabled = true
        let host = NSHostingView(rootView: EditorView().environmentObject(workspace))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { workspace.showSearchDialog = false; WorkspaceWindowRegistry.unregister(window); window.close() }
        window.alphaValue = 0; window.orderBack(nil)
        try #require(await waitUntil { workspace.sourcePanes.view(for: .secondary, documentID: tab.documentID)?.window === window })
        let second = try #require(workspace.sourcePanes.view(for: .secondary, documentID: tab.documentID))
        second.selectionManager.setSelectedRange((source as NSString).range(of: "keep"))
        _ = window.makeFirstResponder(second)
        workspace.scope = .file; workspace.useRegex = false
        workspace.findPattern = "foo"; workspace.replacePattern = "bar"; workspace.showSearchDialog = true
        try #require(await waitUntil { workspace.searchApproval.isComplete && workspace.navMatches.count == 2 })
        try #require(workspace.setSearchMatchesApproved(true, ids: [workspace.navMatches[0].id], generation: workspace.searchApproval.generation))
        let stale = try SearchApprovalPreview.build(SearchApprovalPreview.Request.capture(in: workspace))
        let insertion = try await capture(in: workspace)
        defer { insertion.release() }
        let replacement = try TextSnippetTemplate("{{Name}} / {{Name}}").render(values: ["Name": "é\nNEU"])
        let changed = (source as NSString).replacingCharacters(in: (source as NSString).range(of: "keep"), with: replacement)
        try await insert(replacement, at: insertion)
        #expect(workspace.activeTab?.content.utf8.elementsEqual(changed.utf8) == true)
        #expect(!stale.request.isCurrent(in: workspace))
        #expect(throws: SearchApprovalPreview.Failure.self) { try workspace.applySearchApproval(stale) }
        #expect(workspace.searchApproval.approvedIDs.isEmpty)
        try #require(await waitUntil { workspace.searchApproval.isComplete && workspace.navMatches.count == 2 })
        try #require(workspace.setSearchMatchesApproved(true, ids: [workspace.navMatches[0].id], generation: workspace.searchApproval.generation))
        let fresh = try SearchApprovalPreview.build(SearchApprovalPreview.Request.capture(in: workspace))
        let expected = (changed as NSString).replacingCharacters(in: NSRange(location: 0, length: 3), with: "bar")
        #expect(fresh.changedCount == 1)
        #expect(workspace.activeTab?.content.utf8.elementsEqual(changed.utf8) == true)
        let applied = try workspace.applySearchApproval(fresh)
        try #require(applied)
        #expect(workspace.activeTab?.content.utf8.elementsEqual(expected.utf8) == true)
        try #require(await waitUntil { CommandTargeting.editorTextView(for: workspace)?.string.utf8.elementsEqual(expected.utf8) == true })
        try workspace.restoreSearchApprovalMemory()
        #expect(workspace.activeTab?.content.utf8.elementsEqual(changed.utf8) == true)
        try #require(await waitUntil { CommandTargeting.editorTextView(for: workspace)?.string.utf8.elementsEqual(changed.utf8) == true })
        try workspace.restoreSearchApprovalMemory()
        #expect(workspace.activeTab?.content.utf8.elementsEqual(expected.utf8) == true)
    }

    private func capture(in workspace: Workspace) async throws -> TextSnippetInsertionTarget {
        try await withCheckedThrowingContinuation { done in
            TextSnippetInsertionTarget.capture(in: workspace) { done.resume(with: $0) }
        }
    }

    private func insert(_ text: String, at target: TextSnippetInsertionTarget) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            target.insert(text) { done.resume(with: $0) }
        }
    }
}
