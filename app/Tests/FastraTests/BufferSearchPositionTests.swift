import Foundation
import Testing
@testable import Fastra

@Test("Fortlaufende Trefferpositionen entsprechen dem vollständigen Zeilenindex",
      arguments: ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"])
func incrementalSearchPositions(separator: String) {
    for suffix in ["", separator] {
        let text = "😀e\u{301}" + separator + "zweite" + separator + "Ende" + suffix
        let ns = text as NSString
        let starts = BufferSearch.collectLineStarts(in: ns)
        let options = SearchOptions(find: "(?s)(?=.)|$", replace: "", isRegex: true)
        for range in [NSRange(location: 0, length: ns.length),
                      NSRange(location: 4, length: ns.length - 4),
                      NSRange(location: ns.length, length: 0)] {
            let result = BufferSearch.find(in: text, options: options, searchRange: range)
            #expect(!result.matches.isEmpty)
            for match in result.matches {
                let expected = BufferSearch.lineColumn(forOffset: match.range.location,
                                                       lineStarts: starts)
                #expect(match.line == expected.line)
                #expect(match.column == expected.column)
                #expect(match.range.length == 0)
            }
        }
    }
}

@Test("Ein später Treffer bleibt während der Präfix-Zeilenzählung abbrechbar")
func incrementalSearchCancellation() {
    let text = String(repeating: "Zeile\n", count: 20_000) + "ENDE"
    var checks = 0
    let result = BufferSearch.find(in: text,
        options: SearchOptions(find: "ENDE", replace: "", isRegex: true),
        searchRange: NSRange(location: text.utf16.count - 4, length: 4),
        shouldCancel: { checks += 1; return checks >= 3 })
    #expect(result.matches.isEmpty)
    #expect(result.totalMatches == 0)
    #expect(checks >= 3)
}

@Test("Gemerkte Zeilengrenzen erhalten den Kontext an Umbrüchen und am Dateiende",
      arguments: ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"])
func cachedSearchRemainders(separator: String) {
    let text = "a😀e\u{301}abc" + separator + "def" + separator
    let ns = text as NSString
    // Nullbreite trifft auch innerhalb von CRLF und am EOF; der zweite
    // Ausdruck erzeugt zusätzlich Treffer über mehrere Zeilen hinweg.
    for pattern in ["(?s)(?=.)|$", "(?s).{1,4}"] {
        let options = SearchOptions(find: pattern, replace: "X", isRegex: true)
        let result = BufferSearch.find(in: text, options: options)
        let regex = try! NSRegularExpression(pattern: pattern)
        let original = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        #expect(result.totalMatches == original.count)
        #expect(result.matches.map(\.range) == original.map(\.range))
        for match in result.matches {
            var contentEnd = 0
            let afterMatch = NSMaxRange(match.range)
            // Unabhängige Foundation-Abfrage bei JEDEM Treffer wie vor der
            // Optimierung; damit fallen falsche Wiederverwendungen auf.
            ns.getLineStart(nil, end: nil, contentsEnd: &contentEnd,
                            for: NSRange(location: afterMatch, length: 0))
            #expect(match.lineRemainder == BufferSearch.lineRemainder(
                in: ns, from: afterMatch, to: contentEnd))
        }
    }
}

@Test("Restzeilen-Cache erhält Unicode-Kontext auch jenseits des Auswahlendes")
func cachedSearchLongUnicodeRemainders() {
    let text = String(repeating: "a😀e\u{301}", count: 200) + "\r\nEnde"
    let ns = text as NSString
    let range = NSRange(location: 0, length: 40)
    let result = BufferSearch.find(in: text,
        options: SearchOptions(find: "a", replace: "X", isRegex: false), searchRange: range)
    #expect(result.matches.count > 1)
    for match in result.matches {
        let afterMatch = NSMaxRange(match.range)
        var contentEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &contentEnd,
                        for: NSRange(location: afterMatch, length: 0))
        #expect(match.lineRemainder == BufferSearch.lineRemainder(
            in: ns, from: afterMatch, to: contentEnd))
        #expect(match.lineRemainder.hasSuffix("…"))
        #expect(match.lineRemainder.utf16.count > range.length)
        #expect(match.line == 1)
    }
}
