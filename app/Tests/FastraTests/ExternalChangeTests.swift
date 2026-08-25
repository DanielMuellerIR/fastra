// ExternalChangeTests.swift
//
// Sichert die Extern-Änderungs-Erkennung ab (BBEdit „Reload from Disk" /
// „Automatically refresh documents", Handbuch 16.0.1 Kap. 3 S. 59):
// Inspector-Entscheidungen (wann werden Bytes gelesen?) + Workspace-Pfad
// (Fingerabdruck beim Laden/Speichern, stiller Reload sauberer Tabs,
// Rückfrage bei dirty Tabs, „Behalten" fragt nicht erneut).

import Foundation
import Testing
@testable import Fastra

// MARK: - Hilfen

private func makeFreshDefaults() -> (UserDefaults, suiteName: String) {
    let suiteName = "fastra-test-extchange-\(UUID().uuidString)"
    return (testSuiteDefaults(named: suiteName), suiteName)
}

private func writeTmpUTF8(_ content: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-extchange-\(UUID().uuidString).txt")
    try content.write(to: url, atomically: true, encoding: .utf8)
    // Kanonische Form — genau die trägt der Tab nach loadFile (siehe
    // WorkspaceLoadTests-Helper), damit `$0.url == url` in /var-Temp matcht.
    return url.canonicalFileURL
}

/// Schreibt neuen Inhalt und setzt das Änderungsdatum EXPLIZIT in die
/// Zukunft — Dateisystem-Zeitauflösung darf den Test nicht flaky machen.
private func simulateExternalEdit(_ url: URL, content: String) throws {
    try content.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(10)],
        ofItemAtPath: url.path)
}

/// Lädt eine Datei in einen frischen Workspace und wartet auf die Completion.
@MainActor
private func loadedWorkspace(_ url: URL) async -> Workspace {
    let (defaults, _) = makeFreshDefaults()
    let ws = Workspace(defaults: defaults)
    var done = false
    ws.loadFile(at: url) { _ in done = true }
    await waitUntil { done }
    return ws
}

/// Wartet, bis der Inhalt des Tabs `idx` der Erwartung entspricht (Reload
/// läuft asynchron über Task.detached).
@MainActor
private func waitForContent(_ ws: Workspace, idx: Int, expected: String) async -> Bool {
    return await waitUntil { ws.tabs[idx].content == expected }
}

/// Blockiert nur den ersten Snapshot-Read. Damit können Tests den Zustand
/// „Prüfung läuft" reproduzieren, ohne den Main-Actor zu blockieren.
private final class BlockingSnapshotReader: @unchecked Sendable {
    private let lock = NSLock()
    private let firstReadGate = DispatchSemaphore(value: 0)
    private var reads = 0

    var readCount: Int {
        lock.withLock { reads }
    }

    func read(_ url: URL) -> FileSnapshot? {
        let isFirst = lock.withLock {
            reads += 1
            return reads == 1
        }
        if isFirst { firstReadGate.wait() }
        return try? FileSnapshot.read(from: url).snapshot
    }

    func releaseFirstRead() {
        firstReadGate.signal()
    }
}

// MARK: - ExternalChangeInspector

@Test("Inspector überspringt den Voll-Read, wenn die Bytezahl schon abweicht")
@MainActor
func externalChangeInspector_skipsUnneededContentRead() async throws {
    let url = try writeTmpUTF8("anderer Umfang\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let reader = BlockingSnapshotReader()
    let inspector = ExternalChangeInspector(snapshotReader: { reader.read($0) })
    let request = ExternalChangeInspector.Request(
        tabID: UUID(), documentID: UUID(), url: url,
        knownObservation: nil,
        observedByteCount: 3,   // bewusst anders als die echte Dateigröße
        isDirty: false
    )
    var result: ExternalChangeInspector.Inspection?
    var deliveredOnMainThread = false

    #expect(inspector.inspect(request) {
        deliveredOnMainThread = Thread.isMainThread
        result = $0
    })
    #expect(await waitUntil { result != nil })
    #expect(reader.readCount == 0,
            "Bei sauberem Tab beweist die andere Bytezahl die Änderung bereits ohne Lesen")
    #expect(result?.stableSnapshot == nil)
    #expect(result?.observation != nil)
    #expect(deliveredOnMainThread)
}

@Test("Inspector liest ohne vollständigen Tab-Snapshot nie die Bytes")
@MainActor
func externalChangeInspector_neverReadsWithoutObservedContent() async throws {
    let url = try writeTmpUTF8("Abschnitt oder Hex\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let reader = BlockingSnapshotReader()
    let inspector = ExternalChangeInspector(snapshotReader: { reader.read($0) })
    let request = ExternalChangeInspector.Request(
        tabID: UUID(), documentID: UUID(), url: url,
        knownObservation: nil,
        observedByteCount: nil,   // Abschnitts-/Hex-Tab ohne Voll-Snapshot
        isDirty: true
    )
    var result: ExternalChangeInspector.Inspection?

    #expect(inspector.inspect(request) { result = $0 })
    #expect(await waitUntil { result != nil })
    #expect(reader.readCount == 0,
            "Abschnitts- und Hex-Tabs dürfen nie vollständig in den Speicher gelesen werden")
    #expect(result?.stableSnapshot == nil)
}

