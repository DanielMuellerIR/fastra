// SelfTestPolling.swift
//
// Fristbuchhaltung der In-App-Selbsttests. Nur bediente Zeit verbuchen:
// Längere Main-Thread-Blockaden dürfen die eigentliche Prüffrist nicht
// verbrauchen. Anders als `waitUntil` in `Tests/FastraTests/TestWaiting.swift`
// ist der Deckel je Lücke standardmäßig die angeforderte Pause selbst.
// Damit bleibt das Zeitverhalten der früheren Tick-Zähler erhalten.
//
// `DispatchTime` ist monoton und unabhängig von Uhrzeitänderungen. Ein
// zusätzlicher Wanduhrdeckel beendet die Schleife vor der Runner-Frist, damit
// auch bei Totalblockade eine eigene Diagnose entsteht.
//
// Separate Datei wegen der Quelltext-Wächter `SelfTestReviewFixTests` und
// `SelfTestPerformanceTests`, die `SelfTest.swift` auswerten.

import Foundation

/// Fristbuchhaltung einer Warteschleife — reine Rechnung, ohne Uhr und ohne
/// Queue. Genau deshalb ist sie ohne GUI und ohne echte Zeit prüfbar.
struct SelfTestPollBudget: Equatable {
    /// Ergebnis eines Durchlaufs, dessen Bedingung nicht erfüllt war.
    enum Verdict: Equatable {
        /// Frist ist noch da — nach der Pause erneut prüfen.
        case keepWaiting
        /// Die bediente Zeit ist aufgebraucht.
        case budgetExhausted
        /// Die Wanduhr-Obergrenze ist erreicht (Main-Thread dauerblockiert).
        case hardCapReached
    }

    /// Bediente Zeit, die die Bedingung insgesamt bekommt.
    let budget: TimeInterval
    /// Abstand zweier Prüfungen.
    let pause: TimeInterval
    /// Höchstabzug einer einzelnen Lücke. Alles darüber ist Fremdlast.
    let countedGapCeiling: TimeInterval
    /// Wanduhr-Obergrenze ab Start, unabhängig von der Bedienung.
    let hardCap: TimeInterval
    let startedAt: TimeInterval
    private(set) var lastPollAt: TimeInterval
    /// Summe der angerechneten Lücken.
    private(set) var observed: TimeInterval = 0
    /// Zahl der erfolglosen Durchläufe. Entspricht genau dem früheren `tick`.
    private(set) var polls = 0

    init(budget: TimeInterval,
         pause: TimeInterval,
         hardCap: TimeInterval,
         countedGapCeiling: TimeInterval? = nil,
         now: TimeInterval) {
        self.budget = budget
        self.pause = pause
        self.hardCap = hardCap
        self.countedGapCeiling = countedGapCeiling ?? pause
        startedAt = now
        lastPollAt = now
    }

    /// Verbucht einen Durchlauf, dessen Bedingung nicht erfüllt war.
    mutating func recordMiss(now: TimeInterval) -> Verdict {
        polls += 1
        observed += min(max(now - lastPollAt, 0), countedGapCeiling)
        lastPollAt = now
        if now - startedAt >= hardCap { return .hardCapReached }
        // Halbe Pause Toleranz: `observed` wächst in Schritten von höchstens
        // einer Pause, jede Schranke innerhalb desselben Schritts ergibt
        // dieselbe Zahl Durchläufe. Die Toleranz fängt damit ausschließlich
        // die Fließkomma-Summierung ab — 100 Additionen von 0,03 ergeben
        // 2,999999999999995 und nicht 3,0, was sonst einen Durchlauf zu viel
        // kostete.
        return observed >= budget - pause * 0.5 ? .budgetExhausted : .keepWaiting
    }

    /// Diagnosetext für den Timeout-Zweig. Nennt bewusst beide Zeiten: Weicht
    /// die Wanduhr stark von der bedienten Zeit ab, lag der Fehler nicht im
    /// geprüften Verhalten, sondern an einem fremden Main-Thread-Halter.
    var summary: String {
        String(format: "Frist %.1f s gerissen (bedient %.2f s, Wanduhr %.1f s, "
               + "%d Durchläufe, Pause %.0f ms)",
               budget, observed, lastPollAt - startedAt, polls, pause * 1000)
    }
}

