// GitGraphTests.swift
//
// Tests für die reine Graph-Kernlogik (GitGraph.swift): Log-Parser + Lane-Layout.
// Deckt die gefährlichen Fälle ab, die man visuell leicht übersieht: Diamond
// (Branch + Merge), geteilter Parent zweier Tips, Root, lineare Historie.

import Foundation
import Testing
@testable import Fastra

// Kurzschreibweise: baut die rohe git-log-Ausgabe im erwarteten Format nach
// (RS = \u{1e} vor jedem Commit, US = \u{1f} zwischen den Feldern).
private func rawLog(_ commits: [(h: String, p: String, an: String, d: String, ts: String, refs: String, s: String)]) -> String {
    commits.map { c in
        "\u{1e}\(c.h)\u{1f}\(c.p)\u{1f}\(c.an)\u{1f}\(c.d)\u{1f}\(c.ts)\u{1f}\(c.refs)\u{1f}\(c.s)"
    }.joined()
}

// MARK: - Parser

@Test("Log-Argumente liefern auch für Merge-Commits Dateidetails")
func arguments_includeMergeDetails() {
    #expect(GitGraph.arguments.contains("--raw"))
    #expect(GitGraph.arguments.contains("--numstat"))
    #expect(GitGraph.arguments.contains("--diff-merges=first-parent"))
}

@Test("Parser: einzelner Commit, alle Felder")
func parse_singleCommit() {
    let raw = rawLog([("abc123", "", "Dana", "2026-07-12", "1783872000", "HEAD -> main", "Erster Commit")])
    let commits = GitGraph.parse(raw)
    #expect(commits.count == 1)
    let c = commits[0]
    #expect(c.hash == "abc123")
    #expect(c.parents.isEmpty)
    #expect(c.author == "Dana")
    #expect(c.date == "2026-07-12")
    #expect(c.timestamp == 1_783_872_000)
    #expect(c.refs == ["HEAD -> main"])
    #expect(c.subject == "Erster Commit")
    #expect(c.shortHash == "abc123")
}

@Test("Parser: mehrere Eltern (Merge) leer-getrennt")
func parse_mergeParents() {
    let raw = rawLog([("m", "a b", "Dana", "2026-07-12", "0", "", "Merge")])
    #expect(GitGraph.parse(raw)[0].parents == ["a", "b"])
}

@Test("Parser: mehrere Decorations werden an ', ' getrennt")
func parse_refsSplit() {
    let raw = rawLog([("h", "", "Dana", "2026-07-12", "0", "HEAD -> main, origin/main, tag: v1.0", "x")])
    #expect(GitGraph.parse(raw)[0].refs == ["HEAD -> main", "origin/main", "tag: v1.0"])
}

@Test("Parser: Betreff mit Sonderzeichen (Pipe, Komma) bleibt heil")
func parse_subjectWithSpecials() {
    let raw = rawLog([("h", "", "Dana", "2026-07-12", "0", "", "fix(ui): a | b, c")])
    #expect(GitGraph.parse(raw)[0].subject == "fix(ui): a | b, c")
}

@Test("Parser: Dateistatus und Änderungszahlen bleiben am Commit")
func parse_fileDetails() {
    let raw = rawLog([(
        "h", "", "Dana", "2026-07-12", "1783872000", "", "Dateien\n"
        + ":100644 100644 aaaaaaa bbbbbbb M\tSources/App.swift\n"
        + ":000000 100644 0000000 ccccccc A\tREADME.md\n"
        + "12\t3\tSources/App.swift\n"
        + "8\t0\tREADME.md"
    )])
    let commit = GitGraph.parse(raw)[0]
    #expect(commit.files == [
        GitCommitFile(path: "Sources/App.swift", status: "M", additions: 12, deletions: 3),
        GitCommitFile(path: "README.md", status: "A", additions: 8, deletions: 0),
    ])
    #expect(commit.additions == 20)
    #expect(commit.deletions == 3)
}

@Test("Parser: leere/kaputte Datensätze werden übersprungen")
func parse_skipsGarbage() {
    // Führendes RS erzeugt ein leeres erstes Segment; ein zu kurzer Datensatz.
    let raw = "\u{1e}\u{1e}nur-hash-ohne-felder"
    #expect(GitGraph.parse(raw).isEmpty)
}

// MARK: - Layout: triviale Fälle