@Test("Inspector liest bei dirty Tab auch eine abweichend große Fremdfassung")
@MainActor
func externalChangeInspector_readsDifferentSizeForDirtyTab() async throws {
    let url = try writeTmpUTF8("deutlich längere Fremdfassung\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let reader = BlockingSnapshotReader()
    reader.releaseFirstRead()
    let inspector = ExternalChangeInspector(snapshotReader: { reader.read($0) })
    let request = ExternalChangeInspector.Request(
        tabID: UUID(), documentID: UUID(), url: url,
        knownObservation: nil,
        observedByteCount: 4,   // Tab kennt nur die alte, kleinere Fassung
        isDirty: true
    )
    var result: ExternalChangeInspector.Inspection?

    #expect(inspector.inspect(request) { result = $0 })
    #expect(await waitUntil { result != nil })
    // Die Rückfrage eines dirty Tabs braucht den Snapshot der Fremdfassung:
    // Nur so merkt sich „Behalten" die akzeptierten Bytes und eine spätere
    // reine Metadatenänderung fragt nicht erneut.
    #expect(reader.readCount == 1)
    #expect(result?.stableSnapshot != nil)
}

@Test("Inspector koppelt Snapshot an das vorher und nachher beobachtete Dateiobjekt")
@MainActor
func externalChangeInspector_rejectsSnapshotFromDifferentFile() async throws {
    let observedURL = try writeTmpUTF8("beobachtet\n")
    let foreignURL = try writeTmpUTF8("fremd      \n")
    defer {
        try? FileManager.default.removeItem(at: observedURL)
        try? FileManager.default.removeItem(at: foreignURL)
    }
    let foreignSnapshot = try FileSnapshot.readSnapshotOnly(from: foreignURL)
    let inspector = ExternalChangeInspector(snapshotReader: { _ in foreignSnapshot })
    let request = ExternalChangeInspector.Request(
        tabID: UUID(), documentID: UUID(), url: observedURL,
        knownObservation: nil,
        observedByteCount: Data("beobachtet\n".utf8).count,
        isDirty: false
    )
    var result: ExternalChangeInspector.Inspection?

    #expect(inspector.inspect(request) { result = $0 })
    #expect(await waitUntil { result != nil })
    #expect(result?.observation != nil)
    #expect(result?.stableSnapshot == nil,
            "Ein Snapshot eines anderen Inodes darf nicht als stabiler Stand gelten")
}

