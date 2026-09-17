import AppKit
import Testing
@testable import Fastra

/// `diffForeignPixelFraction` entscheidet im `diffnowrap`-Selbsttest, ob die
/// linke Diff-Spalte in die rechte hineinragt. Die Funktion war von keinem
/// Test aufgerufen — und sie hatte einen Rechenfehler, der nur an bestimmten
/// Hintergrundfarben auffällt: Der Bezugswert kam aus der UNTERGRENZE des
/// häufigsten 5-Bit-Eimers, und ein Eimer ist mit 1/31 ≈ 0,0323 breiter als
/// die Toleranz von 0,03. Lag ein Kanal im oberen Teil seines Eimers, galt
/// jeder Bildpunkt einer EINFARBIGEN Fläche als fremd — der Selbsttest meldete
/// „100 % fremde Schrift" auf leerem Grund.
@Suite("Fremde Bildpunkte im Diff-Ausschnitt")
struct DiffForeignPixelTests {
    /// Malt eine einfarbige Fläche und färbt `foreignPixels` Punkte der
    /// untersten Zeile schwarz. Gezeichnet wird über einen Grafikkontext:
    /// `setColor(_:atX:y:)` scheitert an dieser Bitmap-Form still
    /// („Unrecognized colorspace number -1") und lieferte lauter schwarze
    /// Punkte — die Fläche wäre dann einfarbig und der Test wertlos.
    private func bitmap(channel: CGFloat, foreignPixels: Int = 0,
                        width: Int = 20, height: Int = 10) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: channel, green: channel, blue: channel, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        if foreignPixels > 0 {
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: foreignPixels, height: 1).fill()
        }
        return rep
    }

    /// 0,0322 landet nach der 8-Bit-Rundung auf 8/255 = 0,03137. Mal 31 sind
    /// das 0,9725 — der Wert liegt also fast am oberen Rand seines Eimers,
    /// dessen Untergrenze 0 ist. Der Abstand 0,0314 ist größer als die
    /// Toleranz 0,03: GENAU dieser Wert ließ die alte Rechnung jeden Punkt
    /// als fremd zählen.
    @Test("Eine einfarbige Fläche zählt keine fremden Punkte — auch am Eimerrand",
          arguments: [0.0322, 0.999, 0.9679, 0.5162, 0.0])
    func uniformAreaHasNoForeignPixels(channel: Double) throws {
        let rep = try bitmap(channel: CGFloat(channel))
        #expect(SelfTest.diffForeignPixelFraction(rep) == 0)
    }

    @Test("Fremde Schrift wird anteilig gezählt")
    func foreignPixelsAreCounted() throws {
        // 20 × 10 = 200 Bildpunkte, davon 20 schwarz auf hellem Grund.
        let rep = try bitmap(channel: 0.94, foreignPixels: 20)
        #expect(abs(SelfTest.diffForeignPixelFraction(rep) - 0.1) < 0.001)
    }

    @Test("Ein einzelner Bildpunkt ist immer seine eigene vorherrschende Farbe")
    func singlePixelIsNeverForeign() throws {
        let rep = try bitmap(channel: 0.0322, width: 1, height: 1)
        #expect(SelfTest.diffForeignPixelFraction(rep) == 0)
    }
}
