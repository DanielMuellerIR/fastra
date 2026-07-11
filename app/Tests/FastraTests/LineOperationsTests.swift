import Foundation
import Testing
@testable import Fastra

// Tests für LineOperations — „Zeilen sortieren" und „Duplikate entfernen"
// aus dem Editor-Kontextmenü (v0.8).

// MARK: - expandToFullLines

@Test("expandToFullLines weitet eine Teil-Selektion auf ganze Zeilen aus")
func expand_partialSelection() {
    let text = "alpha\nbeta\ngamma"
    // Selektion „et" in „beta" (Zeile 2 beginnt bei 6).
    let expanded = LineOperations.expandToFullLines(in: text,
                                                    selection: NSRange(location: 7, length: 2))
    // Ganze Zeile „beta" = {6,4}, OHNE das \n dahinter.
    #expect(expanded == NSRange(location: 6, length: 4))
}

@Test("expandToFullLines über Zeilengrenzen nimmt alle berührten Zeilen")
func expand_acrossLines() {
    let text = "alpha\nbeta\ngamma"
    // Selektion von „pha" bis „be" → Zeilen 1+2.
    let expanded = LineOperations.expandToFullLines(in: text,
                                                    selection: NSRange(location: 2, length: 6))
    #expect(expanded == NSRange(location: 0, length: 10))   // „alpha\nbeta"
}

@Test("expandToFullLines ohne Selektion = ganzer Text")
func expand_emptySelection() {
    let text = "a\nb"
    let expanded = LineOperations.expandToFullLines(in: text,
                                                    selection: NSRange(location: 1, length: 0))
    #expect(expanded == NSRange(location: 0, length: 3))
}

// MARK: - sortLines

@Test("sortLines sortiert unsortierte Zeilen aufsteigend")
func sort_ascending() {
    let text = "gamma\nalpha\nbeta"
    let result = LineOperations.sortLines(in: text,
                                          selection: NSRange(location: 0, length: 0))
    #expect(result?.newText == "alpha\nbeta\ngamma")
    #expect(result?.lineCount == 3)
}

@Test("sortLines auf bereits sortierten Zeilen dreht die Reihenfolge um (Toggle)")
func sort_toggleDescending() {
    let text = "alpha\nbeta\ngamma"
    let result = LineOperations.sortLines(in: text,
                                          selection: NSRange(location: 0, length: 0))
    #expect(result?.newText == "gamma\nbeta\nalpha")
}

@Test("sortLines sortiert nur die selektierten Zeilen, Rest bleibt")
func sort_selectionOnly() {
    let text = "kopf\nzz\naa\nfuss"
    // Selektion über „zz\naa" (Position 5..<10).
    let result = LineOperations.sortLines(in: text,
                                          selection: NSRange(location: 5, length: 5))
    #expect(result?.newText == "kopf\naa\nzz\nfuss")
}

@Test("sortLines sortiert natürlich (a2 vor a10) wie der Finder")
func sort_naturalOrder() {
    let text = "a10\na2\na1"
    let result = LineOperations.sortLines(in: text,
                                          selection: NSRange(location: 0, length: 0))
    #expect(result?.newText == "a1\na2\na10")
}

@Test("sortLines mit weniger als 2 Zeilen liefert nil")
func sort_singleLine() {
    let result = LineOperations.sortLines(in: "einzeiler",
                                          selection: NSRange(location: 0, length: 0))
    #expect(result == nil)
}

@Test("sortLines erhält ein fehlendes End-Newline")
func sort_noTrailingNewline() {
    let text = "b\na"
    let result = LineOperations.sortLines(in: text,
                                          selection: NSRange(location: 0, length: 0))
    #expect(result?.newText == "a\nb")
    // Kein \n am Ende dazuerfunden.
    #expect(result?.newText.hasSuffix("\n") == false)
}

// MARK: - removeDuplicateLines

@Test("removeDuplicateLines behält das erste Vorkommen, Reihenfolge stabil")
func dedupe_keepsFirst() {
    let text = "b\na\nb\nc\na"
    let result = LineOperations.removeDuplicateLines(in: text,
                                                     selection: NSRange(location: 0, length: 0))
    #expect(result?.newText == "b\na\nc")
    #expect(result?.lineCount == 3)
}

@Test("removeDuplicateLines ohne Duplikate liefert nil")
func dedupe_noDuplicates() {
    let result = LineOperations.removeDuplicateLines(in: "a\nb\nc",
                                                     selection: NSRange(location: 0, length: 0))
    #expect(result == nil)
}

@Test("removeDuplicateLines wirkt nur im selektierten Bereich")
func dedupe_selectionOnly() {
    let text = "x\nx\ny\nx"
    // Selektion nur über die ersten beiden Zeilen „x\nx" = {0,3}.
    let result = LineOperations.removeDuplicateLines(in: text,
                                                     selection: NSRange(location: 0, length: 3))
    // Das dritte „x" (außerhalb der Selektion) bleibt.
    #expect(result?.newText == "x\ny\nx")
}

@Test("removeDuplicateLines unterscheidet exakt (Groß/Klein, Whitespace)")
func dedupe_exactComparison() {
    let text = "a\nA\na \na"
    let result = LineOperations.removeDuplicateLines(in: text,
                                                     selection: NSRange(location: 0, length: 0))
    // Nur das doppelte exakte „a" fliegt raus.
    #expect(result?.newText == "a\nA\na ")
}

// MARK: - CRLF-Robustheit

@Test("sortLines übersteht CRLF-Inhalt ohne Trenner-Verlust")
func sort_crlf() {
    let text = "b\r\na\r\nc"
    let result = LineOperations.sortLines(in: text,
                                          selection: NSRange(location: 0, length: 0))
    #expect(result?.newText == "a\r\nb\r\nc")
}
