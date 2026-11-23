// SelfTestPollingTests.swift
//
// Die Warteschleifen der Selbsttests laufen nur im laufenden App-Prozess und
// enden dort über `exit()`. Prüfbar ist trotzdem alles, was zählt: Die
// Fristbuchhaltung ist reine Rechnung, und Uhr wie Planer sind austauschbar.
// Diese Tests brauchen deshalb weder ein Fenster noch echte Zeit.

import Foundation
import Testing
@testable import Fastra

/// Die Library wird als Ganzes geladen; keine Quelltextform ist Teil der Test-API.
private func timeoutShell(_ script: String, arguments: [String] = [],
                          environment: [String: String] = [:]) throws -> String {
    // runTestProcess führt Overrides erneut mit der geerbten Umgebung zusammen.
    // Deshalb leere Werte setzen: Entfernte Schlüssel würden wieder geerbt.
    let knownReviewKeys = ["FASTRA_SOFTWRAPINDENT_REVIEW_DIR", "FASTRA_GITHISTORY_REVIEW_DIR",
                           "FASTRA_MARKDOWN_IMPORT_REVIEW_DIR"]
    let inheritedReviewKeys = ProcessInfo.processInfo.environment.keys.filter { $0.hasSuffix("_REVIEW_DIR") }
    var clean = Dictionary(uniqueKeysWithValues: Set(knownReviewKeys + inheritedReviewKeys).map { ($0, "") })
    clean.merge(environment) { _, value in value }
    let library = appDirectory.appendingPathComponent("tools/selftest-timeouts.sh")
    let result = try runTestProcess("/bin/bash", arguments: [
        "-c", "set -u\n. \"$1\"\nshift\n" + script, "timeout-fixture", library.path,
    ] + arguments, environment: clean)
    #expect(result.status == 0, "Bash-Fristen: \(result.output)")
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
}

