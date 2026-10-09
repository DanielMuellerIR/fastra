import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import Testing
@testable import Fastra

@Suite("Markdown: native Einrückung", .serialized)
@MainActor
struct NativeMarkdownReviewTests {
    private func editor(_ text: String) -> TextViewController {
        let controller = TextViewController(string: text, language: .markdown,
            configuration: .init(appearance: .init(theme: EditorView.fastraTheme,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: true)), cursorPositions: [])
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    @Test("Ausrücken bewegt Cursor nur um tatsächlich entfernte Zeichen", arguments: ["a", " a", "  a", "    a"])
    func shortIndent(_ text: String) {
        let controller = editor(text)
        controller.textView.selectionManager.setSelectedRange(NSRange(location: text.utf16.count - 1, length: 0))
        controller.handleIndent(inwards: true)
        #expect(controller.textView.string == "a")
        #expect(controller.textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test("Mehrfachcursor rücken jede Zeile nur einmal ein; Undo stellt Auswahl wieder her")
    func multipleSelections() {
        let controller = editor("abc\n def")
        let before = [NSRange(location: 1, length: 0), NSRange(location: 2, length: 0), NSRange(location: 5, length: 2)]
        controller.textView.selectionManager.setSelectedRanges(before)
        controller.handleIndent()
        #expect(controller.textView.string == "    abc\n     def")
        #expect(controller.textView.selectionManager.textSelections.map(\.range) == [NSRange(location: 5, length: 0), NSRange(location: 6, length: 0), NSRange(location: 13, length: 2)])
        controller.textView.undoManager?.undo()
        #expect(controller.textView.string == "abc\n def")
        #expect(controller.textView.selectionManager.textSelections.map(\.range) == before)
    }

    @Test("Return übernimmt Einrückung auch mit CR und CRLF", arguments: ["\n", "\r", "\r\n"])
    func newline(_ eol: String) {
        let controller = editor("    abc" + eol + "Ende")
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 7, length: 0))
        controller.textView.insertNewline(nil)
        #expect(controller.textView.string == "    abc" + eol + "    " + eol + "Ende")
    }
}
