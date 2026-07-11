import Foundation
import Testing
@testable import Fastra

// Tests für GroupRemoval — das „Gruppe löschen" der Suchmaske.
//
// Die RegexTokenization wird hier VON HAND gebaut (nicht über den
// Tokenizer): die Tests dokumentieren damit zugleich das erwartete
// Token-Format und bleiben vom Tokenizer unabhängig.

/// Baut eine minimale Tokenization für ein Pattern von Hand.
/// `groups`: (number, range, innerRange); `alternations`: Ranges der `|`.
/// `quantifiers`: Ranges der Quantifier-Tokens.
private func makeTokenization(groups: [(Int, NSRange, NSRange)],
                              alternations: [NSRange] = [],
                              quantifiers: [NSRange] = []) -> RegexTokenization {
    var tokens: [RegexToken] = []
    for r in alternations {
        tokens.append(RegexToken(kind: .alternation, range: r, text: "|"))
    }
    for r in quantifiers {
        tokens.append(RegexToken(kind: .quantifier, range: r, text: "+"))
    }
    let groupInfos = groups.map {
        CaptureGroupInfo(number: $0.0, name: nil, range: $0.1, innerRange: $0.2)
    }
    return RegexTokenization(tokens: tokens, groups: groupInfos, hasErrors: false)
}

@Test("remove löst eine einfache Gruppe auf und schiebt $N herunter")
func remove_simpleGroup() {
    // Pattern: (\w+)@(\w+)  — Gruppe 1 = {0,5}, Inhalt {1,3}; Gruppe 2 = {6,5}, Inhalt {7,3}
    let tok = makeTokenization(groups: [
        (1, NSRange(location: 0, length: 5), NSRange(location: 1, length: 3)),
        (2, NSRange(location: 6, length: 5), NSRange(location: 7, length: 3)),
    ])
    let result = GroupRemoval.remove(group: 1, pattern: "(\\w+)@(\\w+)",
                                     tokenization: tok, replacement: "$2-x")
    #expect(result != nil)
    #expect(result?.newPattern == "\\w+@(\\w+)")
    // $2 referenzierte die zweite Gruppe — nach dem Löschen von Gruppe 1
    // ist sie die erste → $1.
    #expect(result?.rewrittenReplacement == "$1-x")
}

@Test("remove einer benannten Gruppe entfernt den kompletten Präfix")
func remove_namedGroup() {
    // Pattern: (?<jahr>\d{4})  — 14 UTF-16-Einheiten gesamt:
    // Präfix `(?<jahr>` = 8, Inhalt `\d{4}` = {8,5}, Suffix `)` = 1.
    let pattern = "(?<jahr>\\d{4})"
    let tok = makeTokenization(groups: [
        (1, NSRange(location: 0, length: 14), NSRange(location: 8, length: 5)),
    ])
    let result = GroupRemoval.remove(group: 1, pattern: pattern,
                                     tokenization: tok, replacement: "")
    #expect(result?.newPattern == "\\d{4}")
}

@Test("remove verweigert, wenn das Replace-Template die Gruppe referenziert")
func remove_refusesWhenReferenced() {
    let tok = makeTokenization(groups: [
        (1, NSRange(location: 0, length: 5), NSRange(location: 1, length: 3)),
    ])
    let result = GroupRemoval.remove(group: 1, pattern: "(\\w+)",
                                     tokenization: tok, replacement: "[$1]")
    #expect(result == nil)
}

@Test("remove verweigert bei Quantifier direkt hinter der Gruppe")
func remove_refusesWhenQuantified() {
    // Pattern: (abc)+  — Quantifier-Token beginnt am Gruppen-Ende (5).
    let tok = makeTokenization(
        groups: [(1, NSRange(location: 0, length: 5), NSRange(location: 1, length: 3))],
        quantifiers: [NSRange(location: 5, length: 1)]
    )
    let result = GroupRemoval.remove(group: 1, pattern: "(abc)+",
                                     tokenization: tok, replacement: "")
    #expect(result == nil)
}

@Test("remove verweigert bei Alternation im Gruppen-Inhalt")
func remove_refusesOnAlternation() {
    // Pattern: (a|b)c  — `|` an Position 2 liegt im Inhalt {1,3}.
    let tok = makeTokenization(
        groups: [(1, NSRange(location: 0, length: 5), NSRange(location: 1, length: 3))],
        alternations: [NSRange(location: 2, length: 1)]
    )
    let result = GroupRemoval.remove(group: 1, pattern: "(a|b)c",
                                     tokenization: tok, replacement: "")
    #expect(result == nil)
}

@Test("remove erlaubt Alternation, wenn eine innere Gruppe sie abschirmt")
func remove_allowsShieldedAlternation() {
    // Pattern: ((a|b))  — äußere Gruppe 1 {0,7}/{1,5}, innere Gruppe 2 {1,5}/{2,3},
    // `|` an Position 3 liegt in der inneren Gruppe → äußere darf weg.
    let tok = makeTokenization(
        groups: [
            (1, NSRange(location: 0, length: 7), NSRange(location: 1, length: 5)),
            (2, NSRange(location: 1, length: 5), NSRange(location: 2, length: 3)),
        ],
        alternations: [NSRange(location: 3, length: 1)]
    )
    let result = GroupRemoval.remove(group: 1, pattern: "((a|b))",
                                     tokenization: tok, replacement: "")
    #expect(result?.newPattern == "(a|b)")
}

@Test("references erkennt $N exakt — $12 ist nicht $1")
func references_maximalDigits() {
    #expect(GroupRemoval.references("$12", group: 12) == true)
    #expect(GroupRemoval.references("$12", group: 1) == false)
    #expect(GroupRemoval.references("a$3b", group: 3) == true)
    #expect(GroupRemoval.references("kein Dollar", group: 1) == false)
}

@Test("references ignoriert escapte Dollars")
func references_ignoresEscaped() {
    // `\$1` ist ein literales „$1" im Ergebnis — keine Referenz.
    #expect(GroupRemoval.references("\\$1", group: 1) == false)
    // `\\$1` = literaler Backslash + echte Referenz.
    #expect(GroupRemoval.references("\\\\$1", group: 1) == true)
}

@Test("shiftReferencesDown schiebt nur Referenzen über der Schwelle")
func shift_down() {
    #expect(GroupRemoval.shiftReferencesDown(in: "$1 $2 $3", above: 1) == "$1 $1 $2")
    #expect(GroupRemoval.shiftReferencesDown(in: "$12", above: 2) == "$11")
    #expect(GroupRemoval.shiftReferencesDown(in: "$0 \\$5", above: 1) == "$0 \\$5")
}
