import Foundation
import Testing
@testable import Fastra

// Preferences haben genau einen Aufräumkern: TestDefaultsPurge. Die Tests
// hier prüfen ihn an eigenen Verzeichnissen; TestSuiteDefaults übernimmt
// den echten Abschluss einmalig über atexit statt über einen assertfreien Test.

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
        in directory: URL = testTemporaryDirectory()
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
func serialRunnerIntegrationJanitorPurgesOnlyStaleFixtureProcesses() throws {
    let directory = testTemporaryDirectory()
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
    : > "$0.ready"
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
        try #require(posix_spawn_file_actions_init(&actions) == 0)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
            try #require(posix_spawn_file_actions_addopen(
                &actions, descriptor, "/dev/null", O_WRONLY, 0) == 0)
        }
        var pid: pid_t = 0
        let spawned = script.path.withCString { executable -> Int32 in
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), nil]
            defer { argv.forEach { free($0) } }
            return posix_spawn(&pid, executable, &actions, nil, &argv, environ)
        }
        // Eine fehlgeschlagene Erzeugung lässt pid bei 0. Diese Zahl darf
        // niemals an kill gehen: Sie bezeichnet die gesamte Prozessgruppe.
        try #require(spawned == 0 && pid > 0,
                     "Fixture konnte nicht gestartet werden (errno \(spawned))")
        return pid
    }

    /// Beendet einen Fixture-Prozess und holt ihn ab. Muss für JEDEN gestarteten
    /// Prozess laufen, auch für den, den der Janitor eigentlich killen soll:
    /// Scheitert der Janitor, darf der Rest nicht als verwaister Prozess
    /// zurückbleiben — sonst wird aus einem roten Test wieder ein Hänger.
    func terminate(_ pid: inout pid_t?) {
        // Solange das Kind noch nicht abgeholt ist, kann seine PID nicht
        // neu vergeben werden. Bereits abgeholte Kinder werden nie signalisiert.
        guard stillRunning(&pid), let child = pid else { return }
        kill(child, SIGKILL)
        var ignored: Int32 = 0
        while waitpid(child, &ignored, 0) == -1 && errno == EINTR {}
        pid = nil
    }

    /// `true`, solange der Kindprozess noch nicht beendet ist. Über `WNOHANG`,
    /// damit hier nichts blockieren kann.
    func stillRunning(_ pid: inout pid_t?) -> Bool {
        guard let child = pid else { return false }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(child, &status, WNOHANG)
        } while result == -1 && errno == EINTR
        if result == 0 { return true }
        if result == child || (result == -1 && errno == ECHILD) { pid = nil }
        return false
    }

    let stale = try makeScript(uuid: UUID().uuidString)
    var stalePID: pid_t? = try launch(stale)
    defer { terminate(&stalePID) }
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)],
                                          ofItemAtPath: stale.path)
    let fresh = try makeScript(uuid: UUID().uuidString)
    var freshPID: pid_t? = try launch(fresh)
    // Jeden erfolgreichen Start sofort absichern, auch wenn schon der
    // Aufbau der zweiten Fixture wirft. Abgeholte PIDs werden oben verworfen.
    defer { terminate(&freshPID) }

    // Erst nach der installierten Trap signalisieren. Ein fester Zeitabstand
    // beweist unter Last nicht, dass die Shell schon so weit gekommen ist.
    for script in [stale, fresh] {
        let ready = script.appendingPathExtension("ready")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready.path) {
            usleep(10_000)
        }
        try #require(FileManager.default.fileExists(atPath: ready.path),
                     "Fixture hat ihre TERM-Trap nicht rechtzeitig eingerichtet")
    }
    // Belegen, dass SIGTERM hier NICHT genügt — sonst wäre die Kernaussage des
    // Janitors (SIGKILL ist Pflicht) nicht geprüft, sondern nur behauptet.
    #expect(kill(try #require(stalePID), SIGTERM) == 0)
    #expect(stillRunning(&stalePID), "Fixture muss SIGTERM überleben")

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
        guard let child = stalePID else { break }
        if waitpid(child, &staleStatus, WNOHANG) == child {
            stalePID = nil
            reaped = true
            break
        }
        usleep(20_000)
    }
    #expect(reaped, "Der alte Fixture-Prozess muss beendet und abholbar sein")
    if reaped {
        #expect(staleStatus & 0x7f == SIGKILL,
                "Die TERM-blockierende Fixture darf nur per SIGKILL enden")
    }
    #expect(stillRunning(&freshPID), "Frischer Prozess muss weiterlaufen")
}

