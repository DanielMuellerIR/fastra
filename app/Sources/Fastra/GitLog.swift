import Foundation

/// Art eines Git-Text-Tabs — steuert Rendering und Read-only-Verhalten.
/// `nil` an einem `EditorTab` = normale, editierbare Datei.
enum GitTabKind: Hashable {
    case log      // `git log --graph` — klickbare Commit-Liste
    case diff     // `git diff` — gefärbter Unified-Diff
    case commit   // `git show <hash>` — Commit-Header + gefärbter Diff
}

/// Pure Helfer für die `git log`-Ausgabe.
enum GitLog {
    /// Argumente für einen kompakten, gut lesbaren Verlaufs-Graphen.
    static let arguments = ["log", "--graph", "--oneline", "--decorate", "--all", "-200"]

    /// Extrahiert den Commit-Hash aus einer `git log --graph --oneline`-Zeile.
    /// Solche Zeilen beginnen mit Graph-Zeichen (`* | / \ _ space`), dann folgt
    /// der abgekürzte Hash (7+ Hex-Zeichen), dann Decorations/Message. Der Hash
    /// ist das erste Hex-Token nach den Graph-Zeichen. Zeilen ohne Commit
    /// (reine Graph-Verbindungslinien wie `|/`) liefern `nil`.
    static func commitHash(inLine line: String) -> String? {
        // Führende Graph-/Whitespace-Zeichen überspringen.
        let graphChars = Set("*|/\\_ \t")
        let trimmed = line.drop(while: { graphChars.contains($0) })
        // Erstes Token = Kandidat für den Hash.
        let token = trimmed.prefix(while: { !$0.isWhitespace })
        let hex = Set("0123456789abcdef")
        guard token.count >= 7, token.count <= 40,
              token.allSatisfy({ hex.contains($0) }) else {
            return nil
        }
        return String(token)
    }
}
