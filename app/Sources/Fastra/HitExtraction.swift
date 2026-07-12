// HitExtraction.swift
//
// BBEdit-Feature „Extract" (User Manual 16.0.1, Kap. 5 S. 168 / Kap. 7
// S. 193): Alle Treffer einer Suche werden — zeilengetrennt — in ein
// NEUES unbenanntes Dokument gesammelt. Ist ein Ersetzungsmuster
// angegeben, wird jeder Treffer VOR dem Sammeln damit transformiert
// (Backrefs `$1`, Case-Operatoren `\U…`, Wildcard-Pillen) — so wird aus
// einer Log-Datei mit `_TAG_(\w+)` → `$1` z.B. die reine Tag-Liste.
//
// Pure Logik, getrennt vom Workspace: aus Treffern wird der Dokument-
// Inhalt gebaut; Tab-Erzeugung und UI bleiben Sache des Aufrufers.

import Foundation

enum HitExtraction {
    enum Separator: String, CaseIterable, Identifiable {
        case newline = "Zeilenumbruch"
        case comma = "Komma"
        case semicolon = "Semikolon"
        case tab = "Tab"
        case custom = "Eigenes"
        var id: String { rawValue }

        func value(custom: String) -> String {
            switch self {
            case .newline: return "\n"
            case .comma: return ","
            case .semicolon: return ";"
            case .tab: return "\t"
            case .custom: return custom
            }
        }
    }

    enum Quoting: String, CaseIterable, Identifiable {
        case none = "Keine Anführungszeichen"
        case whenNeeded = "Nur wenn nötig"
        case always = "Immer doppelte Anführungszeichen"
        var id: String { rawValue }
    }

    enum Destination: String, CaseIterable, Identifiable {
        case newDocument = "Neues Dokument"
        case clipboard = "Zwischenablage"
        var id: String { rawValue }
    }

    struct Options: Equatable {
        var separator: Separator = .newline
        var customSeparator = " | "
        var quoting: Quoting = .none
        var deduplicate = false
        var useReplacement = false
        var destination: Destination = .newDocument
    }
    /// Baut den Inhalt des Extract-Dokuments.
    ///
    /// - `matches`: die Treffer in Dokument-Reihenfolge.
    /// - `useReplacement`: `true` → pro Treffer der transformierte Text
    ///   (`replacedText`), `false` → der rohe Treffertext (`matchText`).
    ///   BBEdit-Regel: Das Ersetzungsmuster ist bei Extract OPTIONAL —
    ///   leer heißt „roh extrahieren", nicht „durch nichts ersetzen".
    ///
    /// Jeder Treffer wird zu einer Zeile; ein End-Newline schließt das
    /// Dokument ab (POSIX-üblich, und die Statistik zählt dann korrekt
    /// N Zeilen). Leere Trefferliste → leerer String (Aufrufer beept).
    static func content(matches: [BufferSearch.Match], useReplacement: Bool) -> String {
        content(matches: matches, options: Options(useReplacement: useReplacement))
    }

    static func content(matches: [BufferSearch.Match], options: Options) -> String {
        guard !matches.isEmpty else { return "" }
        var values = matches.map { options.useReplacement ? $0.replacedText : $0.matchText }
        if options.deduplicate {
            var seen = Set<String>()
            values = values.filter { seen.insert($0).inserted }
        }
        let separator = options.separator.value(custom: options.customSeparator)
        values = values.map { quote($0, separator: separator, mode: options.quoting) }
        let joined = values.joined(separator: separator)
        return options.separator == .newline ? joined + "\n" : joined
    }

    private static func quote(_ value: String, separator: String, mode: Quoting) -> String {
        let needs = value.contains(separator) || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
        guard mode == .always || (mode == .whenNeeded && needs) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