@Test("Inspector startet je Tab höchstens eine parallele Prüfung")
@MainActor
func externalChangeInspector_coalescesConcurrentRequestForTab() async throws {
    let url = try writeTmpUTF8("gleiche Länge\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let reader = BlockingSnapshotReader()
    defer { reader.releaseFirstRead() }
    let inspector = ExternalChangeInspector(snapshotReader: { reader.read($0) })
    let request = ExternalChangeInspector.Request(
        tabID: UUID(), documentID: UUID(), url: url,
        knownObservation: nil,
        observedByteCount: Data("gleiche Länge\n".utf8).count,
        isDirty: false
    )
    var completionCount = 0

    #expect(inspector.inspect(request) { _ in completionCount += 1 })
    #expect(await waitUntil { reader.readCount == 1 })
    #expect(inspector.isInspecting(tabID: request.tabID))
    #expect(!inspector.inspect(request) { _ in completionCount += 1 })

    reader.releaseFirstRead()
    #expect(await waitUntil { completionCount == 1 })
    #expect(!inspector.isInspecting(tabID: request.tabID))
    #expect(reader.readCount == 1)
}

@Test("Veraltete Prüfung eines wiederverwendeten Tabplatzes verändert das neue Dokument nicht")
@MainActor
func workspace_externalInspectionRejectsReusedTabResult() async throws {
    let firstURL = try writeTmpUTF8("eins alt\n")
    let secondURL = try writeTmpUTF8("zwei alt\n")
    defer {
        try? FileManager.default.removeItem(at: firstURL)
        try? FileManager.default.removeItem(at: secondURL)
    }
    let reader = BlockingSnapshotReader()
    defer { reader.releaseFirstRead() }
    let inspector = ExternalChangeInspector(snapshotReader: { reader.read($0) })
    let (defaults, _) = makeFreshDefaults()
    let ws = Workspace(defaults: defaults, externalChangeInspector: inspector)
    var loaded = false
    ws.loadFile(at: firstURL) { _ in loaded = true }
    #expect(await waitUntil { loaded })
    let idx = try #require(ws.tabs.firstIndex { $0.url == firstURL })
    let reusedTabID = ws.tabs[idx].id

    // Die erste Prüfung bleibt im Snapshot-Read stehen. Währenddessen zeigt
    // derselbe Vorschau-Tabplatz bereits ein anderes Dokument.
    try simulateExternalEdit(firstURL, content: "eins neu\n")
    ws.checkExternalChanges()
    #expect(await waitUntil { reader.readCount == 1 })
    let secondData = Data("zwei alt\n".utf8)
    var replacement = EditorTab(
        id: reusedTabID,
        title: secondURL.lastPathComponent,
        path: secondURL.deletingLastPathComponent().path,
        url: secondURL,
        content: "zwei alt\n",
        fileSize: UInt64(secondData.count),
        diskSnapshot: FileSnapshot(data: secondData, at: secondURL)
    )
    replacement.recordExternalFileObservation(
        snapshot: replacement.diskSnapshot,
        observation: ExternalFileObservation(url: secondURL)
    )
    ws.tabs[idx] = replacement
    ws.activeTabID = reusedTabID

    reader.releaseFirstRead()
    try simulateExternalEdit(secondURL, content: "zwei neu\n")
    for _ in 0..<100 where reader.readCount < 2 {
        ws.checkExternalChanges()
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(reader.readCount == 2,
            "Das alte Ergebnis muss verworfen und das neue Dokument getrennt geprüft werden")
    #expect(await waitForContent(ws, idx: idx, expected: "zwei neu\n"))
    #expect(ws.tabs[idx].url == secondURL)
    #expect(ws.tabs[idx].id == reusedTabID)
}

// MARK: - Workspace-Pfad

@Test("loadFile setzt den Platten-Fingerabdruck für die Erkennung")
@MainActor
func workspace_loadSetsBaseline() async throws {
    let url = try writeTmpUTF8("Inhalt\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let tab = ws.tabs.first { $0.url == url }
    #expect(tab?.externalFileObservation != nil)
}

@Test("Extern verschwundene Datei schützt die letzte Tab-Kopie vor stillem Schließen")
@MainActor
func workspace_missingFileProtectsAndRecoversCleanTab() async throws {
    let original = "letzte vorhandene Kopie\n"
    let url = try writeTmpUTF8(original)
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = try #require(ws.tabs.firstIndex { $0.url == url })

    try FileManager.default.removeItem(at: url)
    ws.checkExternalChanges()

    #expect(await waitUntil(timeout: 1) { ws.tabs[idx].isDirty },
            "Ohne erreichbare Plattendatei muss der Tab beim Schließen nachfragen")
    #expect(ws.tabs[idx].content == original)

    // Kehrt exakt derselbe Inhalt zurück, war der Punkt nur ein Schutz gegen
    // Verlust. Er darf wieder verschwinden, solange niemand lokal editiert hat.
    try original.write(to: url, atomically: true, encoding: .utf8)
    ws.checkExternalChanges()
    #expect(await waitUntil { !ws.tabs[idx].isDirty })
    #expect(ws.tabs[idx].content == original)
}

@Test("Lokale Änderung während fehlender Datei bleibt bei Rückkehr geschützt")
@MainActor
func workspace_missingFileRecoveryKeepsLocalEditDirty() async throws {
    let original = "Plattenstand\n"
    let local = "lokal weiterbearbeitet\n"
    let url = try writeTmpUTF8(original)
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = try #require(ws.tabs.firstIndex { $0.url == url })

    try FileManager.default.removeItem(at: url)
    ws.checkExternalChanges()
    #expect(await waitUntil { ws.tabs[idx].isDirty })

    ws.tabs[idx].content = local
    ws.tabs[idx].isDirty = true
    try original.write(to: url, atomically: true, encoding: .utf8)
    ws.checkExternalChanges()
    #expect(await waitUntil { ws.tabs[idx].externalFileObservation != nil })

    #expect(ws.tabs[idx].content == local)
    #expect(ws.tabs[idx].isDirty,
            "Nur der unveränderte gespeicherte Inhalt darf den Schutzpunkt entfernen")
}

@Test("Extern geändert + Tab sauber → stiller Reload mit neuem Inhalt")
@MainActor
func workspace_cleanTabReloadsSilently() async throws {
    let url = try writeTmpUTF8("alt\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    var asked = false
    ws.externalReloadConfirmHandler = { _ in asked = true; return false }

    try simulateExternalEdit(url, content: "neu\n")
    ws.checkExternalChanges()

    let idx = ws.tabs.firstIndex { $0.url == url }!
    #expect(await waitForContent(ws, idx: idx, expected: "neu\n"))
    #expect(asked == false, "sauberer Tab darf ohne Rückfrage neu laden")
    #expect(ws.tabs[idx].isDirty == false)
}

@Test("Extern ersetzte Datei wird auch bei unverändertem Änderungsdatum erkannt")
@MainActor
func workspace_replacedFileWithPreservedDateReloadsSilently() async throws {
    let url = try writeTmpUTF8("alt\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = try #require(ws.tabs.firstIndex { $0.url == url })
    let originalDate = try #require(
        (try FileManager.default.attributesOfItem(atPath: url.path))[.modificationDate] as? Date
    )

    try Data("neu\n".utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.modificationDate: originalDate],
        ofItemAtPath: url.path
    )
    ws.checkExternalChanges()

    #expect(await waitForContent(ws, idx: idx, expected: "neu\n"))
    #expect(ws.tabs[idx].isDirty == false)
}

@Test("Extern geändert + Tab dirty + Behalten → Inhalt bleibt, keine zweite Frage")
@MainActor
func workspace_dirtyKeepDoesNotReAsk() async throws {
    let url = try writeTmpUTF8("alt\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = ws.tabs.firstIndex { $0.url == url }!
    ws.tabs[idx].content = "lokal geändert\n"
    ws.tabs[idx].isDirty = true

    var askCount = 0
    ws.externalReloadConfirmHandler = { _ in askCount += 1; return false }

    try simulateExternalEdit(url, content: "extern\n")
    ws.checkExternalChanges()
    #expect(await waitUntil { askCount == 1 })
    #expect(ws.tabs[idx].content == "lokal geändert\n")

    // Zweiter App-Wechsel, Datei unverändert → Basis-Datum wurde beim
    // „Behalten" nachgezogen, es darf NICHT erneut fragen.
    ws.checkExternalChanges()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(askCount == 1)
}

@Test("„Behalten“ bei anderer Dateigröße: reine Metadatenänderung fragt nicht erneut")
@MainActor
func workspace_dirtyKeepWithDifferentSizeSurvivesMetadataChange() async throws {
    let url = try writeTmpUTF8("alt\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = ws.tabs.firstIndex { $0.url == url }!
    ws.tabs[idx].content = "lokal geändert\n"
    ws.tabs[idx].isDirty = true

    var askCount = 0
    ws.externalReloadConfirmHandler = { _ in askCount += 1; return false }

    // Die Fremdfassung ist DEUTLICH größer — die frühere Abkürzung „andere
    // Bytezahl → Bytes nie lesen" ließ „Behalten" dann ohne Snapshot der
    // akzeptierten Fassung zurück, und jede spätere Metadatenänderung
    // erzeugte einen neuen falschen Dialog.
    try simulateExternalEdit(url, content: "extern deutlich länger als vorher\n")
    ws.checkExternalChanges()
    #expect(await waitUntil { askCount == 1 })
    #expect(ws.tabs[idx].externalContentSnapshot != nil,
            "„Behalten“ muss die akzeptierte Fremdfassung als Snapshot besitzen")

    // Nur das Änderungsdatum bewegt sich, die Bytes bleiben die akzeptierten.
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(20)],
        ofItemAtPath: url.path)
    ws.checkExternalChanges()
    try? await Task.sleep(for: .milliseconds(200))
    #expect(askCount == 1, "bereits akzeptierte Bytes dürfen nicht erneut warnen")
    #expect(ws.tabs[idx].content == "lokal geändert\n")
}

