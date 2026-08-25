// GitFileHistoryTests.swift
//
// Tests für den auf eine Datei eingeschränkten Verlauf: die git-Argumente,
// den Weg vom angeklickten Pfad zum Repo-relativen Pfad und das einspurige
// Layout der gefilterten Commit-Liste.

import Foundation
import Testing
@testable import Fastra

// Kurzschreibweise wie in GitGraphTests: baut die rohe git-log-Ausgabe nach.
private func rawLog(_ commits: [(h: String, p: String, s: String)]) -> Data {
    var data = Data()
    for c in commits {
        data.append(Data("\u{1e}\(c.h)\u{1f}\(c.p)\u{1f}Dana\u{1f}2026-08-24\u{1f}0\u{1f}\u{1f}\(c.s)".utf8))
        data.append(0)
    }
    return data
}

// MARK: - Argumente

@Test("Dateiverlauf folgt Umbenennungen und fragt genau einen Pfad ab")
func fileHistory_argumentsFollowSinglePath() {
    let args = GitFileHistory.arguments(relativePath: "app/Sources/Fastra/Workspace.swift")
    #expect(args.first == "--literal-pathspecs")
    #expect(args.dropFirst().first == "log")
    #expect(args.contains("--follow"))
    // `--follow` verträgt nur einen Pfad; er steht als letztes Argument hinter `--`.
    #expect(args.last == "app/Sources/Fastra/Workspace.swift")
    #expect(args[args.count - 2] == "--")
    // Der Parser ist derselbe wie beim vollen Graphen — deshalb muss auch das
    // Format identisch sein.
    #expect(args.contains("-z"))
    #expect(args.contains("--raw"))
    #expect(args.contains("--numstat"))
    #expect(args.contains("--diff-merges=first-parent"))
    let format = args.first { $0.hasPrefix("--pretty=format:") }
    #expect(format == GitGraph.arguments.first { $0.hasPrefix("--pretty=format:") })
}

@Test("Dateiverlauf behandelt Pathspec-Sonderzeichen als wörtlichen Dateinamen")
func fileHistory_argumentsUseLiteralPathspecs() {
    let path = ":(glob)quelle/[abc]?*.4dm"
    let args = GitFileHistory.arguments(relativePath: path)
    #expect(args.first == "--literal-pathspecs")
    #expect(args.last == path)
}

@Test("Dateiverlauf zeigt nicht alle Branches")
func fileHistory_argumentsWithoutAll() {
    // `--all` würde jede Fassung in jedem Branch mischen. Gefragt ist die
    // Historie, die zum aktuellen Stand der Datei führt.
    #expect(!GitFileHistory.arguments(relativePath: "a.txt").contains("--all"))
}

@Test("Dateiverlauf deckelt die Commit-Zahl")
func fileHistory_argumentsLimit() {
    #expect(GitFileHistory.arguments(relativePath: "a.txt", limit: 42).contains("-42"))
}

@Test("Pfad mit Leerzeichen bleibt ein einzelnes Argument")
func fileHistory_argumentsKeepSpacesIntact() {
    let args = GitFileHistory.arguments(relativePath: "mein ordner/meine datei.txt")
    #expect(args.last == "mein ordner/meine datei.txt")
}

// MARK: - Relativer Pfad

@Test("Relativer Pfad: Datei im Projekt")
func relativePath_insideProject() throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let file = base.appendingPathComponent("sub/datei.txt")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try "x".write(to: file, atomically: true, encoding: .utf8)
    #expect(GitFileHistory.relativePath(of: file, in: base) == "sub/datei.txt")
}

@Test("Relativer Pfad: Datei außerhalb des Projekts ist nil")
func relativePath_outsideProject() throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let inside = base.appendingPathComponent("projekt")
    let outside = base.appendingPathComponent("woanders/datei.txt")
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try "x".write(to: outside, atomically: true, encoding: .utf8)
    #expect(GitFileHistory.relativePath(of: outside, in: inside) == nil)
}

