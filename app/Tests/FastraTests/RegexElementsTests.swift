// RegexElementsTests.swift
//
// Smoke-Tests für die Element-Picker-Bausteine: keine leeren Felder,
// eindeutige Symbole, und der eingefügte Text ergibt zusammen mit etwas
// Kontext einen kompilierbaren RegEx (fängt kaputte Insert-Gerüste).

import Testing
import Foundation
@testable import Fastra

@Test("Kein Baustein hat leere Felder")
func elements_noEmptyFields() {
    for e in RegexElements.all {
        #expect(!e.symbol.isEmpty)
        #expect(!e.insert.isEmpty)
        #expect(!e.hint.isEmpty)
    }
}

@Test("Symbole sind eindeutig")
func elements_uniqueSymbols() {
    let symbols = RegexElements.all.map(\.symbol)
    #expect(Set(symbols).count == symbols.count)
}

@Test("Eingefügter Token ergibt im Kontext einen gültigen RegEx",
      arguments: RegexElements.all)
func elements_insertCompiles(_ element: RegexElement) {
    // Quantifizierer/Alternative brauchen etwas davor — wir testen den
    // Token im Kontext eines vorangestellten Literals.
    let candidate = "a" + element.insert
    #expect(throws: Never.self) {
        _ = try NSRegularExpression(pattern: candidate)
    }
}
