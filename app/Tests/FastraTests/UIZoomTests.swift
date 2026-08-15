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

    @Test("Einstellungsfenster verwendet und aktualisiert die Inhalts-Mindestgröße")
    func settingsWindowUpdatesScaledMinimum() {
        let initialMinimum = NSSize(width: 480, height: 380)
        let scaledMinimum = NSSize(width: 576, height: 456)
        let target = SettingsWindowSizingRecorder(
            currentContentSize: NSSize(width: 400, height: 300)
        )
        SettingsWindowSizing(
            preferredContentSize: NSSize(width: 680, height: 720),
            minimumContentSize: initialMinimum
        ).apply(to: target, resizeToPreferred: true)

        #expect(target.minimumContentSize == initialMinimum)
        #expect(target.currentContentSize == NSSize(width: 680, height: 720))

        target.currentContentSize = NSSize(width: 600, height: 600)
        SettingsWindowSizing(
            preferredContentSize: NSSize(width: 816, height: 864),
            minimumContentSize: scaledMinimum
        ).apply(to: target, resizeToPreferred: false)

        #expect(target.minimumContentSize == scaledMinimum)
        #expect(target.currentContentSize == NSSize(width: 600, height: 600))
    }
}

private final class SettingsWindowSizingRecorder: SettingsWindowSizingTarget {
    var currentContentSize: NSSize
    var minimumContentSize: NSSize = .zero

    init(currentContentSize: NSSize) {
        self.currentContentSize = currentContentSize
    }

    var fastraCurrentContentSize: NSSize {
        currentContentSize
    }

    func fastraSetContentSize(_ size: NSSize) {
        currentContentSize = size
    }

    func fastraSetMinimumContentSize(_ size: NSSize) {
        minimumContentSize = size
    }
}
