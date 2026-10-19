import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Fastra

@Suite("Textabläufe über offene Dokumente: gemeinsame Speicherbasis")
struct TextWorkflowOpenDocumentsPlanTests {
    private let uppercase = TextWorkflow(name: "Großschreibung", steps: [TextWorkflowStep(kind: .uppercase)])

    @MainActor private func fixture(_ body: (Workspace) throws -> Void) throws {
        let domain = "fastra-test-workflow-open-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let workspace = Workspace(defaults: defaults)
        workspace.tabs = [EditorTab(title: "one.txt", path: "", content: "one"),
                          EditorTab(title: "two.txt", path: "", content: "TWO")]
        workspace.activeTabID = workspace.tabs[0].id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { WorkspaceWindowRegistry.unregister(window); window.close() }
        try body(workspace)
    }

    @Test("Apply und gemeinsame Rücknahme ändern nur Speicher und veröffentlichen vollständige Zustände")
    @MainActor func applyAndRestore() throws {
        try fixture { workspace in
            let root = testTemporaryDirectory().appendingPathComponent("workflow-open-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            for index in workspace.tabs.indices {
                let url = root.appendingPathComponent("\(index).txt")
                try Data(workspace.tabs[index].content.utf8).write(to: url)
                workspace.tabs[index].url = url
                workspace.tabs[index].recordSavedContentBaseline()
            }
            let source = try TextWorkflowOpenDocumentsPlan.Source.capture(in: workspace)
            let plan = try TextWorkflowOpenDocumentsPlan.build(uppercase, source: source)
            #expect(plan.changedDocumentCount == 1)
            var observed: [[String]] = []
            let subscription = workspace.$tabs.dropFirst().sink { observed.append($0.map(\.content)) }
            defer { subscription.cancel() }
            let applied = try plan.apply(in: workspace)
            #expect(workspace.tabs.map(\.content) == ["ONE", "TWO"])
            #expect(workspace.tabs[0].isDirty && !workspace.tabs[1].isDirty)
            #expect(observed.allSatisfy { $0 == ["ONE", "TWO"] })
            for (index, tab) in workspace.tabs.enumerated() {
                #expect(try Data(contentsOf: #require(tab.url)) == Data(source.inputs[index].source.utf8))
            }
            let inverse = try applied.restore(in: workspace)
            #expect(workspace.tabs.map(\.content) == ["one", "TWO"])
            #expect(!workspace.tabs[0].isDirty)
            _ = try inverse.restore(in: workspace)
            #expect(workspace.tabs.map(\.content) == ["ONE", "TWO"])
        }
    }

    @Test("Fremde oder wiederverwendete Dokumente entwerten den ganzen Auftrag", arguments: [0, 1, 2, 3, 4, 5])
    @MainActor func staleInputs(_ kind: Int) throws {
        try fixture { workspace in
            let source = try TextWorkflowOpenDocumentsPlan.Source.capture(in: workspace)
            let plan = try TextWorkflowOpenDocumentsPlan.build(uppercase, source: source)
            switch kind {
            case 0: workspace.tabs[1].content = "external"
            case 1: workspace.tabs[1].documentID = UUID()
            case 2: workspace.tabs.removeLast()
            case 3: workspace.tabs[1].readOnlyReason = "Test"
            case 4: workspace.tabs.append(EditorTab(title: "three.txt", path: "", content: "three"))
            default: workspace.tabs[1].url = URL(fileURLWithPath: "/tmp/reused-" + UUID().uuidString)
            }
            let before = workspace.tabs.map(\.content)
            #expect(throws: TextWorkflowOpenDocumentsPlan.Failure.stale) { try plan.apply(in: workspace) }
            #expect(workspace.tabs.map(\.content) == before)
        }
    }

    @Test("Tabs dürfen sich umordnen; ein anderes Fenster bleibt unabhängig")
    @MainActor func windowBinding() throws {
        try fixture { workspace in
            let source = try TextWorkflowOpenDocumentsPlan.Source.capture(in: workspace)
            let plan = try TextWorkflowOpenDocumentsPlan.build(uppercase, source: source)
            workspace.tabs.reverse()
            workspace.activeTabID = workspace.tabs[0].id
            try fixture { other in
                #expect(throws: TextWorkflowOpenDocumentsPlan.Failure.stale) { try plan.apply(in: other) }
                #expect(other.tabs.map(\.content) == ["one", "TWO"])
            }
            _ = try plan.apply(in: workspace)
            #expect(workspace.tabs.map(\.content) == ["TWO", "ONE"])
        }
    }

