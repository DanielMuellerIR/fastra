// FileDiffCancellationTests.swift
//
// Belege für den Folgeauftrag „Diff tatsächlich abbrechen" (2026-09-05):
// 1. Der eigene Myers-Kern liefert dieselben Änderungen wie Foundations
//    `CollectionDifference` — sonst würden sich die Zeilen-Ausrichtung und
//    damit alle vorhandenen Diff-Fixtures verschieben.
// 2. Jeder Prüfpunkt in jeder Phase bricht wirklich ab, ohne Teilergebnis.
// 3. Der Ladepfad meldet Abbruch als Abbruch, nicht als „unlesbar".
// 4. Workspace, Makro-Assistent und externes Fenster brechen ihre Tasks bei
//    Tab-/Fensterschluss, neuer Anfrage und Abbau wirklich ab, und ihre
//    Verwaltung wächst dabei nicht.
// 5. Verzögerung bis zum Abbruch wird gemessen und muss klein bleiben.

import Testing
import Foundation
import Darwin
import FastraDiffProtocol
@testable import Fastra

// MARK: - Kern: Gleichheit mit Foundation

/// Deterministischer Zufall, damit ein roter Fall reproduzierbar bleibt.
private struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

private func foundationChanges(from old: [Int], to new: [Int]) -> MyersDiff.Changes {
    var changes = MyersDiff.Changes()
    for change in new.difference(from: old) {
        switch change {
        case .remove(let offset, _, _): changes.removedOffsets.append(offset)
        case .insert(let offset, _, _): changes.insertedOffsets.append(offset)
        }
    }
    changes.removedOffsets.sort()
    changes.insertedOffsets.sort()
    return changes
}

@Test("Myers-Kern: identische Änderungen wie CollectionDifference (Zufallsfolgen)")
func myersMatchesFoundationOnRandomSequences() throws {
    var random = SeededRandom(seed: 2026_09_05)
    for round in 0..<400 {
        // Kleines Alphabet → viele gleiche Elemente, also viele Gleichstände,
        // an denen sich die Entscheidungsregel des Algorithmus zeigt.
        let alphabet = Int.random(in: 1...6, using: &random)
        let oldCount = Int.random(in: 0...40, using: &random)
        let newCount = Int.random(in: 0...40, using: &random)
        let old = (0..<oldCount).map { _ in Int.random(in: 0..<alphabet, using: &random) }
        let new = (0..<newCount).map { _ in Int.random(in: 0..<alphabet, using: &random) }
        let ours = try #require(MyersDiff.changes(from: old, to: new, isCancelled: { false }))
        let theirs = foundationChanges(from: old, to: new)
        #expect(ours == theirs, "Runde \(round): alt=\(old) neu=\(new)")
        if ours != theirs { return }
    }
}

@Test("Myers-Kern: größere Folgen mit verstreuten Änderungen")
func myersMatchesFoundationOnLargerSequences() throws {
    var random = SeededRandom(seed: 42)
    for _ in 0..<20 {
        let base = (0..<1_500).map { _ in Int.random(in: 0..<200, using: &random) }
        var edited = base
        for _ in 0..<60 {
            switch Int.random(in: 0..<3, using: &random) {
            case 0 where !edited.isEmpty:
                edited.remove(at: Int.random(in: 0..<edited.count, using: &random))
            case 1:
                edited.insert(Int.random(in: 0..<200, using: &random),
                              at: Int.random(in: 0...edited.count, using: &random))
            default:
                guard !edited.isEmpty else { continue }
                edited[Int.random(in: 0..<edited.count, using: &random)] =
                    Int.random(in: 0..<200, using: &random)
            }
        }
        let ours = try #require(MyersDiff.changes(from: base, to: edited, isCancelled: { false }))
        #expect(ours == foundationChanges(from: base, to: edited))
    }
}

@Test("Myers-Kern: Randfälle (leer, gleich, völlig verschieden)")
func myersEdgeCases() throws {
    let cases: [([Int], [Int])] = [
        ([], []), ([1], []), ([], [1]), ([1, 2, 3], [1, 2, 3]),
        ([1, 2, 3], [4, 5, 6]), ([1, 2, 3], [3, 2, 1]), ([1, 1, 1], [1, 1]),
    ]
    for (old, new) in cases {
        let ours = try #require(MyersDiff.changes(from: old, to: new, isCancelled: { false }))
        #expect(ours == foundationChanges(from: old, to: new), "alt=\(old) neu=\(new)")
    }
}

