// RecentFilesStore.swift
//
// Persistenz + reine Listen-Logik für „Zuletzt benutzte Dateien" (BBEdit:
// „Open Recent"). Bewusst parallel zu `RecentSearchFoldersStore` gebaut —
// gleiche Idee (UserDefaults-Suite injizierbar für Tests), aber für Dateien
// statt Suchordner, und als reine Pfad-Liste (kein enabled-Flag nötig).

import Foundation

enum RecentFilesStore {
    static let key = "fastra.recentFiles"

    /// Wie viele zuletzt benutzte Dateien wir uns merken. BBEdit-Default ist
    /// konfigurierbar; für v1.0 reicht eine feste, übersichtliche Obergrenze.
    static let maxCount = 10

    /// Reine Logik fürs Voranstellen: Der frisch benutzte Pfad landet ganz
    /// oben. Ein bereits vorhandener Eintrag (gleicher tilde-expandierter
    /// Pfad) wird nach oben verschoben statt dupliziert. Die Liste wird auf
    /// `max` gekürzt (älteste fallen hinten raus). Getrennt vom UI, damit
    /// unit-testbar.
    static func prepending(_ newPath: String,
                           to existing: [String],
                           max: Int = maxCount) -> [String] {
        let normalized = (newPath as NSString).expandingTildeInPath
        var result = existing.filter {
            ($0 as NSString).expandingTildeInPath != normalized
        }
        result.insert(newPath, at: 0)
        if result.count > max {
            result = Array(result.prefix(max))
        }
        return result
    }

    static func load(from defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    static func save(_ paths: [String], to defaults: UserDefaults = .standard) {
        defaults.set(paths, forKey: key)
    }
}