@Test("Wird der Tab während der laufenden Prüfung dirty, prüft der Workspace neu statt mit alter Lese-Entscheidung zu antworten")
@MainActor
func workspace_dirtyDriftDuringInspectionTriggersFreshCheck() async throws {
    let url = try writeTmpUTF8("alt\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = ws.tabs.firstIndex { $0.url == url }!

    var askCount = 0
    ws.externalReloadConfirmHandler = { _ in askCount += 1; return false }

    // Fremdfassung mit ANDERER Größe: Eine sauber gestartete Prüfung liest
    // dann bewusst keine Bytes. Der Tab wird noch im selben Main-Durchlauf
    // dirty — die Completion der laufenden Prüfung darf ihre alte
    // Lese-Entscheidung („kein Snapshot nötig") jetzt nicht mehr anwenden,
    // sonst speichert „Behalten" keinen Snapshot der akzeptierten Fassung
    // und jede spätere Metadatenänderung fragt fälschlich erneut.
    try simulateExternalEdit(url, content: "extern deutlich länger als vorher\n")
    ws.checkExternalChanges()
    ws.tabs[idx].content = "lokal geändert\n"
    ws.tabs[idx].isDirty = true

    #expect(await waitUntil { askCount == 1 })
    #expect(ws.tabs[idx].content == "lokal geändert\n")
    #expect(await waitUntil { ws.tabs[idx].externalContentSnapshot != nil },
            "die Nachprüfung mit aktuellem Dirty-Zustand muss die Fremdfassung als Snapshot liefern")

    // Nur das Änderungsdatum bewegt sich — die bereits beantwortete
    // Fremdfassung darf nicht erneut warnen.
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(20)],
        ofItemAtPath: url.path)
    ws.checkExternalChanges()
    try? await Task.sleep(for: .milliseconds(200))
    #expect(askCount == 1)
}

@Test("Veraltete Prüfung trifft keinen inzwischen umgebundenen Tab (Sichern unter/Verschieben)")
@MainActor
func workspace_staleInspectionDoesNotHitReboundTab() async throws {
    let firstURL = try writeTmpUTF8("eins alt\n")
    let secondURL = try writeTmpUTF8("zwei bleibt\n")
    defer {
        try? FileManager.default.removeItem(at: firstURL)
        try? FileManager.default.removeItem(at: secondURL)
    }
    let reader = BlockingSnapshotReader()
    defer { reader.releaseFirstRead() }
    let inspector = ExternalChangeInspector(snapshotReader: { reader.read($0) })
    let (defaults, _) = makeFreshDefaults()
    let ws = Workspace(defaults: defaults, externalChangeInspector: inspector)
    var loaded = false
    ws.loadFile(at: firstURL) { _ in loaded = true }
    #expect(await waitUntil { loaded })
    let idx = try #require(ws.tabs.firstIndex { $0.url == firstURL })
    var askCount = 0
    ws.externalReloadConfirmHandler = { _ in askCount += 1; return true }

    // Gleiche Größe erzwingt den (blockierten) Byte-Vergleich — die Prüfung
    // für den ALTEN Pfad hängt jetzt in der Luft.
    try simulateExternalEdit(firstURL, content: "eins neu\n")
    ws.checkExternalChanges()
    #expect(await waitUntil { reader.readCount == 1 })

    // Der Tab wird bei unveränderter Dokument-Identität an einen neuen Pfad
    // gebunden (wie nach „Sichern unter" oder Verschieben im Dateibaum).
    ws.tabs[idx].url = secondURL
    ws.tabs[idx].title = secondURL.lastPathComponent
    ws.tabs[idx].recordExternalFileObservation(
        snapshot: ws.tabs[idx].diskSnapshot,
        observation: ExternalFileObservation(url: secondURL)
    )

    reader.releaseFirstRead()
    try? await Task.sleep(for: .milliseconds(200))

    // Der Befund zum alten Pfad darf am neuen Ziel weder fragen noch laden.
    #expect(askCount == 0)
    #expect(ws.tabs[idx].content == "eins alt\n")
    #expect(ws.tabs[idx].url == secondURL)
}

@Test("reloadTabFromDisk übernimmt nichts in einen während des Ladens umgebundenen Tab")
@MainActor
func workspace_reloadDropsResultAfterURLChange() async throws {
    let url = try writeTmpUTF8("alt\n")
    let otherURL = try writeTmpUTF8("anderes Ziel\n")
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: otherURL)
    }
    let ws = await loadedWorkspace(url)
    let idx = try #require(ws.tabs.firstIndex { $0.url == url })
    try Data("neu von Platte\n".utf8).write(to: url, options: .atomic)
    let delayedResult = try FileLoader.load(url: url)
    let gate = DispatchSemaphore(value: 0)
    ws.reloadFileLoader = { _ in gate.wait(); return delayedResult }

    ws.reloadTabFromDisk(id: ws.tabs[idx].id)
    // Während des Ladens wechselt der Tab seinen Pfad (Sichern unter /
    // Verschieben) — der Inhalt des alten Pfads gehört nicht mehr hierher.
    ws.tabs[idx].url = otherURL
    gate.signal()
    for _ in 0..<100 where ws.tabs[idx].isLoading {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(ws.tabs[idx].content == "alt\n")
    #expect(!ws.tabs[idx].isLoading)
}

