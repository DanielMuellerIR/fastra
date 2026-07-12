// ExternalChangeTests.swift
//
// Sichert die Extern-Änderungs-Erkennung ab (BBEdit „Reload from Disk" /
// „Automatically refresh documents", Handbuch 16.0.1 Kap. 3 S. 59):
// pure Entscheidungs-Logik (ExternalChange.action) + Workspace-Pfad
// (Basis-Datum beim Laden/Speichern, stiller Reload sauberer Tabs,
// Rückfrage bei dirty Tabs, „Behalten" fragt nicht erneut).

import Foundation
import Testing
@testable import Fastra

// MARK: - Hilfen

private func makeFreshDefaults() -> (UserDefaults, suiteName: String) {
    let suiteName = "fastra-test-extchange-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
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
    let deadline = Date().addingTimeInterval(5)
    while !done, Date() < deadline { await Task.yield() }
    return ws
}

/// Wartet, bis der Inhalt des Tabs `idx` der Erwartung entspricht (Reload
/// läuft asynchron über Task.detached).
@MainActor
private func waitForContent(_ ws: Workspace, idx: Int, expected: String) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while ws.tabs[idx].content != expected, Date() < deadline { await Task.yield() }
    return ws.tabs[idx].content == expected
}

// MARK: - Pure Entscheidungs-Logik

@Test("Kein Vergleichs- oder Disk-Datum → keine Aktion")
func action_missingDates() {
    #expect(ExternalChange.action(isDirty: false, knownDate: nil, diskDate: Date()) == .none)
    #expect(ExternalChange.action(isDirty: false, knownDate: Date(), diskDate: nil) == .none)
}

@Test("Disk gleich alt oder älter → keine Aktion")
func action_diskNotNewer() {
    let d = Date()
    #expect(ExternalChange.action(isDirty: false, knownDate: d, diskDate: d) == .none)
    #expect(ExternalChange.action(isDirty: false, knownDate: d,
                                  diskDate: d.addingTimeInterval(-5)) == .none)
}

@Test("Disk neuer + Tab sauber → still neu laden")
func action_newerClean() {
    let d = Date()
    #expect(ExternalChange.action(isDirty: false, knownDate: d,
                                  diskDate: d.addingTimeInterval(5)) == .reloadSilently)
}

@Test("Disk neuer + Tab dirty → Nutzer fragen")
func action_newerDirty() {
    let d = Date()
    #expect(ExternalChange.action(isDirty: true, knownDate: d,
                                  diskDate: d.addingTimeInterval(5)) == .askUser)
}

// MARK: - Workspace-Pfad

@Test("loadFile setzt das Basis-Datum für die Erkennung")
@MainActor
func workspace_loadSetsBaseline() async throws {
    let url = try writeTmpUTF8("Inhalt\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let ws = await loadedWorkspace(url)
    let tab = ws.tabs.first { $0.url == url }
    #expect(tab?.diskModificationDate != nil)
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
    #expect(askCount == 1)
    #expect(ws.tabs[idx].content == "lokal geändert\n")

    // Zweiter App-Wechsel, Datei unverändert → Basis-Datum wurde beim
    // „Behalten" nachgezogen, es darf NICHT erneut fragen.
    ws.checkExternalChanges()
    #expect(askCount == 1)
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
    // Kurz warten: ein fälschlicher Reload wäre asynchron.
    let deadline = Date().addingTimeInterval(0.3)
    while Date() < deadline { await Task.yield() }
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