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
    ws.folderResults = [result]
    ws.tabs = [EditorTab(title: url.lastPathComponent,
                         path: url.deletingLastPathComponent().path,
                         url: url, content: "lokal ungespeichert\n",
                         isDirty: true,
                         diskSnapshot: FileSnapshot(data: Data("foo auf Platte\n".utf8), at: url))]
    ws.activeTabID = ws.tabs[0].id
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