@Test("Extern geändert + Tab dirty + Neu-laden → Disk-Inhalt gewinnt")
@MainActor
func workspace_dirtyReloadDiscardsLocal() async throws {
    let url = try writeTmpUTF8("alt\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = ws.tabs.firstIndex { $0.url == url }!
    ws.tabs[idx].content = "lokal geändert\n"
    ws.tabs[idx].isDirty = true
    ws.externalReloadConfirmHandler = { _ in true }

    try simulateExternalEdit(url, content: "extern\n")
    ws.checkExternalChanges()
    #expect(await waitForContent(ws, idx: idx, expected: "extern\n"))
    #expect(ws.tabs[idx].isDirty == false)
}

@Test("Eigenes Speichern zieht das Basis-Datum nach → kein Fehlalarm")
@MainActor
func workspace_ownSaveIsNoExternalChange() async throws {
    let url = try writeTmpUTF8("alt\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = ws.tabs.firstIndex { $0.url == url }!
    ws.activeTabID = ws.tabs[idx].id
    ws.tabs[idx].content = "gespeichert\n"
    ws.tabs[idx].isDirty = true

    var asked = false
    ws.externalReloadConfirmHandler = { _ in asked = true; return true }

    ws.saveActiveTab()   // schreibt direkt (Tab hat URL) und zieht das Datum nach
    ws.checkExternalChanges()
    // Kurz warten: ein fälschlicher Reload wäre asynchron. Feste Pause mit
    // echtem Schlafen — eine Yield-Schleife würde den Main-Actor belegen.
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(asked == false)
    #expect(ws.tabs[idx].content == "gespeichert\n")
}

@Test("reloadActiveTabFromDisk bei unbenanntem Tab tut nichts (kein Crash)")
@MainActor
func workspace_reloadUntitledBeeps() async {
    let (defaults, _) = makeFreshDefaults()
    let ws = Workspace(defaults: defaults)
    ws.tabs = [EditorTab(title: "untitled-1.txt", path: "—", content: "x")]
    ws.activeTabID = ws.tabs[0].id
    ws.reloadActiveTabFromDisk()
    #expect(ws.tabs[0].content == "x")
}

@Test("Speichern erkennt eine externe Änderung unmittelbar vor dem Write")
@MainActor
func workspace_saveConflictPreservesDiskAndDirtyTab() async throws {
    let url = try writeTmpUTF8("geladen\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = try #require(ws.tabs.firstIndex { $0.url == url })
    ws.activeTabID = ws.tabs[idx].id
    ws.tabs[idx].content = "lokal\n"
    ws.tabs[idx].isDirty = true

    let external = Data("extern\n".utf8)
    try external.write(to: url, options: .atomic)
    var asked = false
    ws.saveConflictConfirmHandler = { _ in asked = true; return false }
    ws.saveActiveTab()

    #expect(asked)
    #expect(try Data(contentsOf: url) == external)
    #expect(ws.tabs[idx].content == "lokal\n")
    #expect(ws.tabs[idx].isDirty)
}

@Test("Bewusst bestätigter Save-Konflikt schreibt und aktualisiert die Basis")
@MainActor
func workspace_confirmedSaveConflictUpdatesSnapshot() async throws {
    let url = try writeTmpUTF8("geladen\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = try #require(ws.tabs.firstIndex { $0.url == url })
    ws.activeTabID = ws.tabs[idx].id
    ws.tabs[idx].content = "lokal bestätigt\n"
    ws.tabs[idx].isDirty = true
    try Data("extern\n".utf8).write(to: url, options: .atomic)
    ws.saveConflictConfirmHandler = { _ in true }

    ws.saveActiveTab()

    #expect(try Data(contentsOf: url) == Data("lokal bestätigt\n".utf8))
    #expect(!ws.tabs[idx].isDirty)
    #expect(ws.tabs[idx].diskSnapshot == FileSnapshot(data: Data("lokal bestätigt\n".utf8),
                                                      at: url))
}

@Test("Folder-Apply blockiert einen betroffenen Dirty Tab vor jedem Write")
@MainActor
func workspace_folderApplyBlocksDirtyTab() throws {
    let url = try writeTmpUTF8("foo auf Platte\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let (defaults, _) = makeFreshDefaults()
    let ws = Workspace(defaults: defaults)
    let options = SearchOptions(find: "foo", replace: "bar", isRegex: false,
                                caseSensitive: true)
    let result = FolderSearch.searchOneFile(at: url, options: options)
    ws.scope = .folder
    ws.findPattern = "foo"
    ws.replacePattern = "bar"
    ws.useRegex = false
    ws.caseSensitive = true
    ws.tabs = [EditorTab(title: url.lastPathComponent,
                         path: url.deletingLastPathComponent().path,
                         url: url, content: "lokal ungespeichert\n",
                         isDirty: true,
                         diskSnapshot: FileSnapshot(data: Data("foo auf Platte\n".utf8), at: url))]
    ws.activeTabID = ws.tabs[0].id
    // Tabs sind selbst Suchinputs. Deshalb setzt die Fixture das bereits
    // abgeschlossene Suchergebnis erst nach dem vorbereiteten Dirty-Tab ein.
    ws.folderResults = [result]
    ws.folderSearching = false
    ws.folderNeedsSearch = false
    let backupRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-workspace-undo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: backupRoot) }
    ws.folderApplyBackupRoot = backupRoot
    var blockedTitles: [String] = []
    ws.folderApplyConflictHandler = { blockedTitles = $0 }

    #expect(!ws.applyAllInFolder())
    #expect(blockedTitles == [url.lastPathComponent])
    #expect(try Data(contentsOf: url) == Data("foo auf Platte\n".utf8))
    #expect(ws.tabs[0].content == "lokal ungespeichert\n")
    #expect(ws.tabs[0].isDirty)
}

@Test("Folder-Apply verwirft eine nach der sichtbaren Suche geänderte Datei")
@MainActor
func workspace_folderApplyRejectsStaleVisibleResult() async throws {
    let url = try writeTmpUTF8("foo sichtbar\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let (defaults, _) = makeFreshDefaults()
    let ws = Workspace(defaults: defaults)
    let options = SearchOptions(find: "foo", replace: "bar", isRegex: false,
                                caseSensitive: true)
    ws.scope = .folder
    ws.findPattern = "foo"
    ws.replacePattern = "bar"
    ws.useRegex = false
    ws.caseSensitive = true
    ws.folderResults = [FolderSearch.searchOneFile(at: url, options: options)]
    // Die Fixture setzt ein bereits abgeschlossenes Suchergebnis direkt ein.
    ws.folderSearching = false
    ws.folderNeedsSearch = false
    let backups = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-visible-undo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: backups) }
    ws.folderApplyBackupRoot = backups
    var warning = ""
    ws.folderPreviewConflictHandler = { warning = $0 }

    let external = Data("foo extern\n".utf8)
    try external.write(to: url, options: .atomic)

    #expect(ws.applyAllInFolder())
    for _ in 0..<100 where ws.folderApplying {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!ws.folderApplying)
    #expect(!warning.isEmpty)
    #expect(try Data(contentsOf: url) == external)
    #expect((try FileManager.default.contentsOfDirectory(atPath: backups.path)).isEmpty)
}

