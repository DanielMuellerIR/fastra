// WildcardWiringTests.swift
//
// Feature J Schritt 2 — verdrahtete Platzhalter-Suche. Testet NICHT die pure
// Übersetzung (das macht WildcardPatternTests), sondern die Verdrahtung in
// SearchOptions.usesWildcard + ApplyEngine.buildRegex/replacementTemplate über
// die echte Such-Engine (BufferSearch).

import Foundation
import Testing
@testable import Fastra

/// Plain-Modus-Optionen mit `*` (Platzhalter, sofern nicht literal).
private func wc(_ find: String, _ replace: String, literal: Bool = false) -> SearchOptions {
    SearchOptions(find: find, replace: replace, isRegex: false, treatWildcardLiterally: literal)
}

// MARK: - usesWildcard-Bedingung

@Test("usesWildcard: Plain + Stern + Schalter aus → true")
func usesWildcard_plainStarSwitchOff() {
    #expect(wc("*, the", "x").usesWildcard)
}

@Test("usesWildcard: ohne Stern → false")
func usesWildcard_noStar() {
    #expect(!wc("hallo", "x").usesWildcard)
}

@Test("usesWildcard: RegEx-Modus → false (Stern ist dort echte RegEx)")
func usesWildcard_regexMode() {
    #expect(!SearchOptions(find: "a*", replace: "x", isRegex: true).usesWildcard)
}

@Test("usesWildcard: Mini-Schalter wörtlich an -> false")
func usesWildcard_literalSwitch() {
    #expect(!wc("a*b", "x", literal: true).usesWildcard)
}

// MARK: - UI-Schalter-Invariante

@Test("∗ wörtlich ist nur im Plain-Modus mit Stern aktiv")
@MainActor
func wildcardLiteralOption_activationCondition() {
    let suite = "fastra.tests.wildcard-option.\(UUID().uuidString)"
    let ws = Workspace(defaults: UserDefaults(suiteName: suite)!)

    ws.findPattern = "a*b"
    ws.useRegex = true
    #expect(!ws.wildcardLiteralOptionIsEnabled)

    ws.useRegex = false
    #expect(ws.wildcardLiteralOptionIsEnabled)

    ws.findPattern = "ab"
    #expect(!ws.wildcardLiteralOptionIsEnabled)
}

@Test("∗ wörtlich wird ohne Stern und bei RegEx abgewählt")
@MainActor
func wildcardLiteralOption_invalidStateResetsSelection() {
    let suite = "fastra.tests.wildcard-reset.\(UUID().uuidString)"
    let ws = Workspace(defaults: UserDefaults(suiteName: suite)!)

    ws.useRegex = false
    ws.findPattern = "a*b"
    ws.treatWildcardLiterally = true
    ws.findPattern = "ab"
    #expect(!ws.treatWildcardLiterally)

    ws.findPattern = "a*b"
    ws.treatWildcardLiterally = true
    ws.useRegex = true
    #expect(!ws.treatWildcardLiterally)
}

// MARK: - End-to-End über BufferSearch

@Test("Kern-Fall: ring, The → The ring via *, the / The *")
func wiring_filmTitleCase() {
    let out = BufferSearch.replaceAll(in: "ring, The", options: wc("*, the", "The *"))
    #expect(out == "The ring")
}

@Test("Gierig: * fängt bis zum LETZTEN Anker-Vorkommen")
func wiring_greedy() {
    // „Hello, There, The" + „*, the" → Gruppe = „Hello, There".
    let out = BufferSearch.replaceAll(in: "Hello, There, The", options: wc("*, the", "<*>"))
    #expect(out == "<Hello, There>")
}

@Test("Stern matcht beliebigen Text (nicht nur literalen Stern)")
func wiring_starMatchesAnyText() {
    let out = BufferSearch.replaceAll(in: "axyzb", options: wc("a*b", "X"))
    #expect(out == "X")
}

@Test("Mini-Schalter wörtlich: Stern wird buchstäblich gesucht")
func wiring_literalStar() {
    // Mit Schalter trifft „a*b" NUR den literalen Text „a*b", nicht „axyzb".
    #expect(BufferSearch.replaceAll(in: "axyzb", options: wc("a*b", "X", literal: true)) == "axyzb")
    #expect(BufferSearch.replaceAll(in: "a*b", options: wc("a*b", "X", literal: true)) == "X")
}

@Test("Stern bleibt zeilenweise — springt nicht über \\n")
func wiring_perLine() {
    // „a*c" auf zwei Zeilen → zwei getrennte Treffer, kein zeilenübergreifender.
    let out = BufferSearch.replaceAll(in: "a1c\na2c", options: wc("a*c", "X"))
    #expect(out == "X\nX")
}

@Test("Mehrere Sterne → mehrere Gruppen, $1/$2 in Reihenfolge")
func wiring_multipleStars() {
    let out = BufferSearch.replaceAll(in: "a - b", options: wc("* - *", "* and *"))
    #expect(out == "a and b")
}

@Test("Sternloses Plain-Verhalten unverändert (Regressions-Schutz)")
func wiring_noStarUnchanged() {
    // Ohne Stern muss exakt der alte wörtliche Pfad greifen: „.“ ist literal.
    let out = BufferSearch.replaceAll(in: "a.b axb", options: wc("a.b", "X"))
    #expect(out == "X axb")
}
