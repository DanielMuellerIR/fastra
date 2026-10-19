import AppKit
import Foundation
import Testing
@testable import Fastra

@Suite("Fensterziel der Trefferfreigabe")
@MainActor
struct SearchApprovalWorkspaceTests {
    @Test("Ein verschwundener Zieltab darf nicht durch das aktive Dokument ersetzt werden")
    func missingTarget() {
        let defaults = testSuiteDefaults(named: "fastra-approvals-\(UUID().uuidString)")
        let workspace = Workspace(defaults: defaults)
        let tab = EditorTab(title: "active.txt", path: "", content: "foo")
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        workspace.scope = .open
        let match = BufferSearch.Match(range: NSRange(location: 0, length: 3),
            line: 1, column: 1, matchText: "foo", replacedText: "bar")
        let gone = Workspace.NavMatch(id: match.id, url: nil, tabID: UUID(), match: match)
        #expect(!workspace.searchMatchIsEditable(gone))
        let missing = Workspace.NavMatch(id: match.id, url: nil, match: match)
        #expect(!workspace.searchMatchIsEditable(missing))
        let valid = Workspace.NavMatch(id: match.id, url: nil, tabID: tab.id, match: match)
        #expect(workspace.searchMatchIsEditable(valid))
    }

    @Test("Eine ausdrücklich erfasste Teilmenge ändert und restauriert nur ihre eigenen Dokumente")
    func memorySubset() throws {
        try fixture { workspace in
            let first = workspace.tabs[0].id, second = workspace.tabs[1].id
            let all = try TextWorkflowOpenDocumentsPlan.Source.capture(in: workspace)
            let selected = try TextWorkflowOpenDocumentsPlan.Source.capture(in: workspace, tabIDs: [first])
            workspace.tabs[1].content = "unrelated change"
            #expect(!all.isCurrent(in: workspace))
            #expect(selected.isCurrent(in: workspace))
            let change = try TextWorkflowOpenDocumentsPlan.applyReplacements([first: "NEW"], source: selected, in: workspace)
            #expect(workspace.tabs.first { $0.id == first }?.content == "NEW")
            #expect(workspace.tabs.first { $0.id == second }?.content == "unrelated change")
            _ = try change.restore(in: workspace)
            #expect(workspace.tabs.first { $0.id == first }?.content == "one")
            #expect(workspace.tabs.first { $0.id == second }?.content == "unrelated change")
        }
    }

