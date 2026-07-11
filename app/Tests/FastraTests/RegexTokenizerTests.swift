// RegexTokenizerTests.swift
//
// Testet `RegexTokenizer.tokenize()` gründlich:
//   • Einzeltokens aller Kategorien
//   • Literal-Merge benachbarter pattern_character-Nodes
//   • Invarianten (Sortierung, Lückenlosigkeit, text==Substring)
//   • Capture-Group-Nummerierung (anonym, benannt, nested, mixed)
//   • UTF-16-Korrektheit (Emoji = 2 UTF-16-Einheiten)
//   • Fehler-Fälle (unvollständiges Pattern, leeres Pattern)
//
// Stil: Swift Testing (@Test / #expect), anfängerfreundliche Kommentare,
// kein XCTest. Basislinie vor diesem File: 145 Tests.
//
// WICHTIG: `.serialized` an der Suite — tree-sitter Parser ist NICHT
// thread-safe. Swift Testing führt Tests standardmäßig parallel aus,
// was zu "Fatal access conflict"-Abstürzen führt. Die Serialisierung
// kostet etwas Laufzeit, verhindert aber Datenzugriffs-Konflikte.

import Testing
import Foundation
@testable import Fastra

// MARK: - Hilfsfunktionen (Modul-Ebene)

/// Prüft, ob der Range des Tokens exakt dem Substring des Patterns entspricht.
func tok_textMatchesSubstring(_ token: RegexToken, in pattern: String) -> Bool {
    let utf16 = pattern.utf16
    guard token.range.location >= 0,
          token.range.location + token.range.length <= utf16.count else {
        return false
    }
    let startIdx = utf16.index(utf16.startIndex, offsetBy: token.range.location)
    let endIdx = utf16.index(utf16.startIndex, offsetBy: token.range.location + token.range.length)
    let slice = String(utf16[startIdx ..< endIdx]) ?? ""
    return token.text == slice
}

/// Gibt `true` zurück, wenn alle UTF-16-Positionen 0..<pattern.utf16.count
/// durch genau einen Token abgedeckt werden (lückenlos, überlappungsfrei).
func tok_isContiguous(_ tokens: [RegexToken], in pattern: String) -> Bool {
    let total = pattern.utf16.count
    guard total > 0 else { return tokens.isEmpty }
    var covered = [Bool](repeating: false, count: total)
    for token in tokens {
        let start = token.range.location
        let end = token.range.location + token.range.length
        guard start >= 0, end <= total else { return false }
        for i in start ..< end {
            if covered[i] { return false }  // Überlappung!
            covered[i] = true
        }
    }
    return covered.allSatisfy { $0 }  // keine Lücke
}

// MARK: - Test-Suite
// .serialized verhindert parallele Ausführung → kein thread-safety-Problem mit tree-sitter

@Suite("RegexTokenizer Tests", .serialized)
struct RegexTokenizerTests {

    // MARK: Leeres Pattern

    @Test("Leeres Pattern liefert RegexTokenization.empty")
    func tokenizer_emptyPattern() {
        let result = RegexTokenizer.tokenize("")
        #expect(result.tokens.isEmpty)
        #expect(result.groups.isEmpty)
        #expect(!result.hasErrors)
        #expect(result == .empty)
    }

    // MARK: Anker

