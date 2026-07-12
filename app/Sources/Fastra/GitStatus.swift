import Foundation

/// Zustand einer Datei laut `git status`. Bewusst wenige, für die Einfärbung
/// in der Seitenleiste relevante Fälle — nicht der volle Porcelain-Zoo.
enum GitFileState: Equatable {
    case modified     // geändert (im Working-Tree oder gestaged)
    case added        // neu und gestaged
    case deleted      // gelöscht
    case untracked    // neu, nicht versioniert
    case renamed      // umbenannt
    case conflicted   // Merge-Konflikt (beide Seiten geändert)

    /// Einbuchstabiges Kürzel für die Seitenleiste (VS-Code-Sprache).
    var badge: String {
        switch self {
        case .modified:   return "M"
        case .added:      return "A"
        case .deleted:    return "D"
        case .untracked:  return "U"
        case .renamed:    return "R"
        case .conflicted: return "!"
        }
    }
}

/// Zusammenfassung von `git status` für die UI: Branch, Ahead/Behind-Zähler
/// und der Zustand je Datei (Pfad RELATIV zum Repo-Root, wie git ihn liefert).
struct GitStatusSummary: Equatable {
    var branch: String?
    var ahead: Int
    var behind: Int
    /// Repo-relativer Pfad → Zustand. Eine Datei erscheint höchstens einmal.
    var entries: [String: GitFileState]

    static let empty = GitStatusSummary(branch: nil, ahead: 0, behind: 0, entries: [:])
}

/// Parst die Ausgabe von `git status --porcelain=v1 -b -z` bzw. mit `\n`.
/// Rein funktional → ohne echtes Repo testbar.
enum GitStatusParser {
    /// Argumente, mit denen `GitStatusSummary` gefüllt werden kann. `-b` bringt
    /// die Branch-Kopfzeile, `--porcelain=v1` das stabile Maschinen-Format.
    static let arguments = ["status", "--porcelain=v1", "-b"]

    /// Parst den kompletten Porcelain-Text. Unbekannte/leere Zeilen werden
    /// übersprungen.
    static func parse(_ output: String) -> GitStatusSummary {
        var summary = GitStatusSummary.empty
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("## ") {
                applyBranchLine(String(line.dropFirst(3)), to: &summary)
            } else if !line.isEmpty {
                applyFileLine(line, to: &summary)
            }
        }
        return summary
    }

    /// Branch-Kopfzeile, z.B. `main...origin/main [ahead 1, behind 2]`
    /// oder `main` (kein Upstream) oder `No commits yet on main`.
    private static func applyBranchLine(_ text: String, to summary: inout GitStatusSummary) {
        // Ahead/Behind aus dem `[…]`-Teil ziehen, bevor er abgeschnitten wird.
        if let bracket = text.range(of: " [") {
            let inside = text[bracket.upperBound...].prefix(while: { $0 != "]" })
            summary.ahead = number(after: "ahead ", in: String(inside))
            summary.behind = number(after: "behind ", in: String(inside))
        }
        // Branch-Name = alles vor `...` (Upstream-Trenner) bzw. vor ` [`.
        var name = text
        if let sep = name.range(of: "...") {
            name = String(name[..<sep.lowerBound])
        } else if let sp = name.range(of: " [") {
            name = String(name[..<sp.lowerBound])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        // Frisches Repo ohne Commits: „No commits yet on <branch>".
        if let marker = name.range(of: "No commits yet on ") {
            name = String(name[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        // Detached HEAD: git schreibt „HEAD (no branch)" — als nil behandeln.
        summary.branch = (name.isEmpty || name.hasPrefix("HEAD")) ? nil : name
    }

    /// Eine Datei-Zeile: zwei Statuszeichen `XY`, ein Leerzeichen, dann der Pfad.
    /// Bei Umbenennungen steht `alt -> neu`; wir nehmen den neuen Pfad.
    private static func applyFileLine(_ line: String, to summary: inout GitStatusSummary) {
        guard line.count >= 4 else { return }
        let chars = Array(line)
        let x = chars[0]   // Index (gestaged)
        let y = chars[1]   // Working-Tree
        // chars[2] ist das Trenn-Leerzeichen.
        var path = String(chars[3...])
        if let arrow = path.range(of: " -> ") {
            path = String(path[arrow.upperBound...])
        }
        path = unquote(path)
        guard !path.isEmpty else { return }
        summary.entries[path] = state(x: x, y: y)
    }

    /// Bildet die zwei Porcelain-Zeichen auf unseren reduzierten Zustand ab.
    private static func state(x: Character, y: Character) -> GitFileState {
        if x == "?" && y == "?" { return .untracked }
        // Konflikt: beide Seiten geändert oder eine Seite „unmerged" (U).
        if x == "U" || y == "U" || (x == "D" && y == "D") || (x == "A" && y == "A") {
            return .conflicted
        }
        if x == "R" || y == "R" { return .renamed }
        if x == "A" { return .added }
        if x == "D" || y == "D" { return .deleted }
        return .modified
    }

    /// Liest die Zahl nach einem Präfix (`ahead `, `behind `) aus dem `[…]`-Text.
    private static func number(after prefix: String, in text: String) -> Int {
        guard let range = text.range(of: prefix) else { return 0 }
        let digits = text[range.upperBound...].prefix(while: { $0.isNumber })
        return Int(digits) ?? 0
    }

    /// Porcelain zitiert Pfade mit „Sonderzeichen" in doppelten Anführungszeichen.
    /// Für die reine Einfärbung reicht es, die Klammern zu entfernen; komplexe
    /// Oktal-Escapes sind extrem selten und stören das Matching nicht kritisch.
    private static func unquote(_ path: String) -> String {
        guard path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 else { return path }
        return String(path.dropFirst().dropLast())
    }
}