@Test("Aufräumlauf: verwaiste Fixture-Prozesse früherer Läufe beenden")
func purgeStaleFixtureProcesses() throws {
    // Kein Assert auf eine Mindestzahl: Auf einem sauberen System ist 0 korrekt.
    try TestFixtureProcessJanitor.purgeStaleFixtures()
}

@Test("Janitor entfernt verwaiste Test-Domains, verschont aktive und fremde")
func janitorPurgesOnlyStaleTestDomains() throws {
    let preferences = testTemporaryDirectory()
        .appendingPathComponent("fastra-preferences-test-\(UUID().uuidString)",
                              isDirectory: true)
    try FileManager.default.createDirectory(
        at: preferences, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: preferences) }
    let uuid = UUID().uuidString
    let staleName = "FastraTests.Janitor.\(uuid.lowercased()).probe"
    let staleURL = preferences.appendingPathComponent(staleName + ".plist")
    // Eine künstlich gealterte Test-Domain-Plist direkt anlegen …
    try Data("bplist-fake".utf8).write(to: staleURL)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)],
                                          ofItemAtPath: staleURL.path)
    // … und eine frische, die ein parallel laufender Test gerade nutzen könnte.
    let freshName = "fastra-janitor-fresh-\(UUID().uuidString)"
    let freshURL = preferences.appendingPathComponent(freshName + ".plist")
    try Data("bplist-fake".utf8).write(to: freshURL)
    let foreignURL = preferences.appendingPathComponent("org.example.\(uuid).plist")
    let fixedURL = preferences.appendingPathComponent("Fastra-feste-suite.plist")
    let protectedContents = Data("fremder Bestand".utf8)
    for url in [foreignURL, fixedURL] {
        try protectedContents.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7200)],
            ofItemAtPath: url.path)
    }
    // Auch eine reine CFPreferences-Löschung kann verzögert eine leere Plist
    // erzeugen. Den zufälligen eigenen Namen deshalb dem äußeren Runner melden.
    try #require(TestDefaultsPurge.register(staleName))
    defer { try? FileManager.default.removeItem(at: freshURL) }
    defer { try? FileManager.default.removeItem(at: staleURL) }

    #expect(TestDefaultsPurge.purgeStale(preferencesDirectory: preferences) == 1)

    #expect(!FileManager.default.fileExists(atPath: staleURL.path),
            "Alte Test-Domain muss entfernt werden")
    #expect(FileManager.default.fileExists(atPath: freshURL.path),
            "Frische Domain (möglicher Parallel-Lauf) muss erhalten bleiben")
    for url in [foreignURL, fixedURL] {
        #expect(try Data(contentsOf: url) == protectedContents,
                "Alte fremde und nicht eindeutig zugeordnete Domains bleiben unverändert")
    }
}

