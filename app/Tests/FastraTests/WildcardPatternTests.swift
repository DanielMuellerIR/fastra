// WildcardPatternTests.swift
//
// Sichert die reine Platzhalter-Übersetzung (Feature J, v0.10) ab, BEVOR
// sie in Schritt 2 in die Such-Engines verdrahtet wird. Zwei Test-Ebenen:
//
//   * STRUKTUR — das erzeugte Pattern/Template stimmt buchstäblich
//     (Escaping korrekt, gierige Gruppen / `$N` an den richtigen Stellen).
//   * VERHALTEN — das Pattern wird in eine echte `NSRegularExpression`
//     gepackt (case-insensitiv, OHNE `.dotMatchesLineSeparators`, genau wie
//     der spätere Plain-Modus-Aufrufer) und gegen echten Text laufen
//     gelassen. Nur so ist „gierig", „nur innerhalb einer Zeile" und der
//     Filmtitel-Fall wirklich belegt — eine reine String-Prüfung des
//     Patterns würde das verfehlen.

import Testing
import Foundation
@testable import Fastra

// MARK: - Test-Helfer

/// Baut die `NSRegularExpression` exakt so, wie es der Plain-Modus später
/// tut: case-insensitiv (Punkt 4 der Semantik) und OHNE
/// `.dotMatchesLineSeparators` (Punkt 2 — `*` bleibt in einer Zeile).
private func wildcardRegex(_ find: String) -> NSRegularExpression {
    let compiled = WildcardPattern.compileFind(find)
    return try! NSRegularExpression(pattern: compiled.regexPattern, options: [.caseInsensitive])
}

/// Komplette Suchen+Ersetzen-Strecke über die echte RegEx-Engine — bildet
/// genau das nach, was „Alle ersetzen" im Plain-Modus tun wird.
private func wildcardReplace(find: String, replace: String, in text: String) -> String {
    let compiled = WildcardPattern.compileFind(find)
    let regex = try! NSRegularExpression(pattern: compiled.regexPattern,
                                         options: [.caseInsensitive])
    // Genau wie ApplyEngine erhält die Replace-Seite die wirkliche Zahl der
    // Suchgruppen. Dadurch bleiben per Pillen eingefügte `$N`-Verweise aktiv.
    let template = WildcardPattern.compileReplace(
        replace,
        captureCount: compiled.starCount
    )
    let ns = text as NSString
    return regex.stringByReplacingMatches(in: text, options: [],
                                          range: NSRange(location: 0, length: ns.length),
                                          withTemplate: template)
}

// MARK: - Kein `*`: identisch zum alten Plain-Text-Pfad

@Test("Ohne `*` ist das Find-Pattern exakt der alte escapedPattern-Pfad")
func find_noWildcard_equalsEscapedPattern() {
    // Genau diese Äquivalenz garantiert, dass Schritt 2 (Engine-Umstellung)
    // das Verhalten für sternlose Eingaben NICHT verändert.
    for input in ["hello", "a.b.c", "preis: $5 (netto)", "C:\\temp\\*x"] where !input.contains("*") {
        let compiled = WildcardPattern.compileFind(input)
        #expect(compiled.regexPattern == NSRegularExpression.escapedPattern(for: input))
        #expect(compiled.starCount == 0)
        #expect(compiled.starOffsets.isEmpty)
    }
}

@Test("Ohne `*` ist das Replace-Template exakt der alte escapedTemplate-Pfad")
func replace_noWildcard_equalsEscapedTemplate() {
    for input in ["the ring", "$5.00", "back\\slash", "kein backref $1"] {
        #expect(WildcardPattern.compileReplace(input) == NSRegularExpression.escapedTemplate(for: input))
    }
}

@Test("`$5.00` im Replace bleibt literal (kein leerer Backref auf Gruppe 5)")
func replace_dollarAmount_staysLiteral() {
    // Ohne Stern darf ein getipptes `$5` NICHT als Rückreferenz wirken.
    let out = wildcardReplace(find: "X", replace: "$5.00", in: "X")
    #expect(out == "$5.00")
}

// MARK: - Struktur des Find-Patterns

@Test("Ein `*` ergibt genau eine gierige Gruppe (.+)")
func find_singleStar_producesOneGroup() {
    let compiled = WildcardPattern.compileFind("*, the")
    #expect(compiled.regexPattern.contains("(.+)"))
    #expect(compiled.starCount == 1)
    #expect(compiled.starOffsets == [0])   // `*` steht ganz vorn
}

@Test("Literale Sonderzeichen neben `*` werden escapt — `*.txt` → (.+)\\.txt")
func find_escapesLiteralMetacharacters() {
    // Der Punkt muss buchstäblich gemeint sein, nicht „beliebiges Zeichen".
    let compiled = WildcardPattern.compileFind("*.txt")
    #expect(compiled.regexPattern == "(.+)\\.txt")
}

