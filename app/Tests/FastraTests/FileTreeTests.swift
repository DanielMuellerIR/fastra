// FileTreeTests.swift
//
// Tests für den Projekt-Dateibaum (Projekt- & Git-Ausbau, Etappe 1) —
// Finder-Sortierung (pur) und Verzeichnis-Listing über temporäre Ordner.

import Foundation
import Testing
@testable import Fastra

private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-filetreetests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

@Test("sorted: Ordner vor Dateien, innerhalb alphabetisch")
func fileTree_sortsFoldersFirst() {
    let nodes = [
        FileTreeNode(url: URL(fileURLWithPath: "/p/b.txt"), isDirectory: false),
        FileTreeNode(url: URL(fileURLWithPath: "/p/zz"), isDirectory: true),
        FileTreeNode(url: URL(fileURLWithPath: "/p/a.txt"), isDirectory: false),
        FileTreeNode(url: URL(fileURLWithPath: "/p/aa"), isDirectory: true),
    ]
    #expect(FileTree.sorted(nodes).map(\.name) == ["aa", "zz", "a.txt", "b.txt"])
}

@Test("sorted: numerisch wie im Finder (2 vor 10)")
func fileTree_sortsNumerically() {
    let nodes = [
        FileTreeNode(url: URL(fileURLWithPath: "/p/kap10.md"), isDirectory: false),
        FileTreeNode(url: URL(fileURLWithPath: "/p/kap2.md"), isDirectory: false),
    ]
    #expect(FileTree.sorted(nodes).map(\.name) == ["kap2.md", "kap10.md"])
}

@Test("children: listet Dateien und Ordner, überspringt Versteckte")
func fileTree_listsAndSkipsHidden() throws {
    try withTempDir { dir in
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent(".versteckt"), atomically: true, encoding: .utf8)

        let children = FileTree.children(of: dir)
        #expect(children.map(\.name) == ["sub", "a.txt"])
        #expect(children.first?.isDirectory == true)
        #expect(children.last?.isDirectory == false)
    }
}

@Test("children: nicht existierender Ordner → leere Liste (kein Crash)")
func fileTree_missingDirEmpty() {
    let missing = URL(fileURLWithPath: "/definitiv/nicht/vorhanden/\(UUID().uuidString)")
    #expect(FileTree.children(of: missing).isEmpty)
}

@Test("FileTreeNode: Identität über den Pfad (stabil über Reload)")
func fileTree_nodeIdentityIsPath() {
    let a = FileTreeNode(url: URL(fileURLWithPath: "/p/x"), isDirectory: true)
    let b = FileTreeNode(url: URL(fileURLWithPath: "/p/x"), isDirectory: true)
    #expect(a.id == b.id)
}

@Test("Aufklappzustand ist pro Projekt getrennt und bleibt erhalten")
func fileTree_expansionPersistence() throws {
    let suiteName = "fastra-filetree-expanded-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let first = URL(fileURLWithPath: "/tmp/projekt-a")
    let second = URL(fileURLWithPath: "/tmp/projekt-b")
    let paths: Set<String> = ["/tmp/projekt-a/Quellen", "/tmp/projekt-a/Tests"]

    FileTreeExpansionStore.save(paths, for: first, defaults: defaults)

    #expect(FileTreeExpansionStore.load(for: first, defaults: defaults) == paths)
    #expect(FileTreeExpansionStore.load(for: second, defaults: defaults).isEmpty)
}

@Test("Dateibaum-Aktionen legen Datei und Ordner an und benennen um")
func fileTree_createAndRename() throws {
    try withTempDir { dir in
        let file = try FileTreeOperations.create(named: "neu.txt", in: dir,
                                                 isDirectory: false)
        let folder = try FileTreeOperations.create(named: "Unterordner", in: dir,
                                                   isDirectory: true)
        let renamed = try FileTreeOperations.rename(file, to: "fertig.txt")

        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path,
                                               isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}

@Test("Dateibaum-Aktionen weisen ungültige und doppelte Namen ab")
func fileTree_rejectsInvalidNames() throws {
    try withTempDir { dir in
        _ = try FileTreeOperations.create(named: "da.txt", in: dir,
                                          isDirectory: false)
        #expect(throws: FileTreeOperationError.self) {
            try FileTreeOperations.create(named: "../weg", in: dir,
                                          isDirectory: false)
        }
        #expect(throws: FileTreeOperationError.self) {
            try FileTreeOperations.create(named: "da.txt", in: dir,
                                          isDirectory: false)
        }
    }
}

@Test("FSEvents-Wächter meldet externe Änderungen in Unterordnern")
@MainActor
func fileTree_watcherRefreshesRecursively() async throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory
        .appendingPathComponent("fastra-filetreewatch-\(UUID().uuidString)")
    let subdir = dir.appendingPathComponent("tief")
    try fm.createDirectory(at: subdir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let watcher = ProjectFileWatcher(rootURL: dir)
    let initial = watcher.generation
    // Dem Stream einen Runloop-Tick zum Starten geben, dann wie ein externes
    // Programm in einem Unterordner schreiben.
    try await Task.sleep(for: .milliseconds(100))
    try "extern".write(to: subdir.appendingPathComponent("neu.txt"),
                       atomically: true, encoding: .utf8)

    for _ in 0..<60 {
        if watcher.generation > initial { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("FSEvents lieferte binnen 3 Sekunden kein rekursives Ereignis")
}

@Test("Ordner-Umbenennung bildet offene Unterdateien auf den neuen Pfad ab")
func fileTree_moveMapsDescendants() {
    let source = URL(fileURLWithPath: "/projekt/Alt")
    let destination = URL(fileURLWithPath: "/projekt/Neu")
    let child = URL(fileURLWithPath: "/projekt/Alt/tief/datei.txt")
    let unrelated = URL(fileURLWithPath: "/projekt/Andere/datei.txt")

    #expect(Workspace.movedURL(child, from: source, to: destination)?.path
            == "/projekt/Neu/tief/datei.txt")
    #expect(Workspace.movedURL(source, from: source, to: destination) == destination)
    #expect(Workspace.movedURL(unrelated, from: source, to: destination) == nil)
}