@Test("TestDefaultsPurge erkennt nur UUID-Testdomains und entfernt Registriertes")
func purgeRecognizesAndRemovesTestDomains() {
    // Erkennung: Präfix UND UUID müssen zusammenkommen.
    #expect(TestDefaultsPurge.isTestDomain(
        "FastraTests.GitPreferences.9E8B2C1A-1234-4EAB-9F00-ABCDEF012345"))
    #expect(TestDefaultsPurge.isTestDomain(
        "fastra-test-extchange-9E8B2C1A-1234-4EAB-9F00-ABCDEF012345"))
    #expect(!TestDefaultsPurge.isTestDomain("de.dm0.fastra"))
    #expect(!TestDefaultsPurge.isTestDomain("com.apple.Terminal"))
    // Präfix ohne UUID bleibt stehen (z. B. die feste Selbsttest-Suite).
    #expect(!TestDefaultsPurge.isTestDomain("fastra-feste-suite"))
    // UUID ohne Test-Präfix bleibt ebenfalls stehen.
    #expect(!TestDefaultsPurge.isTestDomain(
        "org.example.9E8B2C1A-1234-4EAB-9F00-ABCDEF012345"))
    #expect(!TestDefaultsPurge.isTestDomain(
        "FastraTests/../../Terminal.9E8B2C1A-1234-4EAB-9F00-ABCDEF012345"))
    #expect(!TestDefaultsPurge.register(
        "FastraTests/../../Terminal.9E8B2C1A-1234-4EAB-9F00-ABCDEF012345"))

    // Registry-Weg: Eine registrierte, beschriebene Suite verschwindet mit
    // dem Purge aus den Preferences.
    //
    // Nur die EIGENE Probe-Suite abräumen: Das ungezielte
    // `purgeRegistered()` würde jede bis dahin prozessweit registrierte Suite
    // leeren — also auch die der zahlreichen Tests, die im standardmäßig
    // parallelen Lauf gerade `testSuiteDefaults` benutzen. Genau daraus
    // entstanden sporadische Rotläufe (Review 2026-08-10).
    let name = "FastraTests.PurgeProbe.\(UUID().uuidString)"
    TestDefaultsPurge.register(name)
    let defaults = UserDefaults(suiteName: name)!
    defaults.set(true, forKey: "probe")
    // synchronize erzwingt das Persistieren der Domain vor dem Purge.
    defaults.synchronize()
    let remaining = TestDefaultsPurge.purgeRegistered(only: name)
    // `persistentDomain` einer soeben entfernten Suite kann in-Prozess ein
    // LEERES Dictionary statt nil melden — beides heißt: keine Werte mehr da.
    let domain = UserDefaults.standard.persistentDomain(forName: name)
    #expect(domain == nil || domain?.isEmpty == true)
    #expect(!remaining.contains(name))
}

@Test("TestDefaultsPurge folgt in der Sandbox CFFIXED_USER_HOME")
func purgeUsesFixedPreferencesHome() {
    let fixed = "/tmp/fastra-fixed-home-\(UUID().uuidString)"
    let directory = TestDefaultsPurge.resolvedPreferencesDirectory(
        environment: ["CFFIXED_USER_HOME": fixed]
    )
    #expect(directory.path == fixed + "/Library/Preferences")
}

@Test("TestDefaultsPurge meldet eine fehlgeschlagene Suite nicht vorzeitig ab")
func purgeKeepsFailedSuiteRegistered() {
    let failed = "FastraTests.PurgeFailed.\(UUID().uuidString)"
    let succeeded = "FastraTests.PurgeSucceeded.\(UUID().uuidString)"
    TestDefaultsPurge.register(failed)
    TestDefaultsPurge.register(succeeded)
    defer {
        TestDefaultsPurge.updateRegistration(
            afterAttempting: [failed], remaining: [])
    }

    TestDefaultsPurge.updateRegistration(
        afterAttempting: [failed, succeeded], remaining: [failed])

    #expect(TestDefaultsPurge.isRegistered(failed))
    #expect(!TestDefaultsPurge.isRegistered(succeeded))
}

@Test("Runner-Registry wird nach einem Schreibfehler erneut versucht")
func defaultsRunnerRegistrationRetriesAfterFailure() throws {
    let root = testTemporaryDirectory()
        .appendingPathComponent("fastra-defaults-registry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root,
                                            withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let name = "FastraTests.RegistryRetry.\(UUID().uuidString)"
    let registry = root.appendingPathComponent("registry.txt")
    defer { _ = TestDefaultsPurge.purgeRegistered(only: name) }

    // Ein Verzeichnis kann nicht als Registry-Datei geöffnet werden.
    #expect(!TestDefaultsPurge.register(name,
                                       runnerRegistryPath: root.path))
    #expect(TestDefaultsPurge.isRegistered(name))

    #expect(TestDefaultsPurge.register(name,
                                      runnerRegistryPath: registry.path))
    let recorded = try String(contentsOf: registry, encoding: .utf8)
    #expect(recorded.split(whereSeparator: \.isNewline).map(String.init)
        == [name])
}

