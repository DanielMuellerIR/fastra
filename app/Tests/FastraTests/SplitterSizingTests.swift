import Testing
@testable import Fastra

@Suite("Stabile Splitter")
struct SplitterSizingTests {
    @Test("Seitliche Breite nutzt stets den Ziehbeginn")
    func sidebarUsesStartWidth() {
        #expect(SplitterSizing.width(start: 200, translation: 30, direction: 1, minimum: 140, maximum: 480) == 230)
        // Dasselbe Drag-Event darf nicht auf die bereits geänderten 230 addieren.
        #expect(SplitterSizing.width(start: 200, translation: 30, direction: 1, minimum: 140, maximum: 480) == 230)
    }

    @Test("Markdown-Splitter läuft entgegengesetzt und bleibt begrenzt")
    func previewDirectionAndBounds() {
        #expect(SplitterSizing.width(start: 420, translation: 80, direction: -1, minimum: 260, maximum: 760) == 340)
        #expect(SplitterSizing.width(start: 420, translation: 999, direction: -1, minimum: 260, maximum: 760) == 260)
        #expect(SplitterSizing.width(start: 420, translation: -999, direction: -1, minimum: 260, maximum: 760) == 760)
    }
}
