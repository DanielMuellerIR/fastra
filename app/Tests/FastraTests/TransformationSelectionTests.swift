import AppKit
@testable import CodeEditSourceEditor
import CodeEditTextView
import Testing
@testable import Fastra

@MainActor private final class TransformationSelections {
    var ranges: [NSRange] = []
}

@Suite("Stabile Auswahl bei Transformationen und Cursorsprüngen", .serialized)
struct TransformationSelectionTests {
    @MainActor private func fixture(_ source: String) -> (NSWindow, TextViewController) {
        let configuration = SourceEditorConfiguration(appearance: .init(theme: EditorView.fastraTheme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false,
            bracketPairEmphasis: .bordered(color: .systemRed)), peripherals: .init(showMinimap: false))
        let controller = TextViewController(string: source, language: .default,
            configuration: configuration, cursorPositions: [])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        controller.textView.layoutManager.layoutLines()
        controller.textView.updateFrameIfNeeded()
        return (window, controller)
    }

    @Test("Dokumenttransformation publiziert keinen vorübergehenden EOF-Cursor und bleibt rückgängig")
    @MainActor func transformationPublishesOnlyFinalSelection() throws {
        let source = "{\"blob\":\"" + String(repeating: "a", count: 100_000) + "\"}"
        let formatted = try DocumentFormatter.format(source, fileExtension: "json")
        let (window, controller) = fixture(source)
        defer { window.contentViewController = nil; window.close() }
        let editor = controller.textView!
        let events = TransformationSelections()
        let observer = NotificationCenter.default.addObserver(
            forName: TextSelectionManager.selectionChangedNotification,
            object: editor.selectionManager, queue: .main
        ) { _ in MainActor.assumeIsolated { events.ranges.append(editor.fastraSafeSelectedRange) } }
        defer { NotificationCenter.default.removeObserver(observer) }
        editor.selectionManager.setSelectedRange(NSRange(location: 1, length: 0))
        editor.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(events.ranges.contains(NSRange(location: 1, length: 0)))
        events.ranges.removeAll()
        editor.fastraApplyTextOperation(replacing: NSRange(location: 0, length: editor.length), with: formatted)
        #expect(!events.ranges.isEmpty)
        #expect(events.ranges.allSatisfy { $0 == NSRange(location: 0, length: 0) })
        #expect(editor.string == formatted)
        #expect(editor.fastraSafeSelectedRange == NSRange(location: 0, length: 0))
        try #require(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        #expect(editor.string == source)
        #expect(editor.fastraSafeSelectedRange == NSRange(location: 0, length: 0))
        editor.undoManager?.redo()
        #expect(editor.string == formatted)
        #expect(editor.fastraSafeSelectedRange == NSRange(location: 0, length: 0))
    }

    @Test("Echte Auswahl-Observer suchen bei veraltetem Viewport nur nahe Klammern", arguments: [true, false])
    @MainActor func cursorJumpUsesNearbyPairs(reverse: Bool) throws {
        for nearby in [false, true] {
            let body = String(repeating: "a", count: 100_000)
            let source = nearby ? (reverse ? body + "{x}" : "{x}" + body) : "{" + body + "}"
            let (window, controller) = fixture(source)
            defer { window.contentViewController = nil; window.close() }
            let editor = controller.textView!, scroll = controller.scrollView!
            if !reverse {
                scroll.contentView.scroll(to: NSPoint(x: max(editor.frame.width - scroll.contentSize.width, 0), y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
                try #require((editor.visibleTextRange?.location ?? 0) > 50_000)
            } else {
                try #require((editor.visibleTextRange?.upperBound ?? Int.max) < 50_000)
            }
            let previousViewport = scroll.contentView.bounds
            editor.selectionManager.setSelectedRange(NSRange(location: reverse ? editor.length : 1, length: 0))
            #expect(scroll.contentView.bounds == previousViewport)
            let emphasis = try #require(editor.emphasisManager)
            let marked = emphasis.getEmphases(for: "codeedit.bracketPairs").map(\.range.location)
            if nearby { #expect(marked.contains(reverse ? 100_000 : 2)) }
            else { #expect(marked.isEmpty) }
        }
    }

    @Test("Sichtbare Cursor behalten die bisherigen Suchgrenzen einschließlich der Viewportkanten")
    @MainActor func visibleCursorPreservesSearchWindow() {
        let viewport = NSRange(location: 20_000, length: 100)
        for caret in [20_000, 20_050, 20_100] {
            #expect(TextViewController.fastraEmphasisLimit(from: caret, viewport: viewport,
                limit: 24_196, reverse: false) == 24_196)
            #expect(TextViewController.fastraEmphasisLimit(from: caret - 1, viewport: viewport,
                limit: 15_904, reverse: true) == 15_904)
        }
        #expect(TextViewController.fastraEmphasisLimit(from: 99, viewport: viewport,
            limit: 15_904, reverse: true) == 99)
        #expect(TextViewController.fastraEmphasisLimit(from: 90_000, viewport: viewport,
            limit: 24_196, reverse: false) == 90_000)
    }
}
