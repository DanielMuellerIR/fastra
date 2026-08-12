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
// Im Prozess wird über `removePersistentDomain` (cfprefsd-sauber) geleert.
// Der äußere Test-Runner bekommt zusätzlich die exakt registrierten Namen und
// entfernt eine von cfprefsd NACH Prozessende nochmals angelegte leere Plist.
// Erst dann existiert keine lebende UserDefaults-Instanz mehr, die sie erneut
// zurückschreiben könnte.

import Foundation

enum TestDefaultsPurge {

    /// Leitet den Dateipfad aus derselben CFFIXED_USER_HOME-Umgebung ab, die
    /// auch CFPreferences verwendet. `FileManager.homeDirectoryForCurrentUser`
    /// bleibt trotz Test-Sandbox auf dem echten Benutzerordner und würde beim
    /// Nachräumen genau dort leere UUID-Plists anfassen.
    static func resolvedPreferencesDirectory(
        explicit: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicit { return explicit.standardizedFileURL }
        if let fixedHome = environment["CFFIXED_USER_HOME"], !fixedHome.isEmpty {
            return URL(fileURLWithPath: fixedHome, isDirectory: true)
                .appendingPathComponent("Library/Preferences", isDirectory: true)
                .standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .standardizedFileURL
    }

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

    private static let safeNamePattern = try? NSRegularExpression(
        pattern: "^[A-Za-z0-9._-]+$"
    )

    /// `true` nur für Domains, die ein Test-Präfix tragen UND eine UUID im
    /// Namen haben.
    static func isTestDomain(_ name: String) -> Bool {
        guard prefixes.contains(where: { name.hasPrefix($0) }),
              let uuidPattern, let safeNamePattern else { return false }
        let range = NSRange(name.startIndex..., in: name)
        return safeNamePattern.firstMatch(in: name, range: range)?.range == range
            && uuidPattern.firstMatch(in: name, range: range) != nil
    }

    // MARK: - Registry (eigene Suiten dieses Prozesses)

    private static var registered = Set<String>()
    private static var registeredWithRunner = Set<String>()
    private static let lock = NSLock()

    /// Merkt eine in diesem Prozess angelegte Test-Suite zum Abräumen vor.
    @discardableResult
    static func register(
        _ name: String,
        runnerRegistryPath: String? = ProcessInfo.processInfo.environment[
            "FASTRA_TEST_DEFAULTS_REGISTRY"
        ]
    ) -> Bool {
        guard isTestDomain(name) else { return false }
        return lock.withLock {
            registered.insert(name)
            guard !registeredWithRunner.contains(name),
                  let path = runnerRegistryPath, !path.isEmpty else { return true }
            let url = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: path) {
                guard FileManager.default.createFile(
                    atPath: path, contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else { return false }
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return false }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((name + "\n").utf8))
                try handle.close()
                registeredWithRunner.insert(name)
                return true
            } catch {
                // Der normale prozessinterne Purge bleibt weiterhin aktiv.
                // Der Runner übernimmt die Datei nur als zweite Absicherung
                // NACH dem Ende von cfprefsd-Schreibvorgängen.
                try? handle.close()
                return false
            }
        }
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
        lock.withLock {
            registered.subtract(succeeded)
            registeredWithRunner.subtract(succeeded)
        }
    }

    /// Nur für den Regressionstest der Registry-Entscheidung.
    static func isRegistered(_ name: String) -> Bool {
        lock.withLock { registered.contains(name) }
    }

    /// Gemeinsamer Kern beider Purge-Wege.
    private static func purge(names: Set<String>,
                              preferencesDirectory: URL?) -> [String] {
        let directory = resolvedPreferencesDirectory(explicit: preferencesDirectory)
        var remaining: [String] = []
        for name in names {
            guard isTestDomain(name) else {
                remaining.append(name)
                continue
            }
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
            let normalizedDirectory = directory
            let plist = normalizedDirectory
                .appendingPathComponent(name + ".plist", isDirectory: false)
                .standardizedFileURL
            guard plist.deletingLastPathComponent() == normalizedDirectory else {
                remaining.append(name)
                continue
            }
            do {
                try FileManager.default.removeItem(at: plist)
            } catch where (error as NSError).code == NSFileNoSuchFileError {
                // Schon weg ist ebenfalls Erfolg.
            } catch {
                remaining.append(name)
            }
            // Verifikation direkt an cfprefsd vorbeigefragt, nicht am
            // möglicherweise veralteten Instanz-Cache.
            if let keys = CFPreferencesCopyKeyList(
                name as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
            ), CFArrayGetCount(keys) > 0 {
                if !remaining.contains(name) { remaining.append(name) }
            }
            if FileManager.default.fileExists(atPath: plist.path),
               !remaining.contains(name) {
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
        let directory = resolvedPreferencesDirectory(explicit: preferencesDirectory)
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
