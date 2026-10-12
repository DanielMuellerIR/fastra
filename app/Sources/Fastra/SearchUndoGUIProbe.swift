import AppKit
import CodeEditTextView
import WebKit

@MainActor
enum SearchUndoGUIProbe {
    private struct Failure: Error { let message: String }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    private static func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while !condition() {
            try require(Date() < end, "Editorzustand nicht rechtzeitig erreicht")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    private static func undoOrRedo(window: NSWindow, root: NSView, redo: Bool = false) async throws {
        guard let textView = find(TextView.self, in: root) else {
            throw Failure(message: "Editor fehlt")
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        try require(redo ? textView.undoManager?.canRedo == true : textView.undoManager?.canUndo == true,
                    "Dokument ist geändert, aber Rückgängig/Wiederholen ist gesperrt")
        let before = textView.string
        if redo {
            // Derselbe Responderpfad wie im Mehrfenster-Dauertest. Der
            // betroffene Command-Z-Weg wird separat als Tastendruck geprüft.
            try require(NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil),
                        "Wiederholen wurde von der Responder-Kette abgewiesen")
        } else {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "z",
                charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
            NSApp.postEvent(event, atStart: false)
        }
        try await wait { textView.string != before }
    }

    static func run(workspace: Workspace, window: NSWindow) async -> (Bool, String) {
        do {
            guard let root = window.contentView else { throw Failure(message: "Fensterinhalt fehlt") }
            let original = "# Rücknahme\n\n" + String(repeating: "Alpha 😀 und weiterer Text.\n", count: 700)
            var first = EditorTab(title: "undo.md", path: "", content: original)
            first.url = URL(fileURLWithPath: "/tmp/fastra-undo-probe.md")
            first.markdownVisualOverride = false
            let other = EditorTab(title: "zweites.txt", path: "", content: "Alpha zweites Dokument\n")
            workspace.tabs = [first, other]
            workspace.activeTabID = first.id
            try await wait { find(TextView.self, in: root)?.string == original }
            try require(find(WKWebView.self, in: root) != nil, "Markdown-Splitvorschau fehlt")
            guard let editor = find(TextView.self, in: root) else { throw Failure(message: "Editor fehlt") }
            window.makeFirstResponder(editor)
            editor.insertText("Zwischenstand\n", replacementRange: NSRange(location: 0, length: 0))
            let intermediate = "Zwischenstand\n" + original
            try require(workspace.activeTab?.content == intermediate, "Eingabe fehlt im Modell")
            workspace.showSearchDialog = true
            workspace.scope = .file
            workspace.useRegex = false
            workspace.findPattern = "Alpha"
            workspace.replacePattern = "Beta"
            try await wait { workspace.canApplyAllInActiveBuffer }
            try require(workspace.applyAllInActiveBuffer(), "Ersetzen wurde abgewiesen")
            let replaced = intermediate.replacingOccurrences(of: "Alpha", with: "Beta")
            try await wait { find(TextView.self, in: root)?.string == replaced }
            workspace.showSearchDialog = false
            for _ in 0..<12 {
                workspace.selectTab(id: other.id)
                try await wait { find(TextView.self, in: root)?.string == other.content }
                try require(find(TextView.self, in: root)?.undoManager?.canUndo == false,
                            "Undo-Verlauf greift auf ein anderes Dokument über")
                workspace.selectTab(id: first.id)
                try await wait { find(TextView.self, in: root)?.string == replaced }
                try await undoOrRedo(window: window, root: root)
                try require(workspace.activeTab?.content == intermediate, "Undo erreicht den Zwischenstand nicht")
                try await undoOrRedo(window: window, root: root)
                try require(workspace.activeTab?.content == original && workspace.activeTab?.isDirty == false,
                            "Frühere Eingabe oder Änderungspunkt nicht rückgängig")
                try await undoOrRedo(window: window, root: root, redo: true)
                try require(workspace.activeTab?.content == intermediate, "Redo der Eingabe falsch")
                try await undoOrRedo(window: window, root: root, redo: true)
                try require(workspace.activeTab?.content == replaced, "Redo der Ersetzung falsch")
            }
            return (true, "Markdown-Split: 700 Ersetzungen, 24 Tabwechsel, 48 Undo/Redo-Aktionen mit 24 Command-Z-Tastendrücken; Zwischenstände und Änderungspunkt korrekt")
        } catch let failure as Failure {
            return (false, failure.message)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
