// SelfTestPolling.swift
//
// Fristbuchhaltung und Warteschleife der In-App-Selbsttests.
//
// Bis hierher zählte jede Warteschleife der Selbsttests nur ihre Durchläufe:
// „100 × 30 ms ≈ 3 s". Die Rechnung stimmt nur, solange jeder Durchlauf auch
// wirklich nach 30 ms drankommt. Belegt den Main-Thread ein anderer Halter —
// ein großer Editoraufbau, ein synchroner Dateizugriff —, dann zählt derselbe
// Durchlauf trotzdem nur als ein Tick, und die vermeintliche 3-Sekunden-Frist
// dehnt sich unbegrenzt. Sie endet dann nicht mit der Diagnose des Tests,
// sondern als Runner-TIMEOUT (`app/selftest.sh`, `timeout_for_test`) ganz ohne
// Text. Der Tick-Zähler kennt also keine Obergrenze.
//
// Dieselbe Falle traf 2026-08-17 die Unit-Tests; `waitUntil` in
// `Tests/FastraTests/TestWaiting.swift` löst sie dort, indem es nur BEDIENTE
// Zeit verbucht: Eine Lücke weit über der angeforderten Pause gehört einem
// fremden Main-Thread-Halter und verbraucht die Frist nicht. Diese Datei
// überträgt die Rechnung auf die Selbsttests, mit zwei bewussten Abweichungen:
//
// 1. Der Deckel je Lücke ist standardmäßig die Pause SELBST (nicht Pause plus
//    Zugabe). Damit ist die Frist exakt der bisherige Tick-Zähler — die
//    Migration einer Schleife ändert ihr Zeitverhalten nicht. Mit der 50-ms-
//    Zugabe aus `waitUntil` zählte jede 80-ms-Lücke voll, eine 3-Sekunden-
//    Frist wäre schon nach 37 statt 100 Durchläufen aufgebraucht.
// 2. Die Uhr ist `DispatchTime` (monoton, wie `testStartedNanoseconds`), nicht
//    `Date`. Eine Zeitumstellung mitten im Lauf darf keine Frist verschieben.
//
// Neu hinzu kommt der Wanduhr-Deckel: Selbst wenn die Frist nie voll wird,
// endet die Schleife spätestens kurz VOR der Runner-Frist und schreibt ihre
// eigene Diagnose. Das ist eine gewollte Verkürzung unter Totalblockade.
//
// Eigene Datei, damit die Quelltext-Wächter über `SelfTest.swift`
// (`SelfTestReviewFixTests`, `SelfTestPerformanceTests`) unberührt bleiben.

import Foundation

/// Fristbuchhaltung einer Warteschleife — reine Rechnung, ohne Uhr und ohne
/// Queue. Genau deshalb ist sie ohne GUI und ohne echte Zeit prüfbar.
struct SelfTestPollBudget: Equatable {
    /// Ergebnis eines Durchlaufs, dessen Bedingung NICHT erfüllt war.
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

    /// Verbucht einen Durchlauf, dessen Bedingung NICHT erfüllt war.
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

    /// Diagnosetext für den Timeout-Zweig. Nennt bewusst BEIDE Zeiten: Weicht
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
    /// `condition` wird je Durchlauf GENAU EINMAL gerufen, auch im
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
    /// WebKit-JavaScript). Der nächste Durchlauf wird erst NACH der Antwort
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

    /// Ein Durchlauf. Die Buchhaltung wandert als WERT in den nächsten
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

    /// Spiegel von `timeout_for_test` in `app/selftest.sh`. Ein Quelltext-
    /// Wächtertest hält beide Tabellen gleich; ohne ihn entstünde hier ein
    /// zweiter Wahrheitsort zur Runner-Frist.
    static func runnerTimeoutSeconds(for test: String) -> TimeInterval {
        switch test {
        case "print": return 240
        case "softwrapindent": return 180
        case "cmdw", "leakscenario": return 120
        default: return 60
        }
    }

    /// Wanduhr-Deckel: Frist plus 20 s Zugabe wie in `waitUntil`, aber nie über
    /// den Rest der Runner-Frist hinaus. Der Runner-Rest hat Vorrang vor der
    /// Frist: Bleibt weniger Runner-Zeit als Frist, endet die Schleife trotzdem
    /// vor dem Runner — mit eigener Diagnose. Die frühere Untergrenze
    /// „mindestens die Frist" versprach das Gegenteil: Bei `budget = 3` und
    /// 59 s Laufzeit lieferte sie 3 s, die Diagnose entstand erst bei 62 s, und
    /// `selftest.sh` beendete den Prozess bei 60 s als stummen TIMEOUT
    /// (Review-Fund 2026-09-17). Ein bereits aufgebrauchter Rest ergibt 0:
    /// Der erste erfolglose Durchlauf endet dann sofort als `hardCapReached`.
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
