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

    /// Erklärender Tooltip zum Badge (Daniel-Wunsch 2026-07-12): das Kürzel
    /// allein sagt Nicht-Git-Profis wenig.
    var tooltip: String {
        switch self {
        case .modified:   return L10n.string("Geändert (M)")
        case .added:      return L10n.string("Neu, bereitgestellt (A)")
        case .deleted:    return L10n.string("Gelöscht (D)")
        case .untracked:  return L10n.string("Nicht versioniert (U)")
        case .renamed:    return L10n.string("Umbenannt (R)")
        case .conflicted: return L10n.string("Merge-Konflikt (!)")
        }
    }
}

/// Eine Datei mit getrenntem Index- (gestaged) und Working-Tree-Zustand
/// (ungestaged) — die Grundlage der VS-Code-artigen Änderungen-Ansicht. Eine
/// Datei kann gleichzeitig gestaged UND ungestaged geändert sein (z.B. Porcelain
/// „MM"): dann ist sie in beiden Abschnitten sichtbar.
struct GitChange: Equatable, Identifiable {
    /// Repo-relativer Anzeigepfad. Bei ungültigem UTF-8 enthält er sichtbare
    /// Ersatzzeichen; `rawPath` bleibt die kollisionsfreie Quelle der Wahrheit.
    let path: String
    let rawPath: Data
    /// Vorheriger Pfad bei Rename/Copy. Porcelain v2 liefert ihn als eigenen
    /// NUL-Datensatz, damit auch Tabs und Zeilenumbrüche eindeutig bleiben.
    let originalPath: String?
    let rawOriginalPath: Data?
    /// Zustand im Index (Porcelain-Spalte X) — `nil`, wenn nichts bereitgestellt.
    let staged: GitFileState?
    /// Zustand im Working-Tree (Porcelain-Spalte Y) — `nil`, wenn dort nichts offen.
    let unstaged: GitFileState?

    init(path: String, originalPath: String? = nil,
         staged: GitFileState?, unstaged: GitFileState?) {
        self.path = path
        self.rawPath = Data(path.utf8)
        self.originalPath = originalPath
        self.rawOriginalPath = originalPath.map { Data($0.utf8) }
        self.staged = staged
        self.unstaged = unstaged
    }

    init(rawPath: Data, rawOriginalPath: Data? = nil,
         staged: GitFileState?, unstaged: GitFileState?) {
        self.rawPath = rawPath
        self.path = String(decoding: rawPath, as: UTF8.self)
        self.rawOriginalPath = rawOriginalPath
        self.originalPath = rawOriginalPath.map { String(decoding: $0, as: UTF8.self) }
        self.staged = staged
        self.unstaged = unstaged
    }

    var id: Data { rawPath }
    /// Foundation `Process.arguments` kann keine rohen Nicht-UTF8-Bytes
    /// übergeben. Solche Pfade bleiben sichtbar, Git-Aktionen sind aber gesperrt.
    var actionPath: String? { String(data: rawPath, encoding: .utf8) }
    var isPathActionable: Bool { actionPath != nil }

    /// Nur der Dateiname (letzte Pfadkomponente) für die kompakte Anzeige.
    var name: String { (path as NSString).lastPathComponent }
    /// Ordner-Anteil (ohne Dateiname) als dezenter Zusatz, „" wenn im Wurzelordner.
    var directory: String { (path as NSString).deletingLastPathComponent }
}

/// Zusammenfassung von `git status` für die UI: Branch, Ahead/Behind-Zähler
/// und der Zustand je Datei (Pfad RELATIV zum Repo-Root, wie git ihn liefert).
struct GitStatusSummary: Equatable {
    var branch: String?
    /// `true`, wenn HEAD direkt auf einen Commit statt auf einen Branch zeigt.
    var isDetached: Bool
    /// Exakte Objekt-ID aus Porcelain v2. Bei einem Repository ohne Commit nil.
    var headOID: String?
    /// Vollständiger Upstream-Name, z.B. `origin/main`.
    var upstream: String?
    var ahead: Int
    var behind: Int
    /// Repo-relativer Pfad → kombinierter Zustand. Für die Einfärbung im
    /// Dateibaum (eine Datei erscheint höchstens einmal).
    var entries: [String: GitFileState]
    /// Getrennte Index-/Working-Tree-Zustände für die Änderungen-Ansicht,
    /// in git-Reihenfolge.
    var changes: [GitChange]

