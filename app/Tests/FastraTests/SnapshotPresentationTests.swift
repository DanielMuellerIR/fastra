import AppKit
import CodeEditSourceEditor
import Testing
@testable import Fastra

@Suite("Syntaxfarben und Soft Wrap im eingefrorenen Snapshot", .serialized)
@MainActor
struct SnapshotPresentationTests {
    @Test("4D-Farben und Schriftänderung erhalten rohe UTF-16-Positionen und Schreibschutz")
    func sourceColors() async throws {
        _ = NSApplication.shared
        let content = "If (True)\r\nALERT(\"😀\") // Kommentar\r\nEnd if\r\n"
        let scroll = ReadOnlySnapshotTextView.makeScrollView(content: content, reason: "Snapshot")
        let view = try #require(scroll.documentView as? ReadOnlySnapshotTextView)
        let highlighter = SnapshotSyntaxHighlighter(textView: view)
        view.setSelectedRange((content as NSString).range(of: "😀"))
        let selected = view.selectedRange()
        highlighter.analyze(filename: "Methode.4dm")
        func colors() -> Set<NSColor> {
            var result = Set<NSColor>()
            view.textStorage?.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: (content as NSString).length)) { value, _, _ in
                if let color = value as? NSColor { result.insert(color) }
            }
            return result
        }
        #expect(await waitUntil { colors().count >= 3 })
        #expect(view.string == content && view.selectedRange() == selected)
        view.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        highlighter.applyColors()
        #expect(colors().count >= 3)
        #expect(view.string == content && !view.isEditable)
        view.insertText("changed", replacementRange: selected)
        #expect(view.string == content)
    }

    @Test("Soft Wrap wechselt in beide Richtungen ohne Text-/Auswahldrift")
    func wrap() throws {
        let content = String(repeating: "Wort 😀 ", count: 150) + "\r\nEnde"
        let scroll = ReadOnlySnapshotTextView.makeScrollView(content: content, reason: "Snapshot")
        scroll.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let view = try #require(scroll.documentView as? ReadOnlySnapshotTextView)
        let selected = (content as NSString).range(of: "Ende")
        view.setSelectedRange(selected)
        for wrapped in [false, true, false, true] {
            view.setSoftWrap(wrapped)
            #expect(view.textContainer?.widthTracksTextView == wrapped)
            #expect(scroll.hasHorizontalScroller == !wrapped)
            #expect(view.string == content && view.selectedRange() == selected)
        }
        let narrowWidth = view.frame.width
        scroll.setFrameSize(NSSize(width: 850, height: 400))
        scroll.layoutSubtreeIfNeeded()
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        #expect(view.frame.width > narrowWidth + 300)
        #expect(view.textContainer!.containerSize.width > 700)
        #expect(view.string == content && view.selectedRange() == selected)
    }
}
