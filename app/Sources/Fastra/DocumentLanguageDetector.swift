// DocumentLanguageDetector.swift
//
// Koordiniert die nebenläufige Inhaltserkennung eines Dokuments. Die
// Komponente kennt weder Workspace noch Tabs als Modelle: Sie bekommt nur
// stabile Identitäten, Längen und einen unveränderlichen Text-Snapshot.
// Produktentscheidungen wie Eignung, manuelle Sprachwahl und die Mutation des
// Editorzustands bleiben beim Workspace.

import Foundation
import CodeEditLanguages

/// Fensterlokale Koordination der asynchronen Dokument-Spracherkennung.
///
/// Der eigene Zustand ist verriegelt, weil auch direkte Workspace-Tests ohne
/// AppKit-Runloop arbeiten. Der eigentliche Parser läuft über `scheduleWork`
/// im Hintergrund; Ergebnisse gelangen ausschließlich über `deliverResult`
/// zurück auf den Main-Actor. Die Scheduler sind injizierbar, damit
/// Cancellation und Reihenfolge ohne Wanduhr-Wartezeiten direkt getestet
/// werden können.
final class DocumentLanguageDetector: @unchecked Sendable {
    typealias Scheduler = (@escaping @Sendable () -> Void) -> Void
    typealias DelayedScheduler = (TimeInterval, DispatchWorkItem) -> Void
    typealias Analyzer = @Sendable (String) -> Analysis
    typealias ResultHandler = @MainActor @Sendable (DetectionResult) -> Void

    /// Schmaler Auftrag aus dem Workspace. `content` ist ein
    /// Copy-on-write-Snapshot und wird hier noch nicht kopiert; erst die
    /// tatsächlich gestartete Analyse erzeugt daraus die begrenzte Probe.
    struct Request: Sendable {
        let tabID: UUID
        let documentID: UUID
        let oldLength: Int
        let newLength: Int
        let content: String
    }

    /// Reines Analyseergebnis ohne Workspace- oder Editorentscheidung.
    struct Analysis: @unchecked Sendable {
        let format: ContentLanguageDetection.Format?
        /// Nur die Shebang-/Modeline-Rückfallerkennung liefert direkt eine
        /// Grammatik. Für ein erkanntes Format ordnet der Workspace die
        /// Grammatik selbst zu und behält damit die Formatwahrheit.
        let fallbackLanguage: CodeLanguage?
    }

    /// Identitätsgebundenes Ergebnis. Der Workspace prüft beide Kennungen
    /// unmittelbar vor jeder Modellmutation nochmals gegen seinen Tab.
    struct DetectionResult: @unchecked Sendable {
        let tabID: UUID
        let documentID: UUID
        let analysis: Analysis
    }

    /// Kooperatives Abbruchsignal für bereits an den Hintergrund-Scheduler
    /// übergebene Arbeit. Einen laufenden Parser können wir nicht anhalten;
    /// sein Ergebnis wird nach Cancellation aber sicher nicht mehr geliefert.
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private struct State {
        var documentID: UUID
        var generation: UInt64
        /// Länge der letzten ERFOLGREICH gelieferten Analyse. Sie wird erst
        /// bei der Ergebnisübernahme fortgeschrieben: Würde schon der Start
        /// zählen, könnte eine abgebrochene Analyse eine kleine Folgeänderung
        /// als „zu klein" erscheinen lassen — und die Erkennung bliebe auf
        /// einem nie gelieferten Stand hängen.
        var lastAnalyzedLength: Int?
        var delayedWork: DispatchWorkItem?
        /// Der Auftrag eines wartenden Debounce-Laufs liegt im State, nicht
        /// in der Work-Item-Closure: Ein abgesagtes Work-Item bleibt bis zum
        /// Ablauf der Verzögerung in der Main-Queue stehen — läge der
        /// Dokument-Snapshot in der Closure, hielte die Queue bei schnellem
        /// Tippen viele verworfene Snapshots gleichzeitig im Speicher.
        var pendingRequest: Request?
        var analysisCancellation: Cancellation?
    }