    @Test("Eine Änderung nach Apply verhindert die gemeinsame Rücknahme ohne Teiländerung")
    @MainActor func protectedRestore() throws {
        try fixture { workspace in
            workspace.tabs[1].content = "two"
            let source = try TextWorkflowOpenDocumentsPlan.Source.capture(in: workspace)
            let plan = try TextWorkflowOpenDocumentsPlan.build(uppercase, source: source)
            let applied = try plan.apply(in: workspace)
            workspace.tabs[1].content = "extern"
            #expect(throws: TextWorkflowOpenDocumentsPlan.Failure.stale) { try applied.restore(in: workspace) }
            #expect(workspace.tabs.map(\.content) == ["ONE", "extern"])
        }
    }

    @Test("Read-only-Dokumente bleiben erhalten und werden nicht als editierbare Eingabe übernommen")
    @MainActor func readOnlyAndNoChanges() throws {
        try fixture { workspace in
            workspace.tabs[0].readOnlyReason = "Test"
            let source = try TextWorkflowOpenDocumentsPlan.Source.capture(in: workspace)
            #expect(source.inputs.map(\.tabID) == [workspace.tabs[1].id])
            let plan = try TextWorkflowOpenDocumentsPlan.build(uppercase, source: source)
            #expect(throws: TextWorkflowOpenDocumentsPlan.Failure.noChanges) { try plan.apply(in: workspace) }
            #expect(workspace.tabs.map(\.content) == ["one", "TWO"])
        }
    }

    @Test("Gesamtvorschaugrenze, Abbruch und Zeitablauf liefern keine teilbare Schreibbasis", arguments: [0, 1, 2])
    @MainActor func limits(_ kind: Int) throws {
        try fixture { workspace in
            let source = try TextWorkflowOpenDocumentsPlan.Source.capture(in: workspace)
            var limits = TextWorkflowFilePlan.Limits.standard
            if kind == 0 { limits.previewBytes = 29 }
            if kind == 2 { limits.seconds = -1 }
            #expect(throws: TextWorkflowOpenDocumentsPlan.Failure.self) {
                try TextWorkflowOpenDocumentsPlan.build(uppercase, source: source, limits: limits, shouldCancel: { kind == 1 })
            }
            #expect(workspace.tabs.map(\.content) == ["one", "TWO"])
        }
    }

    @Test("Ein später sichtbar gewordener Tab behält natives Undo und Redo nach der Speichertransaktion")
    @MainActor func nativeHistoryAfterTabSwitch() async throws {
        let domain = "fastra-test-workflow-open-history-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let workspace = Workspace(defaults: defaults)
        workspace.tabs = [EditorTab(title: "one.txt", path: "", content: "one"),
                          EditorTab(title: "two.txt", path: "", content: "two")]
        workspace.activeTabID = workspace.tabs[0].id
        let host = NSHostingView(rootView: EditorView().environmentObject(workspace))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { WorkspaceWindowRegistry.unregister(window); window.close() }
        window.alphaValue = 0; window.orderBack(nil)
        try #require(await waitUntil { CommandTargeting.editorTextView(for: workspace)?.string == "one" })
        let source = try TextWorkflowOpenDocumentsPlan.Source.capture(in: workspace)
        let plan = try TextWorkflowOpenDocumentsPlan.build(uppercase, source: source)
        let applied = try plan.apply(in: workspace)
        workspace.activeTabID = workspace.tabs[1].id
        try #require(await waitUntil { CommandTargeting.editorTextView(for: workspace)?.string == "TWO" })
        let editor = try #require(CommandTargeting.editorTextView(for: workspace))
        let history = try #require(editor.undoManager)
        try #require(history.canUndo)
        history.undo()
        try #require(await waitUntil { workspace.activeTab?.content == "two" && history.canRedo })
        #expect(editor.string == "two" && workspace.tabs[0].content == "ONE")
        #expect(throws: TextWorkflowOpenDocumentsPlan.Failure.stale) { try applied.restore(in: workspace) }
        history.redo()
        try #require(await waitUntil { workspace.activeTab?.content == "TWO" && history.canUndo })
        #expect(editor.string == "TWO" && workspace.tabs[0].content == "ONE")
    }
}
