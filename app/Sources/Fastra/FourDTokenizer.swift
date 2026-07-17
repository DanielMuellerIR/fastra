// FourDTokenizer.swift
//
// Leichter, eigener Tokenizer für 4D-Methoden (.4dm) — Etappe 4 Wunschpaket
// 2026-07. BEWUSST keine tree-sitter-Grammatik (Bundle-Größe, Wartung):
// ein einzelner Scan-Durchlauf klassifiziert Kommentare, Strings, Zahlen,
// Schlüsselwörter, Befehle, Konstanten, Variablenarten, Tabellen/Felder
// und Methodenaufrufe. Pure Logik → direkt unit-testbar.
//
// Token-Klassen → CESE-Capture-Slots (Farb-Mapping siehe FourDTheme in
// EditorView; die Slot-Umleitung macht der EditorTheme-Patch in build.sh):
//
// | Token                       | Capture         | 4D-Farbkategorie        |
// |-----------------------------|-----------------|-------------------------|
// | Kommentar (`//`, `/* */`)   | .comment        | comments                |
// | String `"…"`                | .string         | (Fastra-Fallback)       |
// | Zahl                        | .number         | (plain_text wie in 4D)  |
// | Schlüsselwort (If/End if…)  | .keyword        | keywords                |
// | Befehl (ALERT, Get text…)   | .function       | commands                |
// | Konstante (aus Liste/`:K`)  | .variableBuiltin| constants               |
// | $lokal / $1-Parameter       | .variable       | local_variables         |
// | prozessVar / <>interprozess | .property       | process_variables       |
// | [Tabelle]                   | .type           | tables                  |
// | Feld (nach [Tabelle]…)      | .typeAlternate  | fields                  |
// | Methodenaufruf name(…)      | .method         | commands (geteilt)      |
// | Member `.name` / `.f()`     | (kein Capture)  | plain_text (bewusst)    |

import Foundation

enum FourDTokenizer {

    /// Token-Klassen des Tokenizers (siehe Mapping-Tabelle oben).
    enum Kind: Equatable {
        case comment
        case string
        case number
        case keyword
        case command
        case constant
        case localVariable        // $name und $1/$2-Parameter
        case processVariable      // nackter Bezeichner
        case interprocessVariable // <>name
        case table                // [Name]
        case field                // Feldname direkt hinter [Tabelle]
        case methodCall           // bezeichner( — Projektmethode
    }

    struct Token: Equatable {
        let range: NSRange   // UTF-16, passend zu NSAttributedString/CESE
        let kind: Kind
    }

    /// 4D-Kontrollflusswörter (öffentliches Sprachwissen, handgepflegt —
    /// NICHT aus der Doku generiert). Mehrwortige zuerst probieren.
    static let keywords: [String] = [
        "if", "else", "end if",
        "case of", "end case",
        "for each", "end for each", "for", "end for",
        "while", "end while",
        "repeat", "until",
        "use", "end use",
        "begin sql", "end sql",
        "return", "break", "continue",
        "function", "class constructor", "class extends", "property",
        "var", "try", "catch", "end try", "throw",
        "true", "false", "null", "this", "super",
    ]

    /// Nachschlagetabellen, einmalig aufgebaut (case-tolerant über
    /// lowercased-Schlüssel). `maxWords` begrenzt die Longest-Prefix-Suche.
    private struct SymbolTable {
        let names: Set<String>
        let maxWords: Int

        init(_ list: [String]) {
            var set = Set<String>()
            var maxWords = 1
            for name in list {
                set.insert(name.lowercased())
                maxWords = max(maxWords, name.split(separator: " ").count)
            }
            names = set
            self.maxWords = maxWords
        }

        func contains(_ phrase: Substring) -> Bool {
            names.contains(phrase.lowercased())
        }
    }

    private static let commandTable = SymbolTable(FourDSymbols.commands)
    private static let constantTable = SymbolTable(FourDSymbols.constants)
    private static let keywordTable = SymbolTable(keywords)