    @Test("Wiederverwendete Zielslots und fremde Ersetzungsziele werden vor jeder Speicheränderung abgewiesen")
    func staleMemoryTarget() throws {
        try fixture { workspace in
            let first = workspace.tabs[0].id
            let selected = try TextWorkflowOpenDocumentsPlan.Source.capture(in: workspace, tabIDs: [first])
            #expect(throws: (any Error).self) {
                try TextWorkflowOpenDocumentsPlan.applyReplacements([first: "NEW", UUID(): "foreign"], source: selected, in: workspace)
            }
            #expect(workspace.tabs[0].content == "one")
            workspace.tabs[0].documentID = UUID()
            #expect(!selected.isCurrent(in: workspace))
            #expect(throws: (any Error).self) {
                try TextWorkflowOpenDocumentsPlan.applyReplacements([first: "NEW"], source: selected, in: workspace)
            }
            #expect(workspace.tabs[0].content == "one")
        }
    }

    private func fixture(_ body: (Workspace) throws -> Void) throws {
        let defaults = testSuiteDefaults(named: "fastra-approval-memory-\(UUID().uuidString)")
        let workspace = Workspace(defaults: defaults)
        workspace.tabs = [EditorTab(title: "one.txt", path: "", content: "one"),
                          EditorTab(title: "two.txt", path: "", content: "two")]
        workspace.activeTabID = workspace.tabs[0].id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { WorkspaceWindowRegistry.unregister(window); window.close() }
        try body(workspace)
    }

    @Test("Die volle Teilfreigabevorschau ändert nur freigegebene Treffer und unterstützt gemeinsame Rücknahme")
    func selectedPreview() async throws {
        try await previewFixture { workspace in
            let before = workspace.tabs.map(\.content)
            let matches = workspace.navMatches
            try #require(matches.count == 4)
            #expect(workspace.searchApproval.approvedIDs.isEmpty)
            #expect(workspace.setSearchMatchesApproved(true, ids: [matches[1].id, matches[2].id], generation: workspace.searchApproval.generation))
            let request = try SearchApprovalPreview.Request.capture(in: workspace)
            let preview = try SearchApprovalPreview.build(request)
            #expect(preview.entries.count == 2)
            #expect(preview.changedCount == 2)
            #expect(preview.entries.allSatisfy { $0.document.result != nil && $0.document.limitation == nil })
            #expect(workspace.tabs.map(\.content) == before)
            #expect(try workspace.applySearchApproval(preview))
            #expect(workspace.tabs[0].content == "foo\r\n🙂 bar\n")
            #expect(workspace.tabs[1].content == "bar\rfoo")
            #expect(workspace.tabs.allSatisfy { $0.isDirty })
            #expect(!request.isCurrent(in: workspace))
            try workspace.restoreSearchApprovalMemory()
            #expect(workspace.tabs.map(\.content) == before)
            try workspace.restoreSearchApprovalMemory()
            #expect(workspace.tabs[1].content == "bar\rfoo")
        }
    }

    @Test("Optionen, Dokumentzustände und Revisionen entwerten ein Vorschauticket", arguments: [0, 1, 2, 3, 4])
    func previewStaleness(_ kind: Int) async throws {
        try await previewFixture { workspace in
            let match = try #require(workspace.navMatches.first)
            #expect(workspace.setSearchMatchesApproved(true, ids: [match.id], generation: workspace.searchApproval.generation))
            let request = try SearchApprovalPreview.Request.capture(in: workspace)
            let preview = try SearchApprovalPreview.build(request)
            switch kind {
            case 0: workspace.replacePattern = "other"
            case 1: workspace.tabs[1].content = "external edit"
            case 2: workspace.tabs[0].documentID = UUID()
            case 3: workspace.tabs[0].readOnlyReason = "protected"
            default:
                let unchanged = workspace.tabs[0].content
                workspace.tabs[0].content = unchanged
            }
            let before = workspace.tabs.map(\.content)
            #expect(!request.isCurrent(in: workspace))
            #expect(throws: (any Error).self) { try workspace.applySearchApproval(preview) }
            #expect(workspace.tabs.map(\.content) == before)
            if kind >= 3 {
                #expect(workspace.searchApproval.approvedIDs.isEmpty)
                #expect(throws: (any Error).self) { try SearchApprovalPreview.Request.capture(in: workspace) }
            }
        }
    }

    @Test("Die Rücknahme einer Teilfreigabe lässt spätere Änderungen unbeteiligter Dokumente bestehen")
    func undoIgnoresUnchangedDocument() async throws {
        try await previewFixture { workspace in
            let match = try #require(workspace.navMatches.first)
            let approved = workspace.setSearchMatchesApproved(true, ids: [match.id], generation: workspace.searchApproval.generation)
            try #require(approved)
            let preview = try SearchApprovalPreview.build(SearchApprovalPreview.Request.capture(in: workspace))
            let applied = try workspace.applySearchApproval(preview)
            try #require(applied)
            workspace.tabs[1].content = "independent edit"
            try workspace.restoreSearchApprovalMemory()
            #expect(workspace.tabs[0].content == "foo\r\n🙂 foo\n")
            #expect(workspace.tabs[1].content == "independent edit")
        }
    }

    @Test("Eine vollständige Teilfreigabe über vier MiB kann den bestehenden Speicher- und Undo-Weg verwenden")
    func largerMemoryPreview() async throws {
        try await previewFixture { workspace in
            let before = "foo\n" + String(repeating: "a", count: 4 * 1024 * 1024)
            workspace.tabs[0].content = before
            workspace.scope = .file
            let ready = await waitUntil { workspace.searchApproval.isComplete && workspace.navMatches.count == 1 }
            try #require(ready)
            let approved = workspace.setAllSearchMatchesApproved(true, generation: workspace.searchApproval.generation)
            try #require(approved)
            let preview = try SearchApprovalPreview.build(SearchApprovalPreview.Request.capture(in: workspace))
            let applied = try workspace.applySearchApproval(preview)
            try #require(applied)
            #expect(workspace.tabs[0].content.prefix(4) == "bar\n")
            #expect(workspace.tabs[0].content.utf8.count == before.utf8.count)
            try workspace.restoreSearchApprovalMemory()
            let restored = workspace.tabs[0].content.utf8.elementsEqual(before.utf8)
            #expect(restored)
        }
    }

    @Test("Ein vollständig gesuchter Treffer mit zu großem Diff liefert eine erklärte Grenze statt einer Apply-Basis")
    func diffTooDifferent() async throws {
        try await previewFixture { workspace in
            workspace.scope = .file
            workspace.replacePattern = (0...FileDiff.maximumDiffInputLines).map { "replacement \($0)\n" }.joined()
            let ready = await waitUntil { workspace.searchApproval.isComplete }
            try #require(ready)
            let id = try #require(workspace.navMatches.first?.id)
            let approved = workspace.setSearchMatchesApproved(true, ids: [id], generation: workspace.searchApproval.generation)
            try #require(approved)
            let request = try SearchApprovalPreview.Request.capture(in: workspace)
            do {
                _ = try SearchApprovalPreview.build(request)
                Issue.record("Ein begrenzter Diff darf keine vollständige Vorschau liefern")
            } catch SearchApprovalPreview.Failure.tooDifferent(let limit) {
                #expect(limit == FileDiff.maximumDiffInputLines)
            }
            #expect(workspace.tabs[0].content == "foo\r\n🙂 foo\n")
        }
    }

    @Test("Budgetgrenzen und Abbruch liefern keine teilweise anwendbare Freigabevorschau", arguments: [0, 1, 2, 3, 4, 5, 6])
    func previewLimits(_ kind: Int) async throws {
        try await previewFixture { workspace in
            #expect(workspace.setAllSearchMatchesApproved(true, generation: workspace.searchApproval.generation))
            let request = try SearchApprovalPreview.Request.capture(in: workspace)
            var limits = SearchApprovalPreview.Limits.standard
            switch kind {
            case 0: limits.files = 1
            case 1: limits.originalBytes = 1
            case 2: limits.outputBytes = 1
            case 3: limits.previewBytes = 1
            case 4: limits.rows = 0
            case 5: limits.seconds = -1
            default: break
            }
            #expect(throws: (any Error).self) {
                try SearchApprovalPreview.build(request, limits: limits, shouldCancel: { kind == 6 })
            }
            #expect(workspace.tabs[0].content == "foo\r\n🙂 foo\n")
        }
    }

    @Test("Fehlerhafte, gekappte und schreibgeschützte Treffer geben kein Vorschauticket frei", arguments: [0, 1, 2])
    func unavailablePreview(_ kind: Int) async throws {
        try await previewFixture { workspace in
            if kind == 0 { workspace.openResultsWereCapped = true }
            if kind == 1 { workspace.searchError = "failure" }
            if kind == 2 {
                let id = try #require(workspace.navMatches.first?.id)
                workspace.tabs[0].readOnlyReason = "protected"
                #expect(!workspace.setSearchMatchesApproved(true, ids: [id], generation: workspace.searchApproval.generation))
            } else { workspace.publishSearchApprovals() }
            #expect(throws: (any Error).self) { try SearchApprovalPreview.Request.capture(in: workspace) }
        }
    }

    private func previewFixture(_ body: (Workspace) async throws -> Void) async throws {
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra-approval-preview-\(UUID().uuidString)"))
        workspace.tabs = [EditorTab(title: "one.txt", path: "", content: "foo\r\n🙂 foo\n"),
                          EditorTab(title: "two.txt", path: "", content: "foo\rfoo")]
        workspace.activeTabID = workspace.tabs[0].id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { WorkspaceWindowRegistry.unregister(window); window.close(); workspace.showSearchDialog = false }
        workspace.scope = .open; workspace.useRegex = false
        workspace.findPattern = "foo"; workspace.replacePattern = "bar"
        workspace.showSearchDialog = true
        let ready = await waitUntil { workspace.searchApproval.isComplete && workspace.navMatches.count == 4 }
        try #require(ready)
        try await body(workspace)
    }
}
