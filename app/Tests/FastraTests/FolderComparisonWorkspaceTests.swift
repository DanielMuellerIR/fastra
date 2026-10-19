import AppKit
import Foundation
import Testing
@testable import Fastra

@Suite("Fensterzustand des Ordnervergleichs")
@MainActor
struct FolderComparisonWorkspaceTests {
    @Test("Ordnerergebnisse bleiben beim Dateiöffnen erhalten und sind keine Markdown-Dokumente")
    func folderTabIsNotScratch() {
        let request = FolderComparisonRequest(left: URL(fileURLWithPath: "/tmp/left.md"),
            right: URL(fileURLWithPath: "/tmp/right.md"), options: .init())
        var tab = EditorTab(title: "Ordner: left.md ↔ right.md", path: "Ordnervergleich",
            readOnlyReason: "Ordnervergleiche sind schreibgeschützt.")
        tab.folderComparison = FolderComparisonTabState(request: request)
        #expect(!tab.isPristineScratch)
        #expect(!WelcomeLogic.shouldShow(activeTab: tab))
        let opened = EditorTab(title: "opened.txt", path: "", content: "opened file")
        #expect(Workspace.tabsRemovingEmptyScratch([tab, opened], keeping: opened.id).contains { $0.id == tab.id })
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra-folder-role-\(UUID().uuidString)"))
        workspace.tabs = [tab]; workspace.activeTabID = tab.id
        #expect(!workspace.activeTabIsMarkdown)
        tab.readOnlyReason = nil
        #expect(!tab.isOrdinaryTextDocument)
    }

    @Test("Der Ergebnistab ist schreibgeschützt und Dateipaare verwenden den vorhandenen Diff")
    func openPair() async throws {
        try await fixture { workspace, left, right in
            let original = workspace.tabs[0]
            workspace.openFolderComparison(request: .init(left: left, right: right, options: .init()))
            let id = try #require(workspace.activeTabID)
            #expect(await waitUntil { workspace.activeTab?.folderComparison?.result != nil })
            let tab = try #require(workspace.activeTab)
            let state = try #require(tab.folderComparison)
            #expect(!tab.hasUnsavedChanges && tab.url == nil)
            #expect(!tab.isEditableTextDocument && !tab.isEligibleForFileComparison)
            #expect(!workspace.textEditingIsAllowed(for: tab))
            #expect(workspace.fileDiffComputations.activeCount == 0)
            let row = try #require(state.result?.rows.first { $0.path == "a.txt" })
            #expect(row.status == .different && row.canOpenPair)
            workspace.openFolderComparisonPair(tabID: id, requestID: state.request.id, rowID: row.id)
            #expect(await waitUntil { workspace.activeTab?.fileDiffDocument?.result != nil })
            let request = try #require(workspace.activeTab?.fileDiffRequest)
            #expect(request.left.documentOrigin == nil && request.right.documentOrigin == nil)
            #expect(workspace.tabs.first { $0.id == original.id }?.content == original.content)
            #expect(workspace.tabs.first { $0.id == original.id }?.hasUnsavedChanges == original.hasUnsavedChanges)
            #expect(try Data(contentsOf: left.appendingPathComponent("a.txt")) == Data("left\n".utf8))
            #expect(try Data(contentsOf: right.appendingPathComponent("a.txt")) == Data("right\n".utf8))
        }
    }

    @Test("Abbruch, erneuter Start und Schließen entwerten verspätete Rückmeldungen")
    func cancelAndClose() async throws {
        try await fixture { workspace, left, right in
            workspace.openFolderComparison(request: .init(left: left, right: right, options: .init()))
            let id = try #require(workspace.activeTabID)
            workspace.cancelFolderComparison(tabID: id)
            #expect(workspace.fileDiffComputations.activeCount == 0)
            #expect(workspace.activeTab?.folderComparison?.cancelled == true)
            #expect(workspace.activeTab?.folderComparison?.result == nil)
            let requestID = try #require(workspace.activeTab?.folderComparison?.request.id)
            workspace.refreshFolderComparison(tabID: id)
            #expect(workspace.activeTab?.folderComparison?.request.id != requestID)
            workspace.closeTab(id: id)
            #expect(workspace.fileDiffComputations.activeCount == 0)
            #expect(!workspace.tabs.contains { $0.id == id })
            let settled = await waitUntil { workspace.tabs.count == 1 }
            #expect(settled)
            #expect(workspace.tabs[0].content == "unsaved document")
        }
    }

