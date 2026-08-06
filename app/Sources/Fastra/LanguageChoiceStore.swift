// LanguageChoiceStore.swift
//
// Merkt sich die manuelle Formatwahl aus dem Sprach-Chip der Fußzeile pro
// DATEI. Ohne diesen Speicher galt die Wahl nur für den geöffneten Tab: Nach
// dem Schließen der Datei oder einem Neustart fiel Fastra auf die Automatik
// zurück. Bei einer Datei OHNE Endung ist die Automatik machtlos — die Wahl
// war also genau dort verloren, wo sie am nötigsten ist (Daniel-Befund
// 2026-08-06).
//
// Gespeichert wird ausschließlich der stabile Menü-Bezeichner der Wahl
// (`LanguageMenuSupport.Entry.id`), nie ein Dokumentinhalt.

import Foundation

/// Persistenter Zuordnungsspeicher „Dateipfad → gewähltes Format".
final class LanguageChoiceStore {

    struct Payload: Codable, Equatable {
        var version: Int
        /// Pfade in Reihenfolge der letzten Benutzung (vorn = zuletzt).
        /// Nur dafür da, den Speicher beschnitten zu halten.
        var order: [String]
        /// Pfad → `LanguageMenuSupport.Entry.id`.
        var choices: [String: String]
    }

    enum Keys {
        static let choices = "editor.languageChoices"
    }

    static let currentVersion = 1
    /// Obergrenze, damit die Liste über Jahre nicht unbegrenzt wächst. Die
    /// zuletzt benutzten Einträge bleiben erhalten.
    static let maximumEntries = 300

    private let defaults: UserDefaults
    private var payload: Payload

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.choices),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data),
           decoded.version >= 1 {
            payload = Self.normalized(decoded)
        } else {
            payload = Payload(version: Self.currentVersion, order: [], choices: [:])
        }
    }

    /// Gemerkte Wahl einer Datei — `nil`, wenn die Automatik gilt.
    func choiceID(for url: URL) -> String? {
        payload.choices[Self.key(for: url)]
    }

    /// Setzt die Wahl einer Datei. `nil` bedeutet „Automatisch" und löscht
    /// den Eintrag, statt eine leere Zeichenkette zu hinterlassen.
    func setChoiceID(_ id: String?, for url: URL) {
        let key = Self.key(for: url)
        payload.order.removeAll { $0 == key }
        if let id {
            payload.choices[key] = id
            payload.order.insert(key, at: 0)
        } else {
            payload.choices.removeValue(forKey: key)
        }
        payload = Self.normalized(payload)
        persist()
    }

    /// Kanonischer Pfad als Schlüssel: `/var/…` und `/private/var/…` sind
    /// dieselbe Datei und dürfen keine zwei Einträge erzeugen.
    private static func key(for url: URL) -> String {
        url.canonicalFileURL.path
    }

    /// Beschneidet auf `maximumEntries` und wirft verwaiste Einträge weg
    /// (Reihenfolge ohne Wahl beziehungsweise Wahl ohne Reihenfolge).
    static func normalized(_ source: Payload) -> Payload {
        var result = source
        result.version = currentVersion
        // Bekannte Reihenfolge zuerst, danach alles, was nur in `choices`
        // steht (etwa aus einem von Hand bearbeiteten Defaults-Eintrag).
        var seen = Set<String>()
        var order = source.order.filter { key in
            source.choices[key] != nil && seen.insert(key).inserted
        }
        order.append(contentsOf: source.choices.keys.sorted().filter {
            seen.insert($0).inserted
        })
        if order.count > maximumEntries {
            order = Array(order.prefix(maximumEntries))
        }
        let kept = Set(order)
        result.order = order
        result.choices = source.choices.filter { kept.contains($0.key) }
        return result
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Keys.choices)
    }
}
