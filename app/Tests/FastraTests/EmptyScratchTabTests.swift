// EmptyScratchTabTests.swift
//
// Sichert das BBEdit-Verhalten ab (Daniel-Befund 2026-06-22): Öffnet man eine
// Datei, während das leere unbenannte Start-Dokument offen ist, wird dieses
// abgeräumt — getippter/„dirty" Inhalt bleibt dagegen IMMER erhalten.
//
// Zwei Ebenen: die pure Filter-Logik `tabsRemovingEmptyScratch` (deckt alle
// Fall-Unterscheidungen ab) und ein Integrationstest über `loadFile` (belegt,
// dass der leere Tab nach echtem Datei-Laden wirklich verschwindet).

import Foundation
import Testing
@testable import Fastra

// MARK: - Pure Filter-Logik

@Test("Leerer Scratch-Tab (unbenannt, leer, nicht dirty) wird entfernt")
func scratch_emptyUntitledRemoved() {
    let scratch = EditorTab(title: "Ohne Titel", path: "x")           // url nil, content "", !dirty
    let loaded = EditorTab(title: "datei.txt", path: "/tmp",
                           url: URL(fileURLWithPath: "/tmp/datei.txt"), content: "Inhalt")
    let result = Workspace.tabsRemovingEmptyScratch([scratch, loaded], keeping: loaded.id)
    #expect(result.map(\.id) == [loaded.id])
}

@Test("Unbenannter Tab mit getipptem Inhalt bleibt erhalten")
func scratch_nonEmptyUntitledKept() {
    let typed = EditorTab(title: "Ohne Titel", path: "x", content: "schon getippt")
    let loaded = EditorTab(title: "datei.txt", path: "/tmp",
                           url: URL(fileURLWithPath: "/tmp/datei.txt"), content: "Inhalt")
    let result = Workspace.tabsRemovingEmptyScratch([typed, loaded], keeping: loaded.id)
    #expect(result.count == 2)
    #expect(result.contains(where: { $0.id == typed.id }))
}

@Test("Leerer, aber als dirty markierter Tab bleibt erhalten (Rescuing Untitled)")
func scratch_dirtyEmptyKept() {
    let dirty = EditorTab(title: "Ohne Titel", path: "x", content: "", isDirty: true)
    let loaded = EditorTab(title: "datei.txt", path: "/tmp",
                           url: URL(fileURLWithPath: "/tmp/datei.txt"), content: "Inhalt")
    let result = Workspace.tabsRemovingEmptyScratch([dirty, loaded], keeping: loaded.id)
    #expect(result.contains(where: { $0.id == dirty.id }))
}

@Test("Leerer Tab MIT Datei-URL bleibt erhalten (kein Scratch)")
func scratch_emptyWithFileKept() {
    let emptyFile = EditorTab(title: "leer.txt", path: "/tmp",
                              url: URL(fileURLWithPath: "/tmp/leer.txt"), content: "")
    let loaded = EditorTab(title: "datei.txt", path: "/tmp",
                           url: URL(fileURLWithPath: "/tmp/datei.txt"), content: "Inhalt")
    let result = Workspace.tabsRemovingEmptyScratch([emptyFile, loaded], keeping: loaded.id)
    #expect(result.contains(where: { $0.id == emptyFile.id }))
}

@Test("Der zu behaltende Tab wird nie entfernt — auch wenn er selbst leer ist")
func scratch_keepIDAlwaysKept() {
    let keepEmpty = EditorTab(title: "Ohne Titel", path: "x")   // selbst ein leerer Scratch
    let result = Workspace.tabsRemovingEmptyScratch([keepEmpty], keeping: keepEmpty.id)
    #expect(result.map(\.id) == [keepEmpty.id])
}

@Test("Mehrere leere Scratch-Tabs werden alle entfernt, nur keepID bleibt")
func scratch_multipleRemoved() {
    let s1 = EditorTab(title: "Ohne Titel", path: "x")
    let s2 = EditorTab(title: "untitled-2.txt", path: "—")
    let loaded = EditorTab(title: "datei.txt", path: "/tmp",
                           url: URL(fileURLWithPath: "/tmp/datei.txt"), content: "Inhalt")
    let result = Workspace.tabsRemovingEmptyScratch([s1, s2, loaded], keeping: loaded.id)
    #expect(result.map(\.id) == [loaded.id])
}

// MARK: - Integration über loadFile

@Test("loadFile räumt den leeren unbenannten Tab ab, behält den geladenen")
@MainActor
func loadFile_removesEmptyScratchTab() async throws {
    let suiteName = "fastra-test-scratch-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let ws = Workspace(defaults: defaults)
    // Ausgangslage wie ein normaler Folge-Start: genau ein leerer „Ohne Titel".
    let scratch = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert")
    ws.tabs = [scratch]
    ws.activeTabID = scratch.id

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-scratch-\(UUID().uuidString).txt")
    try "echte Datei\nZeile 2\n".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    var done = false
    ws.loadFile(at: url) { _ in done = true }
    let deadline = Date().addingTimeInterval(5)
    while !done, Date() < deadline { await Task.yield() }
    #expect(done, "Completion wurde nie aufgerufen")

    // Der leere Scratch ist weg, nur der geladene Datei-Tab bleibt.
    #expect(ws.tabs.count == 1)
    // loadFile kanonisiert die URL (`/var` → `/private/var`); dagegen prüfen.
    #expect(ws.tabs.first?.url == url.canonicalFileURL)
    #expect(!ws.tabs.contains(where: { $0.id == scratch.id }))
}

@Test("loadFile behält einen unbenannten Tab mit getipptem Inhalt")
@MainActor
func loadFile_keepsTypedUntitledTab() async throws {
    let suiteName = "fastra-test-scratch2-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let ws = Workspace(defaults: defaults)
    let typed = EditorTab(title: "Ohne Titel", path: "x", content: "wichtiger Entwurf")
    ws.tabs = [typed]
    ws.activeTabID = typed.id

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-scratch-\(UUID().uuidString).txt")
    try "echte Datei\n".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    var done = false
    ws.loadFile(at: url) { _ in done = true }
    let deadline = Date().addingTimeInterval(5)
    while !done, Date() < deadline { await Task.yield() }
    #expect(done)

    // Der getippte Entwurf bleibt erhalten, der geladene Tab kommt dazu.
    #expect(ws.tabs.count == 2)
    #expect(ws.tabs.contains(where: { $0.id == typed.id }))
}