    @Test("Anker ^ → kind .anchor, text \"^\"")
    func tokenizer_anchorStart() {
        let r = RegexTokenizer.tokenize("^")
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .anchor)
        #expect(r.tokens[0].text == "^")
    }

    @Test("Anker $ → kind .anchor, text \"$\"")
    func tokenizer_anchorEnd() {
        let r = RegexTokenizer.tokenize("$")
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .anchor)
        #expect(r.tokens[0].text == "$")
    }

    @Test("Anker \\b → kind .anchor")
    func tokenizer_anchorWordBoundary() {
        let r = RegexTokenizer.tokenize(#"\b"#)
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .anchor)
        #expect(r.tokens[0].text == #"\b"#)
    }

    @Test("Anker \\B → kind .anchor")
    func tokenizer_anchorNonBoundary() {
        let r = RegexTokenizer.tokenize(#"\B"#)
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .anchor)
        #expect(r.tokens[0].text == #"\B"#)
    }

    // MARK: Zeichenklassen

    @Test("Wildcard . → kind .characterClass")
    func tokenizer_anyCharacter() {
        let r = RegexTokenizer.tokenize(".")
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .characterClass)
        #expect(r.tokens[0].text == ".")
    }

    @Test("Escape \\d → kind .characterClass")
    func tokenizer_charClassEscapeD() {
        let r = RegexTokenizer.tokenize(#"\d"#)
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .characterClass)
        #expect(r.tokens[0].text == #"\d"#)
    }

    @Test("Escape \\w → kind .characterClass")
    func tokenizer_charClassEscapeW() {
        let r = RegexTokenizer.tokenize(#"\w"#)
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .characterClass)
        #expect(r.tokens[0].text == #"\w"#)
    }

    @Test("Escape \\s → kind .characterClass")
    func tokenizer_charClassEscapeS() {
        let r = RegexTokenizer.tokenize(#"\s"#)
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .characterClass)
        #expect(r.tokens[0].text == #"\s"#)
    }

    @Test("Zeichenklasse [abc] → kind .characterClass, ein Token für die gesamte Klasse")
    func tokenizer_characterClassBrackets() {
        let r = RegexTokenizer.tokenize("[abc]")
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .characterClass)
        #expect(r.tokens[0].text == "[abc]")
    }

    @Test("Zeichenklasse [a-z] → kind .characterClass, ein Token")
    func tokenizer_characterClassRange() {
        let r = RegexTokenizer.tokenize("[a-z]")
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .characterClass)
        #expect(r.tokens[0].text == "[a-z]")
    }

    @Test("Negierte Zeichenklasse [^0-9] → kind .characterClass")
    func tokenizer_characterClassNegated() {
        let r = RegexTokenizer.tokenize("[^0-9]")
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .characterClass)
        #expect(r.tokens[0].text == "[^0-9]")
    }

    // MARK: Quantifier

    @Test("Quantifier + → kind .quantifier, text \"+\"")
    func tokenizer_quantifierPlus() {
        let r = RegexTokenizer.tokenize(#"\d+"#)
        // Erwartet: \d (characterClass) + + (quantifier)
        let quantifiers = r.tokens.filter { $0.kind == .quantifier }
        #expect(quantifiers.count == 1)
        #expect(quantifiers[0].text == "+")
    }

    @Test("Quantifier * → kind .quantifier")
    func tokenizer_quantifierStar() {
        let r = RegexTokenizer.tokenize(#"\w*"#)
        let quantifiers = r.tokens.filter { $0.kind == .quantifier }
        #expect(quantifiers.count == 1)
        #expect(quantifiers[0].text == "*")
    }

    @Test("Quantifier ? → kind .quantifier")
    func tokenizer_quantifierOptional() {
        let r = RegexTokenizer.tokenize(#"\s?"#)
        let quantifiers = r.tokens.filter { $0.kind == .quantifier }
        #expect(quantifiers.count == 1)
        #expect(quantifiers[0].text == "?")
    }

    @Test("Lazy Quantifier +? → EIN .quantifier-Token (lazy-? inklusive)")
    func tokenizer_quantifierLazy() {
        // +? muss als EIN Token ausgegeben werden, nicht als "+" + "?"
        let r = RegexTokenizer.tokenize(#"\w+?"#)
        let quantifiers = r.tokens.filter { $0.kind == .quantifier }
        #expect(quantifiers.count == 1)
        #expect(quantifiers[0].text == "+?")
    }

    @Test("Count-Quantifier {2,5} → EIN .quantifier-Token")
    func tokenizer_quantifierCountRange() {
        let r = RegexTokenizer.tokenize(#"\d{2,5}"#)
        let quantifiers = r.tokens.filter { $0.kind == .quantifier }
        #expect(quantifiers.count == 1)
        #expect(quantifiers[0].text == "{2,5}")
    }

    @Test("Count-Quantifier {3,} → EIN .quantifier-Token (offenes Ende)")
    func tokenizer_quantifierCountMin() {
        let r = RegexTokenizer.tokenize(#"a{3,}"#)
        let quantifiers = r.tokens.filter { $0.kind == .quantifier }
        #expect(quantifiers.count == 1)
        #expect(quantifiers[0].text == "{3,}")
    }

    @Test("Count-Quantifier {2,5}? (lazy) → EIN .quantifier-Token")
    func tokenizer_quantifierCountLazy() {
        let r = RegexTokenizer.tokenize(#"\d{2,5}?"#)
        let quantifiers = r.tokens.filter { $0.kind == .quantifier }
        #expect(quantifiers.count == 1)
        #expect(quantifiers[0].text == "{2,5}?")
    }

    // MARK: Alternation

    @Test("Alternation a|b → mittleres | ist .alternation-Token")
    func tokenizer_alternationPipe() {
        let r = RegexTokenizer.tokenize("a|b")
        let alts = r.tokens.filter { $0.kind == .alternation }
        #expect(alts.count == 1)
        #expect(alts[0].text == "|")
    }

    @Test("Alternation a|b|c → zwei .alternation-Tokens")
    func tokenizer_alternationMultiple() {
        let r = RegexTokenizer.tokenize("a|b|c")
        let alts = r.tokens.filter { $0.kind == .alternation }
        #expect(alts.count == 2)
    }

    // MARK: Escapes

    @Test("Identity-Escape \\. → kind .escape")
    func tokenizer_escapeIdentityDot() {
        let r = RegexTokenizer.tokenize(#"\."#)
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .escape)
        #expect(r.tokens[0].text == #"\."#)
    }

    @Test("Control-Escape \\n → kind .escape")
    func tokenizer_escapeNewline() {
        let r = RegexTokenizer.tokenize(#"\n"#)
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .escape)
        #expect(r.tokens[0].text == #"\n"#)
    }

    @Test("Control-Escape \\t → kind .escape")
    func tokenizer_escapeTab() {
        let r = RegexTokenizer.tokenize(#"\t"#)
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .escape)
        #expect(r.tokens[0].text == #"\t"#)
    }

    // MARK: Rückverweise

    @Test("Rückverweis \\1 → kind .backreference")
    func tokenizer_backreference1() {
        let r = RegexTokenizer.tokenize(#"(a)\1"#)
        let refs = r.tokens.filter { $0.kind == .backreference }
        #expect(refs.count == 1)
        #expect(refs[0].text == #"\1"#)
    }

    @Test("Named Backreference \\k<name> → EIN .backreference-Token")
    func tokenizer_backreferenceNamedK() {
        // Das gesamte \k<name>-Konstrukt muss als EIN Token erscheinen
        let r = RegexTokenizer.tokenize(#"(?<wort>\w+)\k<wort>"#)
        let refs = r.tokens.filter { $0.kind == .backreference }
        #expect(refs.count == 1)
        #expect(refs[0].text == #"\k<wort>"#)
    }

    // MARK: Literal-Merge

    @Test("Einzelnes Literal 'a' → EIN .literal-Token")
    func tokenizer_singleLiteral() {
        let r = RegexTokenizer.tokenize("a")
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .literal)
        #expect(r.tokens[0].text == "a")
    }

    @Test("Benachbarte Literale 'abc' werden zu EINEM .literal-Token gemergt")
    func tokenizer_mergedLiterals() {
        let r = RegexTokenizer.tokenize("abc")
        #expect(r.tokens.count == 1)
        #expect(r.tokens[0].kind == .literal)
        #expect(r.tokens[0].text == "abc")
    }

    @Test("Literal-Merge unterbrochen durch Quantifier: letztes 'c' ist eigenes Token")
    func tokenizer_literalsMergeInterruptedByQuantifier() {
        // 'a' ist ein Literal, 'b' bekommt den Quantifier '+', 'c' ist wieder Literal
        let r = RegexTokenizer.tokenize("ab+c")
        let literals = r.tokens.filter { $0.kind == .literal }
        let quantifiers = r.tokens.filter { $0.kind == .quantifier }
        // Genau ein Quantifier
        #expect(quantifiers.count == 1)
        #expect(quantifiers[0].text == "+")
        // 'c' muss nach dem Quantifier ein eigenes Literal sein
        #expect(literals.last?.text == "c")
        // Lückenlosigkeit einhalten
        #expect(tok_isContiguous(r.tokens, in: "ab+c"))
    }

    @Test("Literal-Merge: 'hello world' → zusammenhängende Literale werden gemergt")
    func tokenizer_mergedLiteralsWithSpace() {
        // Leerzeichen ist kein Sonderzeichen in tree-sitter-regex
        let r = RegexTokenizer.tokenize("hello world")
        let literals = r.tokens.filter { $0.kind == .literal }
        let allText = literals.map(\.text).joined()
        #expect(allText == "hello world")
    }

    // MARK: Gruppen-Delimiter

    @Test("Anonyme Capture-Gruppe (a) → öffnende + schließende groupDelimiter-Tokens")
    func tokenizer_capturingGroupDelimiters() {
        let r = RegexTokenizer.tokenize("(a)")
        let delimiters = r.tokens.filter { $0.kind == .groupDelimiter }
        #expect(delimiters.count == 2)
        #expect(delimiters[0].text == "(")
        #expect(delimiters[1].text == ")")
    }

    @Test("Non-Capturing-Gruppe (?:a) → öffnender '(?:'-Delimiter + Schließer")
    func tokenizer_nonCapturingGroupDelimiters() {
        let r = RegexTokenizer.tokenize("(?:a)")
        let delimiters = r.tokens.filter { $0.kind == .groupDelimiter }
        #expect(delimiters.count == 2)
        #expect(delimiters[0].text == "(?:")
        #expect(delimiters[1].text == ")")
    }

    @Test("Lookahead (?=foo) → öffnendes Präfix + Schließer, kein Capture")
    func tokenizer_lookaheadDelimiters() {
        let r = RegexTokenizer.tokenize("foo(?=bar)")
        let delimiters = r.tokens.filter { $0.kind == .groupDelimiter }
        // "(?=" ist das Präfix, ")" der Schließer
        #expect(delimiters.count == 2)
        // Öffnender Delimiter enthält "(?="
        #expect(delimiters[0].text.hasPrefix("(?"))
        // Kein Capture
        #expect(r.groups.isEmpty)
    }

    @Test("Negative Lookahead (?!foo) → kein Capture")
    func tokenizer_negativeLookaheadNoCapture() {
        let r = RegexTokenizer.tokenize("(?!foo)")
        #expect(r.groups.isEmpty)
        let delimiters = r.tokens.filter { $0.kind == .groupDelimiter }
        #expect(delimiters.count == 2)
    }

    // MARK: E-Mail-Demo-Pattern

    @Test("E-Mail-Demo-Pattern: 3 Capture Groups mit korrekten Ranges")
    func tokenizer_emailDemoPatternGroups() {
        let pattern = #"([a-zA-Z0-9._%+-]+)@([a-zA-Z0-9.-]+)\.([a-zA-Z]{2,})"#
        let r = RegexTokenizer.tokenize(pattern)

        #expect(r.groups.count == 3)
        #expect(r.groups[0].number == 1)
        #expect(r.groups[1].number == 2)
        #expect(r.groups[2].number == 3)

        // Keine Namen
        #expect(r.groups[0].name == nil)
        #expect(r.groups[1].name == nil)
        #expect(r.groups[2].name == nil)

        // Ranges innerhalb des Patterns
        let total = pattern.utf16.count
        for group in r.groups {
            #expect(group.range.location >= 0)
            #expect(group.range.location + group.range.length <= total)
            #expect(group.innerRange.location >= group.range.location)
            #expect(group.innerRange.location + group.innerRange.length
                    <= group.range.location + group.range.length)
        }

        #expect(tok_isContiguous(r.tokens, in: pattern))
    }

    @Test("E-Mail-Demo-Pattern: Token-Invarianten")
    func tokenizer_emailDemoPatternTokens() {
        let pattern = #"([a-zA-Z0-9._%+-]+)@([a-zA-Z0-9.-]+)\.([a-zA-Z]{2,})"#
        let r = RegexTokenizer.tokenize(pattern)

        // Tokens sortiert?
        let locs = r.tokens.map(\.range.location)
        #expect(locs == locs.sorted())

        // Kein Fehler
        #expect(!r.hasErrors)

        // text == Substring für jeden Token
        for token in r.tokens {
            #expect(tok_textMatchesSubstring(token, in: pattern),
                    "Token '\(token.text)' passt nicht zum Pattern-Substring an \(token.range)")
        }
    }

    // MARK: Verschachtelte Gruppen

    @Test("Verschachtelte Gruppen ((a)(b(c))): 4 Capture Groups in Klammer-Reihenfolge")
    func tokenizer_nestedGroupsNumbering() {
        // Klammern in Reihenfolge öffnend:
        //   ( → Gruppe 1 (äußerste)
        //   ( → Gruppe 2 (a)
        //   ( → Gruppe 3 (b...)
        //   ( → Gruppe 4 (c)
        let pattern = "((a)(b(c)))"
        let r = RegexTokenizer.tokenize(pattern)

        #expect(r.groups.count == 4)
        for (i, group) in r.groups.enumerated() {
            #expect(group.number == i + 1)
        }
    }

    @Test("Verschachtelte Gruppen: Gruppen-Ranges schließen Untergruppen ein")
    func tokenizer_nestedGroupsRanges() {
        let pattern = "((a)(b))"
        let r = RegexTokenizer.tokenize(pattern)

        let g1 = r.groups.first { $0.number == 1 }!
        let g2 = r.groups.first { $0.number == 2 }!
        let g3 = r.groups.first { $0.number == 3 }!

        // Gruppe 2 liegt innerhalb Gruppe 1
        #expect(g2.range.location >= g1.range.location)
        #expect(g2.range.location + g2.range.length <= g1.range.location + g1.range.length)

        // Gruppe 3 liegt innerhalb Gruppe 1
        #expect(g3.range.location >= g1.range.location)
        #expect(g3.range.location + g3.range.length <= g1.range.location + g1.range.length)
    }

    // MARK: Named Groups

    @Test("Named Groups (?<jahr>\\d{4})-(?<monat>\\d{2}): Nummern 1,2 + korrekte Namen")
    func tokenizer_namedGroupsNumbersAndNames() {
        let pattern = #"(?<jahr>\d{4})-(?<monat>\d{2})"#
        let r = RegexTokenizer.tokenize(pattern)

        #expect(r.groups.count == 2)
        #expect(r.groups[0].number == 1)
        #expect(r.groups[0].name == "jahr")
        #expect(r.groups[1].number == 2)
        #expect(r.groups[1].name == "monat")
    }

    @Test("Named Group: Präfix-Token enthält gesamten '(?<name>'-Text als EIN Delimiter")
    func tokenizer_namedGroupPrefixIsOneToken() {
        let pattern = #"(?<wort>\w+)"#
        let r = RegexTokenizer.tokenize(pattern)

        let delimiters = r.tokens.filter { $0.kind == .groupDelimiter }
        // Öffnendes Präfix "(?<wort>" und schließendes ")"
        #expect(delimiters.count == 2)
        #expect(delimiters[0].text == "(?<wort>")
        #expect(delimiters[1].text == ")")
    }

    // MARK: Mix capturing/non-capturing

    @Test("Mix (a)(?:b)(c): Nur Gruppen 1 und 2, (?:b) zählt nicht")
    func tokenizer_mixCapturingNonCapturing() {
        let pattern = "(a)(?:b)(c)"
        let r = RegexTokenizer.tokenize(pattern)

        // Zwei fangende Gruppen: (a) = 1, (c) = 2
        #expect(r.groups.count == 2)
        #expect(r.groups[0].number == 1)
        #expect(r.groups[1].number == 2)

        // Inhalt der ersten Gruppe = "a"
        let g1Inner = r.groups[0].innerRange
        let startIdx = pattern.utf16.index(pattern.utf16.startIndex,
                                            offsetBy: g1Inner.location)
        let endIdx = pattern.utf16.index(pattern.utf16.startIndex,
                                          offsetBy: g1Inner.location + g1Inner.length)
        let g1InnerText = String(pattern.utf16[startIdx ..< endIdx])!
        #expect(g1InnerText == "a")
    }

    @Test("Lookahead-Gruppe zählt nicht als Capture Group")
    func tokenizer_lookaheadDoesNotCount() {
        // foo(?=bar)(baz) → nur eine Capture Group: (baz)
        let pattern = "foo(?=bar)(baz)"
        let r = RegexTokenizer.tokenize(pattern)

        #expect(r.groups.count == 1)
        #expect(r.groups[0].number == 1)
    }

    // MARK: UTF-16 Korrektheit

    @Test("Emoji 😀 (Surrogatpaar) + Quantifier: Quantifier beginnt an UTF-16-Offset 2")
    func tokenizer_emojiUTF16Range() {
        // 😀 ist U+1F600 = 2 UTF-16-Code-Units (Surrogatpaar)
        // Pattern: 😀+ → Emoji ist ein pattern_character (literal)
        // Quantifier "+" muss bei UTF-16-Offset 2 beginnen (nicht 1)
        let pattern = "😀+"
        let r = RegexTokenizer.tokenize(pattern)

        let quantifiers = r.tokens.filter { $0.kind == .quantifier }
        #expect(quantifiers.count == 1)
        #expect(quantifiers[0].range.location == 2,
                "Emoji hat 2 UTF-16-Einheiten; + muss an Offset 2 beginnen")
        #expect(quantifiers[0].text == "+")
    }

    @Test("Emoji in Pattern: text==Substring-Invariante gilt")
    func tokenizer_emojiTextInvariant() {
        let pattern = "😀+"
        let r = RegexTokenizer.tokenize(pattern)
        for token in r.tokens {
            #expect(tok_textMatchesSubstring(token, in: pattern),
                    "Token '\(token.text)' stimmt nicht mit Substring überein")
        }
    }

    // MARK: Lückenlosigkeits-Invariante

    @Test("Invariante: Tokens decken einfache Patterns lückenlos ab")
    func tokenizer_invariantContiguousSimplePatterns() {
        let patterns = [
            #"^\d{4}-\d{2}-\d{2}$"#,        // ISO-Datum ohne Gruppen
            #"([a-z]+)@([a-z]+)\.[a-z]+"#,  // einfache E-Mail
            #"(foo|bar|baz)+"#,              // Alternation in Gruppe
            #"\b\w+\b"#,                     // Wortgrenzen
            #"(?<name>\w+)\s+(?<val>\d+)"#,  // Named Groups
            #"(?:https?)://\S+"#,            // URL-artiges
            #"[A-Z][a-z]*"#,                 // Zeichenklasse
            #"a{2,4}b{3}c?"#,               // Quantifier-Mix
        ]
        for pattern in patterns {
            let r = RegexTokenizer.tokenize(pattern)
            #expect(tok_isContiguous(r.tokens, in: pattern),
                    "Pattern '\(pattern)' hat Lücken in der Token-Liste")
        }
    }

    @Test("Invariante: Lückenlosigkeit für alle 16 BuiltInPatterns")
    func tokenizer_invariantContiguousBuiltInPatterns() {
        for template in BuiltInPatterns.all {
            let r = RegexTokenizer.tokenize(template.regex)
            #expect(tok_isContiguous(r.tokens, in: template.regex),
                    "BuiltInPattern '\(template.id)' hat Lücken in der Token-Liste")
        }
    }

    @Test("Invariante: Tokens sind nach range.location sortiert (mehrere Patterns)")
    func tokenizer_invariantSorted() {
        let patterns = [
            #"(\w+)@(\w+)\.de"#,
            #"(?<j>\d{4})-(?<m>\d{2})-(?<t>\d{2})"#,
            #"^https?://\S+$"#,
        ]
        for pattern in patterns {
            let r = RegexTokenizer.tokenize(pattern)
            let locs = r.tokens.map(\.range.location)
            #expect(locs == locs.sorted(),
                    "Tokens sind nicht sortiert für Pattern '\(pattern)'")
        }
    }

    @Test("Invariante: text==Substring für alle BuiltIn-Patterns")
    func tokenizer_invariantTextEqualsSubstringBuiltIn() {
        for template in BuiltInPatterns.all {
            let r = RegexTokenizer.tokenize(template.regex)
            for token in r.tokens {
                #expect(tok_textMatchesSubstring(token, in: template.regex),
                        "BuiltInPattern '\(template.id)': Token '\(token.text)' passt nicht")
            }
        }
    }

    // MARK: Fehler-Fälle

    @Test("Unvollständige Gruppe '(abc' → hasErrors true, kein Crash")
    func tokenizer_errorUnclosedGroup() {
        let r = RegexTokenizer.tokenize("(abc")
        #expect(r.hasErrors)
    }

    @Test("Unvollständige Zeichenklasse '[a-' → hasErrors true, kein Crash")
    func tokenizer_errorUnclosedCharClass() {
        let r = RegexTokenizer.tokenize("[a-")
        #expect(r.hasErrors)
    }

    @Test("Unvollständiger Quantifier 'a{' → hasErrors true, kein Crash")
    func tokenizer_errorUnclosedQuantifier() {
        let r = RegexTokenizer.tokenize("a{")
        #expect(r.hasErrors)
    }

    @Test("Einzelnes Literal ohne Fehler")
    func tokenizer_singleCharNoError() {
        let r = RegexTokenizer.tokenize("x")
        #expect(!r.hasErrors)
        #expect(r.tokens.count == 1)
    }

    // MARK: Capture-Group innerRange

    @Test("innerRange einer anonymen Gruppe zeigt auf Inhalt ohne Klammern")
    func tokenizer_captureGroupInnerRange() {
        let pattern = "(hello)"
        let r = RegexTokenizer.tokenize(pattern)

        #expect(r.groups.count == 1)
        let group = r.groups[0]

        // Gesamte Gruppe: "(hello)" → Länge 7
        #expect(group.range.location == 0)
        #expect(group.range.length == 7)

        // innerRange: "hello" → Offset 1, Länge 5
        #expect(group.innerRange.location == 1)
        #expect(group.innerRange.length == 5)
    }

    @Test("innerRange einer named Group zeigt auf Inhalt ohne '(?<name>' und ')'")
    func tokenizer_namedGroupInnerRange() {
        // "(?<n>ab)" → Präfix "(?<n>" hat Länge 5, Inhalt "ab" hat Länge 2
        let pattern = "(?<n>ab)"
        let r = RegexTokenizer.tokenize(pattern)

        #expect(r.groups.count == 1)
        let group = r.groups[0]

        // Inhalt "ab" beginnt nach "(?<n>" (Offset 5), Länge 2
        #expect(group.innerRange.location == 5)
        #expect(group.innerRange.length == 2)
    }

    // MARK: Komplexe Patterns

    @Test("ISO-Datum-Pattern \\b(\\d{4})-(\\d{2})-(\\d{2})\\b: 3 Gruppen, kein Fehler")
    func tokenizer_isoDatePattern() {
        let pattern = #"\b(\d{4})-(\d{2})-(\d{2})\b"#
        let r = RegexTokenizer.tokenize(pattern)

        #expect(!r.hasErrors)
        #expect(r.groups.count == 3)
        #expect(r.groups[0].number == 1)
        #expect(r.groups[1].number == 2)
        #expect(r.groups[2].number == 3)
        #expect(tok_isContiguous(r.tokens, in: pattern))
    }

    @Test("URL-Pattern https?://... : kein Fehler, Tokens lückenlos")
    func tokenizer_urlPatternNoErrors() {
        let pattern = #"https?://[\w.-]+(?:/[\w./?=&%#-]*)?"#
        let r = RegexTokenizer.tokenize(pattern)
        #expect(!r.hasErrors)
        #expect(tok_isContiguous(r.tokens, in: pattern))
    }

    @Test("Anker am Anfang und Ende ^foo$: anchors an richtigen Positionen")
    func tokenizer_anchorsAtBothEnds() {
        let pattern = "^foo$"
        let r = RegexTokenizer.tokenize(pattern)

        let anchors = r.tokens.filter { $0.kind == .anchor }
        #expect(anchors.count == 2)
        #expect(anchors[0].text == "^")
        #expect(anchors[1].text == "$")
        #expect(tok_isContiguous(r.tokens, in: pattern))
    }

    @Test("Komplexe Alternation in Gruppe (foo|bar)+: Lückenlos + 1 Capture Group")
    func tokenizer_complexAlternationInGroup() {
        let pattern = "(foo|bar)+"
        let r = RegexTokenizer.tokenize(pattern)

        #expect(!r.hasErrors)
        #expect(r.groups.count == 1)
        let alts = r.tokens.filter { $0.kind == .alternation }
        #expect(alts.count == 1)
        #expect(tok_isContiguous(r.tokens, in: pattern))
    }

    @Test("IPv4-Pattern mit non-capturing Gruppen: Lückenlos")
    func tokenizer_ipv4Pattern() {
        let pattern = #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
        let r = RegexTokenizer.tokenize(pattern)
        #expect(!r.hasErrors)
        #expect(r.groups.isEmpty)  // Keine fangenden Gruppen
        #expect(tok_isContiguous(r.tokens, in: pattern))
    }

    @Test("Markdown-Link-Pattern: 2 Capture Groups + Lückenlos")
    func tokenizer_markdownLinkPattern() {
        let pattern = #"\[([^\]]+)\]\(([^)]+)\)"#
        let r = RegexTokenizer.tokenize(pattern)
        #expect(!r.hasErrors)
        #expect(r.groups.count == 2)
        #expect(tok_isContiguous(r.tokens, in: pattern))
    }
}
