import Foundation
import AppKit
import CodeEditTextView
import Testing
@testable import Fastra

@Suite("Klammerblock auswählen")
struct BracketSelectionTests {
    @Test("Command-B gilt nur im Dokument und bewahrt andere Modifier und 4D-Makros")
    func keyboardRouting() {
        func route(_ modifiers: NSEvent.ModifierFlags = .command, document: Bool = true,
                   search: Bool = false, macros: Set<Character> = []) -> KeyRoute {
            KeyRouting.route(isKeyDown: true, modifierFlags: modifiers,
                charactersIgnoringModifiers: "b", keyCode: 11,
                isSearchWindowKey: search, isDocumentWindowKey: document,
                fourDMacroShortcuts: macros)
        }
        #expect(route() == .selectBracketBlockOrBold)
        #expect(route(document: false) == .passThrough)
        #expect(route(document: false, search: true) == .passThrough)
        for modifiers: NSEvent.ModifierFlags in [[], [.command, .shift], [.command, .option], [.command, .control]] {
            #expect(route(modifiers) == .passThrough)
        }
        #expect(route(macros: ["b"]) == .runFourDMacro("b"))
        #expect(KeyRouting.notificationName(for: .selectBracketBlockOrBold) == nil)
    }

    @Test("JSON-Objekt samt Klammern vor dem schließenden Begrenzer")
    func jsonObject() {
        let object = #"{"name":"😀", "literal":"} [ \\\" {", "nested":{"n":1}}"#
        let source = "[\n  \(object),\n  {}\n]"
        #expect((try? JSONSerialization.jsonObject(with: Data(source.utf8))) != nil)
        let expected = (source as NSString).range(of: object)
        #expect(BracketSelection.range(in: source,
            selection: NSRange(location: expected.upperBound - 1, length: 0)) == expected)
        #expect(BracketSelection.range(in: source,
            selection: NSRange(location: expected.location, length: 0)) == expected)
        #expect(BracketSelection.range(in: source,
            selection: NSRange(location: expected.upperBound, length: 0)) == expected)
    }

    @Test("Wiederholen erweitert von innen über das Objekt zum Array")
    func expands() {
        let source = #"[{"n":{"x":1}}]"#
        let inner = (source as NSString).range(of: #"{"x":1}"#)
        let object = NSRange(location: 1, length: source.utf16.count - 2)
        #expect(BracketSelection.range(in: source,
            selection: NSRange(location: inner.location + 2, length: 0)) == inner)
        #expect(BracketSelection.range(in: source, selection: inner) == object)
        #expect(BracketSelection.range(in: source, selection: object) == NSRange(location: 0, length: source.utf16.count))
        #expect(BracketSelection.range(in: source,
            selection: NSRange(location: 0, length: source.utf16.count)) == nil)
    }

    @Test("UTF-16, mehrere Zeilen und partielle Auswahl")
    func unicode() {
        let source = "😀 [\r\n{\"ä\": 2}, {\"b\": 3}\r\n]"
        let first = (source as NSString).range(of: #"{"ä": 2}"#)
        #expect(BracketSelection.range(in: source,
            selection: NSRange(location: first.location + 1, length: first.length - 2)) == first)
        let crossObjects = NSRange(location: first.location + 1, length: 15)
        #expect(BracketSelection.range(in: source, selection: crossObjects)
            == NSRange(location: 3, length: source.utf16.count - 3))
    }

    @Test("Maskierte Backslashes beenden eine JSON-Zeichenkette korrekt")
    func escapes() {
        let source = #"[{"path":"C:\\", "text":"\" } { [ ]"}]"#
        #expect(BracketSelection.range(in: source,
            selection: NSRange(location: source.utf16.count - 2, length: 0))
            == NSRange(location: 1, length: source.utf16.count - 2))
    }

    @Test("Leere und runde Blöcke", arguments: ["{}", "[]", "()", "(a[{}])"])
    func bracketTypes(source: String) {
        #expect(BracketSelection.range(in: source, selection: NSRange(location: 0, length: 0))
            == NSRange(location: 0, length: source.utf16.count))
    }

    @Test("Kein erfundener Partner bei fehlenden oder vertauschten Klammern",
          arguments: ["{", "}", "{[}]", "plain", #"{"x":"}"#, #""{}""#])
    func malformed(source: String) {
        #expect(BracketSelection.range(in: source,
            selection: NSRange(location: source.utf16.count / 2, length: 0)) == nil)
    }

    @Test("JavaScript-Strings und Kommentare verändern keine Blockgrenzen",
          arguments: ["const s = '}';", "// } ] (\n", "/* } ] ( */", "const s = `} ] (`;", "const s = /[}]/;"])
    func javascriptLexicalRanges(fragment: String) {
        let source = "function f() { \(fragment) work(); }"
        let expected = NSRange(location: 13, length: source.utf16.count - 13)
        let cursor = (source as NSString).range(of: "work").location
        #expect(BracketSelection.range(in: source, selection: NSRange(location: cursor, length: 0),
                                       language: .javascript) == expected)
    }

    @Test("Ungültige Editor-Auswahlen werden abgewiesen")
    func invalidRanges() {
        for selection in [NSRange(location: NSNotFound, length: 0),
                          NSRange(location: 3, length: 0), NSRange(location: 1, length: Int.max)] {
            #expect(BracketSelection.range(in: "{}", selection: selection) == nil)
        }
    }

    @Test("Template-Interpolation erweitert Objekt, Aufruf und Interpolation einzeln")
    func javascriptInterpolation() {
        let source = "function f() { return `literal } ${JSON.stringify({n: 1})} (`; }"
        let text = source as NSString
        let object = text.range(of: "{n: 1}")
        let call = text.range(of: "({n: 1})")
        let interpolation = text.range(of: "{JSON.stringify({n: 1})}")
        #expect(BracketSelection.range(in: source,
            selection: NSRange(location: text.range(of: "n: 1").location, length: 0), language: .javascript) == object)
        #expect(BracketSelection.range(in: source, selection: object, language: .javascript) == call)
        #expect(BracketSelection.range(in: source, selection: call, language: .javascript) == interpolation)
        #expect(BracketSelection.range(in: source, selection: interpolation, language: .javascript)
            == NSRange(location: 13, length: source.utf16.count - 13))
    }
}

private final class SelectionRedrawObserver: TextSelectionManagerDelegate {
    var visibleTextRange: NSRange? { nil }
    var invalidations = 0
    func setNeedsDisplay() { invalidations += 1 }
    func estimatedLineHeight() -> CGFloat { 16 }
}

extension BracketSelectionTests {
    @Test("Klammerauswahl invalidiert die Textfläche ohne Fensterwechsel")
    @MainActor
    func selectionRedrawsImmediately() throws {
        let source = "{\n  \"items\": [\n    {\"n\": 1}\n  ]\n}"
        let editor = TextView(string: source)
        let observer = SelectionRedrawObserver()
        let manager = TextSelectionManager(layoutManager: editor.layoutManager,
            textStorage: editor.textStorage, textView: editor, delegate: observer)
        let cursor = (source as NSString).range(of: "[").upperBound
        var selection = NSRange(location: cursor, length: 0)
        for _ in 0..<2 {
            selection = try #require(BracketSelection.range(in: source, selection: selection))
            observer.invalidations = 0
            manager.setSelectedRange(selection)
            #expect(manager.textSelections.first?.range == selection)
            #expect(observer.invalidations > 0, "Auswahlfläche bleibt bis zum Fensterwechsel veraltet")
        }
        #expect(editor.string == source)
    }
}