@Test("Layout: leere Eingabe → keine Zeilen, laneCount 1")
func layout_empty() {
    let l = GitGraph.layout([])
    #expect(l.rows.isEmpty)
    #expect(l.laneCount == 1)
}

@Test("Layout: einzelner Root-Commit → Spalte 0")
func layout_singleRoot() {
    let commits = [GitCommit(hash: "a", parents: [], author: "", date: "", refs: [], subject: "")]
    let l = GitGraph.layout(commits)
    #expect(l.laneCount == 1)
    #expect(l.rows[0].column == 0)
    // Nur ein incoming/through gibt es nicht; ein Root-Tip hat keine Linien.
    #expect(l.rows[0].lines.isEmpty)
}

@Test("Layout: lineare Historie → alles Spalte 0, eine Lane, eine Farbe")
func layout_linear() {
    // Neuester zuerst: A→B→C
    let commits = [
        GitCommit(hash: "A", parents: ["B"], author: "", date: "", refs: [], subject: ""),
        GitCommit(hash: "B", parents: ["C"], author: "", date: "", refs: [], subject: ""),
        GitCommit(hash: "C", parents: [], author: "", date: "", refs: [], subject: ""),
    ]
    let l = GitGraph.layout(commits)
    #expect(l.laneCount == 1)
    #expect(l.rows.allSatisfy { $0.column == 0 })
    #expect(l.rows.allSatisfy { $0.colorIndex == 0 })
    // A: nur outgoing 0→0 ; C: nur incoming 0→0
    #expect(l.rows[0].lines == [GraphLine(fromColumn: 0, toColumn: 0, colorIndex: 0, kind: .outgoing)])
    #expect(l.rows[2].lines == [GraphLine(fromColumn: 0, toColumn: 0, colorIndex: 0, kind: .incoming)])
}

@Test("Layout: HEAD/main bleibt blau, auch wenn ein anderer Tip zuerst kommt")
func layout_primaryBranchKeepsBlue() {
    // `--all` darf einen fremden, neueren Tip vor HEAD liefern. Dieser Tip
    // bekommt eine Nebenfarbe; ab HEAD läuft die First-Parent-Linie blau.
    let commits = [
        GitCommit(hash: "feature", parents: ["head"], author: "", date: "",
                  refs: ["feature"], subject: ""),
        GitCommit(hash: "head", parents: ["base"], author: "", date: "",
                  refs: ["HEAD -> main"], subject: ""),
        GitCommit(hash: "base", parents: [], author: "", date: "",
                  refs: [], subject: ""),
    ]
    let layout = GitGraph.layout(commits)

    #expect(layout.rows[0].colorIndex != 0)
    #expect(layout.rows[1].colorIndex == 0)
    #expect(layout.rows[1].lines.contains {
        $0.kind == .outgoing && $0.colorIndex == 0
    })
    #expect(layout.rows[2].colorIndex == 0)
}

// MARK: - Layout: Verzweigung + Merge (der wichtige Fall)

@Test("Layout: Diamond (Merge M über A und B, gemeinsame Basis)")
func layout_diamond() {
    // Topo-Order, neuester zuerst: M(a,b) · A(base) · B(base) · base()
    let commits = [
        GitCommit(hash: "M", parents: ["A", "B"], author: "", date: "", refs: [], subject: ""),
        GitCommit(hash: "A", parents: ["base"], author: "", date: "", refs: [], subject: ""),
        GitCommit(hash: "B", parents: ["base"], author: "", date: "", refs: [], subject: ""),
        GitCommit(hash: "base", parents: [], author: "", date: "", refs: [], subject: ""),
    ]
    let l = GitGraph.layout(commits)
    #expect(l.laneCount == 2)   // genau zwei Spalten

    // M in Spalte 0, verzweigt zu A (0→0) und B (0→1).
    let m = l.rows[0]
    #expect(m.column == 0)
    #expect(m.lines.contains(GraphLine(fromColumn: 0, toColumn: 0, colorIndex: 0, kind: .outgoing)))
    #expect(m.lines.contains { $0.kind == .outgoing && $0.fromColumn == 0 && $0.toColumn == 1 })

    // B liegt in Spalte 1 und mündet zurück in die base-Lane in Spalte 0.
    let b = l.rows[2]
    #expect(b.column == 1)
    #expect(b.lines.contains { $0.kind == .outgoing && $0.fromColumn == 1 && $0.toColumn == 0 })
    // base-Lane läuft in B's Zeile senkrecht durch Spalte 0.
    #expect(b.lines.contains { $0.kind == .through && $0.fromColumn == 0 && $0.toColumn == 0 })

    // base sammelt die Haupt-Lane wieder ein (incoming in Spalte 0).
    let base = l.rows[3]
    #expect(base.column == 0)
    #expect(base.lines.contains { $0.kind == .incoming && $0.toColumn == 0 })
}

