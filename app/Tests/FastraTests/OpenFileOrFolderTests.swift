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

@Test("Datei-URL → Tab geladen, Elternordner erscheint als Projekt (Etappe 1)")
@MainActor
func openFileOrFolder_fileOpensTab() async throws {
    let fm = FileManager.default
    let file = fm.temporaryDirectory.appendingPathComponent("ff-\(UUID().uuidString).txt")
    try "hallo".write(to: file, atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(at: file) }

    let ws = Workspace(defaults: UserDefaults(suiteName: "ff-\(UUID().uuidString)")!)
    ws.openFileOrFolder(at: file)

    // loadFile legt den (Platzhalter-)Tab mit gesetzter URL sofort synchron an.
    #expect(ws.tabs.contains { $0.url == file.canonicalFileURL })

    // Nach dem asynchronen Laden öffnet der Einzeldatei-Pfad den
    // unmittelbaren Elternordner als Projekt (Wunschpaket 2026-07, Etappe 1).
    let deadline = Date().addingTimeInterval(5)
    while ws.projectURL == nil, Date() < deadline { await Task.yield() }
    #expect(ws.projectURL == file.canonicalFileURL.deletingLastPathComponent())
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

@Test("Projektwechsel entfernt Willkommen, behält ungesicherte Tabs")
@MainActor
func openProject_removesWelcomeButKeepsUnsavedTabs() {
    let root = URL(fileURLWithPath: "/tmp/projekt")
    let welcome = EditorTab(title: "Ohne Titel", path: "—", isWelcome: true)
    let draft = EditorTab(title: "Entwurf", path: "—",
                          content: "ungesichert", isDirty: true)

    let result = Workspace.tabsAfterOpeningProject([welcome, draft], root: root)

    #expect(result.map(\.id) == [draft.id])
    #expect(!result.contains { $0.isWelcome })
}

@Test("Projektwechsel erkennt ähnlich beginnende Nachbarordner nicht als Hierarchie")
@MainActor
func openProject_doesNotKeepSiblingWithSamePrefix() {
    let root = URL(fileURLWithPath: "/tmp/projekt")
    let siblingFile = URL(fileURLWithPath: "/tmp/projekt-alt/datei.txt")
    let tab = EditorTab(title: "datei.txt", path: "/tmp/projekt-alt", url: siblingFile)

    #expect(Workspace.tabsAfterOpeningProject([tab], root: root).isEmpty)
}