    /// Tokenisiert den kompletten Text. Ein Durchlauf, Zeichen für Zeichen;
    /// UTF-16-Offsets, damit die Ranges direkt in CESE/TextKit passen.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let scalars = Array(text.utf16)
        let count = scalars.count
        var index = 0
        // `true`, solange direkt zuvor eine ]-Klammer einer Tabellenreferenz
        // endete — der nächste Bezeichner ist dann ein FELD dieser Tabelle.
        var expectsField = false
        // `true` direkt nach einem `.` — der folgende Bezeichner ist ein
        // Member (plain) bzw. eine Member-Funktion (Methodenfarbe).
        var afterDot = false

        func utf16Char(_ at: Int) -> Character? {
            guard at < count else { return nil }
            guard let scalar = Unicode.Scalar(scalars[at]) else { return nil }
            return Character(scalar)
        }

        while index < count {
            guard let char = utf16Char(index) else { index += 1; continue }

            // ── Kommentare ────────────────────────────────────────────────
            if char == "/", let next = utf16Char(index + 1) {
                if next == "/" {
                    let start = index
                    while index < count, utf16Char(index) != "\n" { index += 1 }
                    tokens.append(Token(range: NSRange(location: start,
                                                       length: index - start),
                                        kind: .comment))
                    expectsField = false
                    continue
                }
                if next == "*" {
                    let start = index
                    index += 2
                    while index < count {
                        if utf16Char(index) == "*", utf16Char(index + 1) == "/" {
                            index += 2
                            break
                        }
                        index += 1
                    }
                    tokens.append(Token(range: NSRange(location: start,
                                                       length: index - start),
                                        kind: .comment))
                    expectsField = false
                    continue
                }
            }

            // ── Strings ───────────────────────────────────────────────────
            if char == "\"" {
                let start = index
                index += 1
                while index < count {
                    let c = utf16Char(index)
                    if c == "\\" { index += 2; continue }
                    index += 1
                    if c == "\"" || c == "\n" { break }
                }
                tokens.append(Token(range: NSRange(location: start,
                                                   length: index - start),
                                    kind: .string))
                expectsField = false
                continue
            }

            // ── Tabellenreferenz [Name] ───────────────────────────────────
            if char == "[" {
                if let close = findTableClose(scalars: scalars, from: index + 1) {
                    tokens.append(Token(range: NSRange(location: index,
                                                       length: close - index + 1),
                                        kind: .table))
                    index = close + 1
                    expectsField = true
                    continue
                }
            }

            // ── Interprozess-Variable <>name ──────────────────────────────
            if char == "<", utf16Char(index + 1) == ">",
               let first = utf16Char(index + 2), isWordStart(first) {
                let start = index
                index += 2
                index = consumeSpacedName(scalars: scalars, from: index)
                tokens.append(Token(range: NSRange(location: start,
                                                   length: index - start),
                                    kind: .interprocessVariable))
                expectsField = false
                continue
            }

            // ── Lokale Variable $name / Parameter $1 ──────────────────────
            if char == "$", let next = utf16Char(index + 1),
               isWordStart(next) || next.isNumber {
                let start = index
                index += 1
                index = consumeSpacedName(scalars: scalars, from: index)
                tokens.append(Token(range: NSRange(location: start,
                                                   length: index - start),
                                    kind: .localVariable))
                expectsField = false
                continue
            }

            // ── Wörter/Phrasen (Befehle, Konstanten, Keywords, Variablen) ─
            if isWordStart(char) || char.isNumber {
                let start = index
                let phraseEnd = consumeSpacedName(scalars: scalars, from: index)
                if let token = classifyPhrase(text: text, scalars: scalars,
                                              start: start, phraseEnd: phraseEnd,
                                              expectsField: expectsField,
                                              afterDot: afterDot) {
                    tokens.append(token)
                    index = token.range.location + token.range.length
                } else {
                    // Member ohne Klammer → bewusst ohne Capture (plain).
                    index = phraseEnd
                }
                expectsField = false
                afterDot = false
                continue
            }

            if char == "." {
                afterDot = true
                index += 1
                continue
            }
            if !char.isWhitespace {
                expectsField = false
                afterDot = false
            }
            index += 1
        }
        return tokens
    }

    // MARK: - Phrasen-Klassifikation

    /// Klassifiziert eine Wort-mit-Leerzeichen-Phrase per Longest-Prefix-
    /// Suche gegen Befehle → Konstanten → Keywords; Reste werden Variable/
    /// Methode/Feld/Zahl. `:Cnnn`/`:Knnn`-Suffixe erzwingen Befehl/Konstante
    /// (tokenisierte 4D-Exporte).
    private static func classifyPhrase(text: String, scalars: [UInt16],
                                       start: Int, phraseEnd: Int,
                                       expectsField: Bool,
                                       afterDot: Bool) -> Token? {
        let full = substring(text, start, phraseEnd)

        // Wortgrenzen der Phrase für die Longest-Prefix-Versuche.
        var boundaries: [Int] = []   // Endoffsets je Wortende (relativ absolut)
        var i = start
        var lastWasSpace = true
        while i < phraseEnd {
            let c = Character(Unicode.Scalar(scalars[i])!)
            if c == " " {
                if !lastWasSpace { boundaries.append(i) }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            i += 1
        }
        boundaries.append(phraseEnd)

        // `name:C123` → Befehl, `name:K12:34` → Konstante (nur EIN Wortende
        // vor dem Doppelpunkt prüfen — Suffix klebt direkt am Namen).
        if let suffixed = suffixToken(scalars: scalars, start: start,
                                      boundaries: boundaries) {
            return suffixed
        }

        // Longest-Prefix: erst Befehle, dann Konstanten, dann Keywords.
        for end in boundaries.reversed() {
            let phrase = substring(text, start, end)
            let lowered = Substring(phrase)
            if commandTable.contains(lowered) {
                return Token(range: NSRange(location: start, length: end - start),
                             kind: .command)
            }
            if constantTable.contains(lowered) {
                return Token(range: NSRange(location: start, length: end - start),
                             kind: .constant)
            }
            if keywordTable.contains(lowered) {
                return Token(range: NSRange(location: start, length: end - start),
                             kind: .keyword)
            }
        }

        let firstWordEnd = boundaries.first ?? phraseEnd
        let firstWord = substring(text, start, firstWordEnd)

        // Nur-Ziffern-Phrase → Zahl; ein direkt folgender Dezimalteil
        // (`42.5`) gehört mit zum Token.
        if firstWord.allSatisfy(\.isNumber) {
            var end = firstWordEnd
            if end < scalars.count,
               Unicode.Scalar(scalars[end]).map(Character.init) == ".",
               end + 1 < scalars.count,
               Unicode.Scalar(scalars[end + 1]).map(Character.init)?.isNumber == true {
                end += 1
                while end < scalars.count,
                      Unicode.Scalar(scalars[end]).map(Character.init)?.isNumber == true {
                    end += 1
                }
            }
            return Token(range: NSRange(location: start, length: end - start),
                         kind: .number)
        }

        // Member-Zugriff `.name` → plain (nil); `.name(` → Methodenfarbe.
        var lookahead = firstWordEnd
        while lookahead < scalars.count,
              let c = Unicode.Scalar(scalars[lookahead]).map(Character.init),
              c == " " { lookahead += 1 }
        let followedByParen = lookahead < scalars.count
            && Unicode.Scalar(scalars[lookahead]).map(Character.init) == "("
        if afterDot {
            guard followedByParen else { return nil }
            return Token(range: NSRange(location: start,
                                        length: firstWordEnd - start),
                         kind: .methodCall)
        }

        // Einzelner Bezeichner: Feld nach [Tabelle], Methodenaufruf vor `(`,
        // sonst Prozessvariable.
        if expectsField {
            return Token(range: NSRange(location: start,
                                        length: firstWordEnd - start),
                         kind: .field)
        }
        if followedByParen {
            return Token(range: NSRange(location: start,
                                        length: firstWordEnd - start),
                         kind: .methodCall)
        }
        return Token(range: NSRange(location: start,
                                    length: firstWordEnd - start),
                     kind: .processVariable)
    }

    /// `name:C123`/`name:K12:34`-Suffixe (kanonisch tokenisierter 4D-Code).
    private static func suffixToken(scalars: [UInt16], start: Int,
                                    boundaries: [Int]) -> Token? {
        guard let nameEnd = boundaries.last else { return nil }
        var i = nameEnd
        guard i < scalars.count,
              Unicode.Scalar(scalars[i]).map(Character.init) == ":" else { return nil }
        i += 1
        guard i < scalars.count,
              let marker = Unicode.Scalar(scalars[i]).map(Character.init),
              marker == "C" || marker == "K" else { return nil }
        i += 1
        var digits = 0
        while i < scalars.count,
              let c = Unicode.Scalar(scalars[i]).map(Character.init),
              c.isNumber || (marker == "K" && c == ":") {
            digits += 1
            i += 1
        }
        guard digits > 0 else { return nil }
        return Token(range: NSRange(location: start, length: i - start),
                     kind: marker == "C" ? .command : .constant)
    }

    // MARK: - Scan-Helfer

    private static func isWordStart(_ char: Character) -> Bool {
        char.isLetter || char == "_"
    }

    private static func isWordChar(_ char: Character) -> Bool {
        // Kein `.`: Punkte trennen Member-Zugriffe; kein generierter
        // Befehls-/Konstantenname enthält einen Punkt.
        char.isLetter || char.isNumber || char == "_"
    }

    /// Konsumiert eine „Phrase": Wortzeichen plus EINZELNE Leerzeichen
    /// zwischen Wörtern (4D-Namen dürfen Leerzeichen enthalten; Befehle und
    /// Konstanten sind mehrwortig). Endet vor doppeltem Leerzeichen,
    /// Zeilenende oder Nicht-Wortzeichen.
    private static func consumeSpacedName(scalars: [UInt16], from: Int) -> Int {
        var i = from
        var lastNonSpace = from
        while i < scalars.count {
            guard let c = Unicode.Scalar(scalars[i]).map(Character.init) else { break }
            if isWordChar(c) {
                i += 1
                lastNonSpace = i
                continue
            }
            if c == " " {
                // Nur ein einzelnes Leerzeichen zwischen Wörtern zulassen.
                guard i + 1 < scalars.count,
                      let n = Unicode.Scalar(scalars[i + 1]).map(Character.init),
                      isWordChar(n) else { break }
                i += 1
                continue
            }
            break
        }
        return lastNonSpace
    }

    /// Tabellenreferenz: `]` auf derselben Zeile suchen; Inhalt muss wie ein
    /// Name aussehen (sonst ist `[` ein Kollektions-Literal o. Ä.).
    private static func findTableClose(scalars: [UInt16], from: Int) -> Int? {
        var i = from
        var sawWordChar = false
        while i < scalars.count {
            guard let c = Unicode.Scalar(scalars[i]).map(Character.init) else { return nil }
            if c == "]" { return sawWordChar ? i : nil }
            if c == "\n" { return nil }
            if isWordChar(c) || c == " " || c == "$" || c == "<" || c == ">" {
                if isWordChar(c) { sawWordChar = true }
                i += 1
                continue
            }
            return nil
        }
        return nil
    }

    private static func substring(_ text: String, _ from: Int, _ to: Int) -> String {
        guard let range = Range(NSRange(location: from, length: to - from), in: text) else {
            return ""
        }
        return String(text[range]).lowercased()
    }
}
