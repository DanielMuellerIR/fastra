// GotoLine.swift
//
// Pure Parse-Logik für den „Zu Zeile springen"-Dialog (CMD+J). Trennt
// die Texteingabe vom AppKit-Dialog, damit der knifflige Teil (User-
// Input → Zeile/Spalte) getestet ist.

import Foundation

enum GotoLineParse {
    /// Versteht:
    ///   - `"5"`   → Zeile 5, ohne Spalte (Cursor an Zeilenanfang)
    ///   - `"5:12"` → Zeile 5, Spalte 12
    ///   - Whitespace ringsherum wird ignoriert.
    /// Ungültige oder unsinnige Eingaben → `nil`.
    static func parse(_ input: String) -> (line: Int, column: Int?)? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard let line = Int(parts[0]), line > 0 else { return nil }
            return (line, nil)
        case 2:
            guard let line = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let col  = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                  line > 0, col > 0 else { return nil }
            return (line, col)
        default:
            return nil
        }
    }
}