// MARK: - Kern: Abbruch an jedem Prüfpunkt

/// Zählt die Abbruch-Abfragen und meldet ab der `cancelAt`-ten `true`.
private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var callsAfterCancel = 0
    let cancelAt: Int

    init(cancelAt: Int) { self.cancelAt = cancelAt }

    func check() -> Bool {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        if calls > cancelAt { callsAfterCancel += 1 }
        return calls >= cancelAt
    }
}

/// Eingabe, die jede Phase durchläuft: mehrere tausend Zeilen (damit die
/// gestaffelten Prüfpunkte mehrfach greifen), CRLF, Unicode, Leerzeilen und
/// verstreute Änderungen — dieselbe Vielfalt wie die Diff-Fixtures.
private func phaseCoveringInputs() -> (String, String) {
    var left: [String] = []
    var right: [String] = []
    for i in 0..<9_000 {
        let line = i % 7 == 0 ? "" : "Zeile \(i) — Ünïcödé 🙂 \(i % 13)"
        left.append(line)
        switch i % 11 {
        case 3: right.append(line + " geändert")
        case 5: continue
        case 8: right.append(line); right.append("eingefügt \(i)")
        default: right.append(line)
        }
    }
    return (left.joined(separator: "\r\n"), right.joined(separator: "\n"))
}

@Test("Abbruch: jeder Prüfpunkt jeder Phase beendet den Vergleich ohne Teilergebnis")
func everyCheckpointCancels() throws {
    let (left, right) = phaseCoveringInputs()
    var options = FileDiffOptions()
    options.ignoreBlankLines = true

    // Erst zählen, wie oft ein vollständiger Lauf nachfragt.
    let counting = CancellationProbe(cancelAt: .max)
    let complete = try FileDiff.compare(left: left, right: right, options: options,
                                        isCancelled: counting.check)
    guard case .result(let reference) = complete else {
        Issue.record("Erwartet: Ergebnis"); return
    }
    let totalChecks = counting.calls
    // Zeilenzerlegung ×2, Schlüssel ×4, Aliase ×2, Myers, Ausrichtung,
    // Blöcke: deutlich mehr als eine Handvoll Prüfpunkte.
    #expect(totalChecks >= 20, "nur \(totalChecks) Prüfpunkte")

    // Dann an Prüfpunkten abbrechen: alle frühen (Zerlegung, Schlüssel,
    // Aliase), eine gleichmäßige Stichprobe über den Myers-Kern und alle
    // späten (Ausrichtung, Blöcke). Es gibt nie ein Ergebnis, und nach dem
    // gemeldeten Abbruch fragt der Kern höchstens noch einmal nach.
    var sample = Set(1...min(totalChecks, 80))
    sample.formUnion(stride(from: 1, through: totalChecks, by: max(1, totalChecks / 40)))
    sample.formUnion(max(1, totalChecks - 30)...totalChecks)
    for cancelAt in sample.sorted() {
        let probe = CancellationProbe(cancelAt: cancelAt)
        do {
            let outcome = try FileDiff.compare(left: left, right: right, options: options,
                                               isCancelled: probe.check)
            Issue.record("Prüfpunkt \(cancelAt): Vergleich lief trotz Abbruch durch: \(outcome)")
            return
        } catch is CancellationError {
            #expect(probe.callsAfterCancel <= 1,
                    "Prüfpunkt \(cancelAt): \(probe.callsAfterCancel) Abfragen nach Abbruch")
        }
    }

    // Ohne Abbruch bleibt das Ergebnis dasselbe wie über die alte Fassung.
    #expect(FileDiff.compare(left: left, right: right, options: options) == .result(reference))
}

@Test("Abbruch: die nicht abbrechbare Fassung liefert weiter dasselbe Ergebnis")
func nonCancellableOverloadMatches() throws {
    let (left, right) = phaseCoveringInputs()
    for options in [FileDiffOptions(), FileDiffOptions(ignoreAllWhitespace: true, ignoreCase: true)] {
        let cancellable = try FileDiff.compare(left: left, right: right, options: options,
                                               isCancelled: { false })
        #expect(cancellable == FileDiff.compare(left: left, right: right, options: options))
    }
}

