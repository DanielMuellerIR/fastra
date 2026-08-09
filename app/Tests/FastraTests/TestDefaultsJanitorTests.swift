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

// Dieselbe Klasse Rückstand, andere Quelle: Der SIGKILL-Pfad-Test in
// `Tool4DLSPTests` startet bewusst einen Kindprozess, der SIGTERM blockiert und
// sich selbst stoppt. Im regulären Ablauf killt der Test ihn. Bricht der Lauf
// vorher ab (⌃C, Timeout, abgeschossener Testprozess), bleibt der gestoppte
// Prozess samt Skript liegen — beobachtet am 2026-07-28: ein solcher Rest war
// drei Tage alt, an launchd umgehängt und in Zustand `T`. Er verbraucht nichts,
// sammelt sich aber pro abgebrochenem Lauf an.

enum TestFixtureProcessJanitor {
    private static let uuidPattern =
        "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"

    /// Nur die eigene Fixture anfassen: bekanntes Präfix, UUID, `.sh`. Damit
    /// kann der Janitor kein fremdes Skript und keinen fremden Prozess treffen.
    private static let scriptPattern =
        "^fastra-tool4d-stop-" + uuidPattern + "\\.sh$"

    struct PurgeResult: Equatable {
        var scriptsRemoved = 0
        var processesKilled = 0
    }

    /// Beendet verwaiste Fixture-Prozesse früherer Läufe und löscht deren
    /// Skripte. Angefasst wird nur, was älter als `age` ist — ein parallel
    /// laufender Testprozess behält seine noch aktive Fixture.
    @discardableResult
    static func purgeStaleFixtures(
        olderThan age: TimeInterval = 3600,
        in directory: URL = FileManager.default.temporaryDirectory
    ) throws -> PurgeResult {
        let regex = try NSRegularExpression(pattern: scriptPattern)
        let cutoff = Date().addingTimeInterval(-age)
        var result = PurgeResult()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        for url in entries {
            let name = url.lastPathComponent
            let range = NSRange(name.startIndex..., in: name)
            guard regex.firstMatch(in: name, range: range) != nil else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            // Erst den Prozess beenden, dann das Skript entfernen — sonst
            // verlöre der nächste Lauf die Spur zum noch laufenden Rest.
            let outcome = killProcesses(runningScriptNamed: name)
            if outcome == .killed { result.processesKilled += 1 }
            // Scheiterte pkill (Startfehler oder Exit > 1), bleibt die
            // Skript-Spur ausdrücklich liegen: Sie ist der einzige Anker,
            // über den ein späterer Lauf den womöglich noch laufenden Rest
            // wiederfindet (Review 2026-08-02).
            guard outcome != .failed else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                result.scriptsRemoved += 1
            }
        }
        return result
    }

    /// Killt alle eigenen Prozesse, deren Kommandozeile dieses Skript nennt.
    ///
    /// Gesucht wird über den DATEINAMEN, nicht den vollen Pfad. Der Name trägt
    /// die UUID und ist damit eindeutig genug — der Pfad wäre dagegen unbrauchbar:
    /// `contentsOfDirectory` liefert die aufgelöste Form `/private/var/folders/…`,
    /// in der Kommandozeile des Prozesses steht aber `/var/folders/…`. Genau
    /// daran traf der erste Entwurf nie etwas und räumte still nichts auf
    /// (Befund 2026-07-28).
    ///
    /// SIGKILL ist Pflicht, nicht Härte: Die Fixture blockiert SIGTERM
    /// ausdrücklich und ist im echten Leck-Fall zusätzlich gestoppt.
    /// Ergebnis des pkill-Aufrufs — die Unterscheidung „nichts lief" von
    /// „pkill scheiterte" entscheidet, ob die Skript-Spur gelöscht werden darf.
    private enum KillOutcome {
        case killed        // Exit 0: mindestens ein Prozess getroffen
        case noneRunning   // Exit 1: kein passender Prozess
        case failed        // Startfehler oder Exit > 1
    }

    private static func killProcesses(runningScriptNamed name: String) -> KillOutcome {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // `-U` grenzt auf eigene Prozesse ein. `pkill` sucht und signalisiert in
        // einem Schritt — kein Pipe-Lesen, kein Ausgabe-Parsen, also auch keine
        // Stelle, an der ein Fehlschlag unbemerkt bleibt.
        pkill.arguments = ["-9", "-U", String(getuid()), "-f", name]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        // Bewusst ohne `waitUntilExit`: das dreht den RunLoop des aufrufenden
        // Threads (siehe AGENTS.md). Hier läuft kein SwiftUI-Layout, aber die
        // Regel gilt im ganzen Projekt einheitlich.
        let finished = DispatchSemaphore(value: 0)
        pkill.terminationHandler = { _ in finished.signal() }
        guard (try? pkill.run()) != nil else { return .failed }
        finished.wait()
        // Exit 0 = mindestens ein Treffer, 1 = nichts gefunden, >1 = Fehler.
        switch pkill.terminationStatus {
        case 0: return .killed
        case 1: return .noneRunning
        default: return .failed
        }
    }
}

@Test("Janitor beendet verwaiste Fixture-Prozesse, verschont frische",
      .timeLimit(.minutes(1)))