@Test("Folder-Apply läuft asynchron und übernimmt die sichtbare Vorschau")
@MainActor
func workspace_folderApplyRunsAsynchronously() async throws {
    let url = try writeTmpUTF8("foo sichtbar\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let (defaults, _) = makeFreshDefaults()
    let ws = Workspace(defaults: defaults)
    let options = SearchOptions(find: "foo", replace: "bar", isRegex: false,
                                caseSensitive: true)
    ws.scope = .folder
    ws.findPattern = "foo"
    ws.replacePattern = "bar"
    ws.useRegex = false
    ws.caseSensitive = true
    ws.folderResults = [FolderSearch.searchOneFile(at: url, options: options)]
    // Die Fixture setzt ein bereits abgeschlossenes Suchergebnis direkt ein.
    ws.folderSearching = false
    ws.folderNeedsSearch = false
    let backups = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-async-undo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: backups) }
    ws.folderApplyBackupRoot = backups

    #expect(ws.applyAllInFolder())
    for _ in 0..<200 where ws.folderApplying {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(!ws.folderApplying)
    #expect(try Data(contentsOf: url) == Data("bar sichtbar\n".utf8))
    #expect(ws.lastApplySession?.entries.map(\.state) == [.applied])
}

// Befund 2026-08-06: Seit die Suchauslöser nach Bereich getrennt sind, löst
// eine Tab-Änderung im Ordner-Bereich keine neue Suche mehr aus — richtig für
// den Trefferklick, aber Fastras EIGENE Schreibvorgänge (Ordner-Apply und
// dessen Rückgängig) machten die sichtbare Trefferbasis damit still veraltet.
// Trefferzahl und Sprungziele zeigten auf Text, den es so nicht mehr gibt.

@Test("Rückgängig verwirft die sichtbare Ordner-Trefferbasis")
@MainActor
func workspace_folderUndoInvalidatesVisibleResults() async throws {
    let url = try writeTmpUTF8("foo sichtbar\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let (defaults, _) = makeFreshDefaults()
    let ws = Workspace(defaults: defaults)
    let options = SearchOptions(find: "foo", replace: "bar", isRegex: false,
                                caseSensitive: true)
    ws.scope = .folder
    ws.findPattern = "foo"
    ws.replacePattern = "bar"
    ws.useRegex = false
    ws.caseSensitive = true
    ws.folderResults = [FolderSearch.searchOneFile(at: url, options: options)]
    ws.folderSearching = false
    ws.folderNeedsSearch = false
    let backups = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-undo-stale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: backups) }
    ws.folderApplyBackupRoot = backups

    #expect(ws.applyAllInFolder())
    for _ in 0..<200 where ws.folderApplying {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try Data(contentsOf: url) == Data("bar sichtbar\n".utf8))

    // Trefferbasis wiederherstellen, wie sie eine erneute Ordnersuche liefern
    // würde. Bewusst OHNE die veröffentlichten Sucheingaben anzufassen: Sonst
    // liefe der 120-ms-Debounce des Suchläufers mit und die Beobachtung unten
    // wäre nicht mehr eindeutig dem Rückgängig zuzuordnen.
    let afterApply = SearchOptions(find: "bar", replace: "baz", isRegex: false,
                                   caseSensitive: true)
    let visible = FolderSearch.searchOneFile(at: url, options: afterApply)
    ws.folderResults = [visible]
    ws.folderTotalMatches = visible.totalMatches
    ws.folderSearching = false
    ws.folderNeedsSearch = false
    #expect(!visible.matches.isEmpty)

    #expect(ws.undoLastFolderApply())

    #expect(try Data(contentsOf: url) == Data("foo sichtbar\n".utf8))
    #expect(ws.folderResults.isEmpty,
            "Rückgängig hat die Datei erneut geschrieben — die sichtbaren Treffer gelten nicht mehr")
    #expect(ws.folderTotalMatches == 0)
    #expect(ws.folderNeedsSearch, "Die Maske muss einen neuen Such-Lauf verlangen")
    #expect(!ws.folderSearching)
}

