// SelfTestPollingTests.swift
//
// Die Warteschleifen der Selbsttests laufen nur im laufenden App-Prozess und
// enden dort über `exit()`. Prüfbar ist trotzdem alles, was zählt: Die
// Fristbuchhaltung ist reine Rechnung, und Uhr wie Planer sind austauschbar.
// Diese Tests brauchen deshalb weder ein Fenster noch echte Zeit.

import Foundation
import Testing
@testable import Fastra

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
        // Der Runner-Rest hat auch dann Vorrang, wenn er KÜRZER als die
        // Frist ist: 15 s Frist bei 50 s Laufzeit ergeben 7 s, nicht 15.
        #expect(SelfTestPolling.hardCap(budget: 15, elapsed: 50, test: "search") == 7)
        // Ist der Runner-Rest schon aufgebraucht, ist der Deckel 0 — die alte
        // Untergrenze „mindestens die Frist" ließ hier 3 s zu, und die Diagnose
        // kam erst bei 62 s, nach der 60-s-Runner-Frist (Review-Fund 2026-09-17).
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
        // Solange die Antwort aussteht, ist NICHTS geplant — sonst könnten
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
    /// Regressionssperre ohne GUI-Lauf: Die Zahl der rohen `asyncAfter`-
    /// Schleifen in `SelfTest.swift` darf nicht wieder steigen. Der Sollwert
    /// sinkt mit jedem migrierten Stapel; eine neue Warteschleife gehört über
    /// `waitFor`/`waitForAsync` gebaut, nicht von Hand gezählt.
    ///
    /// Stand 2026-09-17 nach Stapel 0 und 1: 370 (vorher 391); nach Stapel 3
    /// (Rahmen-Helfer waitForMainWindow/-SearchWindow/-Editor/-EditorShowing/
    /// -UpdatesMenu/waitUntilSelfTest): 364; nach Stapel 2 (benannte
    /// Poll-Helfer der Fenstertests und die Git-UI-Familie): 323; nach
    /// Stapel 4 (65 einschrittige Poll-Helfer): 258; nach Stapel 5a (34
    /// mehrstufige Helfer der Fenster-, Soft-Wrap-, 4D- und Tab-Tests): 219;
    /// nach Stapel 5b (35 weitere, darunter Markdown-DOM, Druck, Diff und
    /// Git-Aufnahmen): 172. Bewusst NICHT migriert und damit Teil dieser Zahl:
    /// Beobachtungsfenster ohne Zielbedingung (observeBackgroundScroll,
    /// pollForFlash, observeSoftWrapAnchor), der Dauertest
    /// (waitForSoakWindows, finishSoakRoundWhenViewsSettled), Messschleifen
    /// mit eigenem Takt (runSidebarToggleCycle, pollProjectOpenPerformance,
    /// pollLoadPerformanceEditor) sowie Einmal-Verzögerungen.
    @Test("Rohe asyncAfter-Warteschleifen in SelfTest.swift werden nicht mehr")
    func rawAsyncAfterCountDoesNotGrow() throws {
        let source = try String(
            contentsOf: appDirectory
                .appendingPathComponent("Sources/Fastra/SelfTest.swift"),
            encoding: .utf8
        )
        let count = source.components(separatedBy: "DispatchQueue.main.asyncAfter").count - 1
        #expect(count <= 172, """
            SelfTest.swift enthält \(count) rohe `DispatchQueue.main.asyncAfter`, \
            erlaubt sind höchstens 172. Neue Warteschleifen gehören über \
            `waitFor`/`waitForAsync` gebaut (siehe SelfTestPolling.swift); wurde \
            ein weiterer Stapel migriert, gehört der Sollwert hier gesenkt.
            """)
    }

    /// `SelfTestPolling.runnerTimeoutSeconds` spiegelt `timeout_for_test` aus
    /// `selftest.sh`. Zwei Tabellen laufen ohne Wächter auseinander — und dann
    /// rechnet der Wanduhr-Deckel mit einer Frist, die der Runner gar nicht
    /// gibt (Vorbild: `knownSelfTestNamesMatchDispatch`).
    @Test("Die Runner-Fristen in Swift und in selftest.sh sind dieselben")
    func runnerTimeoutTableMatchesTheRunner() throws {
        let runnerSource = try String(
            contentsOf: appDirectory.appendingPathComponent("selftest.sh"),
            encoding: .utf8
        )
        let lines = runnerSource.components(separatedBy: .newlines)

        // Vorgabefrist des Runners.
        let defaultLine = try #require(
            lines.first { $0.hasPrefix("TIMEOUT_SECS=") },
            "TIMEOUT_SECS steht nicht mehr in selftest.sh"
        )
        let defaultSeconds = try #require(
            Double(defaultLine.dropFirst("TIMEOUT_SECS=".count)
                .trimmingCharacters(in: .whitespaces)),
            "TIMEOUT_SECS ist keine Zahl mehr: \(defaultLine)"
        )

        // Sonderfälle aus `timeout_for_test`: `name) echo N ;;`.
        let start = try #require(
            lines.firstIndex { $0.hasPrefix("timeout_for_test()") },
            "timeout_for_test steht nicht mehr in selftest.sh"
        )
        let end = try #require(
            lines[start...].firstIndex { $0 == "}" },
            "timeout_for_test endet nicht — Klammern zählen nicht auf"
        )
        var shellTable: [String: Double] = [:]
        var sawDefaultCase = false
        for line in lines[start...end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(";;"), let parenthesis = trimmed.firstIndex(of: ")") else {
                continue
            }
            let label = String(trimmed[trimmed.startIndex..<parenthesis])
            let body = trimmed[trimmed.index(after: parenthesis)...]
                .trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("echo ") else { continue }
            let value = body.dropFirst("echo ".count)
                .replacingOccurrences(of: ";;", with: "")
                .trimmingCharacters(in: .whitespaces)
            if label == "*" {
                #expect(value == "\"$TIMEOUT_SECS\"",
                        "Der Standardzweig liefert nicht mehr TIMEOUT_SECS: \(trimmed)")
                sawDefaultCase = true
                continue
            }
            // `print) echo 240 ;;` — auch mehrere Namen je Zweig wären hier
            // sichtbar, dann stünde ein `|` im Label und der Test fiele auf.
            let seconds = try #require(Double(value),
                                       "Unlesbare Frist in selftest.sh: \(trimmed)")
            for name in label.components(separatedBy: "|") {
                shellTable[name.trimmingCharacters(in: .whitespaces)] = seconds
            }
        }
        #expect(sawDefaultCase, "timeout_for_test hat keinen Standardzweig mehr")
        #expect(!shellTable.isEmpty, "timeout_for_test nennt keine Sonderfristen mehr")

        for (name, seconds) in shellTable {
            #expect(SelfTestPolling.runnerTimeoutSeconds(for: name) == seconds, """
                selftest.sh gibt „\(name)" \(seconds) s, SelfTestPolling aber \
                \(SelfTestPolling.runnerTimeoutSeconds(for: name)) s.
                """)
        }
        #expect(SelfTestPolling.runnerTimeoutSeconds(for: "kein-solcher-selbsttest")
                == defaultSeconds)

        // Gegenrichtung: Swift darf keine Sonderfrist kennen, die der Runner
        // nicht gibt. Die Namen stehen im `switch` der Spiegeltabelle.
        let swiftSource = try String(
            contentsOf: appDirectory
                .appendingPathComponent("Sources/Fastra/SelfTestPolling.swift"),
            encoding: .utf8
        )
        let switchStart = try #require(
            swiftSource.range(of: "func runnerTimeoutSeconds(for test: String)"),
            "runnerTimeoutSeconds steht nicht mehr in SelfTestPolling.swift"
        )
        let switchEnd = try #require(
            swiftSource.range(of: "default: return", range: switchStart.upperBound..<swiftSource.endIndex),
            "runnerTimeoutSeconds hat keinen default-Zweig mehr"
        )
        var swiftNames: Set<String> = []
        for line in swiftSource[switchStart.upperBound..<switchEnd.lowerBound]
            .components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case "), let colon = trimmed.firstIndex(of: ":") else {
                continue
            }
            for raw in trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<colon]
                .components(separatedBy: ",") {
                swiftNames.insert(raw.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            }
        }
        #expect(swiftNames == Set(shellTable.keys), """
            Sonderfristen in SelfTestPolling: \(swiftNames.sorted()) — \
            in selftest.sh: \(shellTable.keys.sorted()).
            """)
    }
}