    static let empty = GitStatusSummary(branch: nil, isDetached: false,
                                        headOID: nil, upstream: nil,
                                        ahead: 0, behind: 0,
                                        entries: [:], changes: [])

    /// Bereitgestellte Änderungen (Index) — für den „Bereitgestellt"-Abschnitt.
    var stagedChanges: [GitChange] { changes.filter { $0.staged != nil } }
    /// Nicht bereitgestellte Änderungen (Working-Tree, inkl. untracked).
    var unstagedChanges: [GitChange] { changes.filter { $0.unstaged != nil } }
}

/// Parst die NUL-getrennte Ausgabe von `git status --porcelain=v2 --branch -z`.
/// Rein funktional → ohne echtes Repo testbar.
enum GitStatusParser {
    /// Argumente, mit denen `GitStatusSummary` gefüllt werden kann. `-b` bringt
    /// die Branch-Kopfzeilen, v2 trennt Rename-Quelle und -Ziel eindeutig.
    // `git status` darf seinen Stat-Cache normalerweise im Index auffrischen
    // und nimmt dafür kurz `index.lock`. Da Fastra Status parallel zu echten
    // Aktionen lädt, verbieten wir diesen rein optionalen Schreibzugriff.
    static let arguments = ["--no-optional-locks", "status", "--porcelain=v2",
                            "--branch", "-z"]

    /// Data ist hier wichtig: Ein Dateiname darf jedes Byte außer NUL enthalten.
    /// Erst nachdem NUL die Datensätze sicher getrennt hat, dekodieren wir die
    /// einzelnen Felder für SwiftUI. Ungültiges UTF-8 wird sichtbar ersetzt,
    /// statt den gesamten Statuslauf zu verwerfen.
    static func parse(_ output: Data) -> GitStatusSummary {
        var summary = GitStatusSummary.empty
        let records = output.split(separator: 0, omittingEmptySubsequences: true)
        var index = 0
        while index < records.count {
            let record = Data(records[index])
            guard let marker = record.first else { index += 1; continue }
            switch marker {
            case 35: // #
                applyHeader(String(decoding: record, as: UTF8.self), to: &summary)
            case 49: // 1
                applyOrdinary(record, to: &summary)
            case 50: // 2
                let original = index + 1 < records.count
                    ? Data(records[index + 1]) : nil
                applyRenamed(record, originalPath: original, to: &summary)
                if original != nil { index += 1 }
            case 117: // u
                applyUnmerged(record, to: &summary)
            case 63: // ?
                applyUntracked(record, to: &summary)
            default:
                break
            }
            index += 1
        }
        return summary
    }

    private static func applyHeader(_ line: String, to summary: inout GitStatusSummary) {
        if line.hasPrefix("# branch.oid ") {
            let value = String(line.dropFirst("# branch.oid ".count))
            summary.headOID = value == "(initial)" ? nil : value
        } else if line.hasPrefix("# branch.head ") {
            let value = String(line.dropFirst("# branch.head ".count))
            summary.isDetached = value == "(detached)"
            summary.branch = summary.isDetached || value == "(unknown)" ? nil : value
        } else if line.hasPrefix("# branch.upstream ") {
            summary.upstream = String(line.dropFirst("# branch.upstream ".count))
        } else if line.hasPrefix("# branch.ab ") {
            let parts = line.split(separator: " ")
            for part in parts.dropFirst(2) {
                if part.hasPrefix("+") { summary.ahead = Int(part.dropFirst()) ?? 0 }
                if part.hasPrefix("-") { summary.behind = Int(part.dropFirst()) ?? 0 }
            }
        }
    }