@Test("Relativer Pfad: die Projektwurzel selbst ist kein Dateipfad")
func relativePath_rootItself() throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(GitFileHistory.relativePath(of: base, in: base) == nil)
}

@Test("Relativer Pfad: Nachbarordner mit gleichem Namensanfang zählt nicht dazu")
func relativePath_siblingWithSharedPrefix() throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    // „projekt-alt" beginnt mit demselben Text wie „projekt". Ohne den
    // trennenden Schrägstrich im Vergleich gälte die Datei als drinnen.
    let project = base.appendingPathComponent("projekt")
    let sibling = base.appendingPathComponent("projekt-alt")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    let file = sibling.appendingPathComponent("datei.txt")
    try "x".write(to: file, atomically: true, encoding: .utf8)
    #expect(GitFileHistory.relativePath(of: file, in: project) == nil)
}

@Test("Relativer Pfad: Projekt über einen Symlink erreicht")
func relativePath_throughSymlink() throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let project = base.appendingPathComponent("projekt")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let file = project.appendingPathComponent("datei.txt")
    try "x".write(to: file, atomically: true, encoding: .utf8)
    let link = base.appendingPathComponent("verweis")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
    // Beide Seiten werden aufgelöst — die Datei liegt drin, egal über welchen
    // Weg das Projekt geöffnet wurde. Der zweite Fall ist der echte: Wer den
    // Verweis als Projekt öffnet, bekommt Dateipfade unter dem Verweis.
    #expect(GitFileHistory.relativePath(of: link.appendingPathComponent("datei.txt"),
                                        in: project) == "datei.txt")
    #expect(GitFileHistory.relativePath(of: file, in: link) == "datei.txt")
    #expect(GitFileHistory.relativePath(of: link.appendingPathComponent("datei.txt"),
                                        in: link) == "datei.txt")
}

@Test("Verlaufs-Filter zeigt nur den Dateinamen an")
func historyFile_nameIsLastComponent() {
    #expect(GitHistoryFile(relativePath: "app/Sources/Fastra/Workspace.swift").name
            == "Workspace.swift")
}

// MARK: - Einspuriges Layout

@Test("Dateiverlauf liegt in einer einzigen Spalte")
func fileHistoryLayout_singleLane() {
    // Ohne Elternteil in der Liste (typisch für eine gefilterte Historie)
    // würde der normale Lane-Algorithmus für JEDEN Commit eine neue Spalte
    // öffnen. Genau das darf hier nicht passieren.
    let commits = GitGraph.parse(rawLog([
        (h: "c3", p: "weg1", s: "dritte Änderung"),
        (h: "c2", p: "weg2", s: "zweite Änderung"),
        (h: "c1", p: "", s: "angelegt"),
    ]))
    let layout = GitFileHistory.layout(commits, headOID: "c3")
    #expect(layout.laneCount == 1)
    #expect(layout.rows.map(\.column) == [0, 0, 0])
    #expect(layout.rows.allSatisfy { $0.colorIndex == 0 })
    #expect(layout.rows.allSatisfy { $0.lines.allSatisfy { $0.fromColumn == 0 && $0.toColumn == 0 } })
}

@Test("Dateiverlauf verbindet die Zeilen durchgehend")
func fileHistoryLayout_connectsRows() {
    let commits = GitGraph.parse(rawLog([
        (h: "c3", p: "c2", s: "c"),
        (h: "c2", p: "c1", s: "b"),
        (h: "c1", p: "", s: "a"),
    ]))
    let rows = GitFileHistory.layout(commits).rows
    // Erste Zeile: nur nach unten. Mittlere: beides. Letzte: nur nach oben.
    #expect(rows[0].lines.map(\.kind) == [.outgoing])
    #expect(rows[1].lines.map(\.kind) == [.incoming, .outgoing])
    #expect(rows[2].lines.map(\.kind) == [.incoming])
}

