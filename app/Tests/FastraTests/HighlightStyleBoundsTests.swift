import AppKit
import CodeEditLanguages
@testable import CodeEditSourceEditor
import CodeEditTextView
import Testing
@testable import Fastra

@Suite(.serialized)
@MainActor
struct HighlightStyleBoundsTests {
    private final class Attributes: ThemeAttributesProviding {
        var beforeAttributes: (() -> Void)?
        func attributesFor(_ capture: CaptureName?) -> [NSAttributedString.Key: Any] {
            beforeAttributes?()
            return [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.systemRed]
        }
    }

    @Test("Verspätete Syntaxfarben nach einer Kürzung färben nur vorhandene Zeichen")
    func shortenedStorage() throws {
        let view = TextView(string: "abcdefghijkl")
        let attributes = Attributes()
        let highlighter = Highlighter(textView: view, minimapView: nil, providers: [FourDHighlightProvider()],
                                      attributeProvider: attributes, language: .default)
        let storage = try #require(view.textStorage)
        // Ein bereits berechneter Stilbereich gehört noch zur längeren Fassung.
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "😀x")
        highlighter.styleContainerDidUpdate(in: NSRange(location: 0, length: 12))
        #expect(view.string == "😀x")
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemRed)
        highlighter.styleContainerDidUpdate(in: NSRange(location: 10, length: 2))
        highlighter.styleContainerDidUpdate(in: NSRange(location: NSNotFound, length: 1))
        #expect(view.string == "😀x")
    }

    @Test("Auch eine Kürzung während der Attributberechnung bleibt innerhalb des Speichers")
    func reentrantShortening() throws {
        let view = TextView(string: "abcdefghijkl")
        let attributes = Attributes()
        let highlighter = Highlighter(textView: view, minimapView: nil, providers: [FourDHighlightProvider()],
                                      attributeProvider: attributes, language: .default)
        let storage = try #require(view.textStorage)
        attributes.beforeAttributes = {
            attributes.beforeAttributes = nil
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "x")
        }
        highlighter.styleContainerDidUpdate(in: NSRange(location: 0, length: 12))
        #expect(view.string == "x")
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemRed)
    }
}
