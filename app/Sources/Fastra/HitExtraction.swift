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
        guard !matches.isEmpty else { return "" }
        let lines = matches.map { useReplacement ? $0.replacedText : $0.matchText }
        return lines.joined(separator: "\n") + "\n"
    }
}
