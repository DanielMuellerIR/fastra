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

@Test("Projektwechsel schließt nur saubere Dateien außerhalb des neuen Ordners")
@MainActor
func openProject_prunesOnlyCleanOutsideFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ff-project-\(UUID().uuidString)")
    let inside = root.appendingPathComponent("inside.txt")
    let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID()).txt")
    let dirtyOutside = root.deletingLastPathComponent().appendingPathComponent("dirty-\(UUID()).txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "im Projekt".write(to: inside, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    let cleanInside = EditorTab(title: "inside.txt", path: root.path, url: inside)
    let cleanOutside = EditorTab(title: "outside.txt",
                                 path: outside.deletingLastPathComponent().path,
                                 url: outside)
    let changedOutside = EditorTab(title: "dirty.txt",
                                   path: dirtyOutside.deletingLastPathComponent().path,
                                   url: dirtyOutside,
                                   content: "ungesichert",
                                   isDirty: true)
    let scratch = EditorTab(title: "Ohne Titel", path: "—")

    let result = Workspace.tabsAfterOpeningProject(
        [cleanInside, cleanOutside, changedOutside, scratch], root: root
    )

    #expect(result.map(\.id) == [cleanInside.id, changedOutside.id, scratch.id])
}

@Test("Projektwechsel erkennt ähnlich beginnende Nachbarordner nicht als Hierarchie")
@MainActor
func openProject_doesNotKeepSiblingWithSamePrefix() {
    let root = URL(fileURLWithPath: "/tmp/projekt")
    let siblingFile = URL(fileURLWithPath: "/tmp/projekt-alt/datei.txt")
    let tab = EditorTab(title: "datei.txt", path: "/tmp/projekt-alt", url: siblingFile)

    #expect(Workspace.tabsAfterOpeningProject([tab], root: root).isEmpty)
}