@Test("Layout: zwei Tips mit gemeinsamem Parent laufen zusammen (kein Merge)")
func layout_sharedParent() {
    // Zwei getrennte Köpfe X und Y, beide auf 'base'. Topo: X · Y · base
    let commits = [
        GitCommit(hash: "X", parents: ["base"], author: "", date: "", refs: [], subject: ""),
        GitCommit(hash: "Y", parents: ["base"], author: "", date: "", refs: [], subject: ""),
        GitCommit(hash: "base", parents: [], author: "", date: "", refs: [], subject: ""),
    ]
    let l = GitGraph.layout(commits)
    #expect(l.laneCount == 2)
    // X in Spalte 0 (setzt base-Lane), Y als zweiter Tip in Spalte 1.
    #expect(l.rows[0].column == 0)
    #expect(l.rows[1].column == 1)
    // Y mündet in die schon offene base-Lane (1→0).
    #expect(l.rows[1].lines.contains { $0.kind == .outgoing && $0.fromColumn == 1 && $0.toColumn == 0 })
    // base wieder in Spalte 0.
    #expect(l.rows[2].column == 0)
}

@Test("Layout: Merge-Farben — die beiden Merge-Äste haben verschiedene Farb-Indizes")
func layout_mergeColorsDistinct() {
    let commits = [
        GitCommit(hash: "M", parents: ["A", "B"], author: "", date: "", refs: [], subject: ""),
        GitCommit(hash: "A", parents: ["base"], author: "", date: "", refs: [], subject: ""),
        GitCommit(hash: "B", parents: ["base"], author: "", date: "", refs: [], subject: ""),
        GitCommit(hash: "base", parents: [], author: "", date: "", refs: [], subject: ""),
    ]
    let l = GitGraph.layout(commits)
    let outgoing = l.rows[0].lines.filter { $0.kind == .outgoing }
    let colors = Set(outgoing.map { $0.colorIndex })
    #expect(colors.count == 2)   // die beiden Äste sind farblich unterscheidbar
}

@Test("Layout: Haupt-Lane bleibt nach später abgearbeitetem Merge-Ast blau")
func layout_primaryLaneWinsAtCommonAncestor() {
    // Gemeldete Problemform: Der Topo-Order zeigt nach dem Merge zuerst den
    // Nebenast. Er merkt dadurch `base` vor, bevor der Hauptast dort ankommt.
    let commits = [
        GitCommit(hash: "M", parents: ["main1", "side1"], author: "", date: "",
                  refs: ["HEAD -> main"], subject: "Merge"),
        GitCommit(hash: "side1", parents: ["side2"], author: "", date: "",
                  refs: [], subject: "Nebenast 1"),
        GitCommit(hash: "side2", parents: ["base"], author: "", date: "",
                  refs: [], subject: "Nebenast 2"),
        GitCommit(hash: "main1", parents: ["main2"], author: "", date: "",
                  refs: [], subject: "Hauptast 1"),
        GitCommit(hash: "main2", parents: ["base"], author: "", date: "",
                  refs: [], subject: "Hauptast 2"),
        GitCommit(hash: "base", parents: ["root"], author: "", date: "",
                  refs: [], subject: "Gemeinsame Basis"),
        GitCommit(hash: "root", parents: [], author: "", date: "",
                  refs: [], subject: "Initiale Version"),
    ]

    let layout = GitGraph.layout(commits)
    let lastMain = layout.rows[4]
    let base = layout.rows[5]
    let root = layout.rows[6]

    #expect(lastMain.lines.contains {
        $0.kind == .joining && $0.colorIndex != 0 && $0.toColumn == lastMain.column
    })
    #expect(base.column == 0)
    #expect(base.colorIndex == 0)
    #expect(root.column == 0)
    #expect(root.colorIndex == 0)
}
