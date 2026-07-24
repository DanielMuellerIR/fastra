import Foundation
import Testing

// Viele Tests legen pro Lauf eigene UserDefaults-Suiten mit UUID-Namen an
// (z. B. "Fastra-DiffLifecycle-<UUID>"). `removePersistentDomain` leert die
// Suite zwar, aber cfprefsd lässt die dann leere Plist-Datei in
// ~/Library/Preferences häufig liegen. Über Monate sammeln sich so tausende
// tote Domains in `defaults domains` an (Befund 2026-07-25: über 8000 Stück).
// Der Janitor unten räumt diese Reste bei jedem vollen `swift test` auf und
// hält den Bestand damit dauerhaft klein.

enum TestDefaultsJanitor {
    /// UUID-Suffix, wie `UUID().uuidString` es erzeugt (Großbuchstaben).
    private static let uuidPattern =
        "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"

    /// Nur Namen anfassen, die eindeutig aus unseren Tests stammen: bekanntes
    /// Präfix UND UUID am Ende. Echte App-Domains (io.github.fastra…) haben
    /// nie ein UUID-Suffix und bleiben dadurch garantiert unberührt.
    private static let stalePattern =
        "^(Fastra-|fastra-|ff-|fastra\\.tests\\.)[A-Za-z0-9._-]*" + uuidPattern + "$"

    /// Löscht verwaiste Test-Suiten aus früheren Läufen. Gelöscht wird nur,
    /// was dem Muster oben entspricht und älter als eine Stunde ist — so
    /// behalten parallel laufende Testprozesse ihre noch aktiven Suiten.
    /// Rückgabe: Anzahl der entfernten Domains.
    @discardableResult
    static func purgeStaleDomains(olderThan age: TimeInterval = 3600) throws -> Int {
        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        let regex = try NSRegularExpression(pattern: stalePattern)
        let cutoff = Date().addingTimeInterval(-age)
        var removed = 0
        let entries = try FileManager.default.contentsOfDirectory(
            at: preferences, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        for url in entries where url.pathExtension == "plist" {
            let name = url.deletingPathExtension().lastPathComponent
            let range = NSRange(name.startIndex..., in: name)
            guard regex.firstMatch(in: name, range: range) != nil else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            // Erst die Suite über cfprefsd leeren, dann die Datei entfernen.
            // Das Löschen darf still scheitern (z. B. Rennen mit cfprefsd);
            // der nächste Lauf räumt den Rest auf.
            UserDefaults.standard.removePersistentDomain(forName: name)
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}

@Test("Janitor entfernt verwaiste Test-Domains, verschont aktive und fremde")
func janitorPurgesOnlyStaleTestDomains() throws {
    let preferences = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences", isDirectory: true)
    let uuid = UUID().uuidString
    let staleName = "fastra-janitor-selftest-\(uuid)"
    let staleURL = preferences.appendingPathComponent(staleName + ".plist")
    // Eine künstlich gealterte Test-Domain-Plist direkt anlegen …
    try Data("bplist-fake".utf8).write(to: staleURL)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)],
                                          ofItemAtPath: staleURL.path)
    // … und eine frische, die ein parallel laufender Test gerade nutzen könnte.
    let freshName = "fastra-janitor-fresh-\(UUID().uuidString)"
    let freshURL = preferences.appendingPathComponent(freshName + ".plist")
    try Data("bplist-fake".utf8).write(to: freshURL)
    defer { try? FileManager.default.removeItem(at: freshURL) }
    defer { try? FileManager.default.removeItem(at: staleURL) }

    try TestDefaultsJanitor.purgeStaleDomains()

    #expect(!FileManager.default.fileExists(atPath: staleURL.path),
            "Alte Test-Domain muss entfernt werden")
    #expect(FileManager.default.fileExists(atPath: freshURL.path),
            "Frische Domain (möglicher Parallel-Lauf) muss erhalten bleiben")
}

@Test("Aufräumlauf: verwaiste Test-Domains früherer Läufe entfernen")
func purgeStaleTestDefaultsDomains() throws {
    // Kein Assert auf eine Mindestzahl: Auf einem sauberen System ist 0 korrekt.
    try TestDefaultsJanitor.purgeStaleDomains()
}
