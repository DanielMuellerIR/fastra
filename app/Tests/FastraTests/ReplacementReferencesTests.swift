import Foundation
import Testing
@testable import Fastra

// Tests für ReplacementReferences — die gemeinsame `$N`-Erkennung von
// „Gruppe definieren" (GroupBuilder) und „Gruppe löschen" (GroupRemoval).
//
// Maßstab ist hier NICHT eine Annahme darüber, wie Replace-Templates
// aussehen sollten, sondern was NSRegularExpression mit ihnen wirklich
// macht. Jede Zusage wird deshalb gegen eine echte Ersetzung geprüft:
// Vorher-Ergebnis und Nachher-Ergebnis müssen gleich sein, sonst hat eine
// Gruppen-Operation den unbeteiligten Ersetzungstext verändert.
//
// Die beiden Foundation-Regeln, die dabei leicht übersehen werden:
//   * Nach dem `$` zählen höchstens so viele Ziffern zur Gruppennummer,
//     wie die Gruppenanzahl selbst hat. `$12` ist bei zwei Gruppen also
//     Gruppe 1 plus das Literal „2".
//   * Nur ASCII-Ziffern zählen, und ein kombinierender Akzent hinter der
//     Ziffer gehört nicht mehr zur Nummer.

/// Führt die Ersetzung wirklich aus — das ist der Maßstab dieser Datei.
private func replaced(_ pattern: String, _ input: String, _ template: String) throws -> String {
    let regex = try NSRegularExpression(pattern: pattern)
    return regex.stringByReplacingMatches(
        in: input,
        range: NSRange(location: 0, length: (input as NSString).length),
        withTemplate: template)
}

/// Alle Gruppennummern, die der Scanner im Template findet.
private func scannedNumbers(_ template: String, groupCount: Int) -> [Int] {
    var found: [Int] = []
    ReplacementReferences.scan(in: template, groupCount: groupCount) { number, _ in
        found.append(number)
    }
    return found
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: - Ziffernregel
// ─────────────────────────────────────────────────────────────────────────

@Test("Ziffernbudget entspricht der Stellenzahl der Gruppenanzahl")
func references_digitBudget() {
    #expect(ReplacementReferences.maxReferenceDigits(forGroupCount: 0) == 1)
    #expect(ReplacementReferences.maxReferenceDigits(forGroupCount: 2) == 1)
    #expect(ReplacementReferences.maxReferenceDigits(forGroupCount: 9) == 1)
    #expect(ReplacementReferences.maxReferenceDigits(forGroupCount: 10) == 2)
    #expect(ReplacementReferences.maxReferenceDigits(forGroupCount: 99) == 2)
    #expect(ReplacementReferences.maxReferenceDigits(forGroupCount: 100) == 3)
}

@Test("Foundation liest `$12` bei zwei Gruppen als Gruppe 1 plus Literal")
func references_twoDigitsNeedTenGroups() throws {
    #expect(try replaced("(a)b(c)", "abc", "$12") == "a2")
    #expect(scannedNumbers("$12", groupCount: 2) == [1])

    // Erst ab zehn Gruppen ist `$12` wirklich zweistellig.
    let twelve = "(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)(l)"
    #expect(try replaced(twelve, "abcdefghijkl", "$12") == "l")
    #expect(scannedNumbers("$12", groupCount: 12) == [12])
}

@Test("Führende Nullen folgen derselben Regel wie bei Foundation")
func references_leadingZeros() throws {
    // Zwei Gruppen, ein Ziffernbudget: `$02` ist Gruppe 0 (ganzer Treffer)
    // gefolgt vom Literal „2".
    #expect(try replaced("(a)b(c)", "abc", "$02") == "abc2")
    #expect(scannedNumbers("$02", groupCount: 2) == [0])

    // Zehn Gruppen, zwei Ziffern Budget: dieselbe Schreibweise ist Gruppe 2.
    let ten = "(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)"
    #expect(try replaced(ten, "abcdefghij", "$02") == "b")
    #expect(scannedNumbers("$02", groupCount: 10) == [2])
}

@Test("Nur ASCII-Ziffern und Skalare vor dem Akzent zählen zur Nummer")
func references_unicodeScalars() throws {
    // Jede Zusage hier gilt einer Foundation-Regel, die sich ändern KÖNNTE —
    // die ASCII-Beschränkung lief ICU-seitig historisch über die
    // Unicode-Kategorie Nd. Der Scanner allein bewiese das nicht; deshalb
    // steht neben jeder Scanner-Zeile eine echte Ersetzung.
    let pattern = "(a)b(c)"

    // Kombinierender Akzent (U+0301) hinter der Ziffer: Die Referenz ist
    // gültig, der Akzent ist literaler Text dahinter.
    #expect(scannedNumbers("$2\u{0301}", groupCount: 2) == [2])
    #expect(try replaced(pattern, "abc", "$2\u{0301}") == "c\u{0301}")

    // Arabisch-indische Ziffern sind für Foundation kein Gruppenindex.
    #expect(scannedNumbers("$\u{0660}", groupCount: 2) == [])
    #expect(try replaced(pattern, "abc", "$\u{0660}") == "$\u{0660}")
    #expect(scannedNumbers("$1\u{0660}", groupCount: 2) == [1])
    #expect(try replaced(pattern, "abc", "$1\u{0660}") == "a\u{0660}")

    // Escapes bleiben Escapes.
    #expect(scannedNumbers("\\$1", groupCount: 2) == [])
    #expect(try replaced(pattern, "abc", "\\$1") == "$1")
    #expect(scannedNumbers("\\\\$1", groupCount: 2) == [1])
    #expect(try replaced(pattern, "abc", "\\\\$1") == "\\a")
}

@Test("Randfälle der Schreibweise: `$` am Ende, `$$1`, `$-1`, Backslash am Ende")
func references_edgeSpellings() throws {
    // Bisher ungepinnt, obwohl das Verhalten stimmt: Ohne diese Paare aus
    // Scanner- und echter Ersetzungsprüfung bliebe ein Foundation-Wechsel an
    // genau diesen Stellen unbemerkt.
    let pattern = "(a)b(c)"

    // Ein `$` ganz am Ende hat keine Ziffer — es ist literaler Text.
    #expect(scannedNumbers("x$", groupCount: 2) == [])
    #expect(try replaced(pattern, "abc", "x$") == "x$")

    // `$$1`: Das erste `$` ist keine Referenz (dahinter steht ein `$`), das
    // zweite ist Gruppe 1.
    #expect(scannedNumbers("$$1", groupCount: 2) == [1])
    #expect(try replaced(pattern, "abc", "$$1") == "$a")

    // `$-1` ist keine negative Nummer, sondern literaler Text.
    #expect(scannedNumbers("$-1", groupCount: 2) == [])
    #expect(try replaced(pattern, "abc", "$-1") == "$-1")

    // Ein Backslash am Stringende hat kein Zeichen mehr zum Escapen.
    #expect(scannedNumbers("$1\\", groupCount: 2) == [1])
    #expect(try replaced(pattern, "abc", "$1\\") == "a")
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: - Gruppe definieren: Ersetzung bleibt wirkungsgleich
// ─────────────────────────────────────────────────────────────────────────

@Test("Gruppe definieren lässt `$12` bei zwei Gruppen wirkungsgleich",
      arguments: ["$12", "$02"])
func references_proposeKeepsLiteralDigits(_ replacement: String) throws {
    let pattern = "(a)b(c)"
    let proposal = try #require(GroupBuilder.propose(
        selection: NSRange(location: 1, length: 1),
        pattern: pattern, tokenization: RegexTokenizer.tokenize(pattern),
        matchText: "abc", replacement: replacement, caseSensitive: true))
    #expect(proposal.newPattern == "(a)(b)(c)")
    let before = try replaced(pattern, "abc", replacement)
    let after = try replaced(proposal.newPattern, "abc", proposal.rewrittenReplacement)
    #expect(after == before)
}

