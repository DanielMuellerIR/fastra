// SearchHistory.swift
//
// Persistenz + reine Logik für den Such-Verlauf (BBEdit: „Search History"-
// Popup am Find-Feld). Ein Eintrag ist ein Find-/Replace-PAAR — beim
// Auswählen werden beide Felder gefüllt, genau wie in BBEdit.

import Foundation

/// Ein gemerktes Such-/Ersetz-Paar. `id` ist nur zur SwiftUI-Identifikation
/// (ForEach im Popup) und wird NICHT persistiert — beim Laden frisch erzeugt,
/// damit die Liste nicht bei jedem Start „neu" wirkt (gleiches Muster wie
/// `SearchFolderEntry`).
struct SearchHistoryEntry: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var find: String
    var replace: String

    enum CodingKeys: String, CodingKey { case find, replace }

    init(id: UUID = UUID(), find: String, replace: String) {
        self.id = id
        self.find = find
        self.replace = replace
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.find = try c.decode(String.self, forKey: .find)
        self.replace = try c.decode(String.self, forKey: .replace)
    }
}

enum SearchHistoryStore {
    static let key = "fastra.searchHistory"

    /// Obergrenze für gemerkte Paare — genug für „eben gesuchtes
    /// wiederholen", aber kein endlos wachsendes Popup.
    static let maxCount = 15

    /// Reine Logik fürs Voranstellen: Das frisch benutzte Paar landet ganz
    /// oben. Ein identisches Paar (gleicher Find UND gleicher Replace) wird
    /// nach oben verschoben statt dupliziert. Liste auf `max` gekürzt.
    ///
    /// Leerer Find-String → keine Aufnahme (gibt die Liste unverändert
    /// zurück); ein leeres Suchfeld gehört nicht in den Verlauf.
    static func prepending(_ entry: SearchHistoryEntry,
                           to existing: [SearchHistoryEntry],
                           max: Int = maxCount) -> [SearchHistoryEntry] {
        guard !entry.find.isEmpty else { return existing }
        var result = existing.filter {
            !($0.find == entry.find && $0.replace == entry.replace)
        }
        result.insert(entry, at: 0)
        if result.count > max {
            result = Array(result.prefix(max))
        }
        return result
    }

    static func load(from defaults: UserDefaults = .standard) -> [SearchHistoryEntry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([SearchHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    static func save(_ entries: [SearchHistoryEntry], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
