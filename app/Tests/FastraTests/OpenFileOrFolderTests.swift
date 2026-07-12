// OpenFileOrFolderTests.swift
//
// ⌘O öffnet Datei ODER Ordner (Daniel-Wunsch 2026-07-12): die reine Routing-
// Entscheidung in Workspace.openFileOrFolder — Ordner → Projekt, Datei → Tab.

import Foundation
import Testing
@testable import Fastra

@Test("Ordner-URL → als Projekt geladen (projectURL gesetzt)")
@MainActor
func openFileOrFolder_directoryOpensProject() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("ff-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let ws = Workspace(defaults: UserDefaults(suiteName: "ff-\(UUID().uuidString)")!)
    ws.openFileOrFolder(at: dir)

    #expect(ws.projectURL == dir.canonicalFileURL)
}

@Test("Datei-URL → in einen Tab geladen (kein Projekt)")
@MainActor
func openFileOrFolder_fileOpensTab() throws {
    let fm = FileManager.default
    let file = fm.temporaryDirectory.appendingPathComponent("ff-\(UUID().uuidString).txt")
    try "hallo".write(to: file, atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(at: file) }

    let ws = Workspace(defaults: UserDefaults(suiteName: "ff-\(UUID().uuidString)")!)
    ws.openFileOrFolder(at: file)

    // loadFile legt den (Platzhalter-)Tab mit gesetzter URL sofort synchron an.
    #expect(ws.projectURL == nil)
    #expect(ws.tabs.contains { $0.url == file.canonicalFileURL })
}
