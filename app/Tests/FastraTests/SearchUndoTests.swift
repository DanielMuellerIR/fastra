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

    @Test("Unicode-Ersetzungen bleiben in allen Dokumentpfaden bytegenau rückgängig", arguments: ["file-all", "file-one", "open-all", "open-one"])
    func unicodeReplacementUndo(_ mode: String) async throws {
        let workspace = Workspace()
        let original = "vor é nach"
        let replaced = "vor e\u{0301} nach"
        let tab = EditorTab(title: "unicode.txt", path: "", content: original)
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        let host = NSHostingView(rootView: EditorView().environmentObject(workspace))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try #require(await waitUntil { self.editor(in: host)?.string == original })
        workspace.scope = mode.hasPrefix("open") ? .open : .file
        workspace.showSearchDialog = true
        workspace.findPattern = "é"
        workspace.replacePattern = "e\u{0301}"
        workspace.useRegex = false
        try #require(await waitUntil { workspace.canReplaceActiveSearchMatch })
        if mode.hasSuffix("one") {
            workspace.replaceActiveMatch()
        } else if workspace.scope == .open {
            #expect(workspace.applyAllInOpenTabs() == 1)
        } else {
            #expect(workspace.applyAllInActiveBuffer())
        }
        try #require(workspace.activeTab?.content.utf8.elementsEqual(replaced.utf8) == true)
        try #require(await waitUntil { self.editor(in: host)?.string.utf8.elementsEqual(replaced.utf8) == true })
        let current = try #require(editor(in: host))
        try #require(current.undoManager?.canUndo == true)
        current.undoManager?.undo()
        #expect(current.string.utf8.elementsEqual(original.utf8))
        #expect(workspace.activeTab?.content.utf8.elementsEqual(original.utf8) == true)
        #expect(workspace.activeTab?.isDirty == false)
        current.undoManager?.redo()
        #expect(current.string.utf8.elementsEqual(replaced.utf8))
        #expect(workspace.activeTab?.content.utf8.elementsEqual(replaced.utf8) == true)
        #expect(workspace.activeTab?.isDirty == true)
    }

    @Test("Markdown-Speichern unter hält den montierten Editor und seinen Undo-Verlauf verbunden")
    func saveAsRelocatesImagesWithMountedEditor() async throws {
        let root = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/document.md")
        let target = root.appendingPathComponent("target/copy.md")
        for directory in [source.deletingLastPathComponent(), target.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("images"), withIntermediateDirectories: true)
        }
        try Data("image".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("images/a.png"))
        let original = "# Titel\n\n![Bild](images/a.png)\n"
        try Data(original.utf8).write(to: source)
        let workspace = Workspace()
        var tab = EditorTab(title: source.lastPathComponent, path: source.deletingLastPathComponent().path, content: original)
        tab.url = source
        tab.markdownVisualOverride = false
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        let host = NSHostingView(rootView: EditorView().environmentObject(workspace))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try #require(await waitUntil { self.editor(in: host)?.string == original })
        let first = try #require(editor(in: host))
        first.fastraApplyTextOperation(replacing: NSRange(location: 0, length: 0), with: "Vorher\n")
        let beforeSave = "Vorher\n" + original
        var saved: Bool?
        workspace.saveTabAs(id: tab.id, to: target, expectedTargetState: .absent, isMarkdown: true) { saved = $0 }
        try #require(await waitUntil { saved != nil })
        try #require(saved == true)
        let relocated = beforeSave.replacingOccurrences(of: "images/a.png", with: "images/1.png")
        #expect(workspace.activeTab?.content == relocated)
        #expect(try String(contentsOf: target, encoding: .utf8) == relocated)
        try #require(await waitUntil { self.editor(in: host)?.string == relocated })
        let current = try #require(editor(in: host))
        #expect(current.undoManager === first.undoManager)
        current.fastraApplyTextOperation(replacing: NSRange(location: 0, length: 0), with: "Nachher\n")
        #expect(workspace.activeTab?.content == "Nachher\n" + relocated)
        current.undoManager?.undo()
        #expect(current.string == relocated)
        #expect(workspace.activeTab?.content == relocated)
        #expect(workspace.activeTab?.isDirty == false)
        current.undoManager?.redo()
        #expect(current.string == "Nachher\n" + relocated)
        #expect(workspace.activeTab?.content == "Nachher\n" + relocated)
        #expect(workspace.activeTab?.isDirty == true)
    }

    @Test("Unicode-Normalisierung im echten Editor bleibt im Modell und in Undo erhalten")
    func unicodeSourceEdit() async throws {
        let workspace = Workspace()
        let original = "a\u{0301}\u{0323}"
        let changed = "a\u{0323}\u{0301}"
        let tab = EditorTab(title: "unicode.txt", path: "", content: original)
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        let host = NSHostingView(rootView: EditorView().environmentObject(workspace))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try #require(await waitUntil { self.editor(in: host)?.string == original })
        let view = try #require(editor(in: host))
        view.fastraApplyTextOperation(replacing: NSRange(location: 0, length: (original as NSString).length),
                                      with: changed)
        #expect(view.string.utf8.elementsEqual(changed.utf8))
        #expect(workspace.activeTab?.content.utf8.elementsEqual(changed.utf8) == true)
        #expect(workspace.activeTab?.isDirty == true)
        try #require(view.undoManager?.canUndo == true)
        view.undoManager?.undo()
        #expect(view.string.utf8.elementsEqual(original.utf8))
        #expect(workspace.activeTab?.content.utf8.elementsEqual(original.utf8) == true)
        #expect(workspace.activeTab?.isDirty == false)
        view.undoManager?.redo()
        #expect(view.string.utf8.elementsEqual(changed.utf8))
        #expect(workspace.activeTab?.content.utf8.elementsEqual(changed.utf8) == true)
        #expect(workspace.activeTab?.isDirty == true)
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