    private var states: [UUID: State] = [:]
    /// Prozesslokal innerhalb dieser Detector-Instanz monoton. Die Generation
    /// darf beim Entfernen eines Zustands nicht zurückspringen: Sonst könnte
    /// ein später neu angelegter Auftrag dieselbe Kennung wie ein altes,
    /// bereits laufendes Ergebnis erhalten.
    private var nextGeneration: UInt64 = 0
    private let stateLock = NSLock()

    private let scheduleWork: Scheduler
    private let scheduleDelayedWork: DelayedScheduler
    private let deliverResult: Scheduler
    private let analyze: Analyzer

    init(
        scheduleWork: @escaping Scheduler = {
            DispatchQueue.global(qos: .utility).async(execute: $0)
        },
        scheduleDelayedWork: @escaping DelayedScheduler = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        deliverResult: @escaping Scheduler = {
            DispatchQueue.main.async(execute: $0)
        },
        analyze: @escaping Analyzer = { sample in
            DocumentLanguageDetector.analyzeContent(sample)
        }
    ) {
        self.scheduleWork = scheduleWork
        self.scheduleDelayedWork = scheduleDelayedWork
        self.deliverResult = deliverResult
        self.analyze = analyze
    }

    /// Plant genau die mechanisch nötige Arbeit. Eine neue Anfrage entwertet
    /// immer ein älteres Ergebnis derselben Tabposition, auch wenn die
    /// Drosselung für den neuen Stand keine weitere Analyse verlangt.
    func schedule(_ request: Request, onResult: @escaping ResultHandler) {
        let plan: (
            trigger: ContentLanguageDetection.Trigger,
            generation: UInt64,
            delayedWork: DispatchWorkItem?
        ) = stateLock.withLock {
            var state = states[request.tabID]
            if state?.documentID != request.documentID {
                state?.delayedWork?.cancel()
                state?.analysisCancellation?.cancel()
                state = nil
            }

            let lastAnalyzedLength = state?.lastAnalyzedLength
            state?.delayedWork?.cancel()
            state?.analysisCancellation?.cancel()

            nextGeneration &+= 1
            let generation = nextGeneration
            let trigger = ContentLanguageDetection.trigger(
                oldLength: request.oldLength,
                newLength: request.newLength,
                lastAnalyzedLength: lastAnalyzedLength
            )
            var updated = State(
                documentID: request.documentID,
                generation: generation,
                lastAnalyzedLength: lastAnalyzedLength,
                delayedWork: nil,
                pendingRequest: nil,
                analysisCancellation: nil
            )
            if trigger == .debounced {
                let tabID = request.tabID
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    // Den Auftrag erst jetzt aus dem State holen: Wurde er
                    // inzwischen ersetzt oder abgebrochen, ist er dort schon
                    // weg und sein Snapshot bereits freigegeben.
                    let pending = self.stateLock.withLock { () -> Request? in
                        guard var state = self.states[tabID],
                              state.generation == generation,
                              let request = state.pendingRequest else {
                            return nil
                        }
                        state.pendingRequest = nil
                        self.states[tabID] = state
                        return request
                    }
                    guard let pending else { return }
                    self.beginAnalysis(
                        pending, generation: generation, onResult: onResult
                    )
                }
                updated.delayedWork = work
                updated.pendingRequest = request
                states[request.tabID] = updated
                return (trigger, generation, work)
            }
            states[request.tabID] = updated
            return (trigger, generation, nil)
        }

