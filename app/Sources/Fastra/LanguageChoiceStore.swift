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
///
/// Der Speicher hält bewusst KEINE Kopie des Inhalts. Jedes Dokumentfenster
/// erzeugt sich eine eigene Instanz; eine beim Initialisieren geladene und
/// später vollständig zurückgeschriebene Kopie hätte deshalb alles
/// überschrieben, was ein anderes Fenster inzwischen gespeichert hat — die
/// Wahl aus Fenster A verschwand, sobald Fenster B eine eigene Wahl traf
/// (Review 2026-08-06, Regel in AGENTS.md). Gelesen und geändert wird
/// stattdessen immer der aktuelle Stand aus den Defaults.
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

    /// Hält Lesen–Ändern–Schreiben zusammen. Alle Instanzen im Prozess teilen
    /// sich diese Sperre: Zwei Fenster ändern denselben Defaults-Eintrag, und
    /// eine Änderung darf nicht mitten in der Änderung des anderen Fensters
    /// landen. Die Sperre ist nur für die Dauer eines Zugriffs gehalten.
    private static let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Gemerkte Wahl einer Datei — `nil`, wenn die Automatik gilt.
    func choiceID(for url: URL) -> String? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return Self.loadPayload(from: defaults).choices[Self.key(for: url)]
    }

    /// Setzt die Wahl einer Datei. `nil` bedeutet „Automatisch" und löscht
    /// den Eintrag, statt eine leere Zeichenkette zu hinterlassen.
    func setChoiceID(_ id: String?, for url: URL) {
        let key = Self.key(for: url)
        mutate { payload in
            payload.order.removeAll { $0 == key }
            if let id {
                payload.choices[key] = id
                payload.order.insert(key, at: 0)
            } else {
                payload.choices.removeValue(forKey: key)
            }
        }
    }

    /// Zieht gemerkte Wahlen nach einer Datei- oder Ordnerumbenennung mit.
    ///
    /// Die Schlüssel sind Dateipfade. Ohne diese Migration bliebe der Eintrag
    /// am ALTEN Pfad liegen: Die verschobene Datei öffnete danach wieder mit
    /// der Automatik, und der verwaiste Eintrag belegte bis zur
    /// Größenbegrenzung Platz. Bei einem Ordner wandert der gesamte
    /// Pfadpräfix mit — auch für Dateien, die gar nicht offen sind und für
    /// die es deshalb keinen Tab gibt, über den man nachbessern könnte
    /// (Review 2026-08-06).
    func moveChoices(from source: URL, to destination: URL) {
        let destinationKey = Self.key(for: destination)
        // Die Quelle gibt es beim Aufruf meist NICHT mehr: Die Umbenennung
        // ist schon ausgeführt, erst danach zieht Fastra seinen Zustand nach.
        // `canonicalPath` beantwortet nur vorhandene Pfade, liefert also den
        // rohen Pfad zurück. Der zweite Kandidat setzt den Schlüssel deshalb
        // aus dem kanonischen ELTERNORDNER und dem alten Namen zusammen —
        // genau so, wie er beim Speichern entstanden ist.
        var sourceKeys: [String] = []
        for candidate in [Self.key(for: source), Self.keyViaParent(for: source)]
        where candidate != destinationKey && !sourceKeys.contains(candidate) {
            sourceKeys.append(candidate)
        }
        guard !sourceKeys.isEmpty else { return }

        mutate { payload in
            // Erst sammeln, dann umhängen: Ein Wörterbuch darf nicht
            // verändert werden, während über seine Schlüssel gelaufen wird.
            var renames: [String: String] = [:]
            for key in payload.choices.keys {
                for sourceKey in sourceKeys where renames[key] == nil {
                    if key == sourceKey {
                        renames[key] = destinationKey
                    } else if key.hasPrefix(sourceKey + "/") {
                        let relative = String(key.dropFirst(sourceKey.count + 1))
                        renames[key] = destinationKey + "/" + relative
                    }
                }
            }
            guard !renames.isEmpty else { return }

            for (oldKey, newKey) in renames {
                payload.choices[newKey] = payload.choices.removeValue(forKey: oldKey)
                // Ein bereits vorhandener Eintrag am Ziel wird ersetzt — nach
                // dem Verschieben IST die Quelldatei die Datei am Zielpfad.
                payload.order.removeAll { $0 == newKey }
            }
            payload.order = payload.order.map { renames[$0] ?? $0 }
        }
    }

    /// Kanonischer Pfad als Schlüssel: `/var/…` und `/private/var/…` sind
    /// dieselbe Datei und dürfen keine zwei Einträge erzeugen.
    private static func key(for url: URL) -> String {
        url.canonicalFileURL.path
    }

    /// Schlüssel für einen Pfad, den es womöglich nicht mehr gibt: Der
    /// Elternordner wird kanonisiert, der Name unverändert angehängt.
    private static func keyViaParent(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        return standardized.deletingLastPathComponent().canonicalFileURL
            .appendingPathComponent(standardized.lastPathComponent).path
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

    /// Lesen, ändern, zurückschreiben — als eine ununterbrochene Einheit.
    /// Geändert wird immer der FRISCH gelesene Stand, nie eine alte Kopie.
    private func mutate(_ change: (inout Payload) -> Void) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let current = Self.loadPayload(from: defaults)
        var updated = current
        change(&updated)
        updated = Self.normalized(updated)
        // Ohne echte Änderung nicht schreiben: Das spart überflüssige
        // Defaults-Schreibvorgänge, etwa beim Verschieben einer Datei ohne
        // gemerkte Wahl.
        guard updated != current else { return }
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: Keys.choices)
    }

    private static func loadPayload(from defaults: UserDefaults) -> Payload {
        guard let data = defaults.data(forKey: Keys.choices),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data),
              decoded.version >= 1 else {
            return Payload(version: currentVersion, order: [], choices: [:])
        }
        return decoded
    }
}
