// TestDefaultsPurge.swift
//
// Räumt die von Unit-Tests und In-App-Selbsttests angelegten
// Preferences-Domains wieder ab. Hintergrund (Roadmap, gemeldet 2026-07-28):
// Jeder Testlauf legte unter `~/Library/Preferences` eigene Domains mit UUID
// im Namen an und ließ sie liegen — gefunden wurden 3713 Plists (~22 MB).
// Das war nicht nur Unordnung: cfprefsd kam mit der Domain-Flut nicht mehr
// klar, `defaults read` lieferte für fremde Domains NICHTS mehr, und
// Terminal.app startete mit dem Standardprofil statt der Nutzereinstellungen.
//
// Zwei getrennte Wege, bewusst beide parallel-läufer-sicher:
//
// 1. REGISTRY: Jede über `register(_:)` gemeldete Suite dieses Prozesses wird
//    am Prozessende gezielt entfernt (`purgeRegistered`). Das trifft exakt
//    die eigenen Suiten — nie die eines gleichzeitig laufenden zweiten
//    Testprozesses (z. B. Worktree-Parallelarbeit).
// 2. STALE: `purgeStale` entfernt Reste früherer, abgestürzter Läufe — nur
//    Domains mit Test-Präfix UND UUID im Namen UND älter als eine Stunde.
//    Echte Nutzer-Domains tragen nie eine UUID im Namen; das Alter schützt
//    die noch aktiven Suiten paralleler Prozesse.
//
// Entfernt wird über `removePersistentDomain` (cfprefsd-sauber), nicht durch
// rohes Datei-Löschen.

import Foundation

enum TestDefaultsPurge {

    /// Präfixe, unter denen Tests und Selbsttests eigene Suiten anlegen.
    /// Neue Test-Suiten sollten unter einem dieser Präfixe bleiben — sonst
    /// sieht der Stale-Aufräumer sie nicht.
    static let prefixes = [
        "FastraTests.",
        "Fastra-",
        "fastra-",
        "fastra.tests.",
        "ff-",
        "search-jump-",
        "smart-paste-context-",
    ]

    private static let uuidPattern = try? NSRegularExpression(
        pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    )

    /// `true` nur für Domains, die ein Test-Präfix tragen UND eine UUID im
    /// Namen haben.
    static func isTestDomain(_ name: String) -> Bool {
        guard prefixes.contains(where: { name.hasPrefix($0) }),
              let uuidPattern else { return false }
        let range = NSRange(name.startIndex..., in: name)
        return uuidPattern.firstMatch(in: name, range: range) != nil
    }

    // MARK: - Registry (eigene Suiten dieses Prozesses)

    private static var registered = Set<String>()
    private static let lock = NSLock()

    /// Merkt eine in diesem Prozess angelegte Test-Suite zum Abräumen vor.
    static func register(_ name: String) {
        lock.withLock { _ = registered.insert(name) }
    }

    /// Entfernt genau die registrierten Suiten dieses Prozesses.
    /// Rückgabe: Domains, die sich NICHT entfernen ließen (sollte leer sein);
    /// der Aufrufer meldet sie sichtbar.
    @discardableResult
    static func purgeRegistered(preferencesDirectory: URL? = nil) -> [String] {
        let names = lock.withLock { registered }
        let remaining = purge(names: names, preferencesDirectory: preferencesDirectory)
        updateRegistration(afterAttempting: names, remaining: remaining)
        return remaining
    }

    /// Entfernt GENAU EINE registrierte Suite und meldet sie ab.
    ///
    /// Nötig für Tests, die den Registry-Weg selbst prüfen: `purgeRegistered()`
    /// räumt alle bis dahin registrierten Suiten des Prozesses ab — mitten im
    /// standardmäßig parallelen Testlauf verlören dadurch gleichzeitig
    /// laufende Tests ihren Preferences-Zustand.
    @discardableResult
    static func purgeRegistered(only name: String,
                                preferencesDirectory: URL? = nil) -> [String] {
        let attempted: Set<String> = [name]
        let remaining = purge(names: attempted,
                              preferencesDirectory: preferencesDirectory)
        updateRegistration(afterAttempting: attempted, remaining: remaining)
        return remaining
    }

    /// Meldet nur bestätigte Erfolge ab. Fehlgeschlagene Domains bleiben für
    /// den prozessweiten `atexit`-Versuch registriert; andere Suite-Namen, die
    /// parallel zum Purge hinzukommen, werden nicht angetastet.
    static func updateRegistration(afterAttempting names: Set<String>,
                                   remaining: [String]) {
        let succeeded = names.subtracting(remaining)
        lock.withLock { registered.subtract(succeeded) }
    }

    /// Nur für den Regressionstest der Registry-Entscheidung.
    static func isRegistered(_ name: String) -> Bool {
        lock.withLock { registered.contains(name) }
    }

    /// Gemeinsamer Kern beider Purge-Wege.
    private static func purge(names: Set<String>,
                              preferencesDirectory: URL?) -> [String] {
        let directory = preferencesDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences", isDirectory: true)
        var remaining: [String] = []
        for name in names {
            // Über eine EIGENE Instanz der Suite entfernen und sofort
            // synchronisieren: `removePersistentDomain` über `.standard`
            // ließ beschriebene Suiten beim Prozessende stehen — die
            // Suite-Instanz der Tests hielt ihren Stand noch im Speicher.
            let defaults = UserDefaults(suiteName: name)
            defaults?.removePersistentDomain(forName: name)
            defaults?.synchronize()
            // `removePersistentDomain` LEERT die Domain, lässt aber die dann
            // inhaltslose Plist-Datei liegen — genau daraus entstand der
            // 3713-Dateien-Berg. Die eigene Datei deshalb mit entfernen.
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(name + ".plist"))
            // Verifikation direkt an cfprefsd vorbeigefragt, nicht am
            // möglicherweise veralteten Instanz-Cache.
            if let keys = CFPreferencesCopyKeyList(
                name as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
            ), CFArrayGetCount(keys) > 0 {
                remaining.append(name)
            }
        }
        return remaining
    }

    // MARK: - Stale (Reste abgestürzter früherer Läufe)

    /// Entfernt liegengebliebene Test-Domains früherer Läufe. Das Alter
    /// schützt aktive Suiten parallel laufender Testprozesse.
    /// Rückgabe: Anzahl der entfernten Domains.
    @discardableResult
    static func purgeStale(olderThan age: TimeInterval = 3600,
                           preferencesDirectory: URL? = nil) -> Int {
        let directory = preferencesDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-age)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        var removed = 0
        for url in entries where url.pathExtension == "plist" {
            let domain = url.deletingPathExtension().lastPathComponent
            guard isTestDomain(domain) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            UserDefaults.standard.removePersistentDomain(forName: domain)
            // Die leere Plist kann cfprefsd liegen lassen — dann gezielt weg;
            // ein Scheitern räumt der nächste Lauf ab.
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }
}
