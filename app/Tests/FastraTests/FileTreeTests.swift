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