@Test("Dateiverlauf: einzelner Commit bekommt keine Verbindungslinie")
func fileHistoryLayout_singleCommit() {
    let commits = GitGraph.parse(rawLog([(h: "c1", p: "", s: "a")]))
    let rows = GitFileHistory.layout(commits).rows
    #expect(rows.count == 1)
    #expect(rows[0].lines.isEmpty)
}

@Test("Dateiverlauf markiert HEAD nur, wenn er wirklich vorkommt")
func fileHistoryLayout_headMarker() {
    let commits = GitGraph.parse(rawLog([
        (h: "c2", p: "c1", s: "b"),
        (h: "c1", p: "", s: "a"),
    ]))
    #expect(GitFileHistory.layout(commits, headOID: "c2").rows.map(\.isHEAD) == [true, false])
    // HEAD hat diese Datei nie angefasst → keine Zeile trägt die Markierung.
    #expect(GitFileHistory.layout(commits, headOID: "fremd").rows.allSatisfy { !$0.isHEAD })
}

@Test("Dateiverlauf: leere Liste ergibt leeres Layout mit einer Spalte")
func fileHistoryLayout_empty() {
    let layout = GitFileHistory.layout([])
    #expect(layout.rows.isEmpty)
    #expect(layout.laneCount == 1)
}

@Test("Fehlgeschlagener Dateiverlauf verbirgt alte Zeilen für die echte Fehlermeldung")
func fileHistory_failedRefreshHidesStaleCommits() {
    let commits = GitGraph.parse(rawLog([(h: "c1", p: "", s: "alt")]))
    #expect(GitFileHistory.commitsForDisplay(commits, state: .loading) == commits)
    #expect(GitFileHistory.commitsForDisplay(commits, state: .idle) == commits)
    #expect(GitFileHistory.commitsForDisplay(
        commits, state: .failed("echte git-Meldung")
    ).isEmpty)
}

@Test("Fehlgeschlagener Dateiverlauf behält den Aufklappzustand für den Retry")
func fileHistory_failedRefreshKeepsExpandedCommits() {
    let commits = GitGraph.parse(rawLog([(h: "c1", p: "", s: "alt")]))
    let expanded: Set<String> = ["c1", "nicht-mehr-geladen"]

    #expect(GitFileHistory.reconciledExpandedCommits(
        expanded, commits: commits, state: .failed("git fehlgeschlagen")
    ) == expanded)
    #expect(GitFileHistory.reconciledExpandedCommits(
        expanded, commits: commits, state: .idle
    ) == ["c1"])
}

// MARK: - Hilfsfunktion

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-filehistory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Zustand im Workspace

@MainActor
@Test("Ohne Projekt gibt es keinen Dateiverlauf")
func workspace_historyNeedsProject() {
    let suite = "fastra-filehistory-\(UUID().uuidString)"
    let ws = Workspace(defaults: testSuiteDefaults(named: suite))
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    #expect(!ws.canShowGitHistory(for: URL(fileURLWithPath: "/tmp/datei.txt")))
    #expect(ws.gitHistoryFile == nil)
    #expect(ws.sidebarMode == .files)
}

@MainActor
@Test("Zurück zur ganzen Historie räumt den Dateiverlauf vollständig ab")
func workspace_clearHistoryFile() {
    let suite = "fastra-filehistory-\(UUID().uuidString)"
    let ws = Workspace(defaults: testSuiteDefaults(named: suite))
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    ws.gitHistoryFile = GitHistoryFile(relativePath: "sub/datei.txt")
    ws.gitFileHistory = GitGraph.parse(rawLog([(h: "c1", p: "", s: "a")]))
    ws.gitFileHistoryState = .loading
    ws.gitGraphExpandedCommits = ["c1"]

    ws.clearGitHistoryFile()

    #expect(ws.gitHistoryFile == nil)
    #expect(ws.gitFileHistory.isEmpty)
    #expect(ws.gitFileHistoryState == .idle)
    // Der Aufklappzustand gehörte zur verlassenen Liste — die ganze Historie
    // zeigt andere Commits.
    #expect(ws.gitGraphExpandedCommits.isEmpty)
}
