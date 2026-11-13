// LazyLongLineLayoutTests.swift
// Synthetische Langzeilen; keine Inhalte aus gemeldeten Dokumenten.
import AppKit
@testable import CodeEditTextView
import CoreText
import Testing

@Suite("Glyphen großer Festbreitenzeilen", .serialized)
struct LazyLongLineLayoutTests {
    private func payload(_ size: Int) -> String {
        let pattern = "A7+/qZ09_-?mN4xB"
        return String(repeating: pattern, count: size / pattern.utf8.count)
            + String(pattern.prefix(size % pattern.utf8.count))
    }

    @MainActor
    private func editor(_ source: String, wrapped: Bool = true) -> (TextView, NSScrollView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let view = TextView(string: source, font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: wrapped)
        scroll.documentView = view
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.layoutManager.layoutLines()
        view.updateFrameIfNeeded()
        view.layoutManager.layoutLines()
        return (view, scroll)
    }

    @Test("Lazy-Zeilen behalten CoreText-Umbruch, Breite und Höhe")
    @MainActor
    func geometryMatchesCoreText() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        for suffix in ["\n", "\r\n"] {
            let source = "  " + payload(256 * 1024) + suffix
            let storage = NSTextStorage(string: source, attributes: [.font: font, .kern: 0.0])
            let range = NSRange(location: 0, length: storage.length)
            for strategy: LineBreakStrategy in [.word, .character] {
                let display = TextLine.DisplayData(maxWidth: 780, lineHeightMultiplier: 1.1, estimatedLineHeight: 17, breakStrategy: strategy, softWrapIndentation: .reverse, softWrapIndentationColumns: 4)
                let actual = TextLine()
                actual.prepareForDisplay(displayData: display, range: range, stringRef: storage, markedRanges: nil, attachments: [])
                let expected = Typesetter()
                expected.typeset(storage, documentRange: range, displayData: display, markedRanges: nil)
                #expect(actual.lineFragments.count == expected.lineFragments.count)
                #expect(abs(actual.lineFragments.height - expected.lineFragments.height) < 0.01)
                for index in [0, 1, actual.lineFragments.count / 2, actual.lineFragments.count - 1] {
                    let lhs = try #require(actual.lineFragments.getLine(atIndex: index))
                    let rhs = try #require(expected.lineFragments.getLine(atIndex: index))
                    #expect(lhs.range == rhs.range)
                    #expect(abs(lhs.data.width - rhs.data.width) < 0.01)
                    #expect(abs(lhs.data.xOffset - rhs.data.xOffset) < 0.01)
                    guard case .text(let line) = lhs.data.contents[0].data else { Issue.record("Textfragment fehlt"); continue }
                    // Eine spätere Zeile formt nur ihren Ausschnitt, keine
                    // Glyphen für alle vorangegangenen Megabytes.
                    #expect(CTLineGetStringRange(line).location == 0)
                    #expect(CTLineGetStringRange(line).length == lhs.range.length)
                }
            }
        }
    }

    @Test("Großes inneres JSON-Feld bleibt umgebrochen, anklickbar und bearbeitbar")
    @MainActor
    func prettyJSONCaretHitTestingAndEditing() throws {
        let source = "{\n  \"größer\": \"" + payload(512 * 1024) + "\"\n}\n"
        let (view, scroll) = editor(source)
        let offset = 256 * 1024 + 17
        let rect = try #require(view.layoutManager.rectForOffset(offset))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(rect.minY - 100, 0)))
        scroll.reflectScrolledClipView(scroll.contentView)
        view.layoutManager.layoutLines()
        let current = try #require(view.layoutManager.rectForOffset(offset))
        let found = view.layoutManager.textOffsetAtPoint(CGPoint(x: current.midX, y: current.midY))
        #expect(found == offset || found == offset + 1)
        #expect(current.maxX <= scroll.contentSize.width + 1)
        view.replaceCharacters(in: NSRange(location: offset, length: 1), with: "Z")
        #expect((view.string as NSString).substring(with: NSRange(location: offset, length: 1)) == "Z")
        view.layoutManager.layoutLines()
        #expect(view.layoutManager.rectForOffset(offset) != nil)
        let visible = view.visibleRect
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: visible))
        view.cacheDisplay(in: visible, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
    }

    @Test("Unicode-Fallback trennt zusammengesetzte Zeichen nicht")
    @MainActor
    func unicodePreservesComposedCharacters() throws {
        let family = "👨‍👩‍👧‍👦"
        let source = payload(256 * 1024) + family + "a\u{0308}" + payload(256 * 1024)
        let (view, _) = editor(source)
        let string = source as NSString
        let line = try #require(view.layoutManager.lineStorage.first)
        for fragment in line.data.lineFragments.linesInRange(NSRange(location: 0, length: string.length)) {
            let end = fragment.range.location + fragment.range.length
            if end < string.length {
                #expect(string.rangeOfComposedCharacterSequence(at: end).location == end)
            }
        }
        #expect(view.string == source)
    }

    @Test("Opt-in: 100 MB werden ohne dokumentweite Glyphen aufgebaut")
    @MainActor
    func optionalHundredMegabyteLayout() throws {
        guard ProcessInfo.processInfo.environment["FASTRA_LAZY_ASCII_STRESS"] == "1" else { return }
        let source = "[{\"größer\":\"" + payload(100_000_000) + "\"}]"
        let begin = ContinuousClock.now
        let (view, scroll) = editor(source)
        let elapsed = begin.duration(to: .now)
        #expect(elapsed < .seconds(10), "100-MB-Aufbau dauerte \(elapsed)")
        #expect(view.string == source)
        #expect(view.subviews.compactMap { $0 as? LineFragmentView }.count < 100)
        let offset = (source as NSString).length - 100
        let rect = try #require(view.layoutManager.rectForOffset(offset))
        #expect(rect.maxX <= scroll.contentSize.width + 1)
        #expect(rect.minY > 0)
        // Ein Umlaut im kompakten JSON muss denselben schnellen Pfad nutzen.
        let line = try #require(view.layoutManager.lineStorage.first)
        let second = try #require(line.data.lineFragments.getLine(atIndex: 1))
        guard case .text(let glyphs) = second.data.contents[0].data else { Issue.record("Glyphen fehlen"); return }
        #expect(CTLineGetStringRange(glyphs).location == 0)
    }

    @Test("Lazy-Glyphen folgen unveränderten Zeilen nach Änderungen davor")
    @MainActor
    func earlierLineEditRebasesLazySource() throws {
        let source = "header\n" + payload(512 * 1024)
        let (view, _) = editor(source)
        let originalLine = try #require(view.layoutManager.textLineForIndex(1))
        let originalID = originalLine.data.id
        view.replaceCharacters(in: NSRange(location: 0, length: 0), with: "12345")
        view.layoutManager.layoutLines()
        let movedLine = try #require(view.layoutManager.textLineForIndex(1))
        #expect(movedLine.data.id == originalID,
                "Die unveraenderte Folgezeile soll ihren Layoutcache behalten")
        #expect(movedLine.range.location == originalLine.range.location + 5)
        let fragment = try #require(movedLine.data.lineFragments.first)
        guard case .text(let actual) = fragment.data.contents[0].data else {
            Issue.record("Textfragment fehlt"); return
        }
        let currentRange = NSRange(location: movedLine.range.location + fragment.range.location,
                                   length: fragment.range.length)
        let expected = CTLineCreateWithAttributedString(view.textStorage.attributedSubstring(from: currentRange))
        func glyphs(_ line: CTLine) -> [CGGlyph] {
            var result: [CGGlyph] = []
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                var values = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &values)
                result.append(contentsOf: values)
            }
            return result
        }
        #expect(glyphs(actual) == glyphs(expected))
        let offset = movedLine.range.location + 30
        let rect = try #require(view.layoutManager.rectForOffset(offset))
        let found = view.layoutManager.textOffsetAtPoint(CGPoint(x: rect.midX, y: rect.midY))
        #expect(found == offset || found == offset + 1)
    }


    @Test("Farben zeichnen neu, Metrikänderungen bauen die Geometrie neu auf")
    @MainActor
    func colorChangesKeepGeometryButFontChangesReflow() throws {
        let (view, _) = editor(payload(512 * 1024))
        let before = try #require(view.layoutManager.lineStorage.first?.data.lineFragments.first)
        let oldID = before.data.id
        let oldLength = before.range.length
        let oldCell = try #require(view.layoutManager.rectForOffset(0)).width
        let colorRange = NSRange(location: 0, length: 4096)
        view.textStorage.addAttribute(.foregroundColor, value: NSColor.red, range: colorRange)
        view.layoutManager.layoutLines()
        let afterColor = try #require(view.layoutManager.lineStorage.first?.data.lineFragments.first)
        #expect(afterColor.data.id == oldID,
                "Farbe allein darf die Rangetabelle der Megazeile nicht verwerfen")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 240, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        graphics.cgContext.clear(CGRect(x: 0, y: 0, width: 240, height: 40))
        let renderer = LineFragmentRenderer(textStorage: view.textStorage, invisibleCharacterDelegate: nil)
        renderer.draw(lineFragment: afterColor.data, in: graphics.cgContext, yPos: 0)
        var redPixels = 0
        for y in 0..<40 {
            for x in 0..<240 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.2 && color.redComponent > 0.6
                    && color.greenComponent < 0.4 && color.blueComponent < 0.4 { redPixels += 1 }
            }
        }
        #expect(redPixels > 10, "Die neue Vordergrundfarbe muss wirklich gezeichnet werden")
        view.textStorage.addAttribute(.font,
            value: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular),
            range: NSRange(location: 0, length: view.textStorage.length))
        view.layoutManager.layoutLines()
        let afterFont = try #require(view.layoutManager.lineStorage.first?.data.lineFragments.first)
        #expect(afterFont.data.id != oldID)
        #expect(afterFont.range.length < oldLength)
        let newCell = try #require(view.layoutManager.rectForOffset(0)).width
        #expect(newCell > oldCell)
    }


    @Test("Explizites Kern null auf einem Teil der Megazeile erhält die feste Geometrie")
    @MainActor
    func partialDefaultKernKeepsFastGeometry() throws {
        let (view, scroll) = editor(payload(512 * 1024))
        let original = try #require(view.layoutManager.lineStorage.first?.data.lineFragments.first)
        #expect(original.data.fastraHasFixedCells)
        let id = original.data.id
        // So unterscheiden sich der anfaengliche Textspeicher und die erste
        // Antwort des Highlighters: Kern fehlt anfangs und wird null gesetzt.
        #expect(view.textStorage.attribute(.kern, at: 0, effectiveRange: nil) == nil)
        view.textStorage.addAttribute(.kern, value: 0.0, range: NSRange(location: 0, length: 4096))
        view.layoutManager.layoutLines()
        let afterHighlight = try #require(view.layoutManager.lineStorage.first?.data.lineFragments.first)
        #expect(afterHighlight.data.id == id)
        #expect(afterHighlight.data.fastraHasFixedCells)
        // Auch der naechste echte Breitenwechsel muss die gemischten, aber
        // metrisch gleichen Attribute wieder als Festzellen erkennen.
        scroll.frame.size.width = 700
        view.frame.size.width = scroll.contentSize.width
        view.layoutManager.setNeedsLayout()
        view.layoutManager.layoutLines()
        let afterResize = try #require(view.layoutManager.lineStorage.first?.data.lineFragments.first)
        #expect(afterResize.data.fastraHasFixedCells)
        #expect(afterResize.data.width <= scroll.contentSize.width + 1)
    }

}
