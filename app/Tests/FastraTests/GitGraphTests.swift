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
private func rawLog(_ commits: [(h: String, p: String, an: String, d: String, ts: String, refs: String, s: String)]) -> Data {
    var data = Data()
    for c in commits {
        data.append(Data("\u{1e}\(c.h)\u{1f}\(c.p)\u{1f}\(c.an)\u{1f}\(c.d)\u{1f}\(c.ts)\u{1f}\(c.refs)\u{1f}\(c.s)".utf8))
        data.append(0)
    }
    return data
}

// MARK: - Parser

@Test("Log-Argumente liefern auch für Merge-Commits Dateidetails")
func arguments_includeMergeDetails() {
    #expect(GitGraph.arguments.contains("--raw"))
    #expect(GitGraph.arguments.contains("--numstat"))
    #expect(GitGraph.arguments.contains("-z"))
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
    var raw = rawLog([("h", "", "Dana", "2026-07-12", "1783872000", "", "Dateien")])
    for field in ["\n:100644 100644 aaaaaaa bbbbbbb M", "Sources/App.swift",
                  ":000000 100644 0000000 ccccccc A", "README.md",
                  "12\t3\tSources/App.swift", "8\t0\tREADME.md"] {
        raw.append(Data(field.utf8)); raw.append(0)
    }
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
    let raw = Data("\u{1e}\u{1e}nur-hash-ohne-felder".utf8)
    #expect(GitGraph.parse(raw).isEmpty)
}

@Test("NUL-Parser erhält Tabs, Zeilenumbrüche, Rename-Quelle und ungültiges UTF-8")
func parseNULPathsLosslessly() {
    let target = Data("neu\tmit\nZeile.txt".utf8)
    let original = Data("alt ü.txt".utf8)
    var raw = rawLog([("h", "p", "Dana", "2026-07-12", "1", "", "Rename")])
    raw.append(Data("\n:100644 100644 aaaaaaa bbbbbbb R100".utf8)); raw.append(0)
    raw.append(original); raw.append(0); raw.append(target); raw.append(0)
    raw.append(Data("0\t0\t".utf8)); raw.append(0)
    raw.append(original); raw.append(0); raw.append(target); raw.append(0)
    raw.append(Data("\u{1e}bad\u{1f}\u{1f}Dana\u{1f}2026-07-12\u{1f}1\u{1f}\u{1f}Bytes".utf8)); raw.append(0)
    raw.append(Data("\n:000000 100644 0000000 ccccccc A".utf8)); raw.append(0)
    raw.append(Data([0xff, 0xfe])); raw.append(0)

    let commits = GitGraph.parse(raw)
    #expect(commits[0].files[0].rawPath == target)
    #expect(commits[0].files[0].rawOriginalPath == original)
    #expect(commits[0].files[0].actionPath == "neu\tmit\nZeile.txt")
    #expect(commits[1].files[0].actionPath == nil)
    #expect(!commits[1].files[0].path.isEmpty)
}

@Test("Graph-Bedienhinweis erhält HEAD und getrennte Aktionen")
func graphAccessibilityHints() {
    let hint = GitGraphAccessibility.commitHint(isHEAD: true, hasFiles: true,
                                                isExpanded: false)
    #expect(hint.contains("HEAD"))
    #expect(hint.contains(L10n.string(
        "Die Aktion „Commit-Diff öffnen“ zeigt den vollständigen Commit-Diff."
    )))
    #expect(hint.contains(L10n.string(
        "Die Dateiliste ist eingeklappt und kann ausgeklappt werden."
    )))
    #expect(GitGraphAccessibility.fileHint(actionable: false).contains("UTF-8"))
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
    let layout = GitGraph.layout(commits, headOID: "head")

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
    let base = layout.rows[5]
    let root = layout.rows[6]

    // Beide Äste treffen erst direkt am gemeinsamen Commit zusammen. So endet
    // keine Nebenfarbe eine Zeile zu früh als sichtbare Sackgasse.
    #expect(base.lines.contains {
        $0.kind == .incoming && $0.fromColumn == 0 && $0.toColumn == 0 && $0.colorIndex == 0
    })
    #expect(base.lines.contains {
        $0.kind == .incoming && $0.fromColumn == 1 && $0.toColumn == 0 && $0.colorIndex != 0
    })
    #expect(base.column == 0)
    #expect(base.colorIndex == 0)
    #expect(root.column == 0)
    #expect(root.colorIndex == 0)
}

@Test("Exakte HEAD-OID schlägt Branch- und Remote-Decorations")
func layout_exactHeadOID() {
    let decorated = GitCommit(hash: "other", parents: ["head"], author: "", date: "",
                              refs: ["HEAD -> falsch", "origin/main"], subject: "Other")
    let actual = GitCommit(hash: "head", parents: [], author: "", date: "",
                           refs: ["main", "origin/main", "tag: v1"], subject: "Actual")
    let layout = GitGraph.layout([decorated, actual], headOID: "head")
    #expect(!layout.rows[0].isHEAD)
    #expect(layout.rows[1].isHEAD)
    #expect(layout.rows.filter(\.isHEAD).count == 1)
}

