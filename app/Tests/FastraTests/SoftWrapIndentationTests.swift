import AppKit
import CoreText
import CodeEditSourceEditor
import CodeEditLanguages
@testable import CodeEditTextView
import Testing
@testable import Fastra

@Suite("Soft-Wrap-Folgefragmentkern")
struct SoftWrapIndentationTests {
    @Test("Alte Profile behalten ihre Werte und verwenden First Line")
    func existingProfilesAndUnknownMode() throws {
        let defaults = testSuiteDefaults(named: "fastra-softwrap-\(UUID().uuidString)")
        let old = #"{"version":2,"formats":{"plain-text":{"softWrapEnabled":false,"indentWidth":2,"tabWidth":8,"softWrapIndentation":"futureMode"}}}"#
        defaults.set(Data(old.utf8), forKey: SoftWrapProfileStore.Keys.profiles)
        let center = NotificationCenter()
        let store = SoftWrapProfileStore(defaults: defaults, notificationCenter: center)
        #expect(store.softWrapIndentation(for: .plainText) == .firstLine)
        #expect(!store.isEnabled(for: .plainText))
        #expect(store.indentationProfile(for: .plainText).indentWidth == 2)
        #expect(store.indentationProfile(for: .plainText).tabWidth == 8)
        store.setSoftWrapIndentation(.reverse, for: .plainText)
        #expect(SoftWrapProfileStore(defaults: defaults, notificationCenter: center).softWrapIndentation(for: .plainText) == .reverse)
        #expect(!store.isEnabled(for: .plainText))
        store.setSoftWrapIndentation(.firstLine, for: .plainText)
        let payload = try JSONDecoder().decode(SoftWrapProfileStore.Payload.self,
            from: #require(defaults.data(forKey: SoftWrapProfileStore.Keys.profiles)))
        #expect(payload.formats[DocumentFormatID.plainText.rawValue]?.softWrapIndentation == nil)
        #expect(payload.formats[DocumentFormatID.plainText.rawValue]?.indentWidth == 2)
    }

    @Test("Folgezeilenmodus synchronisiert Fenster, bleibt ohne Wrap gespeichert und setzt pro Format zurück")
    func modePersistenceAndNotifications() {
        let defaults = testSuiteDefaults(named: "fastra-softwrap-\(UUID().uuidString)")
        let center = NotificationCenter()
        let first = SoftWrapProfileStore(defaults: defaults, notificationCenter: center)
        let second = SoftWrapProfileStore(defaults: defaults, notificationCenter: center)
        first.setEnabled(false, for: .plainText)
        first.setSoftWrapIndentation(.flushLeft, for: .plainText)
        second.setSoftWrapIndentation(.reverse, for: .fourD)
        #expect(second.softWrapIndentation(for: .plainText) == .flushLeft)
        #expect(first.softWrapIndentation(for: .fourD) == .reverse)
        #expect(!second.isEnabled(for: .plainText))
        first.resetToFactoryDefault(for: .plainText)
        #expect(second.softWrapIndentation(for: .plainText) == .firstLine)
        #expect(second.softWrapIndentation(for: .fourD) == .reverse)
    }

    @Test("Tabs, Emoji, lange Tokens und schmale Breiten: keine Lücken, Überlappung oder geteilten Grapheme")
    func fragmentCoverageAndWidth() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let cell = (" " as NSString).size(withAttributes: [.font: font]).width
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = cell * 4
        for prefix in ["", "    ", " \t  ", String(repeating: " ", count: 200)] {
            for suffix in [String(repeating: "Wort ", count: 30),
                           String(repeating: "X", count: 300),
                           String(repeating: "👨‍👩‍👧‍👦e\u{301}🇩🇪 ", count: 20)] {
                let text = prefix + suffix
                let string = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: style])
                let ns = text as NSString
                for width in [CGFloat(-5), 0, 1, cell * 2, cell * 20, cell * 50] {
                    for strategy in [LineBreakStrategy.word, .character] {
                    for mode in SoftWrapIndentation.allCases {
                        let typesetter = Typesetter()
                        typesetter.typeset(string, documentRange: NSRange(location: 0, length: string.length),
                            displayData: .init(maxWidth: width, lineHeightMultiplier: 1,
                                estimatedLineHeight: 18, breakStrategy: strategy,
                                softWrapIndentation: mode, softWrapIndentationColumns: 4), markedRanges: nil)
                        var covered = 0
                        for fragment in typesetter.lineFragments {
                            #expect(fragment.range.location == covered)
                            #expect(fragment.range.length > 0)
                            #expect(ns.rangeOfComposedCharacterSequence(at: covered).location == covered)
                            covered = fragment.range.max
                            if covered < ns.length {
                                #expect(ns.rangeOfComposedCharacterSequence(at: covered).location == covered)
                            }
                            let available = max(width - fragment.data.xOffset, 1)
                            if fragment.data.width > available + 0.5 {
                                // Ein einzelnes überbreites Graphem ist ausdrücklich zulässig.
                                #expect(fragment.range.length == ns.rangeOfComposedCharacterSequence(at: fragment.range.location).length)
                            }
                            #expect(fragment.data.xOffset >= 0)
                            #expect(fragment.data.xOffset <= max(width - 1, 0))
                        }
                        #expect(covered == ns.length)
                    }
                    }
                }
            }
        }
    }

    @Test("Gemischte Tabs messen sechs Zellen; Reverse addiert genau eine Stufe")
    func tabGeometryAndIndentationStep() {
        let font = NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        let cell = (" " as NSString).size(withAttributes: [.font: font, .kern: 0.3]).width
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = 4 * cell
        let string = NSAttributedString(string: " \t  Text", attributes: [.font: font, .kern: 0.3, .paragraphStyle: style])
        let first = SoftWrapFragmentGeometry.continuationOffset(in: string, maxWidth: 500,
            mode: .firstLine, indentationColumns: 2)
        let reverse = SoftWrapFragmentGeometry.continuationOffset(in: string, maxWidth: 500,
            mode: .reverse, indentationColumns: 2)
        #expect(abs(first - 6 * cell) < 0.6)
        #expect(abs(reverse - first - 2 * cell) < 0.6)
    }

    @Test("Breite Attachments und mehrere Runs machen ohne leere Fragmente Fortschritt")
    func attachmentsUseReducedWidth() {
        let string = NSAttributedString(string: "    aXbbbbbbbbbbbbbbbbbbbb", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        for mode in SoftWrapIndentation.allCases {
            let typesetter = Typesetter()
            typesetter.typeset(string, documentRange: NSRange(location: 0, length: string.length),
                displayData: .init(maxWidth: 50, lineHeightMultiplier: 1, estimatedLineHeight: 18,
                    breakStrategy: .word, softWrapIndentation: mode), markedRanges: nil,
                attachments: [AnyTextAttachment(range: NSRange(location: 5, length: 1),
                    attachment: IndentationTestAttachment())])
            var covered = 0
            for fragment in typesetter.lineFragments {
                #expect(fragment.range.location == covered)
                #expect(fragment.range.length > 0)
                covered = fragment.range.max
                if fragment.data.contents.contains(where: {
                    if case .attachment = $0.data { return true }
                    return false
                }) {
                    #expect(fragment.range.length == 1)
                    #expect(fragment.data.width == 80)
                }
            }
            #expect(covered == string.length)
        }
    }

    @Test("Reale Layoutrechtecke und Klicks verwenden den verschobenen Fragmentursprung")
    @MainActor
    func sharedOriginAndReducedWidth() throws {
        let text = "    " + String(repeating: "wort ", count: 150) + "👨‍👩‍👧‍👦 Ende"
        let config = SourceEditorConfiguration(appearance: .init(theme: EditorView.fastraTheme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: true, tabWidth: 4),
            behavior: .init(wrapAtColumn: 40), peripherals: .init(showMinimap: false))
        let editor = TextViewController(string: text, language: .default, configuration: config, cursorPositions: [])
        editor.loadView()
        editor.view.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        editor.view.layoutSubtreeIfNeeded()
        let manager = editor.textView.layoutManager!
        let cell = (" " as NSString).size(withAttributes: [.font: editor.textView.font, .kern: editor.textView.kern]).width
        let before = editor.textView.string
        let undo = editor.textView.undoManager?.canUndo
        var flushCount = 0
        for mode in SoftWrapIndentation.allCases {
            manager.softWrapIndentation = mode
            manager.softWrapIndentationColumns = 4
            manager.layoutLines()
            let line = try #require(manager.lineStorage.first)
            let fragments = Array(line.data.lineFragments)
            #expect(fragments.count > 1)
            if mode == .flushLeft { flushCount = fragments.count }
            else { #expect(fragments.count >= flushCount) }
            let expected = mode == .flushLeft ? 0 : (mode == .firstLine ? 4 : 8) * cell
            for fragment in fragments.dropFirst() {
                #expect(abs(fragment.data.xOffset - expected) < 0.5)
                let range = fragment.range.translate(location: line.range.location)
                let rect = try #require(manager.rectForOffset(range.location))
                #expect(abs(rect.minX - manager.edgeInsets.left - expected) < 0.5)
                #expect(manager.textOffsetAtPoint(CGPoint(x: rect.minX + 0.1, y: rect.midY)) == range.location)
                #expect(manager.textOffsetAtPoint(CGPoint(x: manager.edgeInsets.left, y: rect.midY)) == range.location)
                let bounds = manager.rectsFor(range: NSRange(location: range.location, length: 1))
                #expect(abs(try #require(bounds.first).minX - rect.minX) < 1.0)
            }
        }
        manager.wrapLines = false
        manager.layoutLines()
        #expect(manager.lineStorage.first?.data.lineFragments.first?.data.xOffset == 0)
        #expect(editor.textView.string == before)
        #expect(editor.textView.undoManager?.canUndo == undo)
    }

    @Test("Das erste Emoji-Fragment behält beim Moduswechsel seine vollständigen Schriftmetriken")
    @MainActor
    func firstFragmentMetricsStayUnchanged() throws {
        let text = "    " + String(repeating: "Wort 👨‍👩‍👧‍👦 e\u{301} ", count: 8)
        for width in [CGFloat(300), 700] {
            let editor = TextViewController(string: text, language: .default,
                configuration: .init(appearance: .init(theme: EditorView.fastraTheme,
                    font: .monospacedSystemFont(ofSize: 15, weight: .regular), wrapLines: true),
                    peripherals: .init(showMinimap: false)), cursorPositions: [])
            editor.loadView()
            editor.view.frame = CGRect(x: 0, y: 0, width: width, height: 500)
            editor.view.layoutSubtreeIfNeeded()
            let manager = editor.textView.layoutManager!
            var baseline: (NSRange, CGFloat, CGFloat, CGFloat)?
            for mode in SoftWrapIndentation.allCases {
                manager.softWrapIndentation = mode
                manager.layoutLines()
                let first = try #require(manager.lineStorage.first?.data.lineFragments.first)
                #expect(first.data.height > 15)
                #expect(first.data.descent < first.data.height)
                if let baseline {
                    #expect(first.range == baseline.0)
                    #expect(abs(first.data.width - baseline.1) < 0.5)
                    #expect(abs(first.data.height - baseline.2) < 0.5)
                    #expect(abs(first.data.descent - baseline.3) < 0.5)
                } else {
                    baseline = (first.range, first.data.width, first.data.height, first.data.descent)
                }
            }
        }
    }

    @Test("Drag-Vorschau zeichnet ausschließlich die Auswahl innerhalb eines Folgefragments")
    @MainActor
    func dragPreviewMasksContinuation() throws {
        let config = SourceEditorConfiguration(appearance: .init(theme: EditorView.fastraTheme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: true),
            behavior: .init(wrapAtColumn: 30), peripherals: .init(showMinimap: false))
        let editor = TextViewController(string: "    " + String(repeating: "MMMM ", count: 20),
            language: .default, configuration: config, cursorPositions: [])
        editor.loadView()
        editor.view.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        editor.view.layoutSubtreeIfNeeded()
        let manager = editor.textView.layoutManager!
        for mode in SoftWrapIndentation.allCases {
            manager.softWrapIndentation = mode
            manager.layoutLines()
            let line = try #require(manager.lineStorage.first)
            let fragment = try #require(line.data.lineFragments.first(where: { $0.index == 1 }))
            let start = line.range.location + fragment.range.location + 1
            let selection = NSRange(location: start, length: 2)
            let renderer = try #require(DraggingTextRenderer(ranges: [selection], layoutManager: manager))
            let bitmap = try #require(renderer.bitmapImageRepForCachingDisplay(in: renderer.bounds))
            renderer.cacheDisplay(in: renderer.bounds, to: bitmap)
            var inkColumns = IndexSet()
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                        inkColumns.insert(x)
                        break
                    }
                }
            }
            let first = try #require(inkColumns.first)
            let last = try #require(inkColumns.last)
            let left = try #require(manager.rectForOffset(start)).minX - manager.edgeInsets.left
            let right = try #require(manager.rectForOffset(selection.max)).minX - manager.edgeInsets.left
            let scale = CGFloat(bitmap.pixelsWide) / renderer.bounds.width
            #expect(CGFloat(first) >= left * scale - 2)
            #expect(CGFloat(first) <= left * scale + 3)
            #expect(CGFloat(last) <= right * scale + 2)
            #expect(CGFloat(last - first) > (right - left) * scale / 2)
        }
    }
}

private final class IndentationTestAttachment: TextAttachment {
    var width: CGFloat { 80 }
    var isSelected = false
    func draw(in context: CGContext, rect: NSRect) {}
}
