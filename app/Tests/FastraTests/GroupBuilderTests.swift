// GroupBuilderTests.swift
//
// Tests für die geführte Capture-Group-Definition (GroupBuilder.swift,
// Suchmasken-Konzept §3+§4). Das ist die korrektheitskritischste Logik der
// Phase 3 — der Nutzer baut hier ohne RegEx-Wissen Gruppen, und ein Fehler
// würde ein kaputtes Pattern erzeugen.
//
// WICHTIG — Unabhängigkeit vom Tokenizer:
// Die folgenden Unit-Fixtures verwenden den echten `RegexTokenizer` bewusst
// nicht; der Integrationstest zur Referenzverschiebung prüft ihn zusätzlich. Stattdessen konstruieren diese Tests die `RegexTokenization` mit
// einem kleinen Hand-Tokenizer (`HandTok`) von Hand. Das macht die Tests
// unabhängig vom Tokenizer-Stand UND dokumentiert zugleich das exakte
// Token-Format, das GroupBuilder erwartet (flach, sortiert, lückenlos).

import Testing
import Foundation
@testable import Fastra

// MARK: - Hand-Tokenizer (nur für diese Tests)

/// Mini-Helfer, der aus einer geordneten Liste von (Text, Kind)-Stücken
/// eine `RegexTokenization` baut: berechnet die UTF-16-Ranges sequenziell
/// (lückenlos, sortiert) und leitet die fangenden Gruppen aus den Klammer-
/// Delimitern ab. Deckt nur die einfache Teilmenge der Testpatterns ab.
private enum HandTok {

    /// Ein Stück Pattern für den Hand-Tokenizer.
    struct Piece {
        let text: String
        let kind: RegexTokenKind
        init(_ text: String, _ kind: RegexTokenKind) {
            self.text = text
            self.kind = kind
        }
    }

    /// Baut die `RegexTokenization`. `pattern` dient nur der Verifikation,
    /// dass die zusammengesetzten Stücke wirklich das Pattern ergeben.
    static func tokenize(_ pattern: String, _ pieces: [Piece]) -> RegexTokenization {
        // 1. Tokens mit fortlaufenden UTF-16-Ranges bauen.
        var tokens: [RegexToken] = []
        var loc = 0
        for p in pieces {
            let len = (p.text as NSString).length
            tokens.append(RegexToken(kind: p.kind,
                                     range: NSRange(location: loc, length: len),
                                     text: p.text))
            loc += len
        }
        // Sanity: zusammengesetzte Stücke == Pattern (fängt Tippfehler in den
        // Testdaten).
        let assembled = pieces.map(\.text).joined()
        precondition(assembled == pattern,
                     "HandTok: Stücke ergeben '\(assembled)', erwartet '\(pattern)'")

        // 2. Fangende Gruppen aus den Klammern ableiten (Klammer-Balance).
        //    Eine öffnende Klammer ist fangend, wenn ihr Delimiter-Text `(`
        //    oder `(?<name>` ist (nicht `(?:`/`(?=`/...).
        var groups: [CaptureGroupInfo] = []
        var stack: [(openIndex: Int, number: Int?)] = []
        var number = 0
        for (i, t) in tokens.enumerated() where t.kind == .groupDelimiter {
            if t.text.hasPrefix("(") && !t.text.contains(")") {
                let capturing = isCapturingOpen(t.text)
                if capturing { number += 1 }
                stack.append((i, capturing ? number : nil))
            } else if t.text.contains(")") {
                guard let open = stack.popLast() else { continue }
                if let groupNumber = open.number {
                    let openTok = tokens[open.openIndex]
                    let closeTok = t
                    let groupStart = openTok.range.location
                    let groupEnd = closeTok.range.location + closeTok.range.length
                    let innerStart = openTok.range.location + openTok.range.length
                    let innerEnd = closeTok.range.location
                    groups.append(CaptureGroupInfo(
                        number: groupNumber,
                        name: groupName(openTok.text),
                        range: NSRange(location: groupStart, length: groupEnd - groupStart),
                        innerRange: NSRange(location: innerStart, length: innerEnd - innerStart)))
                }
            }
        }
        // Die Nummer entsteht beim Öffnen, die Range erst beim Schließen.
        // Nach Nummer sortieren, damit äußere Gruppen vor ihren inneren stehen.
        groups.sort { $0.number < $1.number }

        return RegexTokenization(tokens: tokens, groups: groups, hasErrors: false)
    }

