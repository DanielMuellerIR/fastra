// RegexTokens.swift
//
// Datentypen für das RegEx-Token-Modell (Phase 3, v0.7).
//
// Der `RegexTokenizer` (separate Datei) parst den Suchausdruck mit der
// tree-sitter-regex-Grammatik und liefert diese Typen zurück. Sie sind die
// gemeinsame Sprache von drei Verbrauchern:
//   1. Inline-Token-Highlighting im Find-Feld (Farbe pro `kind`),
//   2. Capture-Group-Pills in der Suchmaske (aus `groups`),
//   3. Token-Snap-Logik bei der geführten Gruppen-Definition (Token-Grenzen).
//
// Alle Ranges sind UTF-16-`NSRange` im Pattern-String — dieselbe Einheit,
// mit der NSRegularExpression und AppKit (NSAttributedString) rechnen.

import Foundation

/// Kategorie eines RegEx-Bausteins — bestimmt die Farbe im Find-Feld.
/// Die Fälle entsprechen den Token-Klassen aus dem Suchmasken-Konzept
/// (Anker rötlich, Zeichenklassen bläulich, Quantifier ocker, Literale
/// Standard); die konkrete Farbzuordnung lebt in `Theme.swift`.
enum RegexTokenKind: Equatable {
    /// `^` `$` `\b` `\B` — Positionen, keine Zeichen.
    case anchor
    /// `[...]`, `\d` `\w` `\s`, `.`, POSIX-Klassen — „welche Zeichen".
    case characterClass
    /// `+` `*` `?` `{n,m}` (inkl. lazy-`?`) — „wie oft".
    case quantifier
    /// Klammern und Präfixe von Gruppen: `(` `)` `(?:` `(?<name>` `(?=` …
    case groupDelimiter
    /// `|` — Alternative.
    case alternation
    /// Escapes ohne Klassen-Charakter: `\.` `\n` `\u{…}` `\t` …
    case escape
    /// Rückverweis auf eine Capture Group: `\1`, `\k<name>` …
    case backreference
    /// Normale Zeichen, die wörtlich gematcht werden.
    case literal
    /// Von tree-sitter als Fehler/unvollständig markierter Bereich.
    case error
}

/// Ein einzelner, flacher Token im Suchausdruck. „Flach" heißt: Die Liste
/// aller Tokens überlappt nicht und ist nach `range.location` sortiert —
/// genau das Format, das Highlighting und Token-Snap brauchen. Gruppen-
/// INHALTE sind als eigene Tokens enthalten, die Klammern selbst als
/// `.groupDelimiter`.
struct RegexToken: Equatable {
    let kind: RegexTokenKind
    /// Position im Pattern-String (UTF-16).
    let range: NSRange
    /// Der Token-Text selbst (Substring des Patterns) — für Tests,
    /// Debugging und die Element-Picker-Anzeige.
    let text: String
}

/// Eine Capture Group im Suchausdruck — Grundlage für die Pills in der
/// Maske und das Drag & Drop ins Replace-Feld (`$N`).
struct CaptureGroupInfo: Equatable {
    /// 1-basierte Gruppen-Nummer in NSRegularExpression-Zählung:
    /// ALLE fangenden Gruppen (anonym UND benannt) zählen in der
    /// Reihenfolge ihrer öffnenden Klammer. Nicht-fangende Gruppen
    /// (`(?:…)`, Lookarounds) zählen NICHT.
    let number: Int
    /// Gruppen-Name bei `(?<name>…)`, sonst `nil`.
    let name: String?
    /// Gesamte Gruppe inklusive Klammern (UTF-16 im Pattern).
    let range: NSRange
    /// Inhalt der Gruppe ohne Klammern/Präfix (UTF-16 im Pattern).
    let innerRange: NSRange
}

/// Gesamtergebnis eines Tokenizer-Laufs über einen Suchausdruck.
struct RegexTokenization: Equatable {
    /// Flache, sortierte, überlappungsfreie Token-Liste (siehe `RegexToken`).
    let tokens: [RegexToken]
    /// Alle fangenden Gruppen in Nummern-Reihenfolge (1, 2, 3 …).
    let groups: [CaptureGroupInfo]
    /// `true`, wenn tree-sitter Fehler-Knoten gemeldet hat (Pattern
    /// unvollständig/ungültig). Die UI färbt dann zurückhaltend und
    /// verlässt sich auf die bestehende NSRegularExpression-Fehlermeldung.
    let hasErrors: Bool

    static let empty = RegexTokenization(tokens: [], groups: [], hasErrors: false)
}
