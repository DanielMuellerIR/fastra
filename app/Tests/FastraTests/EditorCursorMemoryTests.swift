import Foundation
import Testing
@testable import Fastra

@Test("Neuer Tab übernimmt keine Auswahl des vorigen Tabs")
func cursorMemoryStartsUnknownTabWithoutSelection() {
    var memory = EditorCursorMemory()
    let first = UUID()
    let second = UUID()

    let restored = memory.switchTab(
        from: first,
        currentRanges: [NSRange(location: 0, length: 5)],
        to: second
    )

    #expect(restored.isEmpty)
}

@Test("Rückkehr zu einem Tab stellt nur dessen eigene Auswahl wieder her")
func cursorMemoryRestoresPerTabSelection() {
    var memory = EditorCursorMemory()
    let first = UUID()
    let second = UUID()
    let firstSelection = NSRange(location: 4, length: 7)
    let secondCursor = NSRange(location: 12, length: 0)

    _ = memory.switchTab(
        from: first,
        currentRanges: [firstSelection],
        to: second
    )
    let restored = memory.switchTab(
        from: second,
        currentRanges: [secondCursor],
        to: first
    )

    #expect(restored == [firstSelection])
}