func janitorPurgesOnlyStaleFixtureProcesses() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-fixture-janitor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Wie die echte Fixture aus Tool4DLSPTests blockiert dieses Skript SIGTERM
    // — nur darauf kommt es dem Janitor an. Das dortige `kill -STOP $$` fehlt
    // hier bewusst: Auf einen gestoppten Kindprozess muss man mit
    // `waitpid(…, WUNTRACED)` warten, und dieses Warten hing im ersten Entwurf
    // dieses Tests dauerhaft. Ein laufender Prozess lässt sich nach dem SIGKILL
    // schlicht mit `waitpid(…, 0)` abholen. SIGKILL wirkt auf beide Zustände
    // gleich, die Aussage des Tests bleibt also vollständig.
    let fixture = """
    #!/bin/sh
    trap '' TERM
    while :; do /bin/sleep 1; done
    """
    func makeScript(uuid: String) throws -> URL {
        let url = directory.appendingPathComponent("fastra-tool4d-stop-\(uuid).sh")
        try Data(fixture.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: url.path)
        return url
    }
    // Bewusst `posix_spawn` statt Foundations `Process`: Dieser Test ist damit
    // der einzige Elternprozess und der einzige, der `waitpid` aufruft. Mit
    // `Process` kommt Foundations eigene Kindprozess-Überwachung dazu, und wer
    // von beiden ein Ereignis abbekommt, ist nicht festgelegt.
    //
    // stdout und stderr gehen ausdrücklich nach /dev/null. Ohne das erbt die
    // Fixture die Standardausgabe des Testprozesses — und das ist die Pipe, aus
    // der SwiftPM liest. Überlebt die Fixture den Test, wartet SwiftPM danach
    // auf ein EOF, das nie kommt: `swift test` hängt dann nach dem letzten
    // Testergebnis endlos (zweimal beobachtet am 2026-07-28, jeweils als
    // scheinbarer Hänger des Tests selbst).
    func launch(_ script: URL) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null",
                                             O_WRONLY, 0)
        }
        var pid: pid_t = 0
        let spawned = script.path.withCString { executable -> Int32 in
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), nil]
            defer { argv.forEach { free($0) } }
            return posix_spawn(&pid, executable, &actions, nil, &argv, environ)
        }
        #expect(spawned == 0, "Fixture konnte nicht gestartet werden (errno \(spawned))")
        return pid
    }

    /// Beendet einen Fixture-Prozess und holt ihn ab. Muss für JEDEN gestarteten
    /// Prozess laufen, auch für den, den der Janitor eigentlich killen soll:
    /// Scheitert der Janitor, darf der Rest nicht als verwaister Prozess
    /// zurückbleiben — sonst wird aus einem roten Test wieder ein Hänger.
    func terminate(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var ignored: Int32 = 0
        waitpid(pid, &ignored, 0)
    }

    /// `true`, solange der Kindprozess noch nicht beendet ist. Über `WNOHANG`,
    /// damit hier nichts blockieren kann.
    func stillRunning(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == 0
    }

    let stale = try makeScript(uuid: UUID().uuidString)
    let stalePID = try launch(stale)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)],
                                          ofItemAtPath: stale.path)
    let fresh = try makeScript(uuid: UUID().uuidString)
    let freshPID = try launch(fresh)
    // BEIDE aufräumen, unabhängig vom Ergebnis. Ein zweiter `terminate` auf
    // einen längst abgeholten Prozess ist harmlos (kill schlägt fehl, waitpid
    // liefert -1).
    defer {
        terminate(freshPID)
        terminate(stalePID)
    }

    // Belegen, dass SIGTERM hier NICHT genügt — sonst wäre die Kernaussage des
    // Janitors (SIGKILL ist Pflicht) nicht geprüft, sondern nur behauptet.
    kill(stalePID, SIGTERM)
    var termSurvived = false
    for _ in 0..<20 where stillRunning(stalePID) {
        usleep(20_000)
        termSurvived = true
    }
    #expect(termSurvived, "Fixture muss SIGTERM überleben")

    #expect(try TestFixtureProcessJanitor.purgeStaleFixtures(in: directory)
            == .init(scriptsRemoved: 1, processesKilled: 1))

    #expect(!FileManager.default.fileExists(atPath: stale.path),
            "Altes Fixture-Skript muss entfernt werden")
    #expect(FileManager.default.fileExists(atPath: fresh.path),
            "Frisches Skript (möglicher Parallel-Lauf) muss erhalten bleiben")
    // Nach dem SIGKILL ist der Kindprozess ein Zombie, bis dieser Test ihn
    // abholt. Deshalb `waitpid` statt `kill(pid, 0)` — letzteres meldet einen
    // Zombie noch als existent. Das Warten ist begrenzt: Räumt der Janitor
    // nicht auf, muss dieser Test ROT werden und nicht die Suite aufhängen.
    var staleStatus: Int32 = 0
    var reaped = false
    for _ in 0..<250 where !reaped {          // höchstens 5 s
        if waitpid(stalePID, &staleStatus, WNOHANG) == stalePID { reaped = true; break }
        usleep(20_000)
    }
    #expect(reaped, "Der alte Fixture-Prozess muss beendet und abholbar sein")
    if reaped {
        #expect(staleStatus & 0x7f == SIGKILL,
                "Die TERM-blockierende Fixture darf nur per SIGKILL enden")
    }
    #expect(stillRunning(freshPID), "Frischer Prozess muss weiterlaufen")
}

@Test("Aufräumlauf: verwaiste Fixture-Prozesse früherer Läufe beenden")
func purgeStaleFixtureProcesses() throws {
    // Kein Assert auf eine Mindestzahl: Auf einem sauberen System ist 0 korrekt.
    try TestFixtureProcessJanitor.purgeStaleFixtures()
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
