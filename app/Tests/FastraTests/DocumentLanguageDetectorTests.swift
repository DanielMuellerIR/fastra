// DocumentLanguageDetectorTests.swift
//
// Direkte Koordinationstests für die fensterlokale Dokument-Spracherkennung.
// Die Scheduler laufen kontrolliert von Hand: Dadurch sind Cancellation und
// verspätete Ergebnisse deterministisch statt von Queue-Timing abhängig.

import Foundation
import Testing
import CodeEditLanguages
@testable import Fastra

private final class ManualWorkScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [@Sendable () -> Void] = []

    var count: Int { lock.withLock { work.count } }

    func schedule(_ item: @escaping @Sendable () -> Void) {
        lock.withLock { work.append(item) }
    }

    func runAll() {
        let pending = lock.withLock {
            let pending = work
            work.removeAll()
            return pending
        }
        pending.forEach { $0() }
    }
}

private final class ManualDelayScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [DispatchWorkItem] = []

    var count: Int { lock.withLock { work.count } }

    func schedule(_ delay: TimeInterval, _ item: DispatchWorkItem) {
        lock.withLock { work.append(item) }
    }

    func runAll() {
        let pending = lock.withLock {
            let pending = work
            work.removeAll()
            return pending
        }
        pending.forEach { $0.perform() }
    }
}

private final class DetectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DocumentLanguageDetector.DetectionResult] = []

    var results: [DocumentLanguageDetector.DetectionResult] {
        lock.withLock { storage }
    }

    func append(_ result: DocumentLanguageDetector.DetectionResult) {
        lock.withLock { storage.append(result) }
    }
}

private final class AnalyzerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var lengths: [Int] = []

    var analyzedLengths: [Int] { lock.withLock { lengths } }

    func analyze(_ sample: String) -> DocumentLanguageDetector.Analysis {
        lock.withLock { lengths.append(sample.count) }
        return .init(format: .json, fallbackLanguage: nil)
    }
}

private func detectorRequest(
    tabID: UUID = UUID(),
    documentID: UUID = UUID(),
    oldLength: Int = 0,
    content: String
) -> DocumentLanguageDetector.Request {
    .init(
        tabID: tabID,
        documentID: documentID,
        oldLength: oldLength,
        newLength: content.count,
        content: content
    )
}

@Suite("Asynchrone Dokument-Spracherkennung")
struct DocumentLanguageDetectorTests {
    @Test("Cancellation entfernt auch eine noch wartende Debounce-Arbeit")
    @MainActor
    func cancellationDropsPendingDebounce() {
        let background = ManualWorkScheduler()
        let delays = ManualDelayScheduler()
        let recorder = DetectionRecorder()
        let detector = DocumentLanguageDetector(
            scheduleWork: background.schedule,
            scheduleDelayedWork: delays.schedule
        )
        let request = detectorRequest(content: "ein kurzer Satz")

        detector.schedule(request, onResult: recorder.append)
        #expect(delays.count == 1)

        detector.cancel(tabID: request.tabID, documentID: request.documentID)
        delays.runAll()

        #expect(background.count == 0)
        #expect(recorder.results.isEmpty)
    }

    @Test("Cancellation verwirft auch ein bereits analysiertes, wartendes Ergebnis")
    @MainActor
    func cancellationDropsQueuedResult() {
        let background = ManualWorkScheduler()
        let delivery = ManualWorkScheduler()
        let recorder = DetectionRecorder()
        let detector = DocumentLanguageDetector(
            scheduleWork: background.schedule,
            deliverResult: delivery.schedule
        )
        let request = detectorRequest(
            content: #"{"name":"Fastra","version":183,"active":true}"#
        )

        detector.schedule(request, onResult: recorder.append)
        background.runAll()
        #expect(delivery.count == 1, "Analyse muss vor der Cancellation fertig sein")

        detector.cancel(tabID: request.tabID, documentID: request.documentID)
        delivery.runAll()

        #expect(recorder.results.isEmpty)
    }