@Test("Gelöschtes Save-Ziel gilt als Konflikt und wird nicht still neu angelegt")
@MainActor
func workspace_saveDeletedDocumentRequiresConfirmation() async throws {
    let url = try writeTmpUTF8("geladen\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = try #require(ws.tabs.firstIndex { $0.url == url })
    ws.activeTabID = ws.tabs[idx].id
    ws.tabs[idx].content = "lokal\n"
    ws.tabs[idx].isDirty = true
    try FileManager.default.removeItem(at: url)
    var asked = false
    ws.saveConflictConfirmHandler = { _ in asked = true; return false }

    ws.saveActiveTab()

    #expect(asked)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(ws.tabs[idx].isDirty)
}

@Test("Save-As überschreibt kein Ziel, das nach dem Abwesenheitscheck entsteht")
@MainActor
func workspace_saveAsTargetAppearingBeforeCoordinateIsPreserved() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-save-as-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("new.txt")
    let (defaults, _) = makeFreshDefaults()
    let ws = Workspace(defaults: defaults)
    ws.tabs = [EditorTab(title: "new.txt", path: directory.path,
                         content: "lokal\n", isDirty: true)]
    ws.activeTabID = ws.tabs[0].id
    ws.saveSafetyWarningHandler = { _, _ in }
    let external = Data("extern entstanden\n".utf8)
    ws.saveBeforeCoordinateHandler = { _ in try? external.write(to: target) }

    #expect(!ws.write(tab: ws.tabs[0], to: target))
    #expect(try Data(contentsOf: target) == external)
    #expect(ws.tabs[0].isDirty)
}

@Test("Fremd-Replace nach dem letzten Save-Preflight bleibt erhalten")
@MainActor
func workspace_saveForeignReplaceAfterFinalPreflightIsPreserved() async throws {
    let url = try writeTmpUTF8("geladen\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let index = try #require(ws.tabs.firstIndex { $0.url == url })
    ws.tabs[index].content = "lokal\n"
    ws.tabs[index].isDirty = true
    ws.saveSafetyWarningHandler = { _, _ in }
    let external = Data("extern im Commit-Fenster\n".utf8)
    var hookCalls = 0
    ws.saveBeforeAtomicReplaceHandler = { coordinatedURL in
        hookCalls += 1
        try? external.write(to: coordinatedURL, options: .atomic)
    }

    #expect(!ws.write(tab: ws.tabs[index], to: url))
    #expect(hookCalls == 1)
    #expect(try Data(contentsOf: url) == external)
    #expect(ws.tabs[index].content == "lokal\n")
    #expect(ws.tabs[index].isDirty)
    let siblings = try FileManager.default.contentsOfDirectory(
        at: url.deletingLastPathComponent(),
        includingPropertiesForKeys: nil)
    #expect(!siblings.contains { $0.lastPathComponent.hasPrefix(".fastra-save-") })
}

@Test("Save-As ersetzt kein Ziel, das erst nach der Panel-Validierung entsteht")
@MainActor
func workspace_saveAsTargetAppearingAfterPanelValidationIsPreserved() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-save-panel-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("new.txt")
    let (defaults, _) = makeFreshDefaults()
    let ws = Workspace(defaults: defaults)
    ws.tabs = [EditorTab(title: "new.txt", path: directory.path,
                         content: "lokal\n", isDirty: true)]
    ws.activeTabID = ws.tabs[0].id
    ws.saveSafetyWarningHandler = { _, _ in }
    let external = Data("nach Panel entstanden\n".utf8)
    try external.write(to: target)

    #expect(!ws.write(tab: ws.tabs[0], to: target,
                      expectedTargetState: .absent))
    #expect(try Data(contentsOf: target) == external)
    #expect(ws.tabs[0].isDirty)
}

