// GitDiffDisplayTests.swift
//
// Verhaltensgleichheit der Umstellung auf den gemeinsamen Renderer
// (Etappe 2 Wunschpaket 2026-07c): Die Abbildung „Git-Diff-Modell →
// gemeinsames Anzeige-Modell" darf die von `GitDiffParser` gelieferte
// Zeilen-Ausrichtung NICHT verändern — gleiche Eingabe, gleiche Zeilen in
// gleicher Reihenfolge mit identischen Nummern, Texten und Intraline-
// Bereichen (das zeigte der frühere Renderer `GitSideBySideDiffView` an).

import Testing
import Foundation
@testable import Fastra

// Baustein-Helfer für kompakte Fixtures.
private func row(_ id: String, hunk: String, kind: GitDiffRowKind,
                 before: (Int, String)? = nil, after: (Int, String)? = nil,
                 beforeHighlight: Range<Int>? = nil,
                 afterHighlight: Range<Int>? = nil) -> GitDiffAlignedRow {
    GitDiffAlignedRow(
        id: id, hunkID: hunk, kind: kind,
        beforeNumber: before?.0, afterNumber: after?.0,
        before: before?.1, after: after?.1,
        beforeHighlight: beforeHighlight, afterHighlight: afterHighlight,
        beforeMissingFinalNewline: false, afterMissingFinalNewline: false,
        intralineWasLimited: false
    )
}

/// Zwei Dateien: eine mit Änderung+Einfügung und langem Kontext (faltbar),
/// eine mit reiner Löschung — deckt alle Zeilenarten und Mehr-Datei ab.
private func sampleDocument() -> GitDiffDocument {
    var rowsA: [GitDiffAlignedRow] = [
        row("a-r0", hunk: "h1", kind: .context, before: (1, "gleich"), after: (1, "gleich")),
        row("a-r1", hunk: "h1", kind: .changed, before: (2, "alt"), after: (2, "neu"),
            beforeHighlight: 0..<3, afterHighlight: 0..<3),
        row("a-r2", hunk: "h1", kind: .added, after: (3, "eingefügt")),
    ]
    // Langer Kontext-Lauf → der Falt-Mechanismus greift (mehr als 2×3+1).
    for i in 0..<10 {
        rowsA.append(row("a-ctx\(i)", hunk: "h1", kind: .context,
                         before: (3 + i, "ctx"), after: (4 + i, "ctx")))
    }
    rowsA.append(row("a-r3", hunk: "h1", kind: .removed, before: (13, "weg")))
    let fileA = GitDiffFile(
        id: "file-a", oldPath: "a.txt", newPath: "a.txt", metadata: [],
        hunks: [GitDiffHunk(id: "h1", header: "@@ -1,13 +1,13 @@",
                            oldStart: 1, newStart: 1, rows: rowsA)],
        limitation: nil
    )
    let rowsB: [GitDiffAlignedRow] = [
        row("b-r0", hunk: "h2", kind: .context, before: (7, "x"), after: (7, "x")),
        row("b-r1", hunk: "h2", kind: .removed, before: (8, "raus")),
        row("b-r2", hunk: "h2", kind: .removed, before: (9, "auch raus")),
        row("b-r3", hunk: "h2", kind: .context, before: (10, "y"), after: (8, "y")),
    ]
    let fileB = GitDiffFile(
        id: "file-b", oldPath: "unter/b.txt", newPath: "unter/b.txt", metadata: [],
        hunks: [GitDiffHunk(id: "h2", header: "@@ -7,4 +7,2 @@",
                            oldStart: 7, newStart: 7, rows: rowsB)],
        limitation: nil
    )
    return GitDiffDocument(files: [fileA, fileB], limitation: nil)
}

/// Zieht die Anzeigezeilen aus einem Item-Strom.
private func displayRows(_ items: [DiffDisplayItem]) -> [DiffDisplayRow] {
    items.compactMap {
        if case .row(let row) = $0 { return row }
        return nil
    }
}

@Test("Gleiche Eingabe → gleiche Zeilen-Ausrichtung wie der frühere Renderer")
func mappingPreservesAlignment() {
    let document = sampleDocument()
    // Der frühere Renderer zeigte GitDiffViewModel.visibleItems an —
    // exakt dessen Zeilenfolge muss der Mapper liefern (eingeklappt).
    let oldRows = GitDiffViewModel.visibleItems(document: document,
                                                expandedFolds: [])
        .compactMap { item -> GitDiffAlignedRow? in
            if case .row(let row) = item { return row }
            return nil
        }
    let newRows = displayRows(GitDiffDisplay.items(document: document,
                                                   expandedFolds: []))
    #expect(newRows.count == oldRows.count)
    for (new, old) in zip(newRows, oldRows) {
        #expect(new.id == old.id)
        #expect(new.beforeNumber == old.beforeNumber)
        #expect(new.afterNumber == old.afterNumber)
        #expect(new.before == old.before)
        #expect(new.after == old.after)
        #expect(new.beforeHighlight == old.beforeHighlight)
        #expect(new.afterHighlight == old.afterHighlight)
        #expect(new.intralineWasLimited == old.intralineWasLimited)
    }
}