    @Test("Wiederverwendeter Tabplatz akzeptiert nur das neue Dokument")
    @MainActor
    func reusedTabSlotRejectsOldDocument() {
        let background = ManualWorkScheduler()
        let delivery = ManualWorkScheduler()
        let recorder = DetectionRecorder()
        let detector = DocumentLanguageDetector(
            scheduleWork: background.schedule,
            deliverResult: delivery.schedule
        )
        let tabID = UUID()
        let first = detectorRequest(
            tabID: tabID,
            documentID: UUID(),
            content: #"{"document":"alt","active":true,"count":1}"#
        )
        let second = detectorRequest(
            tabID: tabID,
            documentID: UUID(),
            content: "<!DOCTYPE html><html><body>neu</body></html>"
        )

        detector.schedule(first, onResult: recorder.append)
        detector.schedule(second, onResult: recorder.append)
        background.runAll()
        delivery.runAll()

        #expect(recorder.results.count == 1)
        #expect(recorder.results.first?.tabID == tabID)
        #expect(recorder.results.first?.documentID == second.documentID)
        #expect(recorder.results.first?.analysis.format == .html)
    }

    @Test("Manuelle Wahl während laufender Analyse bleibt Quelle der Wahrheit")
    @MainActor
    func manualChoiceWinsDuringAnalysis() {
        let background = ManualWorkScheduler()
        let delivery = ManualWorkScheduler()
        let detector = DocumentLanguageDetector(
            scheduleWork: background.schedule,
            deliverResult: delivery.schedule
        )
        let suite = "fastra-detector-manual-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(
            defaults: defaults,
            documentLanguageDetector: detector
        )
        let tab = EditorTab(title: Workspace.untitledBaseName, path: "—")
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id

        workspace.activeTabContent.wrappedValue =
            #"{"name":"Fastra","version":183,"active":true}"#
        #expect(background.count == 1)
        workspace.setLanguageOverride(.swift)

        background.runAll()
        delivery.runAll()