@Test("Tab-Änderung im modalen Save-Konflikt schreibt keine alte Kopie und bleibt dirty")
@MainActor
func workspace_saveConflictModalContentChangeIsPreserved() async throws {
    let url = try writeTmpUTF8("geladen\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = try #require(ws.tabs.firstIndex { $0.url == url })
    ws.activeTabID = ws.tabs[idx].id
    ws.tabs[idx].content = "vor Rückfrage\n"
    ws.tabs[idx].isDirty = true
    let external = Data("extern\n".utf8)
    try external.write(to: url, options: .atomic)
    ws.saveSafetyWarningHandler = { _, _ in }
    ws.saveConflictConfirmHandler = { _ in
        ws.tabs[idx].content = "während Rückfrage neuer\n"
        ws.tabs[idx].isDirty = true
        return true
    }

    ws.saveActiveTab()

    #expect(try Data(contentsOf: url) == external)
    #expect(ws.tabs[idx].content == "während Rückfrage neuer\n")
    #expect(ws.tabs[idx].isDirty)
}

@Test("Reload-Completion überschreibt keine neuere Tab-Generation")
@MainActor
func workspace_reloadGenerationProtectsNewerContent() async throws {
    let url = try writeTmpUTF8("alt\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = try #require(ws.tabs.firstIndex { $0.url == url })
    let newerDisk = Data("vom Apply\n".utf8)
    try newerDisk.write(to: url, options: .atomic)
    let delayedResult = try FileLoader.load(url: url)
    let gate = DispatchSemaphore(value: 0)
    ws.reloadFileLoader = { _ in
        gate.wait()
        return delayedResult
    }

    ws.reloadOpenTabs(for: [url])
    #expect(ws.tabs[idx].isLoading)
    ws.tabs[idx].content = "neuere Editoränderung\n"
    ws.tabs[idx].isDirty = false
    gate.signal()
    for _ in 0..<100 where ws.tabs[idx].isLoading {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(ws.tabs[idx].content == "neuere Editoränderung\n")
    #expect(!ws.tabs[idx].isLoading)
}

@Test("Reload merkt die Observation desselben Dateiobjekts wie Inhalt und Snapshot")
@MainActor
func workspace_reloadObservationCannotSkipLaterAtomicReplacement() async throws {
    let url = try writeTmpUTF8("ursprünglich\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = try #require(ws.tabs.firstIndex { $0.url == url })

    let firstReloadText = "erster Fremdstand\n"
    try firstReloadText.write(to: url, atomically: true, encoding: .utf8)
    let delayedResult = try FileLoader.load(url: url)
    let gate = DispatchSemaphore(value: 0)
    ws.reloadFileLoader = { _ in
        gate.wait()
        return delayedResult
    }

    ws.reloadTabFromDisk(id: ws.tabs[idx].id)
    let finalText = "später atomar ersetzter Fremdstand\n"
    try finalText.write(to: url, atomically: true, encoding: .utf8)
    gate.signal()
    #expect(await waitForContent(ws, idx: idx, expected: firstReloadText))

    // Der nächste Check muss den Austausch sehen. Würde die Completion die
    // Observation erneut am Pfad öffnen, hätte sie hier schon den finalen
    // Inode neben den alten Inhalt/Snapshot gelegt und der Check bliebe still.
    ws.reloadFileLoader = { try FileLoader.load(url: $0) }
    ws.checkExternalChanges()
    #expect(await waitForContent(ws, idx: idx, expected: finalText))
    #expect(!ws.tabs[idx].isDirty)
}

@Test("Manuelles Reload überschreibt keine neuere Tab-Generation")
@MainActor
func workspace_manualReloadGenerationProtectsNewerContent() async throws {
    let url = try writeTmpUTF8("alt\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = try #require(ws.tabs.firstIndex { $0.url == url })
    try Data("neu von Platte\n".utf8).write(to: url, options: .atomic)
    let delayedResult = try FileLoader.load(url: url)
    let gate = DispatchSemaphore(value: 0)
    ws.reloadFileLoader = { _ in gate.wait(); return delayedResult }

    ws.reloadTabFromDisk(id: ws.tabs[idx].id)
    ws.tabs[idx].content = "neu im Editor\n"
    ws.tabs[idx].isDirty = true
    gate.signal()
    for _ in 0..<100 where ws.tabs[idx].isLoading {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(ws.tabs[idx].content == "neu im Editor\n")
    #expect(ws.tabs[idx].isDirty)
    #expect(!ws.tabs[idx].isLoading)
}

@Test("Neu öffnen mit Encoding überschreibt keine neuere Tab-Generation")
@MainActor
func workspace_reopenEncodingGenerationProtectsNewerContent() async throws {
    let url = try writeTmpUTF8("alt\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = try #require(ws.tabs.firstIndex { $0.url == url })
    let delayedResult = try FileLoader.load(url: url, forcedEncoding: .utf8)
    let gate = DispatchSemaphore(value: 0)
    ws.reopenFileLoader = { _, _ in gate.wait(); return delayedResult }

    ws.reopenActiveTab(withEncoding: .utf8)
    ws.tabs[idx].content = "neu im Editor\n"
    ws.tabs[idx].isDirty = true
    gate.signal()
    for _ in 0..<100 where ws.tabs[idx].isLoading {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(ws.tabs[idx].content == "neu im Editor\n")
    #expect(ws.tabs[idx].isDirty)
    #expect(!ws.tabs[idx].isLoading)
}

// MARK: - Reload setzt auch die gespeicherte Vergleichsbasis

// Befund 2026-08-02: Der Reload offener Tabs (etwa nach einem Ordner-Apply)
// ersetzte Inhalt und Platten-Abbild und setzte `isDirty = false`, ließ aber
// im Gegensatz zu jedem anderen Lade- und Speicherpfad die alte Vergleichs-
// basis stehen. Ein Rückgängig auf den Inhalt VOR dem Apply traf damit genau
// diese alte Basis: Der Tab galt als sauber, obwohl er von der Platte abwich,
// und ⌘W hätte ihn ohne Nachfrage geschlossen.

@Test("Nach dem Reload gilt der frische Inhalt als gespeicherter Stand")
@MainActor
func workspace_reloadRecordsSavedContentBaseline() async throws {
    let url = try writeTmpUTF8("vor dem Apply\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let idx = try #require(ws.tabs.firstIndex { $0.url == url })
    ws.activeTabID = ws.tabs[idx].id

    try Data("nach dem Apply\n".utf8).write(to: url, options: .atomic)
    ws.reloadOpenTabs(for: [url])
    #expect(await waitForContent(ws, idx: idx, expected: "nach dem Apply\n"))
    #expect(!ws.tabs[idx].isDirty)

    // Rückgängig bis vor den Apply: Der Tab weicht jetzt von der Platte ab und
    // muss das auch zeigen.
    ws.activeTabContent.wrappedValue = "vor dem Apply\n"
    #expect(ws.tabs[idx].isDirty,
            "Der Inhalt von vor dem Apply ist NICHT der gespeicherte Stand")

    // Und der frisch geladene Stand gilt weiterhin als sauber.
    ws.activeTabContent.wrappedValue = "nach dem Apply\n"
    #expect(!ws.tabs[idx].isDirty)
}
