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
        // `--stat` nennt die geänderten Dateien gut lesbar vor dem eigentlichen
        // Patch; `--patch` hält die bisherige vollständige Diff-Ausgabe fest.
        ["show", "--stat", "--patch", hash]
    }

    /// Nur die bereitgestellte Fassung einer Datei mit dem letzten Commit
    /// vergleichen. Das entspricht exakt einer Zeile im Abschnitt
    /// „Bereitgestellt“ der Änderungen-Ansicht.
    static func stagedFileArguments(path: String) -> [String] {
        ["diff", "--cached", "--", path]
    }

    /// Nur die noch nicht bereitgestellte Fassung einer Datei mit dem Index
    /// vergleichen. So vermischt ein „MM“-Eintrag seine beiden Stände nicht.
    static func unstagedFileArguments(path: String) -> [String] {
        ["diff", "--", path]
    }

    /// Eine unversionierte Datei hat noch keine Git-Gegenseite. `--no-index`
    /// erzeugt deshalb einen normalen Patch gegen die leere Datei `/dev/null`.
    static func untrackedFileArguments(path: String) -> [String] {
        ["diff", "--no-index", "--", "/dev/null", path]
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