@Test("`*.txt` matcht `foo.txt`, aber nicht `fooXtxt` (Punkt bleibt literal)")
func find_dotIsLiteral_behavior() {
    let regex = wildcardRegex("*.txt")
    #expect(regex.firstMatch(in: "foo.txt", options: [], range: NSRange(location: 0, length: 7)) != nil)
    #expect(regex.firstMatch(in: "fooXtxt", options: [], range: NSRange(location: 0, length: 7)) == nil)
}

@Test("`*` am Ende ergibt eine abschließende Gruppe")
func find_starAtEnd() {
    let compiled = WildcardPattern.compileFind("the *")
    #expect(compiled.regexPattern.hasSuffix("(.+)"))
    #expect(compiled.starCount == 1)
}

@Test("Mehrere `*` ergeben mehrere Gruppen, korrekt gezählt")
func find_multipleStars_count() {
    let compiled = WildcardPattern.compileFind("* - *")
    #expect(compiled.starCount == 2)
    #expect(compiled.starOffsets == [0, 4])
}

@Test("starOffsets zählen in UTF-16 (Emoji als Surrogatpaar)")
func find_starOffsets_areUTF16() {
    // 😀 ist 1 Character, aber 2 UTF-16-Code-Units → `*` steht bei Offset 2.
    let compiled = WildcardPattern.compileFind("😀*")
    #expect(compiled.starOffsets == [2])
    #expect(compiled.starCount == 1)
}

@Test("`**` ist EINE zeilenübergreifende Gruppe (Semantik #6, v1.2)")
func find_adjacentStars_multilineGroup() {
    // Geändert 2026-07-10 (Daniel): vorher war `**` ein entartetes
    // `(.+)(.+)` (zwei Gruppen). Jetzt ist ein Lauf aus 2+ Sternen EINE
    // Gruppe, die dank \s\S-Klasse auch Zeilenumbrüche fängt.
    let compiled = WildcardPattern.compileFind("a**b")
    #expect(compiled.regexPattern == #"a([\s\S]+)b"#)
    #expect(compiled.starCount == 1)
    #expect(compiled.starOffsets == [1])
}

@Test("`**` fängt über Zeilenumbrüche, `*` weiterhin nicht")
func behavior_doubleStar_crossesNewlines() throws {
    let compiled = WildcardPattern.compileFind("Anfang**Ende")
    let regex = try NSRegularExpression(pattern: compiled.regexPattern)
    let text = "Anfang\nMitte 1\nMitte 2\nEnde"
    let match = regex.firstMatch(in: text, options: [],
                                 range: NSRange(text.startIndex..., in: text))
    #expect(match != nil, "`**` muss den mehrzeiligen Block fangen")
    if let match, let range = Range(match.range(at: 1), in: text) {
        #expect(text[range] == "\nMitte 1\nMitte 2\n")
    }
}

@Test("Drei+ Sterne verhalten sich wie `**` (ein Lauf = eine Gruppe)")
func find_tripleStars_sameAsDouble() {
    let compiled = WildcardPattern.compileFind("a***b")
    #expect(compiled.regexPattern == #"a([\s\S]+)b"#)
    #expect(compiled.starCount == 1)
}

@Test("`**` im Replace ist EIN Verweis ($1), nicht zwei")
func replace_doubleStar_singleReference() {
    #expect(WildcardPattern.compileReplace("a**b") == "a$1b")
    // Getrennte Läufe bleiben getrennte Verweise.
    #expect(WildcardPattern.compileReplace("** und *") == "$1 und $2")
}

@Test("starRunCount zählt Läufe, nicht Sterne")
func starRunCount_countsRuns() {
    #expect(WildcardPattern.starRunCount("") == 0)
    #expect(WildcardPattern.starRunCount("abc") == 0)
    #expect(WildcardPattern.starRunCount("*") == 1)
    #expect(WildcardPattern.starRunCount("**") == 1)
    #expect(WildcardPattern.starRunCount("* - *") == 2)
    #expect(WildcardPattern.starRunCount("**a***") == 2)
}

@Test("End-to-End: `**` sammelt mehrzeiligen Block zwischen Markern ein")
func endToEnd_doubleStar_multilineBlock() throws {
    // Der Kern-Anwendungsfall: alles zwischen zwei Marker-Zeilen (inkl.
    // Umbrüchen) in EINEM Rutsch umstellen.
    let find = "BEGIN**END"
    let replace = "<<*>>"
    let compiled = WildcardPattern.compileFind(find)
    let regex = try NSRegularExpression(pattern: compiled.regexPattern)
    let template = WildcardPattern.compileReplace(replace, captureCount: compiled.starCount)
    let text = "BEGIN\nzeile 1\nzeile 2\nEND"
    let result = regex.stringByReplacingMatches(
        in: text, options: [],
        range: NSRange(text.startIndex..., in: text),
        withTemplate: template)
    #expect(result == "<<\nzeile 1\nzeile 2\n>>")
}

// MARK: - Verhalten: gierig + Anker