@Test("Falten identisch zum früheren Renderer; ausgeklappt kommen ALLE Zeilen")
func mappingPreservesFolding() {
    let document = sampleDocument()
    let collapsed = GitDiffDisplay.items(document: document, expandedFolds: [])
    let foldIDs = collapsed.compactMap { item -> String? in
        if case .fold(let id, _, _) = item { return id }
        return nil
    }
    #expect(foldIDs.count == 1)   // der lange Kontext-Lauf in Datei A
    let expanded = GitDiffDisplay.items(document: document,
                                        expandedFolds: Set(foldIDs))
    let allRows = displayRows(expanded)
    let sourceRows = document.hunks.flatMap(\.rows)
    #expect(allRows.count == sourceRows.count)
    #expect(allRows.map(\.id) == sourceRows.map(\.id))
    // Ordinale sind die Positionen in der vollen Zeilenfolge.
    #expect(allRows.map(\.ordinal) == Array(0..<sourceRows.count))
}

@Test("Zeilenarten werden 1:1 übersetzt (context→unchanged usw.)")
func kindMapping() {
    let document = sampleDocument()
    let rows = displayRows(GitDiffDisplay.items(
        document: document,
        expandedFolds: []
    ))
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.kind) })
    #expect(byID["a-r0"] == .unchanged)
    #expect(byID["a-r1"] == .changed)
    #expect(byID["a-r2"] == .added)
    #expect(byID["b-r1"] == .removed)
}

@Test("Differenzen-Liste: ein Eintrag je Lauf, Dateiname bei Mehr-Datei-Diffs")
func entriesGrouping() {
    let document = sampleDocument()
    let entries = GitDiffDisplay.entries(document: document)
    // Datei A: geändert+eingefügt (ein Lauf), gelöscht (zweiter Lauf);
    // Datei B: Doppel-Löschung (ein Lauf).
    #expect(entries.count == 3)
    #expect(entries[0].kind == .changed)
    #expect(entries[1].kind == .onlyLeft)
    #expect(entries[2].kind == .onlyLeft)
    // Mehr-Datei-Diff → Dateiname als Präfix.
    #expect(entries[0].label.hasPrefix("a.txt: "))
    #expect(entries[2].label.hasPrefix("b.txt: "))
    // Scroll-Ziel ist die erste Zeile des Laufs.
    #expect(entries[0].scrollTargetID == "a-r1")
    #expect(entries[1].scrollTargetID == "a-r3")
    #expect(entries[2].scrollTargetID == "b-r1")
    // Ordinal-Bereiche decken die Läufe ab (a-r1 ist Zeile 1, a-r2 Zeile 2).
    #expect(entries[0].firstOrdinal == 1)
    #expect(entries[0].lastOrdinal == 2)
}

@Test("Einzel-Datei-Diff bekommt KEINEN Dateinamen-Präfix")
func entriesSingleFile() {
    var document = sampleDocument()
    document.files.removeLast()
    let entries = GitDiffDisplay.entries(document: document)
    #expect(entries.count == 2)
    #expect(!entries[0].label.contains("a.txt"))
}

@Test("Dateikopf-Titel: gleich, umbenannt, gelöscht, reine Metadaten")
func fileTitles() {
    func file(old: String?, new: String?,
              metadata: [String] = []) -> GitDiffFile {
        GitDiffFile(id: "f", oldPath: old, newPath: new,
                    metadata: metadata, hunks: [], limitation: nil)
    }
    #expect(GitDiffDisplay.fileTitle(file(old: "a.txt", new: "a.txt")) == "a.txt")
    #expect(GitDiffDisplay.fileTitle(file(old: "alt.txt", new: "neu.txt"))
            == L10n.format("%@ → %@", "alt.txt", "neu.txt"))
    let deleted = GitDiffDisplay.fileTitle(file(old: "weg.txt", new: nil))
    #expect(deleted.contains("weg.txt"))
    let metaOnly = GitDiffDisplay.fileTitle(
        file(old: nil, new: nil, metadata: ["diff --git a/x b/x"])
    )
    #expect(metaOnly == "diff --git a/x b/x")
}

@Test("Items enthalten Dateiköpfe, Hunk-Köpfe und Lücken in alter Struktur")
func itemsStructure() {
    let document = sampleDocument()
    let items = GitDiffDisplay.items(document: document, expandedFolds: [])
    // Reihenfolge: Kopf A, Hunk-Kopf h1, …, Kopf B, Lücke (h2 startet bei
    // Zeile 7 → 6 ausgelassene Zeilen), Hunk-Kopf h2, …
    guard case .fileHeader(_, let titleA) = items[0] else {
        Issue.record("Erwartet: Dateikopf an Position 0")
        return
    }
    #expect(titleA == "a.txt")
    guard case .hunkHeader(let hunkID, let header, _) = items[1] else {
        Issue.record("Erwartet: Hunk-Kopf an Position 1")
        return
    }
    #expect(hunkID == "h1")
    #expect(header == "@@ -1,13 +1,13 @@")
    let gapCounts = items.compactMap { item -> Int? in
        if case .gap(_, let count) = item { return count }
        return nil
    }
    #expect(gapCounts == [6])
}