/// Der `preferencesDirectory`-Pfad hatte bis zum Infrastruktur-Review
/// 2026-09-10 KEINE Abdeckung — im Repo belegt ihn kein Produktaufrufer. Zwei
/// Zusagen hingen dort in der Luft, beide inzwischen abgesichert:
///
/// 1. `purge` löscht die Plist im übergebenen Verzeichnis und meldet nichts
///    als verbleibend. Der Containment-Vergleich lief über URLs, und ob zwei
///    URLs auf dasselbe Verzeichnis als gleich gelten, entschied das
///    Dateisystem: `standardizedFileURL` setzt das Verzeichnis-Merkmal nur für
///    einen vorhandenen Pfad. Ein Fehler war daraus nicht ableitbar — fehlt
///    das Verzeichnis, gibt es nichts zu löschen —, aber die Zusage hing an
///    einem Zustand, den der Aufrufer nicht sieht.
/// 2. `purgeStale` räumt im übergebenen Verzeichnis auf, ohne im eigenen
///    Preferences-Home eine Domain anzufassen. Vorher folgte nur der Dateipfad
///    dem Argument.
@Test("purge und purgeStale arbeiten in einem ausdrücklich übergebenen Verzeichnis")
func purgeHonoursAnExplicitPreferencesDirectory() throws {
    let root = testTemporaryDirectory()
        .appendingPathComponent("fastra-purge-dir-\(UUID().uuidString)")
    // BEWUSST ohne `isDirectory: true` — genau die Schreibweise, an der der
    // Vergleich zerbrach.
    let preferences = root.appendingPathComponent("Library/Preferences")
    try FileManager.default.createDirectory(at: preferences,
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let name = "FastraTests.PurgeDir.\(UUID().uuidString)"
    let plist = preferences.appendingPathComponent(name + ".plist")
    try Data("<plist/>".utf8).write(to: plist)

    // `purge` muss die Datei löschen und nichts als verbleibend melden.
    let remaining = TestDefaultsPurge.purgeRegistered(
        only: name, preferencesDirectory: preferences)
    #expect(remaining.isEmpty, "purge meldete \(remaining) als verbleibend")
    #expect(!FileManager.default.fileExists(atPath: plist.path))

    // `purgeStale` räumt eine alte Datei im FREMDEN Verzeichnis ab, ohne im
    // eigenen Preferences-Home eine Domain anzufassen.
    let stale = preferences.appendingPathComponent(
        "FastraTests.PurgeStale.\(UUID().uuidString).plist")
    try Data("<plist/>".utf8).write(to: stale)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-7200)],
        ofItemAtPath: stale.path)
    let removed = TestDefaultsPurge.purgeStale(preferencesDirectory: preferences)
    #expect(removed == 1)
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    let ownHome = TestDefaultsPurge.resolvedPreferencesDirectory()
    let strayInOwnHome = ownHome.appendingPathComponent(stale.lastPathComponent)
    #expect(!FileManager.default.fileExists(atPath: strayInOwnHome.path), """
        purgeStale hat im eigenen Preferences-Home eine Domain angefasst, \
        obwohl ein fremdes Verzeichnis übergeben wurde
        """)
}

/// Die Liste der Test-Domain-Präfixe steht ZWEIMAL: in `TestDefaultsPurge`
/// (Swift) und als `case`-Muster in `tools/test-sandbox.sh`. Beide Seiten sind
/// heute gleich, werden aber unabhängig gepflegt — und eine Drift ist teuer:
/// Kommt in Swift ein Präfix dazu, hält `fastra_test_defaults_domain_is_safe`
/// jeden so benannten Registry-Eintrag für unsicher, `purge_fastra_registered_
/// test_defaults` setzt `failed=1`, und JEDER Selbsttestlauf endet mit Exit 2.
/// Fehlt umgekehrt in Swift, was die Shell kennt, bleiben Plists liegen.
@Test("Test-Domain-Präfixe stimmen zwischen Swift und Sandbox-Skript überein")
func testDomainPrefixesMatchTheSandboxScript() throws {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tools/test-sandbox.sh")
    let body = try shellFunction(named: "fastra_test_defaults_domain_is_safe", in: script)

    // Die `case`-Zeile listet die Präfixe als `Muster*|Muster*|…`.
    let patternLine = try #require(
        body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasSuffix("*) ;;") && $0.contains("|") },
        "Die case-Zeile mit den Präfixen steht nicht mehr in der Funktion"
    )
    let shellPrefixes = Set(
        patternLine
            .replacingOccurrences(of: ") ;;", with: "")
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasSuffix("*") }
            .map { String($0.dropLast()) }
    )
    #expect(shellPrefixes.count > 3, "Präfix-Erkennung greift nicht mehr")
    #expect(shellPrefixes == Set(TestDefaultsPurge.prefixes), """
        Swift kennt \(Set(TestDefaultsPurge.prefixes).sorted()), \
        das Sandbox-Skript \(shellPrefixes.sorted()). Läuft das auseinander, \
        endet entweder jeder Lauf mit Exit 2 oder es bleiben Plists liegen.
        """)
}

/// Der atexit-Hook aus `TestSuiteDefaults.swift` war ungeprüft: Ein
/// atexit-Handler läuft nur beim echten Prozessende, und `purgeRegistered()`
/// gegen die ECHTE Registry würde mitten im parallelen Lauf allen anderen
/// Tests ihre Suiten wegräumen. Sein Rumpf liegt deshalb jetzt in
/// `runTestDefaultsExitCleanup`; der Test setzt eine Attrappen-Registry ein
/// und liest die Warnung mit (Review-Hinweis 2026-09-17).
@Test("Prozessende räumt die Registry ab und meldet Übriggebliebene")
func exitCleanupReportsRemainingDomains() {
    /// Ein Durchlauf der ausgelagerten atexit-Logik gegen die Attrappe.
    func cleanup(remaining: [String]) -> (registry: Int, stale: Int, warnings: [String]) {
        var registryCalls = 0
        var staleCalls = 0
        var warnings: [String] = []
        runTestDefaultsExitCleanup(
            purgeRegistered: {
                registryCalls += 1
                // Die Attrappe fasst keine echte Domain an; sie meldet nur,
                // was sich angeblich nicht entfernen ließ.
                return remaining
            },
            purgeStale: { staleCalls += 1 },
            warn: { warnings.append($0) }
        )
        return (registryCalls, staleCalls, warnings)
    }

    let clean = cleanup(remaining: [])
    #expect(clean.registry == 1)
    #expect(clean.stale == 1)
    #expect(clean.warnings.isEmpty, "Ein sauberer Abschluss darf nicht warnen")

    let leftovers = ["Fastra-\(UUID().uuidString)",
                     "FastraTests.Rest.\(UUID().uuidString)"]
    let dirty = cleanup(remaining: leftovers)
    #expect(dirty.registry == 1)
    // Die Reste früherer Läufe müssen auch dann abgeräumt werden, wenn die
    // eigene Registry gerade etwas übrig gelassen hat.
    #expect(dirty.stale == 1)
    #expect(dirty.warnings.count == 1)
    let warning = dirty.warnings.first ?? ""
    #expect(warning.hasPrefix("WARNUNG: Test-Preferences-Domains blieben übrig: "))
    for domain in leftovers {
        #expect(warning.contains(domain), "Domain \(domain) fehlt in: \(warning)")
    }
    #expect(warning.hasSuffix("\n"), "Die Diagnose braucht ihren Zeilenumbruch")
}

/// Gegenprobe zur Auslagerung: `atexit` darf nur noch den Aufruf registrieren.
/// Wandert Logik zurück in die Closure, ist sie wieder unprüfbar.
@Test("Der atexit-Hook enthält nur noch den Aufruf der geprüften Funktion")
func exitHookDelegatesToTestedFunction() throws {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("TestSuiteDefaults.swift")
    let body = try String(contentsOf: source, encoding: .utf8)
    #expect(body.contains("atexit { runTestDefaultsExitCleanup() }"), """
        Der atexit-Hook in TestSuiteDefaults.swift ruft nicht mehr nur \
        runTestDefaultsExitCleanup() auf — Logik in der Closure selbst ist im \
        eigenen Prozess nicht prüfbar.
        """)
}
