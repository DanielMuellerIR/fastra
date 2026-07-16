// GitChangesParseTests.swift
//
// Getrennter Index-/Working-Tree-Zustand (staged/unstaged) für die VS-Code-
// artige Änderungen-Ansicht. Prüft die Porcelain-XY-Aufteilung.

import Foundation
import Testing
@testable import Fastra

private func changesPorcelain(_ records: String...) -> Data {
    var result = Data()
    for record in records {
        result.append(Data(record.utf8))
        result.append(0)
    }
    return result
}

private func tracked(_ xy: String, _ path: String) -> String {
    "1 \(xy) N... 100644 100644 100644 aaaaaaa bbbbbbb \(path)"
}

@Test("Porcelain XY: staged/unstaged korrekt getrennt")
func gitChanges_splitsStagedUnstaged() {
    let out = changesPorcelain(
        "# branch.head main",
        tracked(".M", "nur_working.txt"),
        tracked("M.", "nur_index.txt"),
        tracked("MM", "beides.txt"),
        tracked("A.", "neu_staged.txt"),
        "? untracked.txt"
    )
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
    let out = changesPorcelain(tracked("M.", "a.txt"),
                               tracked(".M", "b.txt"),
                               tracked("MM", "c.txt"),
                               "? d.txt")
    let s = GitStatusParser.parse(out)
    // Staged: a (M ) und c (MM).
    #expect(Set(s.stagedChanges.map(\.path)) == ["a.txt", "c.txt"])
    // Unstaged: b ( M), c (MM), d (??).
    #expect(Set(s.unstagedChanges.map(\.path)) == ["b.txt", "c.txt", "d.txt"])
}

@Test("Merge-Konflikt (UU) erscheint als ungestagete Konflikt-Änderung")
func gitChanges_conflict() {
    let s = GitStatusParser.parse(changesPorcelain(
        "u UU N... 100644 100644 100644 100644 aaaaaaa bbbbbbb ccccccc konflikt.txt"
    ))
    let c = s.changes.first { $0.path == "konflikt.txt" }
    #expect(c?.unstaged == .conflicted)
    #expect(c?.staged == nil)
}

@Test("name/directory einer verschachtelten Änderung")
func gitChanges_nameAndDirectory() {
    let s = GitStatusParser.parse(changesPorcelain(
        tracked(".M", "app/Sources/Foo.swift")
    ))
    let c = s.changes.first
    #expect(c?.name == "Foo.swift")
    #expect(c?.directory == "app/Sources")
}
