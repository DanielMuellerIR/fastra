// GitChangesParseTests.swift
//
// Getrennter Index-/Working-Tree-Zustand (staged/unstaged) für die VS-Code-
// artige Änderungen-Ansicht. Prüft die Porcelain-XY-Aufteilung.

import Foundation
import Testing
@testable import Fastra

@Test("Porcelain XY: staged/unstaged korrekt getrennt")
func gitChanges_splitsStagedUnstaged() {
    // ## Kopf + je eine Datei pro Kombination.
    let out = """
    ## main...origin/main
     M nur_working.txt
    M  nur_index.txt
    MM beides.txt
    A  neu_staged.txt
    ?? untracked.txt
    """
    let s = GitStatusParser.parse(out)

    func change(_ path: String) -> GitChange? { s.changes.first { $0.path == path } }

    #expect(change("nur_working.txt")?.staged == nil)
    #expect(change("nur_working.txt")?.unstaged == .modified)

    #expect(change("nur_index.txt")?.staged == .modified)
    #expect(change("nur_index.txt")?.unstaged == nil)

    #expect(change("beides.txt")?.staged == .modified)
    #expect(change("beides.txt")?.unstaged == .modified)

    #expect(change("neu_staged.txt")?.staged == .added)
    #expect(change("neu_staged.txt")?.unstaged == nil)

    #expect(change("untracked.txt")?.staged == nil)
    #expect(change("untracked.txt")?.unstaged == .untracked)
}

@Test("stagedChanges/unstagedChanges-Filter")
func gitChanges_sectionFilters() {
    let out = """
    ## main
    M  a.txt
     M b.txt
    MM c.txt
    ?? d.txt
    """
    let s = GitStatusParser.parse(out)
    // Staged: a (M ) und c (MM).
    #expect(Set(s.stagedChanges.map(\.path)) == ["a.txt", "c.txt"])
    // Unstaged: b ( M), c (MM), d (??).
    #expect(Set(s.unstagedChanges.map(\.path)) == ["b.txt", "c.txt", "d.txt"])
}

@Test("Merge-Konflikt (UU) erscheint als ungestagete Konflikt-Änderung")
func gitChanges_conflict() {
    let s = GitStatusParser.parse("## main\nUU konflikt.txt")
    let c = s.changes.first { $0.path == "konflikt.txt" }
    #expect(c?.unstaged == .conflicted)
    #expect(c?.staged == nil)
}

@Test("name/directory einer verschachtelten Änderung")
func gitChanges_nameAndDirectory() {
    let s = GitStatusParser.parse("## main\n M app/Sources/Foo.swift")
    let c = s.changes.first
    #expect(c?.name == "Foo.swift")
    #expect(c?.directory == "app/Sources")
}