/// Warteschleifen der Selbsttests. Eigener Namensraum statt `SelfTest`-
/// Erweiterung: `SelfTest.finish`, `testLabel` und `testStartedNanoseconds`
/// sind `private` und damit nur in `SelfTest.swift` sichtbar. Der Kern hier
/// kommt deshalb ohne sie aus; `SelfTest` legt eine dünne Hülle darüber.
enum SelfTestPolling {
    /// Zeit und Planer sind austauschbar, damit die Schleife ohne GUI und ohne
    /// echte Zeit prüfbar ist (Vorbild: `waitForCompletionPopupClosure`).
    struct Environment {
        var now: () -> TimeInterval
        var schedule: (TimeInterval, @escaping () -> Void) -> Void

        /// Der echte Betrieb: monotone Uhr, Main-Queue.
        static var main: Environment {
            Environment(
                now: { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
                schedule: { pause, work in
                    DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: work)
                }
            )
        }
    }

    /// Wartet, bis `condition` wahr ist, und ruft dann `then`. Reißt die Frist,
    /// läuft `onTimeout` mit der Buchhaltung — der Aufrufer schreibt dort seine
    /// eigene Diagnose und räumt seine Fixtures ab (kein `defer` im Helfer:
    /// `SelfTest.finish` endet über `exit()` und wickelt den Stack nicht ab).
    ///
    /// `condition` wird je Durchlauf genau einmal gerufen, auch im
    /// Timeout-Zweig nie zusätzlich. Sie darf deshalb nachziehen (scrollen,
    /// klicken), ohne dass eine Aktion doppelt zugestellt wird. Der erste
    /// Durchlauf läuft sofort, nicht erst nach der ersten Pause.
    static func waitFor(
        budget: TimeInterval,
        pause: TimeInterval,
        hardCap: TimeInterval,
        countedGapCeiling: TimeInterval? = nil,
        environment: Environment = .main,
        condition: @escaping () -> Bool,
        onTimeout: @escaping (SelfTestPollBudget) -> Void,
        then: @escaping () -> Void
    ) {
        let book = SelfTestPollBudget(
            budget: budget, pause: pause, hardCap: hardCap,
            countedGapCeiling: countedGapCeiling, now: environment.now()
        )
        step(book, environment: environment, condition: condition,
             onTimeout: onTimeout, then: then)
    }

    /// Wie `waitFor`, aber die Bedingung antwortet asynchron (git-Ground-Truth,
    /// WebKit-JavaScript). Der nächste Durchlauf wird erst nach der Antwort
    /// geplant; zwei Durchläufe können sich also nie überholen.
    static func waitForAsync(
        budget: TimeInterval,
        pause: TimeInterval,
        hardCap: TimeInterval,
        countedGapCeiling: TimeInterval? = nil,
        environment: Environment = .main,
        check: @escaping (@escaping (Bool) -> Void) -> Void,
        onTimeout: @escaping (SelfTestPollBudget) -> Void,
        then: @escaping () -> Void
    ) {
        let book = SelfTestPollBudget(
            budget: budget, pause: pause, hardCap: hardCap,
            countedGapCeiling: countedGapCeiling, now: environment.now()
        )
        stepAsync(book, environment: environment, check: check,
                  onTimeout: onTimeout, then: then)
    }

    /// Ein Durchlauf. Die Buchhaltung wandert als Wert in den nächsten
    /// Durchlauf — dasselbe Muster wie das bisherige `tick + 1`, nur mit mehr
    /// Inhalt. Kein geteilter veränderlicher Zustand, keine Box.
    private static func step(
        _ book: SelfTestPollBudget,
        environment: Environment,
        condition: @escaping () -> Bool,
        onTimeout: @escaping (SelfTestPollBudget) -> Void,
        then: @escaping () -> Void
    ) {
        if condition() { then(); return }
        var book = book
        switch book.recordMiss(now: environment.now()) {
        case .keepWaiting:
            let carried = book
            environment.schedule(book.pause) {
                step(carried, environment: environment, condition: condition,
                     onTimeout: onTimeout, then: then)
            }
        case .budgetExhausted, .hardCapReached:
            onTimeout(book)
        }
    }