    /// Fangend = `(` oder benannt `(?<name>`/`(?P<name>` — aber NICHT
    /// `(?:`, `(?=`, `(?!`, `(?<=`, `(?<!`.
    private static func isCapturingOpen(_ delim: String) -> Bool {
        if delim == "(" { return true }
        if delim.hasPrefix("(?<") {
            // Lookbehind `(?<=` / `(?<!` ausschließen.
            let after = delim.dropFirst(3)
            return after.first != "=" && after.first != "!"
        }
        if delim.hasPrefix("(?P<") { return true }
        return false
    }

    private static func groupName(_ delim: String) -> String? {
        // `(?<name>` → „name". Sonst nil. Nur grob, reicht für Tests.
        guard delim.hasPrefix("(?<"), delim.hasSuffix(">") else { return nil }
        return String(delim.dropFirst(3).dropLast())
    }
}

// Bequeme Kurzschreibweise für Piece.
private func p(_ text: String, _ kind: RegexTokenKind) -> HandTok.Piece {
    HandTok.Piece(text, kind)
}

// MARK: - Wiederverwendete Token-Layouts

private extension HandTok {
    /// `(\w+)@(\w+)\.de` — der E-Mail-Klassiker aus der Layout-Skizze.
    static var emailTok: RegexTokenization {
        tokenize("(\\w+)@(\\w+)\\.de", [
            p("(", .groupDelimiter), p("\\w", .characterClass), p("+", .quantifier), p(")", .groupDelimiter),
            p("@", .literal),
            p("(", .groupDelimiter), p("\\w", .characterClass), p("+", .quantifier), p(")", .groupDelimiter),
            p("\\.", .escape),
            p("de", .literal),
        ])
    }
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: - Unit-Bildung (Schritt 1)
// ─────────────────────────────────────────────────────────────────────────

@Test("E-Mail-Pattern → 5 Units, beide Gruppen erkannt")
func units_emailFive() {
    let tok = HandTok.emailTok
    let units = GroupBuilder.units(pattern: "(\\w+)@(\\w+)\\.de", tokenization: tok,
                                   matchText: "anna@test.de", caseSensitive: false)
    #expect(units != nil)
    #expect(units?.count == 5)
    // Unit 0 und 2 sind die bestehenden Gruppen 1 und 2.
    #expect(units?[0].isExistingGroup == true)
    #expect(units?[0].existingGroupNumber == 1)
    #expect(units?[2].isExistingGroup == true)
    #expect(units?[2].existingGroupNumber == 2)
    // `@`, `\.`, `de` sind keine Gruppen.
    #expect(units?[1].isExistingGroup == false)
    #expect(units?[3].isExistingGroup == false)
    #expect(units?[4].isExistingGroup == false)
}

@Test("`\\d+abc?` → Units `\\d+`, `ab`, `c?` (Quantifier bindet nur letztes Zeichen)")
func units_quantifierBindsLastChar() {
    let pattern = "\\d+abc?"
    let tok = HandTok.tokenize(pattern, [
        p("\\d", .characterClass), p("+", .quantifier),
        p("abc", .literal), p("?", .quantifier),
    ])
    let units = GroupBuilder.units(pattern: pattern, tokenization: tok,
                                   matchText: "5ab", caseSensitive: false)
    #expect(units != nil)
    #expect(units?.count == 3)
    // patternRange-Längen prüfen: `\d+` = 3, `ab` = 2, `c?` = 2.
    #expect(units?[0].patternRange.length == 3)   // \d+
    #expect(units?[1].patternRange.length == 2)   // ab
    #expect(units?[2].patternRange.length == 2)   // c?
}

@Test("`^foo$` → Anker sind zero-width, `foo` nicht")
func units_anchorsZeroWidth() {
    let pattern = "^foo$"
    let tok = HandTok.tokenize(pattern, [
        p("^", .anchor), p("foo", .literal), p("$", .anchor),
    ])
    let units = GroupBuilder.units(pattern: pattern, tokenization: tok,
                                   matchText: "foo", caseSensitive: false)
    #expect(units != nil)
    #expect(units?.count == 3)
    #expect(units?[0].isZeroWidth == true)
    #expect(units?[1].isZeroWidth == false)
    #expect(units?[2].isZeroWidth == true)
    // Anker haben keinen Match-Beitrag.
    #expect(units?[0].matchRange == nil)
    #expect(units?[2].matchRange == nil)
}

@Test("Top-Level-Alternation `a|b` → genau 1 Unit (v1.0-Einschränkung)")
func units_topLevelAlternationSingleUnit() {
    let pattern = "a|b"
    let tok = HandTok.tokenize(pattern, [
        p("a", .literal), p("|", .alternation), p("b", .literal),
    ])
    let units = GroupBuilder.units(pattern: pattern, tokenization: tok,
                                   matchText: "a", caseSensitive: false)
    #expect(units?.count == 1)
    #expect(units?[0].patternRange == NSRange(location: 0, length: 3))
}

@Test("Alternation in Gruppe `(a|b)c` → 2 Units, Gruppe bleibt eine Einheit")
func units_alternationInsideGroup() {
    let pattern = "(a|b)c"
    let tok = HandTok.tokenize(pattern, [
        p("(", .groupDelimiter), p("a", .literal), p("|", .alternation), p("b", .literal), p(")", .groupDelimiter),
        p("c", .literal),
    ])
    let units = GroupBuilder.units(pattern: pattern, tokenization: tok,
                                   matchText: "ac", caseSensitive: false)
    #expect(units?.count == 2)
    #expect(units?[0].isExistingGroup == true)
    #expect(units?[0].existingGroupNumber == 1)
    #expect(units?[1].isExistingGroup == false)
}

@Test("Quantifizierte Gruppe `(\\w)+` ist NICHT isExistingGroup")
func units_quantifiedGroupNotReusable() {
    let pattern = "(\\w)+"
    let tok = HandTok.tokenize(pattern, [
        p("(", .groupDelimiter), p("\\w", .characterClass), p(")", .groupDelimiter), p("+", .quantifier),
    ])
    let units = GroupBuilder.units(pattern: pattern, tokenization: tok,
                                   matchText: "abc", caseSensitive: false)
    #expect(units?.count == 1)
    // Die Gruppe MIT folgendem Quantifier ist als Ganzes keine wiederverwendbare
    // Gruppe — sonst würde `(\w)+` zerteilt.
    #expect(units?[0].isExistingGroup == false)
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: - Re-Match-Beiträge (Schritte 2+3)
// ─────────────────────────────────────────────────────────────────────────

@Test("E-Mail-Match `anna@test.de`: Unit-Beiträge anna / @ / test / . / de")
func rematch_emailContributions() {
    let tok = HandTok.emailTok
    let text = "anna@test.de"
    let ns = text as NSString
    let units = GroupBuilder.units(pattern: "(\\w+)@(\\w+)\\.de", tokenization: tok,
                                   matchText: text, caseSensitive: false)
    #expect(units != nil)
    guard let u = units, u.count == 5 else { return }

    // Jeden Beitrag als Substring zurücklesen und vergleichen.
    func sub(_ r: NSRange?) -> String? { r.map { ns.substring(with: $0) } }
    #expect(sub(u[0].matchRange) == "anna")
    #expect(sub(u[1].matchRange) == "@")
    #expect(sub(u[2].matchRange) == "test")
    #expect(sub(u[3].matchRange) == ".")
    #expect(sub(u[4].matchRange) == "de")
}

@Test("Optional ohne Beitrag: `colou?r` gegen `color` → `u?`-Unit ohne Beitrag")
func rematch_optionalNoContribution() {
    // colou?r → Tokens: c, o, l, o, u, ?, r — aber der Tokenizer liefert
    // Literale gröber. Wir geben ein einzelnes „colo"+„u"+„?"+„r"-Layout,
    // damit `u?` eine eigene Unit wird (letztes Zeichen vor Quantifier).
    let pattern = "colou?r"
    let tok = HandTok.tokenize(pattern, [
        p("colou", .literal), p("?", .quantifier), p("r", .literal),
    ])
    let text = "color"
    let ns = text as NSString
    let units = GroupBuilder.units(pattern: pattern, tokenization: tok,
                                   matchText: text, caseSensitive: false)
    #expect(units != nil)
    // Units: `colo` (head), `u?` (last+quant), `r`.
    #expect(units?.count == 3)
    func sub(_ r: NSRange?) -> String? { r.map { ns.substring(with: $0) } }
    #expect(sub(units?[0].matchRange) == "colo")
    // `u?` hat in „color" nichts beigetragen → matchRange == nil.
    #expect(units?[1].matchRange == nil)
    #expect(sub(units?[2].matchRange) == "r")
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: - Snap (Schritt 4)
// ─────────────────────────────────────────────────────────────────────────

@Test("Selektion mitten in `anna` snappt auf ganz `anna`")
func snap_insideAnna() {
    let tok = HandTok.emailTok
    let text = "anna@test.de"
    // Selektion „nn" (Indizes 1..3) mitten im ersten Wort.
    let prop = GroupBuilder.propose(selection: NSRange(location: 1, length: 2),
                                    pattern: "(\\w+)@(\\w+)\\.de", tokenization: tok,
                                    matchText: text, replacement: "", caseSensitive: false)
    #expect(prop != nil)
    // „anna" = location 0, length 4.
    #expect(prop?.snappedMatchRange == NSRange(location: 0, length: 4))
}

@Test("Selektion `nna@te` snappt über drei Units auf `anna@test`")
func snap_acrossUnits() {
    let tok = HandTok.emailTok
    let text = "anna@test.de"   // a n n a @ t e s t . d e
    // „nna@te" = Indizes 1..7 (length 6).
    let prop = GroupBuilder.propose(selection: NSRange(location: 1, length: 6),
                                    pattern: "(\\w+)@(\\w+)\\.de", tokenization: tok,
                                    matchText: text, replacement: "", caseSensitive: false)
    #expect(prop != nil)
    // Snappt auf „anna@test" = location 0, length 9.
    #expect(prop?.snappedMatchRange == NSRange(location: 0, length: 9))
}

@Test("Leere Selektion (Cursor) in `test` snappt auf `test`")
func snap_emptySelectionInTest() {
    let tok = HandTok.emailTok
    let text = "anna@test.de"   // „test" = Indizes 5..9
    // Cursor bei Index 7 (mitten in „test"), Länge 0.
    let prop = GroupBuilder.propose(selection: NSRange(location: 7, length: 0),
                                    pattern: "(\\w+)@(\\w+)\\.de", tokenization: tok,
                                    matchText: text, replacement: "", caseSensitive: false)
    #expect(prop != nil)
    #expect(prop?.snappedMatchRange == NSRange(location: 5, length: 4))
}

@Test("Leere Selektion exakt auf Unit-Grenze → RECHTE Unit gewinnt (§4 Tie-Break)")
func snap_emptySelectionOnBoundaryPicksRight() {
    let tok = HandTok.emailTok
    let text = "anna@test.de"   // „anna"=0..4, „@"=4..5
    // Cursor bei Index 4 — genau die Grenze zwischen „anna" (endet bei 4)
    // und „@" (beginnt bei 4). Das Konzept bricht den Gleichstand zugunsten
    // der RECHTEN Unit auf → es snappt auf „@", nicht auf „anna".
    let prop = GroupBuilder.propose(selection: NSRange(location: 4, length: 0),
                                    pattern: "(\\w+)@(\\w+)\\.de", tokenization: tok,
                                    matchText: text, replacement: "", caseSensitive: false)
    #expect(prop != nil)
    #expect(prop?.snappedMatchRange == NSRange(location: 4, length: 1))
}

@Test("Snap über beitragslose Unit hinweg: `colou?r`/`color`, Selektion `olor`")
func snap_overEmptyOptional() {
    let pattern = "colou?r"
    let tok = HandTok.tokenize(pattern, [
        p("colou", .literal), p("?", .quantifier), p("r", .literal),
    ])
    let text = "color"   // c o l o r  (5 Zeichen, kein „u")
    // Selektion „lor" = Indizes 2..5 (length 3) — überspannt `colo`-Rest,
    // die beitragslose `u?` und `r`.
    let prop = GroupBuilder.propose(selection: NSRange(location: 2, length: 3),
                                    pattern: pattern, tokenization: tok,
                                    matchText: text, replacement: "", caseSensitive: false)
    #expect(prop != nil)
    // Snappt auf „color" minus Kopf: „lor" liegt in `colo`(0..4) + `r`(4..5);
    // die `u?` dazwischen trägt nichts bei → Snapped umfasst „lor" → „lor"
    // beginnt bei 2, deckt `colo`-Teil (bis 4) und `r` (4..5) → Vereinigung
    // 2..5 = „lor". Aber die Unit `colo` trägt 0..4 bei → Snap auf GANZE
    // beitragende Units: „colo"(0..4) ∪ „r"(4..5) = „color"(0..5).
    #expect(prop?.snappedMatchRange == NSRange(location: 0, length: 5))
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: - Proposal (Schritt 5)
// ─────────────────────────────────────────────────────────────────────────

@Test("Selektion `de` → newPattern `(\\w+)@(\\w+)\\.(de)`, Gruppe 3, $-Refs bleiben")
func proposal_deBecomesGroup3() {
    let tok = HandTok.emailTok
    let text = "anna@test.de"   // „de" = Indizes 10..12
    let prop = GroupBuilder.propose(selection: NSRange(location: 10, length: 2),
                                    pattern: "(\\w+)@(\\w+)\\.de", tokenization: tok,
                                    matchText: text, replacement: "[$1]($2)", caseSensitive: false)
    #expect(prop != nil)
    #expect(prop?.newPattern == "(\\w+)@(\\w+)\\.(de)")
    #expect(prop?.newGroupNumber == 3)
    #expect(prop?.isAlreadyGroup == false)
    // $1 und $2 liegen UNTER 3 → bleiben unverändert.
    #expect(prop?.rewrittenReplacement == "[$1]($2)")
}

@Test("Selektion `@` → newPattern `(\\w+)(@)(\\w+)\\.de`, Gruppe 2, $2→$3")
func proposal_atBecomesGroup2() {
    let tok = HandTok.emailTok
    let text = "anna@test.de"   // „@" = Index 4..5
    let prop = GroupBuilder.propose(selection: NSRange(location: 4, length: 1),
                                    pattern: "(\\w+)@(\\w+)\\.de", tokenization: tok,
                                    matchText: text, replacement: "$1-$2", caseSensitive: false)
    #expect(prop != nil)
    #expect(prop?.newPattern == "(\\w+)(@)(\\w+)\\.de")
    #expect(prop?.newGroupNumber == 2)
    // Die bestehende Gruppe 2 (zweites `\w+`) rückt auf 3 → $2 wird $3, $1 bleibt.
    #expect(prop?.rewrittenReplacement == "$1-$3")
}

@Test("isAlreadyGroup: Selektion exakt `anna` wenn `(\\w+)` schon Gruppe 1")
func proposal_alreadyGroup() {
    let tok = HandTok.emailTok
    let text = "anna@test.de"   // „anna" = Indizes 0..4
    let prop = GroupBuilder.propose(selection: NSRange(location: 0, length: 4),
                                    pattern: "(\\w+)@(\\w+)\\.de", tokenization: tok,
                                    matchText: text, replacement: "$1+$2", caseSensitive: false)
    #expect(prop != nil)
    #expect(prop?.isAlreadyGroup == true)
    #expect(prop?.newGroupNumber == 1)
    // Pattern und Replacement bleiben unverändert.
    #expect(prop?.newPattern == "(\\w+)@(\\w+)\\.de")
    #expect(prop?.rewrittenReplacement == "$1+$2")
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: - shiftBackreferencesUp (Schritt 5c, pur)
// ─────────────────────────────────────────────────────────────────────────

@Test("shift `$1 $2 $12` atOrAbove 2 → `$1 $3 $13`")
func shift_basic() {
    let out = GroupBuilder.shiftBackreferencesUp(in: "$1 $2 $12", atOrAbove: 2)
    #expect(out == "$1 $3 $13")
}

@Test("shift: escapter `\\$2` bleibt, `$0` bleibt")
func shift_escapedAndZero() {
    #expect(GroupBuilder.shiftBackreferencesUp(in: "\\$2", atOrAbove: 1) == "\\$2")
    #expect(GroupBuilder.shiftBackreferencesUp(in: "$0", atOrAbove: 1) == "$0")
    // Gemischt: $0 bleibt, $1 (>=1) wird $2, \$3 bleibt literal.
    #expect(GroupBuilder.shiftBackreferencesUp(in: "$0-$1-\\$3", atOrAbove: 1) == "$0-$2-\\$3")
}

@Test("shift: zweistellige Nummern korrekt (`$12` ist Gruppe 12)")
func shift_twoDigit() {
    // atOrAbove 12 → $12 wird $13, $11 bleibt.
    #expect(GroupBuilder.shiftBackreferencesUp(in: "$11 $12", atOrAbove: 12) == "$11 $13")
    // atOrAbove 5 → beide >= 5 → +1.
    #expect(GroupBuilder.shiftBackreferencesUp(in: "$11 $12", atOrAbove: 5) == "$12 $13")
}

@Test("shift: Text ohne Backrefs bleibt 1:1")
func shift_noBackrefs() {
    #expect(GroupBuilder.shiftBackreferencesUp(in: "hello world", atOrAbove: 1) == "hello world")
    #expect(GroupBuilder.shiftBackreferencesUp(in: "Preis: 5 EUR", atOrAbove: 1) == "Preis: 5 EUR")
}

@Test("Neue Gruppe erhält die Ersetzung nach einem literalen Backslash")
func proposal_preservesReferenceAfterLiteralBackslash() throws {
    let pattern = "(a)b(c)"
    let replacement = #"\\$2"#
    let proposal = try #require(GroupBuilder.propose(
        selection: NSRange(location: 1, length: 1),
        pattern: pattern, tokenization: RegexTokenizer.tokenize(pattern),
        matchText: "abc", replacement: replacement, caseSensitive: true))
    #expect(proposal.newPattern == "(a)(b)(c)")
    #expect(proposal.rewrittenReplacement == #"\\$3"#)
    let regex = try NSRegularExpression(pattern: proposal.newPattern)
    let result = regex.stringByReplacingMatches(
        in: "abc", range: NSRange(location: 0, length: 3),
        withTemplate: proposal.rewrittenReplacement)
    #expect(result == #"\c"#)
}

@Test("Referenzverschiebung berücksichtigt gerade und ungerade Backslash-Zahlen",
      arguments: 0...4)
func shift_backslashParity(_ count: Int) {
    let prefix = String(repeating: "\\", count: count)
    let shifted = GroupBuilder.shiftBackreferencesUp(in: prefix + "$2", atOrAbove: 2)
    #expect(shifted == prefix + (count.isMultiple(of: 2) ? "$3" : "$2"))
    // Das Entfernen der zuvor eingefügten Gruppe muss dieselben Referenzen
    // erkennen und das ursprüngliche Template wiederherstellen.
    #expect(GroupRemoval.shiftReferencesDown(in: shifted, above: 2) == prefix + "$2")
}

@Test("Nicht verschiebbare Gruppennummern bleiben ohne Überlauf erhalten")
func shift_unrepresentableReferencesStayUnchanged() {
    for input in ["$\(Int.max)", "$999999999999999999999999999999", "$²", "$٠"] {
        #expect(GroupBuilder.shiftBackreferencesUp(in: input, atOrAbove: 1) == input)
    }
    #expect(GroupBuilder.shiftBackreferencesUp(in: "$01 $0", atOrAbove: 2) == "$01 $0")
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: - Sonderfälle: Emoji, caseSensitive, nicht zuordenbar
// ─────────────────────────────────────────────────────────────────────────

@Test("Emoji im Match-Text (Surrogatpaar) — Snap-Ranges in UTF-16 korrekt")
func emoji_utf16Ranges() {
    // Pattern: (\w+)-(.+)  — Match: „a-😀b"
    // „😀" ist ein UTF-16-Surrogatpaar (2 Code-Units). Wir prüfen, dass die
    // Snap-Ranges in UTF-16 rechnen (sonst läge das Ende um 1 daneben).
    let pattern = "(\\w+)-(.+)"
    let tok = HandTok.tokenize(pattern, [
        p("(", .groupDelimiter), p("\\w", .characterClass), p("+", .quantifier), p(")", .groupDelimiter),
        p("-", .literal),
        p("(", .groupDelimiter), p(".", .characterClass), p("+", .quantifier), p(")", .groupDelimiter),
    ])
    let text = "a-😀b"
    let ns = text as NSString
    // UTF-16-Länge: a(1) -(1) 😀(2) b(1) = 5.
    #expect(ns.length == 5)
    let units = GroupBuilder.units(pattern: pattern, tokenization: tok,
                                   matchText: text, caseSensitive: false)
    #expect(units != nil)
    guard let u = units, u.count == 3 else { return }
    func sub(_ r: NSRange?) -> String? { r.map { ns.substring(with: $0) } }
    // Unit 2 ist `(.+)` → matcht „😀b" (Indizes 2..5, length 3).
    #expect(u[2].matchRange == NSRange(location: 2, length: 3))
    #expect(sub(u[2].matchRange) == "😀b")
}

@Test("caseSensitive=false: Pattern `ABC` matcht `abc` — Re-Match funktioniert")
func caseInsensitiveRematch() {
    let pattern = "ABC"
    let tok = HandTok.tokenize(pattern, [ p("ABC", .literal) ])
    // Match-Text in Kleinbuchstaben — nur bei case-insensitivem Re-Match
    // findet das Instrument einen Treffer.
    let units = GroupBuilder.units(pattern: pattern, tokenization: tok,
                                   matchText: "abc", caseSensitive: false)
    #expect(units != nil)
    #expect(units?.count == 1)
    #expect(units?[0].matchRange == NSRange(location: 0, length: 3))
}

@Test("caseSensitive=true: Pattern `ABC` matcht `abc` NICHT → nil")
func caseSensitiveNoMatch() {
    let pattern = "ABC"
    let tok = HandTok.tokenize(pattern, [ p("ABC", .literal) ])
    // Bei case-SENSITIVEM Re-Match passt „abc" nicht zu „ABC" → nicht
    // zuordenbar, kein Crash.
    let units = GroupBuilder.units(pattern: pattern, tokenization: tok,
                                   matchText: "abc", caseSensitive: true)
    #expect(units == nil)
}

@Test("Nicht zuordenbar: Match-Text passt nicht zum Pattern → nil, kein Crash")
func notMappable() {
    let tok = HandTok.emailTok
    // „völlig anderer Text" matcht das E-Mail-Pattern nicht → Re-Matching
    // scheitert → nil.
    let units = GroupBuilder.units(pattern: "(\\w+)@(\\w+)\\.de", tokenization: tok,
                                   matchText: "kein treffer hier", caseSensitive: false)
    #expect(units == nil)

    // propose muss auf demselben Weg nil liefern (kein Crash).
    let prop = GroupBuilder.propose(selection: NSRange(location: 0, length: 1),
                                    pattern: "(\\w+)@(\\w+)\\.de", tokenization: tok,
                                    matchText: "kein treffer hier", replacement: "$1",
                                    caseSensitive: false)
    #expect(prop == nil)
}

@Test("Cursor am Textende wählt den letzten Beitrag")
func selectionAtEndChoosesLastContribution() {
    let prop = GroupBuilder.propose(selection: NSRange(location: 12, length: 0),
                                    pattern: "(\\w+)@(\\w+)\\.de", tokenization: HandTok.emailTok,
                                    matchText: "anna@test.de", replacement: "", caseSensitive: false)
    #expect(prop?.snappedMatchRange == NSRange(location: 10, length: 2))
}

@Test("Selektion hinter allen Beiträgen liefert keinen Gruppenvorschlag",
      arguments: [NSRange(location: 13, length: 0), NSRange(location: 13, length: 2)])
func selectionOutsideAnyContribution(_ selection: NSRange) {
    #expect(GroupBuilder.propose(selection: selection,
        pattern: "(\\w+)@(\\w+)\\.de", tokenization: HandTok.emailTok,
        matchText: "anna@test.de", replacement: "", caseSensitive: false) == nil)
}

@Test("Verschachtelte bestehende Gruppe behält ihre äußere Nummer")
func proposal_nestedExistingGroup() throws {
    let pattern = "((a)b)c"
    let tokens = HandTok.tokenize(pattern, [
        p("(", .groupDelimiter), p("(", .groupDelimiter), p("a", .literal),
        p(")", .groupDelimiter), p("b", .literal), p(")", .groupDelimiter), p("c", .literal),
    ])
    let proposal = try #require(GroupBuilder.propose(
        selection: NSRange(location: 0, length: 2), pattern: pattern,
        tokenization: tokens, matchText: "abc", replacement: "$1 $2", caseSensitive: true))
    #expect(proposal.isAlreadyGroup)
    #expect(proposal.newGroupNumber == 1)
    #expect(proposal.newPattern == pattern)
    #expect(proposal.rewrittenReplacement == "$1 $2")
}
