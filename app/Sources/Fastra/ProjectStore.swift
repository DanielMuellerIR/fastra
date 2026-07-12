import Foundation

/// Ein Eintrag in der Liste „zuletzt benutzte Projekte" (Willkommensbildschirm).
/// Ein Projekt ist schlicht ein Ordner — typischerweise ein Git-Repository
/// (Ordner mit `.git`), aber auch ein bewusst per „Ordner öffnen…" gewählter
/// Ordner ohne Git zählt (Nutzer-Absicht schlägt Heuristik).
///
/// `id` dient nur der SwiftUI-Identifikation und wird NICHT persistiert —
/// gleiches Muster wie `SearchFolderEntry` (UUID würde sonst pro App-Start
/// „neu" wirken).
struct ProjectEntry: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    /// Tilde-abgekürzter Pfad (`~/git/fastra`) — kompakt in UI und Defaults.
    var path: String

    enum CodingKeys: String, CodingKey { case path }

    init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.path = try c.decode(String.self, forKey: .path)
    }

    /// Tilde-expandierte Datei-URL für den tatsächlichen Zugriff.
    var url: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Anzeigename = letzter Pfadbestandteil („fastra").
    var name: String {
        url.lastPathComponent
    }
}

/// Verwaltet die Liste „zuletzt benutzte Projekte": reine Listen-Logik
/// (testbar) + Persistenz in UserDefaults (JSON, injizierbare Suite) +
/// Git-Repository-Erkennung. Muster: `RecentSearchFoldersStore`.
enum ProjectStore {
    static let key = "fastra.recentProjects"
    static let maxCount = 12

    /// Fügt einen Projekt-Pfad oben in die Liste ein: Tilde-Normalisierung,
    /// Dedup (vorhandener Eintrag wandert nach oben), Kürzung auf `max`.
    /// Pure Funktion → unit-testbar.
    static func prepending(_ newPath: String,
                           to existing: [ProjectEntry],
                           max: Int = maxCount) -> [ProjectEntry] {
        let normalized = (newPath as NSString).abbreviatingWithTildeInPath
        var result = existing.filter { $0.path != normalized }
        result.insert(ProjectEntry(path: normalized), at: 0)
        return Array(result.prefix(max))
    }

    static func load(from defaults: UserDefaults = .standard) -> [ProjectEntry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([ProjectEntry].self, from: data) else {
            return []
        }
        return entries
    }

    static func save(_ entries: [ProjectEntry], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    /// Sucht vom Startpunkt aufwärts den Wurzelordner eines Git-Repositories:
    /// den ersten Ordner, der einen `.git`-Eintrag enthält. `.git` darf Ordner
    /// ODER Datei sein — bei `git worktree` ist `.git` eine Datei mit Verweis.
    /// Liefert `nil`, wenn bis zur Wurzel nichts gefunden wird (kein Repo).
    ///
    /// Bewusst KEINE Ausführung von `git` — reiner Dateisystem-Check, damit
    /// die Erkennung auch ohne installiertes git funktioniert.
    static func repositoryRoot(for url: URL,
                               fileManager: FileManager = .default) -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        // Aufstieg über PFAD-STRINGS, nicht über URL.deletingLastPathComponent:
        // Letzteres hängt je nach URL-Form an der Wurzel `/..`-Komponenten an,
        // statt bei `/` stehen zu bleiben — der Selbsttest `search` hing damit
        // in einer Endlosschleife (Befund 2026-07-12, per `sample` diagnostiziert).
        // NSString.deletingLastPathComponent ist deterministisch: `/a` → `/`,
        // `/` → `/`. Bewusst KEINE Symlink-/Standardisierungs-Magie: Der
        // gefundene Root behält denselben Pfad-Präfix wie die Eingabe — so
        // landet in `recentProjects` derselbe String wie bei `openProject`.
        //
        // Startpunkt: bei einer Datei deren Ordner, sonst der Ordner selbst.
        var current = isDirectory.boolValue
            ? url.path
            : (url.path as NSString).deletingLastPathComponent

        while !current.isEmpty {
            let gitEntry = (current as NSString).appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitEntry) {
                return URL(fileURLWithPath: current)
            }
            // Wurzel erreicht und kein Repo gefunden → fertig.
            if current == "/" { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
}

// MARK: - Gespeicherte Such-Datei-Sets pro Projekt

struct ProjectFileSet: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// Projekt-relative Dateien oder Ordner. „.“ bezeichnet die Projektwurzel.
    var paths: [String]

    init(id: UUID = UUID(), name: String, paths: [String]) {
        self.id = id
        self.name = name
        self.paths = paths
    }
}

struct ProjectSearchConfiguration: Codable, Equatable {
    var fileSets: [ProjectFileSet]
    var activeSetID: UUID
    var fileTypeFilter: FileTypeFilter
    /// Komma- oder zeilengetrennte Globs, relativ zur Projektwurzel.
    var excludePatternsText: String

    static func fresh() -> ProjectSearchConfiguration {
        let all = ProjectFileSet(name: "Gesamtes Projekt", paths: ["."])
        return ProjectSearchConfiguration(fileSets: [all], activeSetID: all.id,
                                          fileTypeFilter: .knownText,
                                          excludePatternsText: ".git, .build, build")
    }

    var activeSet: ProjectFileSet? {
        fileSets.first { $0.id == activeSetID }
    }

    var excludePatterns: [String] {
        excludePatternsText
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum ProjectSearchStore {
    static let key = "fastra.projectSearchConfigurations"

    private static func storageKey(for rootURL: URL) -> String {
        rootURL.standardizedFileURL.path
    }

    static func load(for rootURL: URL,
                     defaults: UserDefaults = .standard) -> ProjectSearchConfiguration {
        guard let data = defaults.data(forKey: key),
              let all = try? JSONDecoder().decode([String: ProjectSearchConfiguration].self,
                                                  from: data),
              let config = all[storageKey(for: rootURL)] else {
            return .fresh()
        }
        return normalized(config)
    }

    static func save(_ config: ProjectSearchConfiguration, for rootURL: URL,
                     defaults: UserDefaults = .standard) {
        var all: [String: ProjectSearchConfiguration] = [:]
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: ProjectSearchConfiguration].self,
                                                   from: data) {
            all = decoded
        }
        all[storageKey(for: rootURL)] = normalized(config)
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key)
        }
    }

    /// Auch manuell bearbeitete oder ältere Defaults dürfen nie einen Picker
    /// ohne gültige Auswahl erzeugen. Die UI verhindert den Leerfall bereits;
    /// diese Normalisierung schützt zusätzlich die Persistenzgrenze.
    private static func normalized(_ config: ProjectSearchConfiguration)
        -> ProjectSearchConfiguration {
        guard !config.fileSets.isEmpty else { return .fresh() }
        var result = config
        if !result.fileSets.contains(where: { $0.id == result.activeSetID }) {
            result.activeSetID = result.fileSets[0].id
        }
        return result
    }
}