        switch plan.trigger {
        case .none:
            break
        case .immediate:
            beginAnalysis(
                request, generation: plan.generation, onResult: onResult
            )
        case .debounced:
            if let delayedWork = plan.delayedWork {
                scheduleDelayedWork(
                    ContentLanguageDetection.debounceInterval, delayedWork
                )
            }
        }
    }

    /// Beendet wartende Arbeit und entwertet bereits laufende Ergebnisse für
    /// diese Tabposition. `documentID` schützt optional vor dem versehentlichen
    /// Abbruch eines inzwischen im selben Platz dargestellten neuen Dokuments.
    func cancel(tabID: UUID, documentID: UUID? = nil) {
        let state = stateLock.withLock { () -> State? in
            guard let state = states[tabID],
                  documentID == nil || documentID == state.documentID else {
                return nil
            }
            states.removeValue(forKey: tabID)
            return state
        }
        state?.delayedWork?.cancel()
        state?.analysisCancellation?.cancel()
    }

    /// Workspace-Wechsel und Fensterschluss räumen ihre gesamte lokale Arbeit
    /// ab. Andere Fenster besitzen eigene Detector-Instanzen und bleiben
    /// dadurch vollständig unberührt.
    func cancelAll() {
        let removedStates = stateLock.withLock {
            let removedStates = Array(states.values)
            states.removeAll()
            return removedStates
        }
        for state in removedStates {
            state.delayedWork?.cancel()
            state.analysisCancellation?.cancel()
        }
    }

    private func beginAnalysis(
        _ request: Request,
        generation: UInt64,
        onResult: @escaping ResultHandler
    ) {
        let cancellation = Cancellation()
        let shouldBegin = stateLock.withLock {
            guard var state = states[request.tabID],
                  state.documentID == request.documentID,
                  state.generation == generation else { return false }
            state.delayedWork = nil
            state.analysisCancellation = cancellation
            states[request.tabID] = state
            return true
        }
        guard shouldBegin, !cancellation.isCancelled else { return }

        // Erst jetzt Material erzeugen: Bei verworfenen Debounce-Aufträgen
        // wurde damit auch keine 64-KiB-Probe kopiert. Der vollständige
        // Snapshot wird nie an den Hintergrund-Parser weitergegeben.
        let sample = String(
            request.content.prefix(ContentLanguageDetection.analysisCharacterLimit)
        )
        let tabID = request.tabID
        let documentID = request.documentID
        let analyzedLength = request.newLength

        let analyze = self.analyze
        let deliverResult = self.deliverResult
        scheduleWork { [weak self] in
            guard !cancellation.isCancelled else { return }
            let analysis = analyze(sample)
            guard !cancellation.isCancelled else { return }
            let result = DetectionResult(
                tabID: tabID,
                documentID: documentID,
                analysis: analysis
            )
            deliverResult { [weak self] in
                dispatchPrecondition(condition: .onQueue(.main))
                guard let self, !cancellation.isCancelled else { return }
                let shouldDeliver = self.stateLock.withLock {
                    guard var current = self.states[tabID],
                          current.documentID == documentID,
                          current.generation == generation,
                          current.analysisCancellation === cancellation else {
                        return false
                    }
                    current.analysisCancellation = nil
                    // Erst die tatsächlich gelieferte Analyse zählt als
                    // Drosselungs-Basis für künftige Änderungen.
                    current.lastAnalyzedLength = analyzedLength
                    self.states[tabID] = current
                    return true
                }
                guard shouldDeliver else { return }
                MainActor.assumeIsolated {
                    onResult(result)
                }
            }
        }
    }

    /// Inhaltliche Erkennung bleibt dieselbe wie zuvor im Workspace. Diese
    /// Funktion kennt keine Tabs und keine Produktprioritäten; sie analysiert
    /// ausschließlich die bereits begrenzte Probe.
    private static func analyzeContent(_ sample: String) -> Analysis {
        let format = ContentLanguageDetection.detect(in: sample)
        guard format == nil else {
            return Analysis(format: format, fallbackLanguage: nil)
        }

        let fallback = CodeLanguage.detectLanguageFrom(
            // Bewusst ohne Endung: Es zählt allein der Inhalt.
            url: URL(fileURLWithPath: "unbenannt"),
            prefixBuffer: String(sample.prefix(512)),
            suffixBuffer: nil
        )
        return Analysis(
            format: nil,
            fallbackLanguage: fallback.id == .plainText ? nil : fallback
        )
    }
}