        #expect(workspace.tabs[0].languageOverride == .swift)
        #expect(workspace.tabs[0].contentDetectedLanguage == nil)
        #expect(workspace.tabs[0].contentDetectedFormat == nil)
    }

    @Test("Zwei Fenster besitzen unabhängige laufende Arbeiten")
    @MainActor
    func multipleWindowsDoNotShareDetectionState() {
        let background = ManualWorkScheduler()
        let delivery = ManualWorkScheduler()
        let firstResults = DetectionRecorder()
        let secondResults = DetectionRecorder()
        // Gleiche Identitäten stellen den schärfsten Fall nach: Nur getrennte
        // Detector-Instanzen verhindern dann eine fensterübergreifende
        // Cancellation oder Ergebnisübernahme.
        let tabID = UUID()
        let documentID = UUID()
        let firstDetector = DocumentLanguageDetector(
            scheduleWork: background.schedule,
            deliverResult: delivery.schedule
        )
        let secondDetector = DocumentLanguageDetector(
            scheduleWork: background.schedule,
            deliverResult: delivery.schedule
        )
        let first = detectorRequest(
            tabID: tabID,
            documentID: documentID,
            content: #"{"window":"first","active":true,"count":1}"#
        )
        let second = detectorRequest(
            tabID: tabID,
            documentID: documentID,
            content: "<!DOCTYPE html><html><body>second</body></html>"
        )

        firstDetector.schedule(first, onResult: firstResults.append)
        secondDetector.schedule(second, onResult: secondResults.append)
        firstDetector.cancel(tabID: tabID, documentID: documentID)
        background.runAll()
        delivery.runAll()

        #expect(firstResults.results.isEmpty)
        #expect(secondResults.results.count == 1)
        #expect(secondResults.results.first?.analysis.format == .html)
    }

    @Test("Große Eingaben werden nur bis zur Analysegrenze weitergegeben")
    @MainActor
    func largeInputIsBoundedBeforeAnalysis() {
        let background = ManualWorkScheduler()
        let delivery = ManualWorkScheduler()
        let probe = AnalyzerProbe()
        let detector = DocumentLanguageDetector(
            scheduleWork: background.schedule,
            deliverResult: delivery.schedule,
            analyze: probe.analyze
        )
        let content = String(
            repeating: "0123456789abcdef",
            count: ContentLanguageDetection.analysisCharacterLimit
        )

        detector.schedule(detectorRequest(content: content)) { _ in }
        background.runAll()
        delivery.runAll()

        #expect(content.count > ContentLanguageDetection.analysisCharacterLimit)
        #expect(probe.analyzedLengths == [ContentLanguageDetection.analysisCharacterLimit])
    }

    @Test("Die zuletzt analysierte Länge drosselt kleine Folgeänderungen")
    @MainActor
    func analyzedLengthThrottlesSmallFollowUp() {
        let background = ManualWorkScheduler()
        let delivery = ManualWorkScheduler()
        let probe = AnalyzerProbe()
        let detector = DocumentLanguageDetector(
            scheduleWork: background.schedule,
            deliverResult: delivery.schedule,
            analyze: probe.analyze
        )
        let tabID = UUID()
        let documentID = UUID()
        let firstContent = String(repeating: "x", count: 100)
        detector.schedule(detectorRequest(
            tabID: tabID,
            documentID: documentID,
            content: firstContent
        )) { _ in }
        background.runAll()
        delivery.runAll()

        detector.schedule(detectorRequest(
            tabID: tabID,
            documentID: documentID,
            oldLength: firstContent.count,
            content: firstContent + "y"
        )) { _ in }

        #expect(background.count == 0)
        #expect(probe.analyzedLengths == [100])
    }

    @Test("Eine abgebrochene Analyse drosselt die Ersatzanalyse nicht")
    @MainActor
    func cancelledAnalysisDoesNotThrottleReplacement() {
        let background = ManualWorkScheduler()
        let delays = ManualDelayScheduler()
        let delivery = ManualWorkScheduler()
        let recorder = DetectionRecorder()
        let detector = DocumentLanguageDetector(
            scheduleWork: background.schedule,
            scheduleDelayedWork: delays.schedule,
            deliverResult: delivery.schedule
        )
        let tabID = UUID()
        let documentID = UUID()
        let bigContent = String(repeating: "x", count: 2_000)

        // Große Einfügung startet sofort eine Analyse — sie bleibt aber im
        // Hintergrund-Scheduler liegen (noch kein Ergebnis geliefert).
        detector.schedule(detectorRequest(
            tabID: tabID, documentID: documentID, content: bigContent
        ), onResult: recorder.append)
        #expect(background.count == 1)

        // Die kleine Folgeänderung verwirft die laufende Analyse. Sie darf
        // dann nicht an der nie gelieferten Länge gemessen und als „zu
        // klein" verworfen werden — sonst bliebe die Erkennung hängen.
        detector.schedule(detectorRequest(
            tabID: tabID, documentID: documentID,
            oldLength: bigContent.count, content: bigContent + "y"
        ), onResult: recorder.append)
        #expect(delays.count == 1, "Ersatzanalyse muss eingeplant sein")

        background.runAll()   // verworfene alte Analyse läuft ins Leere
        delays.runAll()
        background.runAll()
        delivery.runAll()

        #expect(recorder.results.count == 1)
    }

    @Test("Ein überholtes Debounce-Work-Item startet keine Analyse mehr")
    @MainActor
    func supersededDebounceWorkItemIsInert() {
        let background = ManualWorkScheduler()
        let delays = ManualDelayScheduler()
        let recorder = DetectionRecorder()
        let probe = AnalyzerProbe()
        let detector = DocumentLanguageDetector(
            scheduleWork: background.schedule,
            scheduleDelayedWork: delays.schedule,
            analyze: probe.analyze
        )
        let request = detectorRequest(content: "ein kurzer Satz")

        detector.schedule(request, onResult: recorder.append)
        #expect(delays.count == 1)
        detector.cancel(tabID: request.tabID, documentID: request.documentID)

        // Das abgesagte Work-Item liegt noch in der (Test-)Queue; sein
        // Auftrag samt Snapshot ist aber schon aus dem State entfernt.
        delays.runAll()
        background.runAll()

        #expect(probe.analyzedLengths.isEmpty)
        #expect(recorder.results.isEmpty)
    }

    @Test("Der Produkt-Scheduler liefert Ergebnisse auf dem Main-Thread")
    @MainActor
    func defaultDeliveryReturnsToMainThread() async {
        let detector = DocumentLanguageDetector()
        let deliveredOnMain = await withCheckedContinuation { continuation in
            detector.schedule(detectorRequest(
                content: #"{"main":true,"version":183,"count":1}"#
            )) { _ in
                continuation.resume(returning: Thread.isMainThread)
            }
        }

        #expect(deliveredOnMain)
    }
}