@Test("Die Fristenbibliothek bleibt beim Sourcing ohne Runner-Nebenwirkungen")
func timeoutLibrarySourcingHasNoRunnerSideEffects() throws {
    let root = testTemporaryDirectory().appendingPathComponent("timeout-source-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = appDirectory.appendingPathComponent("tools/selftest-timeouts.sh")
    let result = try runTestProcess("/bin/bash", arguments: ["-c", #"""
        set -eu
        cd "$2"
        PATH=/nonexistent
        # Jede externe Aktion beim Sourcing wäre ein Vertragsbruch. Der DEBUG-
        # Trap läuft auch in Subshells und meldet ausgeführte Befehle, keine Definitionen.
        source_command='. "$1"'
        set -T
        trap 'if [[ "$BASH_COMMAND" != "$source_command" && "$BASH_COMMAND" != "TIMEOUT_SECS=60" ]]; then printf "Unerwartete Aktion: %s\n" "$BASH_COMMAND" >&2; exit 1; fi' DEBUG
        . "$1"
        """#, "source-fixture", library.path, root.path])
    #expect(result.status == 0, "\(result.output)")
    #expect(result.output.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test("Runner-Fristen und Reviewzuordnungen sind in beiden Richtungen abgeglichen")
func runnerTimeoutConfigurationMatchesBash() throws {
    let shellNames = try timeoutShell("selftest_timeout_special_names")
        .split(whereSeparator: \.isWhitespace).map(String.init)
    let swiftNames = SelfTestPolling.timeoutRules.filter { $0.seconds != nil }.map(\.test)
    #expect(Set(shellNames) == Set(swiftNames))
    #expect(shellNames.count == Set(shellNames).count)
    #expect(swiftNames.count == Set(swiftNames).count)

    let mappingLines = try timeoutShell("selftest_timeout_review_mappings").split(separator: "\n")
    var shellReviews: [String: String] = [:]
    for line in mappingLines {
        let fields = line.split(separator: " ")
        try #require(fields.count == 2)
        #expect(shellReviews.updateValue(String(fields[1]), forKey: String(fields[0])) == nil)
    }
    var swiftReviews: [String: String] = [:]
    for rule in SelfTestPolling.timeoutRules {
        if let key = rule.reviewKey { swiftReviews[rule.test] = key }
    }
    #expect(swiftReviews == shellReviews)

    let names = Set(shellNames).union(swiftNames).union(shellReviews.keys)
        .union(swiftReviews.keys).union(["search", "kein-solcher-selbsttest"])
    let keys = Set(shellReviews.values).union(swiftReviews.values)
    var environments: [[String: String]] = [[:], Dictionary(uniqueKeysWithValues: keys.map { ($0, "") })]
    for key in keys {
        environments.append([key: ""])
        environments.append([key: "/tmp/review"])
    }
    environments.append(Dictionary(uniqueKeysWithValues: keys.map { ($0, "/tmp/review") }))
    for environment in environments {
        for name in names {
            let output = try timeoutShell("timeout_for_test \"$1\"",
                                          arguments: [name], environment: environment)
            let shell = try #require(Double(output))
            let swift = SelfTestPolling.runnerTimeoutSeconds(for: name, environment: environment)
            #expect(swift == shell, "\(name), Reviewumgebung \(environment)")
        }
    }
    for name in names {
        let output = try timeoutShell("TIMEOUT_SECS=37\ntimeout_for_test \"$1\"", arguments: [name])
        let expected = SelfTestPolling.timeoutRules.first { $0.test == name }?.seconds ?? 37
        #expect(Double(output) == expected, "Konfigurierter Shellstandard, \(name)")
    }
    #expect(SelfTestPolling.runnerTimeoutSeconds(for: "search", environment: [:]) == 60)
    #expect(SelfTestPolling.runnerTimeoutSeconds(for: "kein-solcher-selbsttest", environment: [:]) == 60)
}

/// Quelldateien, robust aus der Testdatei-Position abgeleitet
/// (app/Tests/FastraTests/… → app/…).
private let appDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // FastraTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // app

/// Fake-Planer und Fake-Uhr: kein Timer, keine Wanduhr. Beim Ausführen eines
/// Auftrags springt die Uhr um die angeforderte Pause plus `extraGap` vor —
/// `extraGap` ist die Fremdlast, die einen Main-Thread-Halter nachbildet.
private final class FakePollClock {
    var now: TimeInterval = 0
    var extraGap: TimeInterval = 0
    private(set) var scheduled = 0
    private var queue: [(TimeInterval, () -> Void)] = []

    var environment: SelfTestPolling.Environment {
        SelfTestPolling.Environment(
            now: { self.now },
            schedule: { pause, work in
                self.scheduled += 1
                self.queue.append((pause, work))
            }
        )
    }

    /// Arbeitet die Warteschlange ab. `limit` begrenzt den Lauf, damit ein
    /// kaputter Helfer den Testlauf nicht endlos dreht.
    func run(limit: Int = 10_000) {
        var executed = 0
        while !queue.isEmpty, executed < limit {
            let (pause, work) = queue.removeFirst()
            now += pause + extraGap
            executed += 1
            work()
        }
    }
}

/// Zählt die Durchläufe bis zum ersten Verdikt ungleich `keepWaiting`.
/// `gap` ist der Abstand zweier Prüfungen auf der Fake-Uhr.
private func pollsUntilVerdict(
    _ book: SelfTestPollBudget, gap: TimeInterval
) -> (polls: Int, verdict: SelfTestPollBudget.Verdict, book: SelfTestPollBudget) {
    var book = book
    var clock = book.startedAt
    var polls = 0
    while true {
        polls += 1
        let verdict = book.recordMiss(now: clock)
        if verdict != .keepWaiting { return (polls, verdict, book) }
        clock += gap
        // Sicherung gegen eine Schleife ohne Abbruch.
        if polls > 10_000 { return (polls, verdict, book) }
    }
}

@Suite("Fristbuchhaltung der Selbsttest-Warteschleifen")
struct SelfTestPollBudgetTests {
    @Test("Die Frist zählt genau so viele Durchläufe wie der bisherige Tick-Zähler")
    func budgetMatchesLegacyTickCount() {
        // `tick >= 100` bei 30 ms Pause bedeutete: 101 Prüfungen, 100 Pausen.
        let result = pollsUntilVerdict(
            SelfTestPollBudget(budget: 3, pause: 0.03, hardCap: 1_000, now: 0),
            gap: 0.03
        )
        #expect(result.polls == 101)
        #expect(result.verdict == .budgetExhausted)

        // Auch die übrigen migrierten Fristen treffen ihre alte Tick-Zahl.
        for (ticks, pause) in [(67, 0.03), (34, 0.03), (200, 0.03),
                               (150, 0.03), (300, 0.05), (100, 0.1)] {
            let budget = Double(ticks) * pause
            let run = pollsUntilVerdict(
                SelfTestPollBudget(budget: budget, pause: pause, hardCap: 1_000_000, now: 0),
                gap: pause
            )
            #expect(run.polls == ticks + 1,
                    "\(ticks) × \(pause) s ergab \(run.polls) statt \(ticks + 1) Durchläufe")
        }
    }

    @Test("Fremdlast auf dem Main-Thread verbraucht die Frist nicht")
    func foreignLoadDoesNotConsumeTheBudget() {
        // Jede Lücke ist hundertmal so lang wie die Pause — sie gehört einem
        // fremden Main-Thread-Halter und zählt deshalb nur mit dem Deckel.
        // Die Bedingung bekommt dadurch exakt gleich viele Prüfungen wie ohne
        // Last; genau das war die Ursache falsch roter Tests.
        let loaded = pollsUntilVerdict(
            SelfTestPollBudget(budget: 3, pause: 0.03, hardCap: 1_000_000, now: 0),
            gap: 3.0
        )
        #expect(loaded.polls == 101)
        #expect(loaded.verdict == .budgetExhausted)
        #expect(loaded.book.observed < 3.01)
        // Die Wanduhr steht dabei bei 300 s und steht so auch im Diagnosetext.
        #expect(loaded.book.summary.contains("Wanduhr 300"))
    }

    @Test("Ein weiterer Deckel als die Pause verkürzt die Frist sichtbar")
    func aWiderGapCeilingShortensTheBudget() {
        // Der Deckel aus `waitUntil` wäre Pause + 50 ms. Bei 80-ms-Lücken
        // zählte dann jede Lücke voll, und die 3-Sekunden-Frist wäre nach 39
        // statt 101 Durchläufen weg. Deshalb ist der Standard die Pause selbst.
        let wide = pollsUntilVerdict(
            SelfTestPollBudget(budget: 3, pause: 0.03, hardCap: 1_000_000,
                               countedGapCeiling: 0.08, now: 0),
            gap: 0.08
        )
        #expect(wide.polls == 39)
    }

    @Test("Der Wanduhr-Deckel beendet eine dauerblockierte Schleife")
    func hardCapEndsAPermanentlyBlockedLoop() {
        // Dauerblockade: Lücken von 3 s bei 30 ms Pause. Die Frist wird nie
        // voll, der Deckel bei 23 s greift beim neunten Durchlauf (t = 24 s).
        let blocked = pollsUntilVerdict(
            SelfTestPollBudget(budget: 3, pause: 0.03, hardCap: 23, now: 0),
            gap: 3.0
        )
        #expect(blocked.verdict == .hardCapReached)
        #expect(blocked.polls == 9)
        #expect(blocked.book.observed < 3)
    }

    @Test("Der Deckel bleibt unter der Runner-Frist, auch unter der eigenen Frist")
    func hardCapStaysBelowTheRunnerDeadline() {
        // Früh im Lauf: Frist plus 20 s Zugabe, wie in `waitUntil`.
        #expect(SelfTestPolling.hardCap(budget: 15, elapsed: 1, test: "search") == 35)
        // Spät im Lauf: Der Deckel darf die Runner-Frist nicht überholen,
        // sonst endet der Test ohne eigene Diagnose als Runner-TIMEOUT.
        #expect(SelfTestPolling.hardCap(budget: 3, elapsed: 50, test: "search") == 7)
        // Der Runner-Rest hat auch dann Vorrang, wenn er kürzer als die
        // Frist ist: 15 s Frist bei 50 s Laufzeit ergeben 7 s, nicht 15.
        #expect(SelfTestPolling.hardCap(budget: 15, elapsed: 50, test: "search") == 7)
        // Bei aufgebrauchtem Runner-Rest muss der Deckel 0 sein, damit die
        // Diagnose nicht erst nach der äußeren Abbruchfrist entsteht.
        #expect(SelfTestPolling.hardCap(budget: 3, elapsed: 59, test: "search") == 0)
        #expect(SelfTestPolling.hardCap(budget: 3, elapsed: 90, test: "search") == 0)
        // Ein langer Test hat entsprechend mehr Rest.
        #expect(SelfTestPolling.hardCap(budget: 15, elapsed: 200, test: "print") == 35)
    }

    @Test("Ein aufgebrauchter Deckel endet beim ersten erfolglosen Durchlauf")
    func exhaustedHardCapEndsOnTheFirstMiss() {
        // Deckel 0: Die Bedingung bekommt genau eine Prüfung; der erste
        // Fehlschlag ist sofort `hardCapReached`, ganz ohne Pause und ohne
        // dass die Frist überhaupt angerechnet wird.
        var book = SelfTestPollBudget(budget: 3, pause: 0.03, hardCap: 0, now: 100)
        #expect(book.recordMiss(now: 100) == .hardCapReached)
        #expect(book.polls == 1)
    }
}

@Suite("Warteschleife der Selbsttests")
struct SelfTestPollingLoopTests {
    @Test("Der erste Durchlauf läuft sofort, nicht erst nach der Pause")
    func firstPollRunsImmediately() {
        let clock = FakePollClock()
        var successes = 0
        SelfTestPolling.waitFor(budget: 1, pause: 0.5, hardCap: 100,
                                environment: clock.environment,
                                condition: { true },
                                onTimeout: { _ in Issue.record("Frist riss bei erfüllter Bedingung") },
                                then: { successes += 1 })
        #expect(successes == 1)
        #expect(clock.now == 0)
        #expect(clock.scheduled == 0)
    }

    @Test("Bei Erfolg läuft die Fortsetzung genau einmal und der Timeout nie")
    func successRunsTheContinuationExactlyOnce() {
        let clock = FakePollClock()
        var checks = 0
        var successes = 0
        var timeouts = 0
        SelfTestPolling.waitFor(budget: 1, pause: 0.1, hardCap: 100,
                                environment: clock.environment,
                                condition: { checks += 1; return checks == 4 },
                                onTimeout: { _ in timeouts += 1 },
                                then: { successes += 1 })
        clock.run()
        // Je Durchlauf genau eine Auswertung — eine zusätzliche Prüfung im
        // Timeout-Zweig würde eine nachziehende Bedingung doppelt zustellen.
        #expect(checks == 4)
        #expect(clock.scheduled == 3)
        #expect(successes == 1)
        #expect(timeouts == 0)
    }

    @Test("Bei gerissener Frist läuft der Timeout einmal und die Fortsetzung nie")
    func timeoutRunsOnceWithTheBookkeeping() {
        let clock = FakePollClock()
        var checks = 0
        var successes = 0
        var summaries: [String] = []
        SelfTestPolling.waitFor(budget: 1, pause: 0.1, hardCap: 1_000,
                                environment: clock.environment,
                                condition: { checks += 1; return false },
                                onTimeout: { book in summaries.append(book.summary) },
                                then: { successes += 1 })
        clock.run()
        // 10 × 100 ms Frist → 11 Prüfungen, danach ist Schluss.
        #expect(checks == 11)
        #expect(successes == 0)
        #expect(summaries.count == 1)
        #expect(summaries.first?.contains("Frist 1.0 s gerissen") == true)
        #expect(summaries.first?.contains("11 Durchläufe") == true)
    }

    @Test("Fremdlast dehnt die Wanduhr, nicht die Zahl der Prüfungen")
    func foreignLoadKeepsTheNumberOfChecks() {
        let clock = FakePollClock()
        clock.extraGap = 2.0   // fremder Main-Thread-Halter je Durchlauf
        var checks = 0
        SelfTestPolling.waitFor(budget: 1, pause: 0.1, hardCap: 1_000,
                                environment: clock.environment,
                                condition: { checks += 1; return false },
                                onTimeout: { _ in },
                                then: { Issue.record("Bedingung wurde nie wahr") })
        clock.run()
        #expect(checks == 11)
        #expect(clock.now > 20)
    }

    @Test("Die asynchrone Variante plant erst nach der Antwort neu")
    func asyncLoopSchedulesOnlyAfterTheAnswer() {
        let clock = FakePollClock()
        var pending: [(Bool) -> Void] = []
        var successes = 0
        var timeouts = 0
        SelfTestPolling.waitForAsync(budget: 1, pause: 0.1, hardCap: 100,
                                     environment: clock.environment,
                                     check: { done in pending.append(done) },
                                     onTimeout: { _ in timeouts += 1 },
                                     then: { successes += 1 })
        // Solange die Antwort aussteht, ist nichts geplant — sonst könnten
        // sich zwei Durchläufe überholen und git doppelt befragen.
        #expect(pending.count == 1)
        #expect(clock.scheduled == 0)

        pending.removeFirst()(false)
        #expect(clock.scheduled == 1)
        #expect(pending.isEmpty)

        clock.run(limit: 1)
        #expect(pending.count == 1)
        #expect(clock.scheduled == 1)

        pending.removeFirst()(true)
        #expect(successes == 1)
        #expect(timeouts == 0)
        #expect(clock.scheduled == 1)
    }
}

@Suite("Wächter über die Umstellung der Selbsttest-Warteschleifen")
struct SelfTestPollingRatchetTests {
    /// Quellprüfung ohne GUI-Lauf: Rohe `asyncAfter`-Schleifen dürfen nicht
    /// zunehmen. Neue Warteschleifen nutzen `waitFor`/`waitForAsync`.
    /// Verbleibende Ausnahmen sind Beobachtungsfenster ohne Zielbedingung
    /// (`observeBackgroundScroll`, `pollForFlash`, `observeSoftWrapAnchor`),
    /// Dauerteststeuerung (`waitForSoakWindows`, `finishSoakRoundWhenViewsSettled`),
    /// Messschleifen mit eigenem Takt (`runSidebarToggleCycle`,
    /// `pollProjectOpenPerformance`, `pollLoadPerformanceEditor`) und einmalige
    /// Verzögerungen.
    @Test("Rohe asyncAfter-Warteschleifen im gesamten Harness werden nicht mehr")
    func rawAsyncAfterCountDoesNotGrow() throws {
        let sources = try selfTestHarnessSources(in: appDirectory)
        #expect(sources.contains { $0.path == "Sources/Fastra/SelfTest.swift" })
        #expect(sources.contains { $0.path == "Sources/Fastra/SelfTestPolling.swift" })
        #expect(sources.contains { $0.path == "Sources/Fastra/SoakTest.swift" })
        let counts = sources.map { ($0.path, $0.source.components(
            separatedBy: "DispatchQueue.main.asyncAfter").count - 1) }
        let count = counts.reduce(0) { $0 + $1.1 }
        // Unveränderte, jetzt vollständig erfasste Basis: SelfTest 172,
        // zentraler Polling-Timer 1 und Soak 8. Dateiumzüge senken sie nicht.
        #expect(count <= 181, """
            Das Harness enthält \(count) rohe `DispatchQueue.main.asyncAfter`, \
            erlaubt sind höchstens 181: \(counts). Neue Warteschleifen gehören \
            über `waitFor`/`waitForAsync` gebaut; nach Migration den Sollwert senken.
            """)
    }

    @Test("Die Harness-Inventur erfasst verschobene Timer und defer rekursiv")
    func harnessInventoryIncludesNestedStatements() throws {
        let sandbox = testTemporaryDirectory().appendingPathComponent("harness-audit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("Sources/Fastra")
        let nested = root.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let source = "DispatchQueue.main.asyncAfter(deadline: .now()) {}\ndefer { cleanup() }\n"
        for name in ["SelfTestMoved.swift", "Nested/SoakTestMoved.swift", "Document.swift", "SelfTestNotes.md"] {
            try source.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let sources = try selfTestHarnessSources(in: sandbox)
        #expect(sources.map(\.path) == ["Sources/Fastra/Nested/SoakTestMoved.swift", "Sources/Fastra/SelfTestMoved.swift"])
        #expect(sources.allSatisfy { $0.source == source })
    }

    @Test("Die Harness-Inventur lehnt eine fehlende Quellwurzel ab")
    func harnessInventoryRejectsMissingRoot() {
        let missing = testTemporaryDirectory().appendingPathComponent("missing-harness-\(UUID())")
        #expect(throws: (any Error).self) { try selfTestHarnessSources(in: missing) }
    }

}
