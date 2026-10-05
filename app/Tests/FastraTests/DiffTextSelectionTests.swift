import AppKit
import Testing
@testable import Fastra

private func selectionRow(_ id: String, _ before: String?, _ after: String?) -> DiffDisplayItem {
    .row(DiffDisplayRow(id: id, ordinal: 0, kind: .changed,
                       beforeNumber: 1, afterNumber: 1, before: before, after: after,
                       beforeHighlight: nil, afterHighlight: nil,
                       beforeMissingFinalNewline: false, afterMissingFinalNewline: false,
                       intralineWasLimited: false))
}

@Test("Diff-Auswahl kopiert nur Text der gewählten Seite einschließlich echter Leerzeilen")
func diffSelection_columnText() {
    let items = [selectionRow("a", "alt", "neu"), selectionRow("b", nil, "zusätzlich"),
                 selectionRow("c", "", ""), selectionRow("d", "Ende", "Ende")]
    let before = DiffSelectionColumn(items: items, before: true)
    #expect(before.text == "alt\n\nEnde")
    #expect(before.range(for: "b") == nil)
    #expect(before.range(for: "c") == NSRange(location: 4, length: 0))
    #expect(DiffSelectionColumn(items: items, before: false).text == "neu\nzusätzlich\n\nEnde")
}

@Test("Diff-Auswahl verwendet UTF-16 auch bei Emoji und kombinierenden Zeichen")
func diffSelection_unicodeRanges() {
    let column = DiffSelectionColumn(items: [selectionRow("a", "🇩🇪 é", nil),
                                             selectionRow("b", "日本", nil)], before: true)
    #expect(column.range(for: "a") == NSRange(location: 0, length: 7))
    #expect(column.range(for: "b") == NSRange(location: 8, length: 2))
    #expect(column.substring(in: NSRange(location: 5, length: 5)) == "é\n日本")
    #expect(column.substring(in: NSRange(location: NSNotFound, length: 1)).isEmpty)
}

@MainActor
@Test("Native Diff-Mausauswahl zieht vorwärts und rückwärts über Zeilen und bleibt in ihrer Spalte")
func diffSelection_nativeDragAcrossRows() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let root = try #require(window.contentView)
    let selection = DiffTextSelection()
    selection.update(items: [selectionRow("a", "alpha", "eins"),
                             selectionRow("b", "beta", "zwei")])
    func view(_ id: String, _ text: String, _ before: Bool, _ y: CGFloat) -> DiffSelectionTextView {
        let view = DiffSelectionTextView(frame: NSRect(x: before ? 0 : 350, y: y, width: 300, height: 22))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.string = text
        view.rowID = id
        view.before = before
        view.selection = selection
        root.addSubview(view)
        selection.register(view)
        view.delegate = selection
        return view
    }
    let a = view("a", "alpha", true, 100)
    let b = view("b", "beta", true, 70)
    let other = view("b", "zwei", false, 70)
    func event(_ type: NSEvent.EventType, _ point: NSPoint,
               modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                       timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    let first = a.convert(NSPoint(x: 0, y: 5), to: nil)
    let last = b.convert(NSPoint(x: 290, y: 5), to: nil)
    selection.begin(try event(.leftMouseDown, first), in: a)
    selection.drag(try event(.leftMouseDragged, last))
    #expect(selection.range == NSRange(location: 0, length: 10))
    #expect(a.selectedRange() == NSRange(location: 0, length: 5))
    #expect(b.selectedRange() == NSRange(location: 0, length: 4))
    #expect(other.selectedRange().length == 0)
    selection.end()
    selection.begin(try event(.leftMouseDown, last), in: b)
    selection.drag(try event(.leftMouseDragged, first))
    #expect(selection.range == NSRange(location: 0, length: 10))
    selection.end()
    let cursor = a.convert(NSPoint(x: 290, y: 5), to: nil)
    selection.begin(try event(.leftMouseDown, cursor), in: a)
    selection.end()
    #expect(selection.range == NSRange(location: 5, length: 0))
    selection.begin(try event(.leftMouseDown, last, modifiers: .shift), in: b)
    selection.end()
    #expect(selection.range == NSRange(location: 5, length: 5))
    selection.begin(try event(.leftMouseDown, first, modifiers: .shift), in: a)
    selection.end()
    #expect(selection.range == NSRange(location: 0, length: 5))
    let opposite = other.convert(NSPoint(x: 290, y: 5), to: nil)
    selection.begin(try event(.leftMouseDown, opposite, modifiers: .shift), in: other)
    selection.end()
    #expect(selection.range == NSRange(location: 9, length: 0))
    selection.selectAll(in: other)
    #expect(selection.range == NSRange(location: 0, length: 9))
    #expect(a.selectedRange().length == 0)
    #expect(other.selectedRange() == NSRange(location: 0, length: 4))
}

@Test("Diff-Zeilenindex liefert bei 20.000 kurzen Zeilen sämtliche Bereiche")
func diffSelection_largeIndexedColumn() {
    for count in [10_000, 20_000] {
        let column = DiffSelectionColumn(items: (0..<count).map {
            selectionRow("row-\($0)", "x", nil)
        }, before: true)
        let clock = ContinuousClock()
        let start = clock.now
        for index in 0..<count {
            #expect(column.range(for: "row-\(index)") == NSRange(location: index * 2, length: 1))
        }
        print("DiffSelection-Index \(count) Lookups: \(start.duration(to: clock.now))")
        #expect(column.range(for: "missing") == nil)
    }
}