@Test("Filmtitel-Fall: `*, the` fängt vor dem nachgestellten Artikel")
func behavior_articleAtEnd_basic() {
    let regex = wildcardRegex("*, the")
    let text = "ring, The"
    let m = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length))!
    // Gruppe 1 = das, was `*` gefangen hat. Der Anker „, The" ist NICHT drin.
    let group1 = (text as NSString).substring(with: m.range(at: 1))
    #expect(group1 == "ring")
}

@Test("Gierig nimmt das LETZTE Anker-Vorkommen: `Hello, There, The`")
func behavior_greedy_takesLastAnchor() {
    let regex = wildcardRegex("*, the")
    let text = "Hello, There, The"
    let m = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length))!
    let group1 = (text as NSString).substring(with: m.range(at: 1))
    // Gierig → „Hello, There" (bis zum LETZTEN „, the"), nicht nur „Hello".
    #expect(group1 == "Hello, There")
}

@Test("Anker case-insensitiv: `*, the` matcht auch `, The`/`, THE`")
func behavior_anchorCaseInsensitive() {
    let regex = wildcardRegex("*, the")
    for text in ["ring, The", "ring, THE", "ring, the"] {
        let ns = text as NSString
        #expect(regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) != nil)
    }
}

// MARK: - Verhalten: nur innerhalb einer Zeile

@Test("`*` springt NICHT über Zeilenumbrüche (kein dotMatchesLineSeparators)")
func behavior_doesNotCrossNewlines() {
    let regex = wildcardRegex("*, the")
    let text = "Hello, the\nWorld, the"
    let ns = text as NSString
    let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
    // Zwei getrennte Treffer (je Zeile einer), nicht ein zeilenübergreifender.
    #expect(matches.count == 2)
    // Erster Treffer-Group endet VOR dem `\n`.
    let g1 = ns.substring(with: matches[0].range(at: 1))
    #expect(g1 == "Hello")
    #expect(!g1.contains("\n"))
}

// MARK: - Verhalten: mehrere `*`

@Test("Zwei `*` mit Literal dazwischen: `* - *` auf `a - b - c`")
func behavior_twoStars_greedySplit() {
    let regex = wildcardRegex("* - *")
    let text = "a - b - c"
    let ns = text as NSString
    let m = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length))!
    // Erste Gruppe gierig → „a - b", letzte → „c" (Anker = letztes „ - ").
    #expect(ns.substring(with: m.range(at: 1)) == "a - b")
    #expect(ns.substring(with: m.range(at: 2)) == "c")
}

// MARK: - Struktur des Replace-Templates

@Test("Ein `*` im Replace wird zu $1")
func replace_singleStar_isDollar1() {
    #expect(WildcardPattern.compileReplace("the *") == "the $1")
}

@Test("Mehrere `*` im Replace werden in Reihenfolge zu $1, $2")
func replace_multipleStars_numbered() {
    #expect(WildcardPattern.compileReplace("* by *") == "$1 by $2")
}

@Test("`*` am Anfang des Replace beginnt mit $1")
func replace_starAtStart() {
    #expect(WildcardPattern.compileReplace("*, foo") == "$1, foo")
}

@Test("Pillen-Verweise $2 $1 bleiben bei zwei Wildcard-Gruppen aktiv")
func replace_explicitPillReferencesRemainActive() {
    #expect(WildcardPattern.compileReplace("$2 $1", captureCount: 2) == "$2 $1")
}

@Test("Ungültiger Pillen-Verweis bleibt auch im Wildcard-Modus literal")
func replace_invalidPillReferenceStaysLiteral() {
    let input = "$5.00"
    #expect(WildcardPattern.compileReplace(input, captureCount: 2)
        == NSRegularExpression.escapedTemplate(for: input))
}

// MARK: - End-to-End: der namensgebende Anwendungsfall

@Test("Kern-Fall: `ring, The` → `The ring` via `*, the` / `The *`")
func endToEnd_articleReorder() {
    let out = wildcardReplace(find: "*, the", replace: "The *", in: "ring, The")
    #expect(out == "The ring")
}

@Test("End-to-End mit zwei `*`: `a - b` → `a and b`")
func endToEnd_twoStars() {
    let out = wildcardReplace(find: "* - *", replace: "* and *", in: "a - b")
    #expect(out == "a and b")
}

@Test("End-to-End: Wildcard-Pillen tauschen Nachname und Vorname")
func endToEnd_explicitPillsReorderNames() {
    let out = wildcardReplace(
        find: "*, *",
        replace: "$2 $1",
        in: "Müller, Daniel"
    )
    #expect(out == "Daniel Müller")
}

@Test("Mehrzeilig End-to-End: jede Zeile wird einzeln umgestellt")
func endToEnd_multiline() {
    let out = wildcardReplace(find: "*, the", replace: "The *",
                              in: "ring, The\nhobbit, The")
    #expect(out == "The ring\nThe hobbit")
}