// MARK: - Ladepfad

@Test("Ladepfad: Abbruch beim Dateilesen kommt als Abbruch zurück, nicht als „unlesbar“")
func loadPathReportsCancellationHonestly() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-filediff-cancel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.txt")
    let b = dir.appendingPathComponent("b.txt")
    try "eins\nzwei".write(to: a, atomically: true, encoding: .utf8)
    try "eins\nzwo".write(to: b, atomically: true, encoding: .utf8)
    let request = FileDiffRequest(left: .file(a), right: .file(b), options: FileDiffOptions())

    // Sofortiger Abbruch: noch vor dem ersten Lesen.
    #expect(throws: CancellationError.self) {
        try Workspace.computeFileDiffDocument(request: request, isCancelled: { true })
    }
    // Abbruch erst nach dem Laden (im Diff): ebenfalls CancellationError.
    let late = CancellationProbe(cancelAt: 6)
    #expect(throws: CancellationError.self) {
        try Workspace.computeFileDiffDocument(request: request, isCancelled: late.check)
    }
    // Ohne Abbruch: das bekannte Ergebnis.
    let document = try Workspace.computeFileDiffDocument(request: request, isCancelled: { false })
    #expect(document.result?.blocks.count == 1)
    #expect(document == Workspace.computeFileDiffDocument(request: request))
}

// MARK: - Workspace: verwaltete Tasks

/// Ein „Vergleich", der so lange rechnet, bis sein Task abgebrochen wird —
/// wie der kooperative Dummy der Makro-Tests. Meldet Start und Abbruch.
private struct BlockingCompute {
    let started = DispatchSemaphore(value: 0)
    let cancelled = DispatchSemaphore(value: 0)

    func run(_ request: FileDiffRequest) throws -> FileDiffDocument {
        started.signal()
        while !Task.isCancelled {
            Thread.sleep(forTimeInterval: 0.001)
        }
        cancelled.signal()
        throw CancellationError()
    }
}

private func probeRequest(_ tag: String = UUID().uuidString) -> FileDiffRequest {
    FileDiffRequest(left: .text("links", name: "links-\(tag)"),
                    right: .text("rechts", name: "rechts-\(tag)"),
                    options: FileDiffOptions())
}

@MainActor
private func makeWorkspace(_ suite: String) -> (Workspace, UserDefaults) {
    let defaults = testSuiteDefaults(named: suite)
    return (Workspace(defaults: defaults), defaults)
}

