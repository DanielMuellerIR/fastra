// CaseTemplateTests.swift
//
// Sichert die BBEdit-Case-Operatoren im Ersetzungsmuster ab
// (\U \L \u \l \E — Handbuch 16.0.1, Kap. 8 S. 216). Getestet wird
// sowohl die pure Zerlege-/Expansions-Logik (CaseTemplate) als auch
// die Verdrahtung durch BufferSearch (Treffer-Vorschau + Alle ersetzen).

import Testing
import Foundation
@testable import Fastra

// MARK: - Hilfen

/// Kürzel: RegEx-Suche mit Case-Sensitivität (damit die erwartete
/// Schreibweise im Ergebnis eindeutig vom Operator kommt, nicht vom Match).
private func regexOptions(_ find: String, _ replace: String) -> SearchOptions {
    SearchOptions(find: find, replace: replace, isRegex: true, caseSensitive: false)
}

/// Führt „Alle ersetzen" über BufferSearch aus und liefert das Ergebnis.
private func replaceAll(_ text: String, _ find: String, _ replace: String) -> String? {
    BufferSearch.replaceAll(in: text, options: regexOptions(find, replace))
}

// MARK: - Parser

@Test("Template ohne Operatoren wird als ein Text-Stück erkannt")
func pieces_plainTemplate() {
    #expect(CaseTemplate.pieces(of: "$2 $1") == [.text("$2 $1")])
    #expect(CaseTemplate.containsOperators("$2 $1") == false)
}

@Test("Escaptes \\\\U ist KEIN Operator (literaler Backslash + U)")
func pieces_escapedBackslashIsNoOperator() {
    // Eingabe im Feld: \\U → Template-Escape für literales „\U".
    #expect(CaseTemplate.containsOperators("\\\\Ups") == false)
}

@Test("Einsamer Backslash am Ende bleibt literal erhalten")
func pieces_trailingBackslash() {
    #expect(CaseTemplate.pieces(of: "abc\\") == [.text("abc\\")])
}

@Test("Operatoren werden zwischen Text-Stücken erkannt")
func pieces_mixedTemplate() {
    let p = CaseTemplate.pieces(of: "a\\U$1\\Eb")
    #expect(p == [.text("a"), .upperAll, .text("$1"), .end, .text("b")])
}

// MARK: - \U / \L (dauerhaft bis \E)

@Test("\\U macht Backref-Inhalt GROSS, \\E beendet")
func upperAll_untilEnd() {
    let out = replaceAll("Müller, Daniel", "(\\w+), (\\w+)", "\\U$2\\E $1")
    #expect(out == "DANIEL Müller")
}

@Test("\\L macht alles Folgende klein — auch über mehrere Backrefs")
func lowerAll_spansBackrefs() {
    let out = replaceAll("ABC DEF", "(\\w+) (\\w+)", "\\L$1-$2")
    #expect(out == "abc-def")
}

@Test("Ohne \\E wirkt \\U bis zum Template-Ende")
func upperAll_runsToEnd() {
    let out = replaceAll("hallo", "(hallo)", "\\U$1 welt")
    #expect(out == "HALLO WELT")
}

@Test("Neuer Operator ersetzt den alten ohne \\E")
func modeSwitch_withoutEnd() {
    let out = replaceAll("Hallo Welt", "(\\w+) (\\w+)", "\\U$1 \\L$2")
    // Achtung: das Leerzeichen zwischen den Backrefs gehört noch zum \U-Lauf.
    #expect(out == "HALLO welt")
}

// MARK: - \u / \l (genau ein Zeichen)

@Test("\\u macht nur das ERSTE Zeichen des Folgetexts groß")
func upperNext_firstCharOnly() {
    let out = replaceAll("daniel", "(\\w+)", "\\u$1")
    #expect(out == "Daniel")
}

@Test("\\l macht nur das erste Zeichen klein")
func lowerNext_firstCharOnly() {
    let out = replaceAll("DANIEL", "(\\w+)", "\\l$1")
    #expect(out == "dANIEL")
}

@Test("\\u überträgt sich auf das nächste NICHT-leere Segment (leere Gruppe)")
func upperNext_carriesOverEmptyExpansion() {
    // Gruppe 1 matcht leer ((x?) vor „daniel" ohne x) → \u muss am
    // ersten echten Ausgabezeichen (aus $2) greifen.
    let out = replaceAll("daniel", "(x?)(\\w+)", "\\u$1$2")
    #expect(out == "Daniel")
}

@Test("\\u wirkt Graphem-sicher (Umlaut bleibt EIN Zeichen)")
func upperNext_umlaut() {
    let out = replaceAll("über", "(\\w+)", "\\u$1")
    #expect(out == "Über")
}

@Test("\\u kombiniert mit laufendem \\L: erstes Zeichen groß, Rest klein")
func upperNext_insideLowerAll() {
    let out = replaceAll("MÜLLER", "(\\w+)", "\\L\\u$1")
    #expect(out == "Müller")
}

// MARK: - Abgrenzung Plain-/Platzhalter-Modus

@Test("Plain-Modus: \\U im Ersetzen-Feld bleibt LITERAL (kein Operator)")
func plainMode_backslashUStaysLiteral() {
    let out = BufferSearch.replaceAll(
        in: "foo", options: SearchOptions(find: "foo", replace: "\\Ubar",
                                          isRegex: false, caseSensitive: true))
    #expect(out == "\\Ubar")
}

@Test("Platzhalter-Modus: \\U bleibt literal, * funktioniert weiter")
func wildcardMode_backslashUStaysLiteral() {
    let out = BufferSearch.replaceAll(
        in: "ring, The", options: SearchOptions(find: "*, The", replace: "\\U The *",
                                                isRegex: false, caseSensitive: false))
    #expect(out == "\\U The ring")
}

// MARK: - Verdrahtung: Treffer-Vorschau (find) und ApplyEngine-Pfad

@Test("Treffer-Vorschau (replacedText) zeigt die Case-Transformation")
func find_previewShowsTransformedText() {
    let r = BufferSearch.find(in: "Müller, Daniel",
                              options: regexOptions("(\\w+), (\\w+)", "\\U$2\\E $1"))
    #expect(r.matches.count == 1)
    #expect(r.matches.first?.replacedText == "DANIEL Müller")
}

@Test("Alle ersetzen ohne Operatoren bleibt unverändert (Fast Path)")
func replaceAll_fastPathUnchanged() {
    let out = replaceAll("Müller, Daniel", "(\\w+), (\\w+)", "$2 $1")
    #expect(out == "Daniel Müller")
}

@Test("Mehrere Treffer werden einzeln transformiert, Zwischentext bleibt")
func replaceAll_multipleMatchesKeepGaps() {
    let out = replaceAll("ab und cd", "(\\w)(\\w)", "\\u$1\\l$2")
    #expect(out == "Ab Und Cd")
}