@Test("Gruppe definieren verschiebt die Referenz vor einem kombinierenden Zeichen")
func references_proposeShiftsBeforeCombiningMark() throws {
    let pattern = "(a)b(c)"
    let replacement = "$2\u{0301}"
    let proposal = try #require(GroupBuilder.propose(
        selection: NSRange(location: 1, length: 1),
        pattern: pattern, tokenization: RegexTokenizer.tokenize(pattern),
        matchText: "abc", replacement: replacement, caseSensitive: true))
    #expect(proposal.newPattern == "(a)(b)(c)")
    #expect(proposal.rewrittenReplacement == "$3\u{0301}")
    let before = try replaced(pattern, "abc", replacement)
    #expect(before == "c\u{0301}")
    let after = try replaced(proposal.newPattern, "abc", proposal.rewrittenReplacement)
    #expect(after == before)
}

@Test("Übergang von neun auf zehn Gruppen erhält die Ersetzung")
func references_nineToTenGroups() throws {
    let pattern = "(a)(b)(c)(d)(e)(f)(g)(h)(i)j"
    let text = "abcdefghij"
    // Bei neun Gruppen: Gruppe 1 plus Literal „2".
    let replacement = "$12"
    let before = try replaced(pattern, text, replacement)
    #expect(before == "a2")

    let proposal = try #require(GroupBuilder.propose(
        selection: NSRange(location: 9, length: 1),
        pattern: pattern, tokenization: RegexTokenizer.tokenize(pattern),
        matchText: text, replacement: replacement, caseSensitive: true))
    #expect(proposal.newGroupNumber == 10)
    // Ab zehn Gruppen liest Foundation zwei Ziffern — die Referenz muss
    // deshalb aufgefüllt werden, sonst würde daraus Gruppe 12.
    #expect(proposal.rewrittenReplacement == "$012")
    let after = try replaced(proposal.newPattern, text, proposal.rewrittenReplacement)
    #expect(after == before)

    // Rückweg: dieselbe Gruppe wieder löschen, Ergebnis muss zurückkippen.
    let removal = try #require(GroupRemoval.remove(
        group: 10, pattern: proposal.newPattern,
        tokenization: RegexTokenizer.tokenize(proposal.newPattern),
        replacement: proposal.rewrittenReplacement))
    #expect(removal.newPattern == pattern)
    #expect(removal.rewrittenReplacement == replacement)
    #expect(try replaced(removal.newPattern, text, removal.rewrittenReplacement) == before)
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: - Gruppe löschen: Sperre für referenzierte Gruppen
// ─────────────────────────────────────────────────────────────────────────

@Test("Gruppe löschen bleibt gesperrt, wenn die Ersetzung sie referenziert",
      arguments: [(1, "$12"), (2, "$2\u{0301}"), (1, "$1\u{0660}")])
func references_removalStaysLocked(_ number: Int, _ replacement: String) {
    let pattern = "(a)b(c)"
    #expect(GroupRemoval.remove(group: number, pattern: pattern,
                                tokenization: RegexTokenizer.tokenize(pattern),
                                replacement: replacement) == nil)
}
