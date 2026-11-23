// TestDefaultsPurge.swift
//
// Räumt Test-Preferences-Domains ab, damit abgestürzte Läufe cfprefsd nicht
// mit dauerhaft liegengebliebenen Domains belasten.
//
// 1. `purgeRegistered` entfernt genau die per `register(_:)` gemeldeten Suiten
//    dieses Prozesses; parallele Testprozesse bleiben unberührt.
// 2. `purgeStale` entfernt frühere Reste nur mit Testpräfix, UUID im Namen und
//    Mindestalter einer Stunde. Das Alter schützt aktive parallele Suiten.
//
// Im Prozess per `removePersistentDomain` leeren. Der äußere Runner erhält
// die registrierten Namen und entfernt nach Prozessende nochmals angelegte
// leere Plists; dann kann keine lebende UserDefaults-Instanz sie zurückschreiben.

import Foundation
import Darwin

enum TestDefaultsPurge {

    /// Leitet den Dateipfad aus derselben CFFIXED_USER_HOME-Umgebung ab, die
    /// auch CFPreferences verwendet. `FileManager.homeDirectoryForCurrentUser`
    /// bleibt trotz Test-Sandbox auf dem echten Benutzerordner und würde beim
    /// Nachräumen genau dort leere UUID-Plists anfassen.
    static func resolvedPreferencesDirectory(
        explicit: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        // Als Verzeichnis normalisieren, damit der Containment-Vergleich in `purge`
        // nicht davon abhängt, ob `standardizedFileURL` den Pfad bereits auf dem
        // Dateisystem als Verzeichnis erkennen kann.
        if let explicit {
            return URL(fileURLWithPath: explicit.path, isDirectory: true)
                .standardizedFileURL
        }
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

    /// `true` nur für Domains, die ein Test-Präfix tragen und eine UUID im
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
            let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return false }
            var needsClose = true
            defer {
                if needsClose { Darwin.close(descriptor) }
            }
            // Append allein schützt keine Zeile, die writeAll in mehreren
            // Teilschritten schreibt. Die Dateisperre schützt kooperierende Prozesse.
            var lockResult: Int32
            repeat {
                lockResult = flock(descriptor, LOCK_EX)
            } while lockResult == -1 && errno == EINTR
            guard lockResult == 0 else { return false }
            do {
                try Data((name + "\n").utf8).withUnsafeBytes {
                    try POSIXBufferWriter.writeAll($0, to: descriptor)
                }
                // close gibt zugleich die Sperre frei. Auch bei einem Fehler
                // nicht erneut schließen: Die Nummer könnte schon neu vergeben sein.
                let closeResult = Darwin.close(descriptor)
                needsClose = false
                guard closeResult == 0 else { return false }
                registeredWithRunner.insert(name)
                return true
            } catch {
                // Der normale prozessinterne Purge bleibt weiterhin aktiv.
                // Der Runner übernimmt die Datei nur als zweite Absicherung
                // nach dem Ende von cfprefsd-Schreibvorgängen.
                return false
            }
        }
    }

    /// Entfernt genau die registrierten Suiten dieses Prozesses.
    /// Rückgabe: Domains, die sich nicht entfernen ließen (sollte leer sein);
    /// der Aufrufer meldet sie sichtbar.
    @discardableResult
    static func purgeRegistered(preferencesDirectory: URL? = nil) -> [String] {
        let names = lock.withLock { registered }
        let remaining = purge(names: names, preferencesDirectory: preferencesDirectory)
        updateRegistration(afterAttempting: names, remaining: remaining)
        return remaining
    }

    /// Entfernt genau eine registrierte Suite und meldet sie ab.
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
            // Über eine eigene Instanz der Suite entfernen und sofort
            // synchronisieren: `removePersistentDomain` über `.standard`
            // ließ beschriebene Suiten beim Prozessende stehen — die
            // Suite-Instanz der Tests hielt ihren Stand noch im Speicher.
            let defaults = UserDefaults(suiteName: name)
            defaults?.removePersistentDomain(forName: name)
            defaults?.synchronize()
            // `removePersistentDomain` leert die Domain, lässt aber die dann
            // inhaltslose Plist-Datei liegen — genau daraus entstand der
            // 3713-Dateien-Berg. Die eigene Datei deshalb mit entfernen.
            let plist = directory
                .appendingPathComponent(name + ".plist", isDirectory: false)
                .standardizedFileURL
            // Über die Pfade vergleichen, nicht über die URLs: Zwei URLs auf
            // dasselbe Verzeichnis gelten als verschieden, sobald eine davon
            // den Schrägstrich am Ende trägt.
            guard plist.deletingLastPathComponent().path == directory.path else {
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
        // Zeigt das Verzeichnis woanders hin als das Preferences-Home dieses
        // Prozesses, bleibt es beim reinen Dateiaufräumen. Vorher folgte der
        // Dateipfad dem Argument, `removePersistentDomain` aber immer dem
        // eigenen Home — die Funktion räumte also an einer Stelle auf und
        // fasste eine ganz andere an. Ein Schaden ließ sich nicht nachweisen:
        // Ein Testlauf gegen die alte Fassung erzeugte im eigenen Home keine
        // Datei (die leere Plist, vor der `test-sandbox.sh` warnt, entsteht
        // nur zeitweise und nicht bei jedem Aufruf). Die Unstimmigkeit bleibt
        // trotzdem eine Falle für den nächsten Aufrufer.
        let ownDirectory = resolvedPreferencesDirectory()
        let touchesOwnDomains = directory.path == ownDirectory.path
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
            if touchesOwnDomains {
                // Denselben Weg wie `purge` gehen: eine eigene Suite-Instanz
                // plus `synchronize()`. Über `.standard` blieben beschriebene
                // Suiten beim Prozessende stehen (siehe Begründung dort).
                let defaults = UserDefaults(suiteName: domain)
                defaults?.removePersistentDomain(forName: domain)
                defaults?.synchronize()
            }
            // Die leere Plist kann cfprefsd liegen lassen — dann gezielt weg;
            // ein Scheitern räumt der nächste Lauf ab.
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }
}
