import Foundation
import Testing
@testable import Fastra

@Suite("Menü-Beschriftungen mit fester Höchstlänge")
struct MenuLabelFitTests {
    @Test("Kurze Namen bleiben unverändert, lange werden mittig gekürzt")
    func shortensInTheMiddle() {
        #expect(MenuLabelFit.shortened("E-Mail", maxCharacters: 24) == "E-Mail")
        #expect(MenuLabelFit.shortened("  Datum  ", maxCharacters: 24) == "Datum")
        let long = String(repeating: "A", count: 30) + "-" + String(repeating: "Z", count: 30)
        let short = MenuLabelFit.shortened(long, maxCharacters: 24)
        #expect(short.count == 24)
        #expect(short.hasPrefix("AAAA"))
        #expect(short.hasSuffix("ZZZZ"))
        #expect(short.contains("…"))
    }

    @Test("Genau die Höchstlänge wird nicht gekürzt, ein Zeichen mehr schon")
    func boundary() {
        let exact = String(repeating: "x", count: 10)
        #expect(MenuLabelFit.shortened(exact, maxCharacters: 10) == exact)
        #expect(MenuLabelFit.shortened(exact + "y", maxCharacters: 10).count == 10)
    }

    @Test("Emoji und zusammengesetzte Zeichen zählen als ein Zeichen")
    func graphemes() {
        let flags = String(repeating: "🇩🇪", count: 20)
        let short = MenuLabelFit.shortened(flags, maxCharacters: 9)
        #expect(short.count == 9)
        #expect(!short.unicodeScalars.contains { $0.value == 0xFFFD })
    }
}
