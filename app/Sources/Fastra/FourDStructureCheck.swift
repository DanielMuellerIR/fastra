// FourDStructureCheck.swift
//
// 4D-Struktur-Hinweise (Etappe 5 Wunschpaket 2026-07c): heuristischer
// Check auf Basis des vorhandenen `FourDTokenizer` — Block-Balance
// (If/End if, For each/End for each, Case of/End case, Repeat/Until,
// While/End while, For/End for, Function-Grenzen), Klammer-, String- und
// Kommentar-Balance.
//
// EHRLICH als Hinweise benannt: kein Compiler-Ersatz. Leitregel „im
// Zweifel KEINE Meldung statt einer falschen" — deshalb mehrere bewusste
// Schutzmaßnahmen gegen Fehlklassifikationen:
// - Block-Schlüsselwörter zählen nur am ZEILENANFANG (kanonische
//   4D-Exporte schreiben sie so; `4D.Function` & Co. bleiben außen vor).
// - Zwischen `Begin SQL` und `End SQL` wird nichts geprüft (SQL-Text
//   könnte 4D-Wörter enthalten).
// - Klammern werden nur über das GANZE Dokument bilanziert (keine
//   Pro-Zeile-Annahmen); Kommentare, Strings und [Tabellen] sind
//   ausgenommen.

import Foundation

enum FourDStructureCheck {

    /// Öffner → erwartetes Schlusswort (kanonische 4D-Schreibweise für
    /// die Meldung).
    private static let closerByOpener: [String: String] = [
        "if": "End if",
        "case of": "End case",
        "for each": "End for each",
        "for": "End for",
        "while": "End while",
        "repeat": "Until",
    ]

    /// Schlusswort → erwarteter Öffner.
    private static let openerByCloser: [String: String] = [
        "end if": "if",
        "end case": "case of",
        "end for each": "for each",
        "end for": "for",
        "end while": "while",
        "until": "repeat",
    ]

    /// Kanonische Anzeige-Schreibweise der Schlüsselwörter.
    private static let displayName: [String: String] = [
        "if": "If", "case of": "Case of", "for each": "For each",
        "for": "For", "while": "While", "repeat": "Repeat",
        "end if": "End if", "end case": "End case",
        "end for each": "End for each", "end for": "End for",
        "end while": "End while", "until": "Until", "else": "Else",
    ]

    /// Prüft den Text und liefert den ERSTEN Struktur-Hinweis (kleinste
    /// Position) oder `nil`. Pure Funktion → unit-testbar.
    static func check(_ text: String) -> DocumentLinter.Issue? {
        let tokens = FourDTokenizer.tokenize(text)
        var candidates: [(location: Int, message: String)] = []

        collectStringAndCommentHints(text: text, tokens: tokens, into: &candidates)
        collectBracketHints(text: text, tokens: tokens, into: &candidates)
        collectBlockHints(text: text, tokens: tokens, into: &candidates)

        guard let first = candidates.min(by: { $0.location < $1.location }) else {
            return nil
        }
        let position = position(of: first.location, in: text)
        return DocumentLinter.Issue(line: position.line, column: position.column,
                                    message: first.message)
    }

    // MARK: - String- und Kommentar-Balance

    private static func collectStringAndCommentHints(
        text: String, tokens: [FourDTokenizer.Token],
        into candidates: inout [(location: Int, message: String)]
    ) {
        for token in tokens {
            switch token.kind {
            case .string:
                // Der Tokenizer beendet Strings am Zeilenende bzw. Datei-
                // ende — nur ein `"` als letztes Zeichen ist ein sauberer
                // Abschluss (Mindestlänge 2: das leere Paar `""`).
                let value = substring(text, token.range)
                if value.count < 2 || !value.hasSuffix("\"") {
                    candidates.append((token.range.location,
                                       L10n.string("String ohne schließendes Anführungszeichen — 4D-Strings enden auf derselben Zeile.")))
                }
            case .comment:
                // Blockkommentar ohne Abschluss (Mindestlänge 4: `/**/`).
                let value = substring(text, token.range)
                if value.hasPrefix("/*"),
                   value.count < 4 || !value.hasSuffix("*/") {
                    candidates.append((token.range.location,
                                       L10n.string("Blockkommentar „/*“ ohne schließendes „*/“.")))
                }
            default:
                break
            }
        }
    }

    // MARK: - Klammer-Balance