    private static func stepAsync(
        _ book: SelfTestPollBudget,
        environment: Environment,
        check: @escaping (@escaping (Bool) -> Void) -> Void,
        onTimeout: @escaping (SelfTestPollBudget) -> Void,
        then: @escaping () -> Void
    ) {
        check { ok in
            if ok { then(); return }
            var book = book
            switch book.recordMiss(now: environment.now()) {
            case .keepWaiting:
                let carried = book
                environment.schedule(book.pause) {
                    stepAsync(carried, environment: environment, check: check,
                              onTimeout: onTimeout, then: then)
                }
            case .budgetExhausted, .hardCapReached:
                onTimeout(book)
            }
        }
    }

    /// Spiegel der Runner-Fristen in `tools/selftest-timeouts.sh`. Lookup und
    /// Auflistung verwenden dieselben Regeln; Tests vergleichen echte Antworten.
    struct TimeoutRule {
        let test: String
        let seconds: TimeInterval?
        var reviewKey: String? = nil
    }

    static let timeoutRules: [TimeoutRule] = [
        TimeoutRule(test: "print", seconds: 240),
        TimeoutRule(test: "jsonstress", seconds: 360),
        TimeoutRule(test: "softwrapindent", seconds: 180,
                    reviewKey: "FASTRA_SOFTWRAPINDENT_REVIEW_DIR"),
        TimeoutRule(test: "mdblocks", seconds: 180),
        TimeoutRule(test: "searchapproval", seconds: 180),
        TimeoutRule(test: "filedifftransfer", seconds: 180),
        TimeoutRule(test: "foldercompare", seconds: 180),
        TimeoutRule(test: "mdreferences", seconds: 180),
        TimeoutRule(test: "codeoutline", seconds: 180),
        TimeoutRule(test: "sourcesplit", seconds: 180),
        TimeoutRule(test: "snippets", seconds: 180),
        TimeoutRule(test: "snippetfiles", seconds: 180),
        TimeoutRule(test: "controlhost", seconds: 130),
        TimeoutRule(test: "tabfiledrag", seconds: 60),
        TimeoutRule(test: "diffexport", seconds: 120),
        TimeoutRule(test: "cmdw", seconds: 120),
        TimeoutRule(test: "leakscenario", seconds: 120),
        TimeoutRule(test: "githistory", seconds: nil,
                    reviewKey: "FASTRA_GITHISTORY_REVIEW_DIR"),
        TimeoutRule(test: "markdownimportui", seconds: nil,
                    reviewKey: "FASTRA_MARKDOWN_IMPORT_REVIEW_DIR"),
    ]

    static func runnerTimeoutSeconds(
        for test: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        let rule = timeoutRules.first { $0.test == test }
        if let key = rule?.reviewKey, let directory = environment[key], !directory.isEmpty {
            return 420
        }
        return rule?.seconds ?? 60
    }

    /// Wanduhrdeckel: Prüffrist plus 20 s Zugabe wie bei `waitUntil`, höchstens
    /// die restliche Runner-Zeit. Der Runner-Rest hat Vorrang, damit noch eine
    /// eigene Diagnose vor dessen Abbruch entsteht. Aufgebrauchter Rest ergibt 0;
    /// der erste erfolglose Durchlauf meldet `hardCapReached`.
    /// `elapsed` ist die bisherige Laufzeit des Testprozesses.
    static func hardCap(budget: TimeInterval, elapsed: TimeInterval,
                        test: String) -> TimeInterval {
        // Drei Sekunden Abstand: Der Runner braucht nach der Frist noch Zeit,
        // die Ergebniszeile zu lesen; eine Diagnose auf der Ziellinie käme zu
        // spät.
        let runnerRemaining = runnerTimeoutSeconds(for: test) - elapsed - 3
        return max(min(budget + 20, runnerRemaining), 0)
    }
}
