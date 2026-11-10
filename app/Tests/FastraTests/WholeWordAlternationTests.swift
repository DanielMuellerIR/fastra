import Foundation
import Testing
@testable import Fastra

@Test("Ganzwort begrenzt beide Regex-Alternativen bei Buffer-Suche und Ersetzung")
func wholeWordAlternation_searchAndReplace() {
    let text = "foobar xbar foo bar"
    let options = SearchOptions(find: "foo|bar", replace: "X",
                                isRegex: true, caseSensitive: true, wholeWord: true)
    let result = BufferSearch.find(in: text, options: options)
    #expect(result.invalidPatternMessage == nil)
    #expect(result.matches.map(\.matchText) == ["foo", "bar"])
    #expect(result.matches.map(\.range) == [NSRange(location: 12, length: 3),
                                         NSRange(location: 16, length: 3)])
    #expect(BufferSearch.applyReplacements(in: text, matches: result.matches)
        == "foobar xbar X X")
}

@Test("Ganzwort erhält die Capture-Nummern und nicht beteiligte Alternativgruppen")
func wholeWordAlternation_preservesCaptures() throws {
    let text = "foobar xbar foo bar"
    let options = SearchOptions(find: "(foo)|(bar)", replace: "$2/$1",
                                isRegex: true, caseSensitive: true, wholeWord: true)
    let plan = try SearchPlan(options: options)
    let captures = plan.regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
    #expect(captures.count == 2)
    let first = try #require(captures.first)
    let last = try #require(captures.last)
    #expect(first.numberOfRanges == 3)
    #expect(last.numberOfRanges == 3)
    #expect(first.range(at: 1) == NSRange(location: 12, length: 3))
    #expect(first.range(at: 2).location == NSNotFound)
    #expect(last.range(at: 1).location == NSNotFound)
    #expect(last.range(at: 2) == NSRange(location: 16, length: 3))
    let result = BufferSearch.find(in: text, options: options)
    #expect(result.matches.map(\.replacedText) == ["/foo", "bar/"])
    #expect(BufferSearch.applyReplacements(in: text, matches: result.matches)
        == "foobar xbar /foo bar/")
}

@Test("Ganzwort erhält literale Alternationszeichen und Wildcard-Captures")
func wholeWordAlternation_preservesLiteralAndWildcard() {
    let cases: [(String, String, String, String)] = [
        ("xfoo|bar foo|barx foo|bar", "foo|bar", "$1", "xfoo|bar foo|barx $1"),
        ("fABo\nxfABoz\nfCDo", "f*o", "<*>", "<AB>\nxfABoz\n<CD>"),
        ("fAB\no", "f**o", "<**>", "<AB\n>"),
    ]
    for (text, pattern, replacement, expected) in cases {
        let options = SearchOptions(find: pattern, replace: replacement,
                                    isRegex: false, caseSensitive: true, wholeWord: true)
        let result = BufferSearch.find(in: text, options: options)
        #expect(result.invalidPatternMessage == nil)
        #expect(BufferSearch.applyReplacements(in: text, matches: result.matches) == expected)
    }
}