@Test("Workspace: Tab schließen bricht den laufenden Vergleich ab")
@MainActor
func closingTabCancelsComputation() throws {
    let suite = "fastra-test-diff-cancel-close-\(UUID().uuidString)"
    let (workspace, defaults) = makeWorkspace(suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let compute = BlockingCompute()
    workspace.openFileDiffTab(request: probeRequest(), compute: compute.run)
    #expect(compute.started.wait(timeout: .now() + 2) == .success)
    #expect(workspace.fileDiffComputations.activeCount == 1)

    let tabID = try #require(workspace.tabs.first(where: { $0.fileDiffRequest != nil })?.id)
    workspace.closeTab(id: tabID)

    #expect(compute.cancelled.wait(timeout: .now() + 2) == .success)
    #expect(workspace.fileDiffComputations.activeCount == 0)
    #expect(!workspace.tabs.contains(where: { $0.fileDiffRequest != nil }))
}

@Test("Workspace: neue Anfrage für denselben Vergleich bricht die alte ab und wird fertig")
@MainActor
func newRequestCancelsPreviousAndCompletes() async throws {
    let suite = "fastra-test-diff-cancel-rerun-\(UUID().uuidString)"
    let (workspace, defaults) = makeWorkspace(suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = probeRequest("gleich")
    let blocking = BlockingCompute()
    workspace.openFileDiffTab(request: first, compute: blocking.run)
    #expect(blocking.started.wait(timeout: .now() + 2) == .success)
    let tabCount = workspace.tabs.count

    // Inhaltlich derselbe Vergleich → derselbe Tab, neue Berechnung. Die
    // alte muss enden, die neue ungestört fertig werden.
    let second = probeRequest("gleich")
    #expect(second.matches(first))
    workspace.openFileDiffTab(request: second) { request in
        try Workspace.computeFileDiffDocument(request: request, isCancelled: { Task.isCancelled })
    }
    #expect(blocking.cancelled.wait(timeout: .now() + 2) == .success)
    #expect(workspace.tabs.count == tabCount, "Tab wurde gestapelt statt wiederverwendet")

    let delivered = await waitUntil {
        workspace.tabs.first(where: { $0.fileDiffRequest?.id == second.id })?.fileDiffDocument != nil
    }
    #expect(delivered)
    let tab = try #require(workspace.tabs.first(where: { $0.fileDiffRequest?.id == second.id }))
    #expect(tab.fileDiffDocument?.result?.blocks.count == 1)
    #expect(workspace.fileDiffComputations.activeCount == 0)
}

@Test("Workspace: Fensterschluss bricht alle Vergleiche ab")
@MainActor
func closingWindowCancelsAllComputations() {
    let suite = "fastra-test-diff-cancel-window-\(UUID().uuidString)"
    let (workspace, defaults) = makeWorkspace(suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let computes = [BlockingCompute(), BlockingCompute()]
    for compute in computes {
        workspace.openFileDiffTab(request: probeRequest(), compute: compute.run)
        #expect(compute.started.wait(timeout: .now() + 2) == .success)
    }
    #expect(workspace.fileDiffComputations.activeCount == 2)

    #expect(workspace.prepareToCloseWindow())

    for compute in computes {
        #expect(compute.cancelled.wait(timeout: .now() + 2) == .success)
    }
    #expect(workspace.fileDiffComputations.activeCount == 0)
}

@Test("Workspace: ein abgebrochener Vergleich veröffentlicht nie ein Dokument")
@MainActor
func cancelledComputationNeverPublishes() async throws {
    let suite = "fastra-test-diff-cancel-publish-\(UUID().uuidString)"
    let (workspace, defaults) = makeWorkspace(suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let request = probeRequest()
    let started = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0)
    // Rechnet nach dem Abbruch scheinbar „fertig" — so wie ein Kern, der
    // das Signal genau zwischen letztem Prüfpunkt und Rückgabe bekommt.
    workspace.openFileDiffTab(request: request) { request in
        started.signal()
        released.wait()
        return Workspace.computeFileDiffDocument(request: request)
    }
    #expect(started.wait(timeout: .now() + 2) == .success)
    let tabID = try #require(workspace.tabs.first(where: { $0.fileDiffRequest?.id == request.id })?.id)
    workspace.fileDiffComputations.cancel(tabID: tabID)
    released.signal()

    // Kurz Gelegenheit geben — das Dokument darf trotzdem nie ankommen.
    _ = await waitUntil(timeout: 0.3) { false }
    #expect(workspace.tabs.first(where: { $0.id == tabID })?.fileDiffDocument == nil)
}

private final class WeakWorkspaceReference {
    weak var workspace: Workspace?
    init(_ workspace: Workspace) { self.workspace = workspace }
}

@MainActor
private func workspaceWithBlockingDiff(defaults: UserDefaults)
    -> (WeakWorkspaceReference, BlockingCompute) {
    let workspace = Workspace(defaults: defaults)
    let compute = BlockingCompute()
    workspace.openFileDiffTab(request: probeRequest(), compute: compute.run)
    return (WeakWorkspaceReference(workspace), compute)
}

@Test("Workspace-Abbau lässt keinen Vergleich weiterrechnen")
@MainActor
func workspaceDeinitCancelsComputation() {
    let suite = "fastra-test-diff-cancel-deinit-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let (reference, compute) = workspaceWithBlockingDiff(defaults: defaults)
    #expect(compute.started.wait(timeout: .now() + 2) == .success)

    // Wie im Makro-Pendant: Der appweite Dokumentkontext hält den zuletzt
    // aktiven Workspace; erst ein Wechsel gibt ihn frei.
    let otherWorkspace = Workspace(defaults: defaults)
    ActiveDocumentContext.shared.activate(otherWorkspace)

    #expect(reference.workspace == nil)
    #expect(compute.cancelled.wait(timeout: .now() + 10) == .success)
}

@Test("Workspace: die Verwaltung wächst über viele Abbrüche und Abschlüsse nicht")
@MainActor
func bookkeepingDoesNotGrow() async {
    let suite = "fastra-test-diff-cancel-growth-\(UUID().uuidString)"
    let (workspace, defaults) = makeWorkspace(suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    for round in 0..<20 {
        let compute = BlockingCompute()
        workspace.openFileDiffTab(request: probeRequest("wachstum"), compute: compute.run)
        #expect(compute.started.wait(timeout: .now() + 2) == .success)
        // Jede zweite Runde schließt den Tab, sonst überschreibt die nächste
        // Anfrage — beide Wege müssen den Eintrag freigeben.
        if round % 2 == 0,
           let tabID = workspace.tabs.first(where: { $0.fileDiffRequest != nil })?.id {
            workspace.closeTab(id: tabID)
            #expect(compute.cancelled.wait(timeout: .now() + 2) == .success)
            #expect(workspace.fileDiffComputations.activeCount == 0)
        }
    }
    // Abschließend eine echte Berechnung — sie trägt sich selbst aus.
    let request = probeRequest("wachstum")
    workspace.openFileDiffTab(request: request)
    let delivered = await waitUntil {
        workspace.tabs.first(where: { $0.fileDiffRequest?.id == request.id })?.fileDiffDocument != nil
    }
    #expect(delivered)
    #expect(workspace.fileDiffComputations.activeCount == 0)
}

// MARK: - Externes Vergleichsfenster

@Test("Externes Vergleichsfenster: Schließen bricht die Berechnung ab")
@MainActor
func externalDiffCancelsOnClose() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-external-diff-cancel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let left = root.appendingPathComponent("a.txt")
    let right = root.appendingPathComponent("b.txt")
    try "a\n".write(to: left, atomically: true, encoding: .utf8)
    try "b\n".write(to: right, atomically: true, encoding: .utf8)
    let invocation = try #require(try DiffInvocation.parse(["--", left.path, right.path],
                                                           directory: root))
    let compute = BlockingCompute()
    let model = ExternalDiffModel(DiffWireRequest(invocation), compute: compute.run)
    #expect(compute.started.wait(timeout: .now() + 2) == .success)

    model.cancel()

    #expect(compute.cancelled.wait(timeout: .now() + 2) == .success)
    #expect(model.document == nil)
}

// MARK: - Messung: Verzögerung bis zum Abbruch

@Test("Messung: Abbruch mitten im Diff kommt binnen kurzer Zeit zurück")
func cancellationLatencyStaysSmall() async throws {
    // Zwei Seiten ohne gemeinsame Zeilen im Mittelteil: der Myers-Kern
    // arbeitet hier am längsten (viele Tiefenrunden je Rechteck) — genau
    // der Fall, der vorher nicht unterbrechbar war.
    let left = (0..<4_000).map { "links \($0)" }.joined(separator: "\n")
    let right = (0..<4_000).map { "rechts \($0)" }.joined(separator: "\n")

    let clock = ContinuousClock()
    let cancelFlag = ManagedAtomicFlag()
    let finished = DispatchSemaphore(value: 0)
    var outcome: Result<FileDiff.Outcome, Error>?
    var returnedAt: ContinuousClock.Instant?
    let thread = Thread {
        outcome = Result { try FileDiff.compare(left: left, right: right,
                                                isCancelled: cancelFlag.isSet) }
        returnedAt = clock.now
        finished.signal()
    }
    thread.start()
    try await Task.sleep(for: .milliseconds(15))
    let cancelledAt = clock.now
    cancelFlag.set()
    #expect(finished.wait(timeout: .now() + 5) == .success)

    guard case .failure(let error)? = outcome, error is CancellationError else {
        // Lief der Vergleich schon vor dem Abbruch durch, misst dieser Lauf
        // nichts — auf sehr schneller Hardware möglich, aber kein Fehler.
        print("Abbruchmessung: Vergleich war vor dem Abbruch fertig (\(String(describing: outcome)))")
        return
    }
    let latency = cancelledAt.duration(to: try #require(returnedAt))
    print("Abbruchmessung: Verzögerung bis Rückkehr \(latency)")
    // Grobe Obergrenze: Ein Vergleich, der das Signal ignoriert, braucht
    // für diese Eingabe ein Vielfaches davon; echte Werte liegen im
    // Millisekundenbereich (Fremdlast im parallelen Testlauf eingerechnet).
    #expect(latency < .seconds(1), "Abbruch dauerte \(latency)")
}

/// Messung am echten schlechtesten Fall (Budgetgrenze 30.000 Zeilen
/// Unterschiedsbereich): Verzögerung bis Abbruch und Spitzenspeicher.
/// Läuft nur mit `FASTRA_DIFF_MEASURE=1`, weil sie bewusst über eine
/// Sekunde rechnet und über ein Gigabyte belegt — Werte stehen im
/// Testprotokoll (siehe CHANGELOG 1.120.0).
@Test("Messung (manuell): Abbruch und Spitzenspeicher am Budget-Maximum")
func manualWorstCaseMeasurement() async throws {
    guard ProcessInfo.processInfo.environment["FASTRA_DIFF_MEASURE"] == "1" else { return }
    let half = FileDiff.maximumDiffInputLines / 2
    let left = (0..<half).map { "links \($0)" }.joined(separator: "\n")
    let right = (0..<half).map { "rechts \($0)" }.joined(separator: "\n")
    let clock = ContinuousClock()

    // 1. Vollständiger Lauf: Dauer und Spitzenspeicher des Prozesses.
    let footprintBefore = peakFootprint()
    let fullStart = clock.now
    let full = try FileDiff.compare(left: left, right: right, isCancelled: { false })
    let fullDuration = fullStart.duration(to: clock.now)
    guard case .result = full else { Issue.record("Erwartet: Ergebnis"); return }
    let footprintAfterFull = peakFootprint()
    print("Messung: vollständiger Lauf \(fullDuration), Spitzenspeicher vorher \(footprintBefore / 1_048_576) MiB, nachher \(footprintAfterFull / 1_048_576) MiB")
    // Zum Vergleich: Foundation auf denselben Ganzzahlfolgen (nur der Kern,
    // ohne Zeilenzerlegung) — der eigene Kern darf nicht spürbar langsamer sein.
    let oldAliases = Array(0..<half)
    let newAliases = Array(half..<(2 * half))
    let ownStart = clock.now
    _ = MyersDiff.changes(from: oldAliases, to: newAliases, isCancelled: { false })
    let ownDuration = ownStart.duration(to: clock.now)
    let foundationStart = clock.now
    _ = newAliases.difference(from: oldAliases)
    let foundationDuration = foundationStart.duration(to: clock.now)
    print("Messung: nur Kern — eigener \(ownDuration), Foundation \(foundationDuration)")

    // 2. Abbruch zu mehreren Zeitpunkten während des Laufs.
    for fraction in [0.1, 0.5, 0.9] {
        let cancelFlag = ManagedAtomicFlag()
        let finished = DispatchSemaphore(value: 0)
        var returnedAt: ContinuousClock.Instant?
        var cancelledOutcome: Result<FileDiff.Outcome, Error>?
        Thread {
            cancelledOutcome = Result { try FileDiff.compare(left: left, right: right,
                                                             isCancelled: cancelFlag.isSet) }
            returnedAt = clock.now
            finished.signal()
        }.start()
        try await Task.sleep(for: fullDuration * fraction)
        let cancelledAt = clock.now
        cancelFlag.set()
        #expect(finished.wait(timeout: .now() + 30) == .success)
        let latency = cancelledAt.duration(to: try #require(returnedAt))
        let cancelled = if case .failure(let error)? = cancelledOutcome { error is CancellationError } else { false }
        print("Messung: Abbruch bei \(Int(fraction * 100)) % → Rückkehr nach \(latency), abgebrochen=\(cancelled)")
        #expect(cancelled)
        #expect(latency < .seconds(1))
    }
}

/// Höchster physischer Speicherbedarf des Prozesses bisher (Bytes).
private func peakFootprint() -> UInt64 {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return result == 0 ? usage.ri_lifetime_max_phys_footprint : 0
}

/// Threadsicheres Abbruch-Flag für die Messung.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
