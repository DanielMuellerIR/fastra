import Foundation

/// Klasse einer Zeile in einem Unified-Diff (`git diff` / `git show`) — steuert
/// die Färbung. Rein präsentativ.
enum GitDiffLineKind: Equatable {
    case added        // `+…` (aber nicht der `+++`-Header)
    case removed      // `-…` (aber nicht der `---`-Header)
    case hunk         // `@@ -a,b +c,d @@`
    case fileHeader   // `diff --git`, `+++`, `---`, `index …`, `new file …`
    case commitMeta   // `commit …`, `Author:`, `Date:` (aus git show)
    case context      // unveränderte Zeile
}

/// Pure Helfer für Diff-/Commit-Text.
enum GitDiff {
    /// Argumente für den Arbeitsverzeichnis-Diff (unstaged + staged gegen HEAD).
    static let arguments = ["diff", "HEAD"]

    /// Argumente für `git show <hash>` (Commit-Header + Diff).
    static func showArguments(hash: String) -> [String] {
        ["show", hash]
    }

    /// Nur den Patch einer Datei aus einem Commit laden. `--` trennt den
    /// Repo-Pfad sicher von Optionen (auch bei Dateinamen, die mit `-` starten).
    static func showFileArguments(hash: String, path: String) -> [String] {
        ["show", "--format=", hash, "--", path]
    }

    /// Klassifiziert eine einzelne Diff-Zeile für die Färbung. Pure Funktion.
    static func classify(_ line: String) -> GitDiffLineKind {
        if line.hasPrefix("diff --git") || line.hasPrefix("index ")
            || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file")
            || line.hasPrefix("rename ") || line.hasPrefix("similarity ") {
            return .fileHeader
        }
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("commit ") || line.hasPrefix("Author:")
            || line.hasPrefix("Date:") || line.hasPrefix("Merge:") {
            return .commitMeta
        }
        // Reine Datei-Header (+++/---) sind oben schon abgefangen; hier zählen
        // nur echte Inhaltszeilen.
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }
}