    @Test("Veraltete Ergebnis-IDs öffnen keine Dateipaare und erneute Prüfung zeigt Fremdänderungen")
    func refresh() async throws {
        try await fixture { workspace, left, right in
            workspace.openFolderComparison(request: .init(left: left, right: right, options: .init()))
            let id = try #require(workspace.activeTabID)
            #expect(await waitUntil { workspace.activeTab?.folderComparison?.result != nil })
            let old = try #require(workspace.activeTab?.folderComparison)
            let row = try #require(old.result?.rows.first { $0.path == "a.txt" })
            try Data("left\n".utf8).write(to: right.appendingPathComponent("a.txt"), options: .atomic)
            workspace.refreshFolderComparison(tabID: id)
            workspace.openFolderComparisonPair(tabID: id, requestID: old.request.id, rowID: row.id)
            #expect(workspace.activeTabID == id && workspace.tabs.count == 2)
            #expect(await waitUntil { workspace.activeTab?.folderComparison?.result != nil })
            #expect(workspace.activeTab?.folderComparison?.result?.rows.first?.status == .identical)
            #expect(workspace.activeTab?.folderComparison?.result?.isComplete == true)
        }
    }

    @Test("Byteunterschiede durch BOM und Zeilenenden bleiben beim Öffnen des Textvergleichs unverändert")
    func byteAndTextComparison() async throws {
        try await fixture { workspace, left, right in
            var leftBytes = Data([0xEF, 0xBB, 0xBF]); leftBytes.append(Data("same\r\n".utf8))
            let rightBytes = Data("same\n".utf8)
            try leftBytes.write(to: left.appendingPathComponent("a.txt"))
            try rightBytes.write(to: right.appendingPathComponent("a.txt"))
            workspace.openFolderComparison(request: .init(left: left, right: right, options: .init()))
            #expect(await waitUntil { workspace.activeTab?.folderComparison?.result != nil })
            let tab = try #require(workspace.activeTab), state = try #require(tab.folderComparison)
            let row = try #require(state.result?.rows.first { $0.path == "a.txt" })
            #expect(row.status == .different && state.result?.budgetBytes == 14)
            workspace.openFolderComparisonPair(tabID: tab.id, requestID: state.request.id, rowID: row.id)
            #expect(await waitUntil { workspace.activeTab?.fileDiffDocument?.result != nil })
            #expect(workspace.activeTab?.fileDiffDocument?.result?.isIdentical == true)
            #expect(try Data(contentsOf: left.appendingPathComponent("a.txt")) == leftBytes)
            #expect(try Data(contentsOf: right.appendingPathComponent("a.txt")) == rightBytes)
        }
    }

    private func fixture(_ body: (Workspace, URL, URL) async throws -> Void) async throws {
        let root = testTemporaryDirectory().appendingPathComponent("fastra-folder-workspace-\(UUID().uuidString)")
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
        for url in [left, right] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("left\n".utf8).write(to: left.appendingPathComponent("a.txt"))
        try Data("right\n".utf8).write(to: right.appendingPathComponent("a.txt"))
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra-folder-workspace-\(UUID().uuidString)"))
        workspace.tabs = [EditorTab(title: "draft.txt", path: "", content: "unsaved document", isDirty: true)]
        workspace.activeTabID = workspace.tabs[0].id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer {
            workspace.fileDiffComputations.cancelAll()
            WorkspaceWindowRegistry.unregister(window)
            window.close()
        }
        try await body(workspace, left, right)
    }
}
