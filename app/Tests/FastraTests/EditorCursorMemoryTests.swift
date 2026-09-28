import Foundation
import CodeEditSourceEditor
import Testing
@testable import Fastra

@Test("Neuer Tab übernimmt keine Auswahl des vorigen Tabs")
func cursorMemoryStartsUnknownTabWithoutSelection() {
    var memory = EditorCursorMemory()
    let first = UUID()
    let second = UUID()

    let restored = memory.switchTab(
        from: first,
        currentPositions: [CursorPosition(range: NSRange(location: 0, length: 5))],
        to: second
    )

    #expect(restored.isEmpty)
}

@Test("Rückkehr zu einem Tab stellt nur dessen eigene Auswahl wieder her")
func cursorMemoryRestoresPerTabSelection() {
    var memory = EditorCursorMemory()
    let first = UUID()
    let second = UUID()
    let firstSelection = CursorPosition(range: NSRange(location: 4, length: 7))
    let secondCursor = CursorPosition(range: NSRange(location: 12, length: 0))

    _ = memory.switchTab(
        from: first,
        currentPositions: [firstSelection],
        to: second
    )
    let restored = memory.switchTab(
        from: second,
        currentPositions: [secondCursor],
        to: first
    )

    #expect(restored == [firstSelection])
}

@Test("Suchauswahl behält Zeile und Spalte über wiederholte Tabwechsel")
func cursorMemoryPreservesLineColumnSearchJumps() {
    var memory = EditorCursorMemory()
    let first = UUID()
    let second = UUID()
    let selections = [
        CursorPosition(start: .init(line: 360, column: 25),
                       end: .init(line: 360, column: 40)),
        CursorPosition(start: .init(line: 780, column: 25),
                       end: .init(line: 780, column: 40))
    ]
    #expect(selections.allSatisfy { $0.range.location == NSNotFound })
    memory.remember([selections[0]], for: first)
    var current = [selections[1]]
    for step in 0..<24 {
        let returningToFirst = step.isMultiple(of: 2)
        current = memory.switchTab(
            from: returningToFirst ? second : first,
            currentPositions: current,
            to: returningToFirst ? first : second)
        #expect(current == [selections[returningToFirst ? 0 : 1]])
    }
}

@Test("Suchpositionen werden exakt wie die tatsächliche Editor-Auswahl aufgelöst")
@MainActor
func cursorResolutionMatchesAppliedSelection() throws {
    let text = (1...1200).map { "Zeile \($0): Kontakt 😀 Beispiel" }.joined(separator: "\n")
    let controller = TextViewController(
        string: text, language: .default,
        configuration: SourceEditorConfiguration(
            appearance: .init(theme: EditorView.fastraThemeDark,
                              font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                              wrapLines: false, tabWidth: 4)),
        cursorPositions: [])
    controller.loadView()
    for (startLine, startColumn, endLine, endColumn) in [
        (360, 12, 360, 19), (780, 12, 780, 19), (779, 12, 781, 8), (780, 12, 780, 12)
    ] {
        let position = CursorPosition(start: .init(line: startLine, column: startColumn),
                                      end: .init(line: endLine, column: endColumn))
        let start = BufferSearch.nsRange(forLine: startLine, column: startColumn, in: text).location
        let end = BufferSearch.nsRange(forLine: endLine, column: endColumn, in: text).location
        let expected = NSRange(location: start, length: end - start)
        let resolved = try #require(controller.resolveCursorPosition(position))
        #expect(resolved.range == expected)
        controller.setCursorPositions([position])
        #expect(controller.textView.selectionManager.textSelections.map(\.range) == [expected])
        #expect(controller.cursorPositions == [resolved])
    }
    let caret = CursorPosition(line: 780, column: 12)
    let expectedCaret = BufferSearch.nsRange(forLine: 780, column: 12, in: text)
    #expect(controller.resolveCursorPosition(caret)?.range == expectedCaret)
}