    /// Bilanziert (), [] und {} über das ganze Dokument — außerhalb von
    /// Kommentaren, Strings und [Tabellen]-Referenzen.
    private static func collectBracketHints(
        text: String, tokens: [FourDTokenizer.Token],
        into candidates: inout [(location: Int, message: String)]
    ) {
        let skip = tokens.filter {
            $0.kind == .comment || $0.kind == .string || $0.kind == .table
        }.map(\.range).sorted { $0.location < $1.location }
        let scalars = Array(text.utf16)
        var skipIndex = 0
        var stack: [(char: Character, location: Int)] = []
        let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
        let openers: Set<Character> = ["(", "[", "{"]
        let closers: Set<Character> = [")", "]", "}"]

        var i = 0
        while i < scalars.count {
            // Ausgenommene Bereiche (Kommentar/String/Tabelle) überspringen.
            while skipIndex < skip.count, NSMaxRange(skip[skipIndex]) <= i {
                skipIndex += 1
            }
            if skipIndex < skip.count, skip[skipIndex].contains(i) {
                i = NSMaxRange(skip[skipIndex])
                continue
            }
            guard let scalar = Unicode.Scalar(scalars[i]) else { i += 1; continue }
            let char = Character(scalar)
            if openers.contains(char) {
                stack.append((char, i))
            } else if closers.contains(char) {
                if let top = stack.last {
                    if pairs[top.char] == char {
                        stack.removeLast()
                    } else {
                        let opened = position(of: top.location, in: text)
                        candidates.append((i, L10n.format(
                            "„%@“ passt nicht zur offenen „%@“ aus Zeile %ld.",
                            String(char), String(top.char), opened.line
                        )))
                        return
                    }
                } else {
                    candidates.append((i, L10n.format(
                        "„%@“ ohne passende öffnende Klammer.", String(char)
                    )))
                    return
                }
            }
            i += 1
        }
        if let oldest = stack.first {
            candidates.append((oldest.location, L10n.format(
                "„%@“ ohne schließende „%@“.",
                String(oldest.char), String(pairs[oldest.char] ?? " ")
            )))
        }
    }

    // MARK: - Block-Balance

    private static func collectBlockHints(
        text: String, tokens: [FourDTokenizer.Token],
        into candidates: inout [(location: Int, message: String)]
    ) {
        let scalars = Array(text.utf16)
        var stack: [(keyword: String, location: Int)] = []
        var inSQL = false

        func unclosedMessage(_ entry: (keyword: String, location: Int),
                             before boundary: String?) -> String {
            let opened = displayName[entry.keyword] ?? entry.keyword
            let closer = closerByOpener[entry.keyword] ?? "?"
            if let boundary {
                return L10n.format("„%@“ ohne schließendes „%@“ (vor %@).",
                                   opened, closer, boundary)
            }
            return L10n.format("„%@“ ohne schließendes „%@“.", opened, closer)
        }

        for token in tokens where token.kind == .keyword {
            let word = substring(text, token.range).lowercased()

            // Innerhalb von Begin SQL … End SQL nichts deuten — der
            // SQL-Text kann 4D-Wörter enthalten.
            if inSQL {
                if word == "end sql" { inSQL = false }
                continue
            }
            if word == "begin sql" {
                inSQL = true
                continue
            }

            // Nur Schlüsselwörter am Zeilenanfang zählen (kanonischer
            // 4D-Export); `4D.Function`, Member-Namen u. Ä. bleiben außen
            // vor — im Zweifel keine Meldung.
            guard isAtLineStart(token.range.location, scalars: scalars) else {
                continue
            }

            if closerByOpener[word] != nil {
                stack.append((word, token.range.location))
                continue
            }
            if let expectedOpener = openerByCloser[word] {
                if let top = stack.last {
                    if top.keyword == expectedOpener {
                        stack.removeLast()
                    } else {
                        let opened = position(of: top.location, in: text)
                        candidates.append((token.range.location, L10n.format(
                            "„%@“ passt nicht zum offenen „%@“ aus Zeile %ld.",
                            displayName[word] ?? word,
                            displayName[top.keyword] ?? top.keyword,
                            opened.line
                        )))
                        return
                    }
                } else {
                    candidates.append((token.range.location, L10n.format(
                        "„%@“ ohne vorheriges „%@“.",
                        displayName[word] ?? word,
                        displayName[expectedOpener] ?? expectedOpener
                    )))
                    return
                }
                continue
            }
            if word == "else" {
                // Else gehört direkt in If oder Case of.
                let top = stack.last?.keyword
                if top != "if" && top != "case of" {
                    candidates.append((token.range.location, L10n.string(
                        "„Else“ außerhalb von „If“/„Case of“."
                    )))
                    return
                }
                continue
            }
            if word == "function" || word == "class constructor" {
                // Abschnittsgrenze in Klassendateien: Beim Beginn einer
                // neuen Function müssen alle Blöcke geschlossen sein.
                if let oldest = stack.first {
                    candidates.append((oldest.location, unclosedMessage(
                        oldest, before: L10n.format("„Function“ in Zeile %ld",
                                                    position(of: token.range.location,
                                                             in: text).line)
                    )))
                    return
                }
                continue
            }
        }
        if let oldest = stack.first {
            candidates.append((oldest.location,
                               unclosedMessage(oldest, before: nil)))
        }
    }

    // MARK: - Helfer

    /// Steht vor dem Offset auf derselben Zeile nur Leerraum?
    private static func isAtLineStart(_ location: Int, scalars: [UInt16]) -> Bool {
        var i = location - 1
        while i >= 0 {
            guard let scalar = Unicode.Scalar(scalars[i]) else { return false }
            let char = Character(scalar)
            if char == "\n" || char == "\r" { return true }
            guard char == " " || char == "\t" else { return false }
            i -= 1
        }
        return true   // Dateianfang
    }

    /// Zeile/Spalte (1-basiert) eines UTF-16-Offsets.
    private static func position(of location: Int, in text: String)
        -> (line: Int, column: Int) {
        guard let range = Range(NSRange(location: 0, length: location), in: text) else {
            return (1, 1)
        }
        return DocumentLinter.lineColumn(atEndOf: String(text[range]))
    }

    private static func substring(_ text: String, _ range: NSRange) -> String {
        guard let stringRange = Range(range, in: text) else { return "" }
        return String(text[stringRange])
    }
}
