import AppKit
import SwiftUI
import Testing
import WebKit
import CodeEditTextView
@testable import Fastra

@Suite(.serialized)
@MainActor
struct SearchUndoTests {
    private func editor(in view: NSView) -> TextView? {
        if let text = view as? TextView { return text }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }

    @Test("Geöffnet-Ersetzen sichert auch noch nie montierte Tabs", arguments: [false, true])
    func openTabs(single: Bool) async throws {
        let workspace = Workspace()
        let first = EditorTab(title: "a.txt", path: "", content: "Alpha erster 😀\n")
        let second = EditorTab(title: "b.txt", path: "", content: "Alpha zweiter\n")
        workspace.tabs = [first, second]
        workspace.activeTabID = first.id
        workspace.scope = .open
        workspace.showSearchDialog = true
        workspace.findPattern = "Alpha"
        workspace.replacePattern = "Beta"
        workspace.useRegex = false
        try #require(await waitUntil { workspace.canApplyAllInOpenTabs })
        if single {
            workspace.activeMatchIndex = 1
            workspace.replaceActiveMatch()
        } else {
            #expect(workspace.applyAllInOpenTabs() == 2)
        }
        for tab in workspace.tabs where tab.isDirty {
            let original = tab.id == first.id ? first.content : second.content
            let view = TextView(string: tab.content)
            view.setUndoManager(tab.undoHistory.manager(for: tab.content))
            try #require(view.undoManager?.canUndo == true)
            view.undoManager?.undo()
            #expect(view.string == original)
            view.undoManager?.redo()
            #expect(view.string == original.replacingOccurrences(of: "Alpha", with: "Beta"))
        }
        #expect(workspace.tabs[1].content == "Beta zweiter\n")
        #expect(workspace.tabs[0].content == (single ? first.content : "Beta erster 😀\n"))
    }

    @Test("Altes Editor-Binding verändert weder neues Dokument noch dessen Verlauf")
    func staleBinding() {
        let workspace = Workspace()
        let first = EditorTab(title: "a.txt", path: "", content: "Alt")
        let second = EditorTab(id: first.id, title: "b.txt", path: "", content: "Neu")
        workspace.tabs = [first]
        workspace.activeTabID = first.id
        let oldBinding = workspace.sourceEditorContent
        workspace.tabs = [second]
        oldBinding.wrappedValue = "Verspätet"
        #expect(workspace.activeTab?.content == "Neu")
        #expect(!second.undoHistory.manager(for: second.content).canUndo)
    }

    @Test("Alter Editor darf eine Ersetzung bis zum Neuaufbau nicht überschreiben")
    func staleEditorAfterReplacement() {
        let workspace = Workspace()
        let tab = EditorTab(title: "a.txt", path: "", content: "Alpha")
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        let oldBinding = workspace.sourceEditorContent
        tab.undoHistory.replace("Alpha", with: "Beta")
        workspace.activeTabContent.wrappedValue = "Beta"
        workspace.editorReloadNonce += 1
        oldBinding.wrappedValue = "Alpha verspätet"
        #expect(workspace.activeTab?.content == "Beta")
        let view = TextView(string: "Beta")
        view.setUndoManager(tab.undoHistory.manager(for: "Beta"))
        view.undoManager?.undo()
        #expect(view.string == "Alpha")
    }

    @Test("Ersetzen bewahrt den getippten Zwischenstand und dessen Undo in Markdown-Split", arguments: [false, true])
    func replacementKeepsEarlierEdits(single: Bool) async throws {
        let workspace = Workspace()
        var tab = EditorTab(title: "undo.md", path: "", content: "# Titel\n\nAlpha Alpha 😀\n")
        tab.url = URL(fileURLWithPath: "/tmp/fastra-search-undo.md")
        tab.markdownVisualOverride = false
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        let host = NSHostingView(rootView: EditorView().environmentObject(workspace))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        #expect(await waitUntil { self.editor(in: host)?.string == tab.content })
        let first = try #require(editor(in: host))
        first.fastraApplyTextOperation(replacing: NSRange(location: 0, length: 0), with: "Vorher\n")
        let intermediate = "Vorher\n" + tab.content
        #expect(workspace.activeTab?.content == intermediate)
        workspace.scope = .file
        workspace.showSearchDialog = true
        workspace.findPattern = "Alpha"
        workspace.replacePattern = "Beta"
        workspace.useRegex = false
        #expect(await waitUntil { workspace.canApplyAllInActiveBuffer })
        if single { workspace.replaceActiveMatch() }
        else { #expect(workspace.applyAllInActiveBuffer()) }
        let replaced = single
            ? intermediate.replacingOccurrences(of: "Alpha Alpha", with: "Beta Alpha")
            : intermediate.replacingOccurrences(of: "Alpha", with: "Beta")
        #expect(await waitUntil { self.editor(in: host)?.string == replaced })
        let current = try #require(editor(in: host))
        try #require(current.undoManager?.canUndo == true)
        current.undoManager?.undo()
        #expect(current.string == intermediate)
        #expect(workspace.activeTab?.content == intermediate)
        current.undoManager?.undo()
        #expect(current.string == tab.content)
        #expect(workspace.activeTab?.isDirty == false)
        current.undoManager?.redo()
        #expect(current.string == intermediate)
        current.undoManager?.redo()
        #expect(current.string == replaced)

        // Jeder Wechsel baut einen anderen echten TextView auf. Beide
        // Richtungen des Verlaufs müssen dennoch beim ursprünglichen Tab bleiben.
        let other = EditorTab(title: "other.txt", path: "", content: "Unverändert")
        workspace.tabs.append(other)
        for _ in 0..<8 {
            workspace.selectTab(id: other.id)
            try #require(await waitUntil { self.editor(in: host)?.string == other.content })
            #expect(editor(in: host)?.undoManager?.canUndo == false)
            workspace.selectTab(id: tab.id)
            try #require(await waitUntil { self.editor(in: host)?.string == replaced })
            let remounted = try #require(editor(in: host))
            try #require(remounted.undoManager?.canUndo == true)
            remounted.undoManager?.undo()
            #expect(remounted.string == intermediate)
            remounted.undoManager?.redo()
            #expect(remounted.string == replaced)
        }
    }
}
