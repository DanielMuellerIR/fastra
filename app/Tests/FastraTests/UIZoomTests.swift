import Testing
import AppKit
@testable import Fastra

@Suite("Globale UI-Skalierung")
struct UIZoomTests {
    @Test("Normalstufe entspricht exakt Faktor 1")
    func normalScale() {
        #expect(UIZoom.scale(for: 0) == 1)
    }

    @Test("Zoomstufen werden an beiden Grenzen geklemmt")
    func clampsLevels() {
        #expect(UIZoom.clamped(-999) == UIZoom.minimumLevel)
        #expect(UIZoom.clamped(999) == UIZoom.maximumLevel)
        #expect(UIZoom.scale(for: -999) == UIZoom.scale(for: UIZoom.minimumLevel))
        #expect(UIZoom.scale(for: 999) == UIZoom.scale(for: UIZoom.maximumLevel))
    }

    @Test("Jede Stufe vergrößert den Faktor monoton")
    func levelsAreMonotonic() {
        let levels = UIZoom.minimumLevel...UIZoom.maximumLevel
        let scales = levels.map(UIZoom.scale(for:))
        #expect(zip(scales, scales.dropFirst()).allSatisfy(<))
    }

    @Test("Editor- und AppKit-Schrift verwenden denselben Faktor")
    func appKitFontUsesScale() {
        let scale = UIZoom.scale(for: 3)
        let font = NSFont.fastraMonospaced(size: 13, scale: scale)
        #expect(font.pointSize == 13 * scale)
    }
}