    private static func applyOrdinary(_ record: Data, to summary: inout GitStatusSummary) {
        let fields = record.split(separator: 32, maxSplits: 8,
                                  omittingEmptySubsequences: false)
        guard fields.count == 9 else { return }
        append(xy: String(decoding: fields[1], as: UTF8.self),
               rawPath: Data(fields[8]), rawOriginalPath: nil, to: &summary)
    }

    private static func applyRenamed(_ record: Data, originalPath: Data?,
                                     to summary: inout GitStatusSummary) {
        let fields = record.split(separator: 32, maxSplits: 9,
                                  omittingEmptySubsequences: false)
        guard fields.count == 10 else { return }
        append(xy: String(decoding: fields[1], as: UTF8.self),
               rawPath: Data(fields[9]), rawOriginalPath: originalPath, to: &summary)
    }

    private static func applyUnmerged(_ record: Data, to summary: inout GitStatusSummary) {
        let fields = record.split(separator: 32, maxSplits: 10,
                                  omittingEmptySubsequences: false)
        guard fields.count == 11 else { return }
        append(xy: String(decoding: fields[1], as: UTF8.self),
               rawPath: Data(fields[10]), rawOriginalPath: nil, to: &summary)
    }

    private static func applyUntracked(_ record: Data, to summary: inout GitStatusSummary) {
        let fields = record.split(separator: 32, maxSplits: 1,
                                  omittingEmptySubsequences: false)
        guard fields.count == 2 else { return }
        let rawPath = Data(fields[1])
        guard !rawPath.isEmpty else { return }
        if let path = String(data: rawPath, encoding: .utf8) {
            summary.entries[path] = .untracked
        }
        summary.changes.append(GitChange(rawPath: rawPath, staged: nil,
                                        unstaged: .untracked))
    }

    private static func append(xy: String, rawPath: Data, rawOriginalPath: Data?,
                               to summary: inout GitStatusSummary) {
        let characters = Array(xy)
        guard characters.count == 2, !rawPath.isEmpty else { return }
        let x = characters[0]
        let y = characters[1]
        if let path = String(data: rawPath, encoding: .utf8) {
            summary.entries[path] = state(x: x, y: y)
        }
        summary.changes.append(change(x: x, y: y, rawPath: rawPath,
                                     rawOriginalPath: rawOriginalPath))
    }

    /// Zerlegt die zwei Porcelain-Zeichen in getrennten Index-/Working-Tree-
    /// Zustand für die Änderungen-Ansicht (staged = X, unstaged = Y).
    private static func change(x: Character, y: Character, rawPath: Data,
                               rawOriginalPath: Data?) -> GitChange {
        // Untracked: nur im Working-Tree, nichts gestaged.
        if x == "?" && y == "?" {
            return GitChange(rawPath: rawPath, rawOriginalPath: rawOriginalPath,
                             staged: nil, unstaged: .untracked)
        }
        // Unmerged/Konflikt: als ungestagete Konflikt-Änderung zeigen.
        if x == "U" || y == "U" || (x == "D" && y == "D") || (x == "A" && y == "A") {
            return GitChange(rawPath: rawPath, rawOriginalPath: rawOriginalPath,
                             staged: nil, unstaged: .conflicted)
        }
        return GitChange(rawPath: rawPath, rawOriginalPath: rawOriginalPath,
                         staged: sideState(x), unstaged: sideState(y))
    }

    /// Bildet EIN Porcelain-Zeichen (einer Spalte) auf unseren Zustand ab.
    /// Leerzeichen = nichts an dieser Stelle.
    private static func sideState(_ c: Character) -> GitFileState? {
        switch c {
        case "M":       return .modified
        case "A":       return .added
        case "D":       return .deleted
        case "R":       return .renamed
        case "C":       return .modified   // kopiert → als Änderung behandeln
        case "?":       return .untracked
        default:        return nil          // "." (nichts) und Unbekanntes
        }
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

}
