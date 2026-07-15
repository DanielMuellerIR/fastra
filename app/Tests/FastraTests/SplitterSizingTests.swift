import CoreGraphics
import Testing
@testable import Fastra

@Suite("Stabile Splitter")
struct SplitterSizingTests {
    @Test("Dokumentfenster starten mindestens in der normalen Startgröße")
    func documentWindowClampsSmallFrontWindow() {
        let front = CGRect(x: 100, y: 200, width: 320, height: 200)
        let result = MainWindowSizing.cascadedFrame(from: front)

        #expect(result.width == MainWindowSizing.defaultWidth)
        #expect(result.height == MainWindowSizing.defaultHeight)
        #expect(result.origin.x == 124)
        #expect(result.origin.y == 176)
    }

    @Test("Dokumentfenster übernehmen eine bereits ausreichende Größe")
    func documentWindowKeepsLargeFrontWindow() {
        let front = CGRect(x: 10, y: 20, width: 1200, height: 800)
        let result = MainWindowSizing.cascadedFrame(from: front)

        #expect(result.size == front.size)
    }

    @Test("Skalierter Fenster-Chrome rückt native Ampeln nach unten")
    func trafficLightsFollowScaledChrome() {
        let normal = MainWindowSizing.trafficLightOriginY(
            superviewHeight: 28, buttonHeight: 14,
            chromeHeight: 28, isFlipped: false
        )
        let enlarged = MainWindowSizing.trafficLightOriginY(
            superviewHeight: 28, buttonHeight: 14,
            chromeHeight: 40, isFlipped: false
        )

        #expect(normal == 7)
        #expect(enlarged == 1)
        #expect(enlarged < normal)
    }

    @Test("Splitter-Klick kann das Fenster nicht verschieben")
    @MainActor
    func splitterDoesNotMoveWindow() {
        let view = SplitterDragView(value: 200, range: 140...480,
                                    direction: 1, onChange: { _ in })
        #expect(view.mouseDownCanMoveWindow == false)
    }

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
