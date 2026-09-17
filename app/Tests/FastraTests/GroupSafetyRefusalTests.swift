import Foundation
import Testing
@testable import Fastra

// Diese Datei prüft die beiden Zusagen, an denen „Gruppe definieren" und
// „Gruppe löschen" hängen — und zwar an ECHTEN Ersetzungen und echten
// Treffern, nicht an Zwischenwerten:
//
//   1. Das Suchmuster trifft nach der Aktion dieselbe Textmenge.
//   2. Das Replace-Template erzeugt denselben Text wie vorher, nur aus den
//      umnummerierten Gruppen.
//
// Wo eine der beiden Zusagen nicht einzuhalten ist, muss die Aktion
// VERWEIGERN (nil) statt still etwas anderes zu tun.

/// Trifft `pattern` in `text` genau diese Fundstellen?
private func matches(_ pattern: String, _ text: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range) }
}

private func replacedText(_ pattern: String, _ text: String,
                          _ template: String) throws -> String {
    let regex = try NSRegularExpression(pattern: pattern)
    let ns = text as NSString
    return regex.stringByReplacingMatches(
        in: text, range: NSRange(location: 0, length: ns.length),
        withTemplate: template)
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: - Rückverweise im Suchmuster
// ─────────────────────────────────────────────────────────────────────────

@Test("Gemessen: ein Rückverweis ändert seine Bedeutung mit der Gruppenzahl")
func backreference_meaningDependsOnNumbering() throws {
    // Der Beleg dafür, warum beide Aktionen hier verweigern müssen. Ohne ihn
    // wäre die Verweigerung nur eine Behauptung.
    #expect(try matches("(a)b\\1", "aba") == ["aba"])
    #expect(try matches("((a)b)\\1", "aba").isEmpty)
    #expect(try matches("((a)b)\\1", "abab") == ["abab"])
    #expect(try matches("(a)(b)\\1", "aba") == ["aba"])
    #expect(try matches("a(b)\\1", "aba").isEmpty)
    #expect(try matches("a(b)\\1", "abb") == ["abb"])
}

@Test("Gruppe definieren verweigert bei einem Rückverweis im Muster")
func propose_refusesBackreference() {
    let pattern = "(a)b\\1"
    let proposal = GroupBuilder.propose(
        selection: NSRange(location: 0, length: 2),
        pattern: pattern, tokenization: RegexTokenizer.tokenize(pattern),
        matchText: "aba", replacement: "$1", caseSensitive: true)
    #expect(proposal == nil)
}

@Test("Gruppe löschen verweigert bei einem Rückverweis im Muster",
      arguments: ["(a)(b)\\1", "(a)(b)\\2", "(?<n>a)(b)\\k<n>"])
func remove_refusesBackreference(pattern: String) {
    let tokenization = RegexTokenizer.tokenize(pattern)
    // Vorbedingung: Der Tokenizer sieht den Rückverweis wirklich.
    #expect(RegexBackreferences.contains(in: tokenization))
    #expect(GroupRemoval.remove(group: 1, pattern: pattern,
                                tokenization: tokenization,
                                replacement: "x") == nil)
}

@Test("Ohne Rückverweis bleibt beides erlaubt")
func groupActionsStillWorkWithoutBackreferences() throws {
    let pattern = "(a)b(c)"
    let proposal = try #require(GroupBuilder.propose(
        selection: NSRange(location: 1, length: 1),
        pattern: pattern, tokenization: RegexTokenizer.tokenize(pattern),
        matchText: "abc", replacement: "$2", caseSensitive: true))
    #expect(proposal.newPattern == "(a)(b)(c)")
    #expect(proposal.rewrittenReplacement == "$3")
    let removal = try #require(GroupRemoval.remove(
        group: 2, pattern: proposal.newPattern,
        tokenization: RegexTokenizer.tokenize(proposal.newPattern),
        replacement: proposal.rewrittenReplacement))
    #expect(removal.newPattern == pattern)
    #expect(removal.rewrittenReplacement == "$2")
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: - Referenzen, die ins Leere zeigen
// ─────────────────────────────────────────────────────────────────────────

@Test("Gruppe definieren lässt eine ins Leere zeigende Referenz ins Leere zeigen")
func propose_keepsDanglingReferenceDangling() throws {
    // Der Befund: `$3` zeigt bei zwei Gruppen ins Leere. Nach dem Einfügen
    // gäbe es drei Gruppen — stehengeblieben fiele die Referenz auf die neue.
    let pattern = "(a)b(c)"
    #expect(try replacedText(pattern, "abc", "X$3Y") == "XY")
    let proposal = try #require(GroupBuilder.propose(
        selection: NSRange(location: 1, length: 1),
        pattern: pattern, tokenization: RegexTokenizer.tokenize(pattern),
        matchText: "abc", replacement: "X$3Y", caseSensitive: true))
    #expect(proposal.newPattern == "(a)(b)(c)")
    #expect(try replacedText(proposal.newPattern, "abc",
                             proposal.rewrittenReplacement) == "XY")
}