@Test("HEAD-Präsentation benennt Branch und Detached-Zustand sichtbar")
func headPresentationBranchAndDetached() {
    let commit = GitCommit(hash: "abcdef123456", parents: [], author: "Dana", date: "",
                           refs: ["origin/main"], subject: "Test")
    let row = GitGraph.layout([commit], headOID: commit.hash).rows[0]
    let branch = GitHeadPresentation.make(row: row, branch: "feature/ü")
    #expect(branch?.label == L10n.format("HEAD · %@", "feature/ü"))
    #expect(branch?.isDetached == false)
    #expect(branch?.tooltip.contains("feature/ü") == true)

    let detached = GitHeadPresentation.make(row: row, branch: nil)
    #expect(detached?.label.contains("abcdef1") == true)
    #expect(detached?.isDetached == true)
    #expect(detached?.tooltip.contains("abcdef1") == true)
}

@Test("Merge-Rolle und HEAD-Rolle bleiben unabhängig")
func layoutMergeAndHeadIndependent() {
    let headMerge = GitCommit(hash: "M", parents: ["A", "B"], author: "", date: "",
                              refs: [], subject: "Merge")
    let oldMerge = GitCommit(hash: "A", parents: ["C", "D"], author: "", date: "",
                             refs: [], subject: "Old merge")
    let side = GitCommit(hash: "B", parents: [], author: "", date: "", refs: [], subject: "")
    let c = GitCommit(hash: "C", parents: [], author: "", date: "", refs: [], subject: "")
    let d = GitCommit(hash: "D", parents: [], author: "", date: "", refs: [], subject: "")
    let layout = GitGraph.layout([headMerge, oldMerge, side, c, d], headOID: "M")
    #expect(layout.rows[0].isHEAD)
    #expect(layout.rows[0].commit.parents.count == 2)
    #expect(!layout.rows[1].isHEAD)
    #expect(layout.rows[1].commit.parents.count == 2)
}

@Test("Neuer Snapshot verschiebt HEAD ohne Decoration-Heuristik")
func layoutHeadRefresh() {
    let a = GitCommit(hash: "A", parents: ["B"], author: "", date: "",
                      refs: ["origin/main"], subject: "A")
    let b = GitCommit(hash: "B", parents: [], author: "", date: "",
                      refs: ["main"], subject: "B")
    #expect(GitGraph.layout([a, b], headOID: "A").rows.map(\.isHEAD) == [true, false])
    #expect(GitGraph.layout([a, b], headOID: "B").rows.map(\.isHEAD) == [false, true])
}

@Test("Reales Graph-Protokoll öffnet Rename mit Leerraum, Unicode, Tab und Zeilenumbruch")
func graphRealRepositorySpecialRenameAndCommitDiff() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-graph-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await graphGit(["init", "-q"], in: root)
    _ = try await graphGit(["config", "user.name", "Fastra Test"], in: root)
    _ = try await graphGit(["config", "user.email", "test@example.invalid"], in: root)

    let original = "alt Grüße mit space.txt"
    let target = "neu\tGrüße\nmit Zeile.txt"
    try Data("inhalt\n".utf8).write(to: root.appendingPathComponent(original))
    _ = try await graphGit(["--literal-pathspecs", "add", "--", original], in: root)
    _ = try await graphGit(["commit", "-q", "-m", "root"], in: root)
    _ = try await graphGit(["mv", "--", original, target], in: root)
    _ = try await graphGit(["commit", "-q", "-m", "rename"], in: root)

    let result = try await graphGit(GitGraph.arguments, in: root)
    let commits = GitGraph.parse(result.stdoutData)
    guard let head = commits.first, let file = head.files.first(where: { $0.status == "R" }) else {
        Issue.record("Realer Rename fehlt im Graph")
        return
    }
    #expect(file.actionPath == target)
    #expect(file.originalPath == original)
    #expect(file.additions == 0)
    #expect(file.deletions == 0)

    let request = GitDiffRequest(repositoryPath: root.path, source: .commit(
        hash: head.hash,
        parent: .commit(hash: head.parents[0], number: 1, total: head.parents.count),
        path: try #require(file.actionPath)
    ))
    let diff = try await graphGit(request.arguments, in: root)
    #expect(GitDiffParser.parse(diff.stdoutData).limitation == nil)
}

private enum GraphTestFailure: Error {
    case outcome(GitExecutionOutcome)
    case exit(Int32, String)
}

private func graphGit(_ arguments: [String], in root: URL) async throws -> GitResult {
    let outcome = await withCheckedContinuation { continuation in
        GitRunner.runDetailed(arguments, in: root) { continuation.resume(returning: $0) }
    }
    guard case .completed(let result) = outcome else { throw GraphTestFailure.outcome(outcome) }
    guard result.exitCode == 0 else {
        throw GraphTestFailure.exit(result.exitCode, result.stderrForDisplay)
    }
    return result
}