@Test("Gruppe definieren verweigert, wenn die Referenz nicht ausweichen kann")
func propose_refusesWhenDanglingReferenceCannotMove() throws {
    // Acht Gruppen, Ziffernbudget 1: `$9` zeigt ins Leere. Nach dem Einfügen
    // gäbe es neun Gruppen, und eine einstellige Nummer über neun existiert
    // nicht — `$10` läse Foundation als Gruppe 1 plus das Literal „0".
    let pattern = "(a)(b)(c)(d)(e)(f)(g)(h)i"
    let tokenization = RegexTokenizer.tokenize(pattern)
    #expect(tokenization.groups.count == 8)
    #expect(try replacedText(pattern, "abcdefghi", "<$9>") == "<>")
    #expect(GroupBuilder.propose(
        selection: NSRange(location: 8, length: 1),
        pattern: pattern, tokenization: tokenization,
        matchText: "abcdefghi", replacement: "<$9>", caseSensitive: true) == nil)
    // Gegenprobe: Ohne die hängende Referenz geht dieselbe Aktion durch.
    let ok = try #require(GroupBuilder.propose(
        selection: NSRange(location: 8, length: 1),
        pattern: pattern, tokenization: tokenization,
        matchText: "abcdefghi", replacement: "<$8>", caseSensitive: true))
    #expect(ok.newPattern == "(a)(b)(c)(d)(e)(f)(g)(h)(i)")
}

@Test("Gruppe löschen verweigert, wenn das kleinere Ziffernbudget die Referenz umdeutet",
      arguments: ["<$11>", "<$99>"])
func remove_refusesWhenShrinkingBudgetChangesTheReading(template: String) throws {
    // Zehn Gruppen, Budget 2: beide Referenzen zeigen ins Leere. Mit neun
    // Gruppen läse Foundation nur noch eine Ziffer — aus `$11` würde Gruppe 1
    // plus „1". Ausweichen geht nicht: Über neun ist einstellig nicht
    // darstellbar.
    let pattern = "(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)"
    #expect(try replacedText(pattern, "abcdefghij", template) == "<>")
    let tokenization = RegexTokenizer.tokenize(pattern)
    #expect(tokenization.groups.count == 10)
    #expect(GroupRemoval.remove(group: 3, pattern: pattern,
                                tokenization: tokenization,
                                replacement: template) == nil)
}

@Test("Gruppe löschen bleibt erlaubt, solange die Referenz weiter ins Leere zeigt")
func remove_allowsDanglingReferenceThatStaysDangling() throws {
    // Drei Gruppen, `$4` zeigt ins Leere; danach zwei Gruppen — `$4` zeigt
    // weiterhin ins Leere, das Ergebnis bleibt gleich.
    let pattern = "(a)(b)(c)"
    #expect(try replacedText(pattern, "abc", "<$4>") == "<>")
    let removal = try #require(GroupRemoval.remove(
        group: 1, pattern: pattern,
        tokenization: RegexTokenizer.tokenize(pattern), replacement: "<$4>"))
    #expect(removal.newPattern == "a(b)(c)")
    #expect(try replacedText(removal.newPattern, "abc",
                             removal.rewrittenReplacement) == "<>")
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: - Die Gleichbedeutungs-Prüfung selbst
// ─────────────────────────────────────────────────────────────────────────

@Test("Ein Template wird so gelesen, wie Foundation es liest")
func reading_matchesFoundation() {
    // Die ins Leere zeigende Referenz trägt nichts bei; benachbarte Literale
    // werden zusammengefasst, damit zwei Schreibweisen desselben Ergebnisses
    // nicht als verschieden gelten.
    #expect(ReplacementReferences.reading(of: "X$3Y", groupCount: 2)
            == [.literal("XY")])
    #expect(ReplacementReferences.reading(of: "X$3Y", groupCount: 3)
            == [.literal("X"), .group(3), .literal("Y")])
    #expect(ReplacementReferences.reading(of: "$0", groupCount: 0) == [.group(0)])
    #expect(ReplacementReferences.reading(of: "\\$1", groupCount: 2)
            == [.literal("\\$1")])
}

@Test("rewriteKeepsMeaning erkennt eine still veränderte Ersetzung")
func rewriteKeepsMeaning_catchesSilentChange() {
    // Gleichbedeutend: Die Referenz wandert mit ihrer Gruppe.
    #expect(ReplacementReferences.rewriteKeepsMeaning(
        original: "a$1b", groupCount: 2, rewritten: "a$2b", newGroupCount: 3,
        mapping: { $0 + 1 }))
    // Nicht gleichbedeutend: vorher leer, nachher Gruppe 3.
    #expect(!ReplacementReferences.rewriteKeepsMeaning(
        original: "X$3Y", groupCount: 2, rewritten: "X$3Y", newGroupCount: 3,
        mapping: { $0 }))
}
